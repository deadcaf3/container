//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

@preconcurrency import AccessoryAccess
import AppKit
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import IOKit
import Logging

/// The API server's mach service, where the shared broker checks in its endpoint.
let apiServerService = "com.apple.container.apiserver"
/// Must match `XPCRoute.usbBrokerCheckIn` and `XPCKeys.usbBrokerEndpoint`.
let checkInRoute = "usbBrokerCheckIn"
let endpointKey = "usbBrokerEndpoint"
/// Must match `USBBrokerRoutes` and the `XPCKeys` of the same names.
let listRoute = "com.apple.container.usb-broker/list"
let registerRoute = "com.apple.container.usb-broker/register"
let unregisterRoute = "com.apple.container.usb-broker/unregister"
let updateFiltersRoute = "com.apple.container.usb-broker/updateFilters"
let releasedRoute = "com.apple.container.usb-broker/released"
let devicesKey = "usbDevices"
let idKey = "id"
let filtersKey = "usbFilters"
let runtimeServiceKey = "usbRuntimeService"
let runtimePIDKey = "usbRuntimePID"
let registryIDKey = "usbRegistryID"

/// One broker for every container.
///
/// An app launched by LaunchServices cannot check in a launchd mach service, and a broker that
/// launchd starts is a background service that is never offered a device. So this broker serves
/// an anonymous XPC listener and checks its endpoint in with the API server, which hands it to
/// whoever needs the broker. It quits once it has been idle for `idleTimeout`.
///
/// Runtimes register their container, mach service, pid and filters. Each held device goes to
/// the earliest registered runtime whose filters match it; a device a runtime releases goes to
/// the next match, never straight back.
///
/// A device a VM gives up re-enumerates: AccessoryAccess withdraws its accessory and, since the
/// assignment persists, offers the same device again as a new accessory a few hundred
/// milliseconds later. A second representation of the withdrawn accessory is useless (the
/// receiving runtime cannot rebuild it), so a released device waits for its new accessory.
@available(macOS 27, *)
final class SharedBroker: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    static let idleTimeout: Duration = .seconds(60)
    /// How long a released device may take to come back as a new accessory before the old one
    /// is offered again, for a device that does not re-enumerate.
    static let reenumerationTimeout: Duration = .seconds(2)
    /// How long a release is remembered, so a device unplugged after its release and plugged
    /// in much later is offered as a new device.
    static let releaseLifetime: Duration = .seconds(10)

    private struct Held {
        var accessory: AAUSBAccessory
        var vendorID: UInt16
        var productID: UInt16
        var serialNumber: String?
        var product: String?
        /// The container whose runtime holds the device, if any.
        var owner: String?
    }

    /// A runtime that receives devices matching `filters` on its mach service.
    private struct Registration {
        var filters: [USBDeviceFilter]
        var client: XPCClient
        var pid: pid_t
        var exit: DispatchSourceProcess
        /// Registration order; the earliest matching registration gets a device.
        var order: Int
    }

    /// A device a container gave up, waiting to come back as a new accessory.
    private struct Release {
        var vendorID: UInt16
        var productID: UInt16
        var serialNumber: String?
        /// The container that gave it up; the new accessory goes to the next match.
        var containerID: String
        var at: ContinuousClock.Instant
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var held: [UInt64: Held] = [:]
    /// Keyed by the registry ID of the accessory that was released.
    private var releases: [UInt64: Release] = [:]
    private var registrations: [String: Registration] = [:]
    private var nextOrder = 0
    private var lastRequest = ContinuousClock.now

    private nonisolated(unsafe) let listener = xpc_connection_create(nil, nil)
    private nonisolated(unsafe) var apiServer: xpc_connection_t?

    func start() {
        let server = XPCServer(
            connection: listener,
            routes: [
                listRoute: XPCServer.route(list),
                registerRoute: XPCServer.route(register),
                unregisterRoute: XPCServer.route(unregister),
                updateFiltersRoute: XPCServer.route(updateFilters),
                releasedRoute: XPCServer.route(released),
            ],
            log: Logging.Logger(label: "com.apple.container.usb-broker")
        )
        Task {
            do {
                try await server.listen()
            } catch {
                logger.error("broker listener failed: \(error, privacy: .public)")
            }
        }
        checkIn()
        watchIdle()
    }

    func register() {
        // Empty criteria, as for the per-container broker.
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [self] connected, error in
            if let error {
                logger.error("registerListener failed: \(error, privacy: .public)")
                return
            }
            logger.info("listener registered; \(connected.count) device(s) already assigned")
            connected.forEach(hold)
        }
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        hold(usbAccessory)
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        let registryID = usbAccessory.registryID
        let owner: XPCClient? = lock.withLock {
            guard let device = held.removeValue(forKey: registryID), let owner = device.owner else {
                return nil
            }
            return registrations[owner]?.client
        }
        logger.info("device withdrawn: \(String(format: "0x%llx", registryID), privacy: .public)")
        // Tell the owner so `container usb ls` shows the device as unassigned.
        if let owner {
            let message = XPCMessage(route: usbAccessoryWithdrawnRoute)
            message.set(key: registryIDKey, value: registryID)
            Task {
                _ = try? await owner.send(message, responseTimeout: .seconds(10))
            }
        }
    }

    private func hold(_ accessory: AAUSBAccessory) {
        let bytes = [UInt8](accessory.deviceDescriptorData)
        guard bytes.count >= 12 else {
            return
        }
        let vendorID = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        let productID = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
        let device = Held(
            accessory: accessory,
            vendorID: vendorID,
            productID: productID,
            serialNumber: Self.registryString(accessory.registryID, "USB Serial Number"),
            product: Self.registryString(accessory.registryID, "USB Product Name")
        )
        let (isNew, release): (Bool, Release?) = lock.withLock {
            guard held[accessory.registryID] == nil else {
                return (false, nil)
            }
            held[accessory.registryID] = device
            // The same device coming back after a container released it.
            let now = ContinuousClock.now
            releases = releases.filter { now - $0.value.at < Self.releaseLifetime }
            let match = releases.first { _, release in
                release.vendorID == vendorID && release.productID == productID && release.serialNumber == device.serialNumber
            }
            if let match {
                releases.removeValue(forKey: match.key)
            }
            return (true, match?.value)
        }
        guard isNew else {
            return
        }
        let ids = String(format: "%04x:%04x", vendorID, productID)
        if let release {
            logger.info("holding \(ids, privacy: .public), back after \(release.containerID, privacy: .public) released it")
        } else {
            logger.info("holding \(ids, privacy: .public)")
        }
        Task { await offer(accessory.registryID, excluding: release?.containerID) }
    }

    /// Frees a device `containerID` gave up and waits for it to come back as a new accessory,
    /// which then goes to the next match. Offers the old accessory again if the device has not
    /// re-enumerated within `reenumerationTimeout`.
    private func awaitReenumeration(of registryID: UInt64, releasedBy containerID: String) {
        lock.withLock {
            guard let device = held[registryID] else {
                return
            }
            releases[registryID] = Release(
                vendorID: device.vendorID, productID: device.productID, serialNumber: device.serialNumber, containerID: containerID, at: .now)
        }
        Task { [self] in
            try? await Task.sleep(for: Self.reenumerationTimeout)
            let stillHere = lock.withLock {
                guard held[registryID] != nil, releases.removeValue(forKey: registryID) != nil else {
                    return false
                }
                return true
            }
            if stillHere {
                logger.info("\(String(format: "0x%llx", registryID), privacy: .public) did not re-enumerate; offering it again")
                await offer(registryID, excluding: containerID)
            }
        }
    }

    /// Sends a free device to the earliest registered runtime, other than `excluded`, whose
    /// filters match it, and returns once the runtime answered. The device counts as owned from
    /// the moment it is sent, so concurrent offers never send it twice; it is free again if the
    /// runtime does not take it.
    private func offer(_ registryID: UInt64, excluding excluded: String? = nil) async {
        let target: (containerID: String, client: XPCClient, accessory: AAUSBAccessory, ids: String)? = lock.withLock {
            guard let device = held[registryID], device.owner == nil else {
                return nil
            }
            let candidates = registrations.filter { containerID, registration in
                containerID != excluded
                    && registration.filters.contains {
                        $0.matches(vendorID: device.vendorID, productID: device.productID, serialNumber: device.serialNumber)
                    }
            }
            guard let (containerID, registration) = candidates.min(by: { $0.value.order < $1.value.order }) else {
                return nil
            }
            held[registryID]?.owner = containerID
            return (containerID, registration.client, device.accessory, String(format: "%04x:%04x", device.vendorID, device.productID))
        }
        guard let target else {
            return
        }

        let ids = target.ids
        let message = XPCMessage(route: usbAccessoryRoute)
        message.set(key: "accessory", xpcDictionary: target.accessory.createXPCRepresentation())
        logger.info("forwarding \(ids, privacy: .public) to container \(target.containerID, privacy: .public)")
        do {
            let reply = try await target.client.send(message, responseTimeout: .seconds(30))
            let result = reply.string(key: "result") ?? ""
            logger.info("runtime \(target.containerID, privacy: .public): \(result, privacy: .public)")
            if !result.hasPrefix("attaching") {
                free(registryID, heldBy: target.containerID)
            }
        } catch {
            logger.error("forwarding \(ids, privacy: .public) failed: \(error, privacy: .public)")
            free(registryID, heldBy: target.containerID)
        }
    }

    /// Clears the owner of `registryID` if it is still `containerID`. Returns whether it was.
    @discardableResult
    private func free(_ registryID: UInt64, heldBy containerID: String) -> Bool {
        lock.withLock {
            guard held[registryID]?.owner == containerID else {
                return false
            }
            held[registryID]?.owner = nil
            return true
        }
    }

    /// Offers every free device to the registered runtimes, except released ones still waiting
    /// to come back as new accessories.
    private func offerFree() async {
        let free = lock.withLock { held.filter { $0.value.owner == nil && releases[$0.key] == nil }.map(\.key) }
        for registryID in free {
            await offer(registryID)
        }
    }

    // MARK: Routes

    @Sendable
    private func list(_ message: XPCMessage) async throws -> XPCMessage {
        let devices = lock.withLock {
            lastRequest = .now
            return held.map { registryID, device in
                USBDeviceState(
                    registryID: registryID,
                    vendorID: device.vendorID,
                    productID: device.productID,
                    serialNumber: device.serialNumber,
                    product: device.product,
                    containerID: device.owner ?? "",
                    status: device.owner != nil ? .attached : .assigned
                )
            }
            .sorted { ($0.ids, $0.registryID) < ($1.ids, $1.registryID) }
        }
        let reply = message.reply()
        reply.set(key: devicesKey, value: try JSONEncoder().encode(devices))
        return reply
    }

    @Sendable
    private func register(_ message: XPCMessage) async throws -> XPCMessage {
        let containerID = try Self.containerID(message)
        guard let service = message.string(key: runtimeServiceKey) else {
            throw ContainerizationError(.invalidArgument, message: "missing runtime service")
        }
        let pid = pid_t(message.int64(key: runtimePIDKey))
        guard pid > 0 else {
            throw ContainerizationError(.invalidArgument, message: "missing runtime pid")
        }
        let filters = try Self.filters(message)

        // Drop the registration when the runtime exits, so a crashed container never keeps the
        // broker running or holds devices.
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [self] in
            logger.info("runtime \(pid, privacy: .public) of container \(containerID, privacy: .public) exited")
            Task { await drop(containerID, pid: pid) }
        }
        let previous = lock.withLock {
            lastRequest = .now
            let previous = registrations[containerID]
            registrations[containerID] = Registration(
                filters: filters, client: XPCClient(service: service), pid: pid, exit: exit, order: previous?.order ?? nextOrder)
            nextOrder += 1
            return previous
        }
        previous?.exit.cancel()
        exit.resume()
        logger.info("registered container \(containerID, privacy: .public): \(filters, privacy: .public)")
        // The runtime may have exited before the source was armed.
        if kill(pid, 0) != 0 && errno == ESRCH {
            await drop(containerID, pid: pid)
        } else {
            await offerFree()
        }
        return message.reply()
    }

    @Sendable
    private func unregister(_ message: XPCMessage) async throws -> XPCMessage {
        let containerID = try Self.containerID(message)
        lock.withLock { lastRequest = .now }
        await drop(containerID)
        return message.reply()
    }

    @Sendable
    private func updateFilters(_ message: XPCMessage) async throws -> XPCMessage {
        let containerID = try Self.containerID(message)
        let filters = try Self.filters(message)
        let registered = lock.withLock {
            lastRequest = .now
            guard registrations[containerID] != nil else {
                return false
            }
            registrations[containerID]?.filters = filters
            return true
        }
        guard registered else {
            throw ContainerizationError(.notFound, message: "container \(containerID) is not registered with the USB broker")
        }
        logger.info("container \(containerID, privacy: .public) filters: \(filters, privacy: .public)")
        // Replies once the runtime answered, so `usb attach` can report the devices sent.
        await offerFree()
        return message.reply()
    }

    @Sendable
    private func released(_ message: XPCMessage) async throws -> XPCMessage {
        let containerID = try Self.containerID(message)
        let registryID = message.uint64(key: registryIDKey)
        lock.withLock { lastRequest = .now }
        if free(registryID, heldBy: containerID) {
            logger.info("container \(containerID, privacy: .public) released \(String(format: "0x%llx", registryID), privacy: .public)")
            // Never straight back to the container that gave it up.
            awaitReenumeration(of: registryID, releasedBy: containerID)
        }
        return message.reply()
    }

    /// Removes the registration of `containerID` (only if it is still the one from `pid`, when
    /// given) and frees the devices it held.
    private func drop(_ containerID: String, pid: pid_t? = nil) async {
        let freed: [UInt64]? = lock.withLock {
            guard let registration = registrations[containerID], pid == nil || registration.pid == pid else {
                return nil
            }
            registrations.removeValue(forKey: containerID)
            registration.exit.cancel()
            let owned = held.filter { $0.value.owner == containerID }.map(\.key)
            for registryID in owned {
                held[registryID]?.owner = nil
            }
            return owned
        }
        guard let freed else {
            return
        }
        logger.info("unregistered container \(containerID, privacy: .public)")
        // Its VM let the devices go, or is about to; they come back as new accessories.
        for registryID in freed {
            awaitReenumeration(of: registryID, releasedBy: containerID)
        }
    }

    private static func containerID(_ message: XPCMessage) throws -> String {
        guard let containerID = message.string(key: idKey), !containerID.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "missing container ID")
        }
        return containerID
    }

    private static func filters(_ message: XPCMessage) throws -> [USBDeviceFilter] {
        guard let data = message.dataNoCopy(key: filtersKey) else {
            throw ContainerizationError(.invalidArgument, message: "missing USB device filters")
        }
        return try JSONDecoder().decode([USBDeviceFilter].self, from: data)
    }

    // MARK: Lifetime

    /// Hands the listener's endpoint to the API server. Checks in again when the API server
    /// restarts, and quits when it is gone for good.
    private func checkIn() {
        // Only used on the main queue, which runs its event handler.
        nonisolated(unsafe) let connection = xpc_connection_create_mach_service(apiServerService, .main, 0)
        xpc_connection_set_event_handler(connection) { [self] event in
            if xpc_equal(event, XPC_ERROR_CONNECTION_INTERRUPTED) {
                logger.info("API server restarted; checking in again")
                sendCheckIn(on: connection)
            }
        }
        xpc_connection_activate(connection)
        apiServer = connection
        sendCheckIn(on: connection)
    }

    private func sendCheckIn(on connection: xpc_connection_t) {
        let message = XPCMessage(route: checkInRoute)
        message.set(key: endpointKey, value: xpc_endpoint_create(listener))
        xpc_connection_send_message_with_reply(connection, message.underlying, .main) { reply in
            if xpc_equal(reply, XPC_ERROR_CONNECTION_INVALID) {
                logger.info("API server is gone; quitting")
                Self.quit()
                return
            }
            if let error = XPCMessage(object: reply).errorKeyDescription() {
                logger.error("check-in refused: \(error, privacy: .public)")
            } else {
                logger.info("checked in with the API server")
            }
        }
    }

    /// Quits after `idleTimeout` without a request while no runtime is registered.
    private func watchIdle() {
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [self] _ in
            let idle = lock.withLock { registrations.isEmpty && ContinuousClock.now - lastRequest > Self.idleTimeout }
            if idle {
                logger.info("idle; quitting")
                Self.quit()
            }
        }
    }

    /// Terminates the app. Call on the main queue, where the check-in replies and the idle timer run.
    private static func quit() {
        MainActor.assumeIsolated {
            NSApplication.shared.terminate(nil)
        }
    }

    /// A string property of the IORegistry entry `registryID`, or nil when it is missing or empty.
    private static func registryString(_ registryID: UInt64, _ key: String) -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard entry != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        return text
    }
}
