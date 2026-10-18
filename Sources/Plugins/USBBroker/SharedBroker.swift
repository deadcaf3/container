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
import Foundation
import IOKit
import Logging

/// The API server's mach service, where the shared broker checks in its endpoint.
let apiServerService = "com.apple.container.apiserver"
/// Must match `XPCRoute.usbBrokerCheckIn` and `XPCKeys.usbBrokerEndpoint`.
let checkInRoute = "usbBrokerCheckIn"
let endpointKey = "usbBrokerEndpoint"
/// Must match `USBBrokerRoutes.list` and `XPCKeys.usbDevices`.
let listRoute = "com.apple.container.usb-broker/list"
let devicesKey = "usbDevices"

/// One broker for every container (`--shared`).
///
/// An app launched by LaunchServices cannot check in a launchd mach service, and a broker that
/// launchd starts is a background service that is never offered a device. So this broker serves
/// an anonymous XPC listener and checks its endpoint in with the API server, which hands it to
/// whoever needs the broker. It quits once it has been idle for `idleTimeout`.
@available(macOS 27, *)
final class SharedBroker: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    static let idleTimeout: Duration = .seconds(60)

    private struct Held {
        var accessory: AAUSBAccessory
        var vendorID: UInt16
        var productID: UInt16
        var serialNumber: String?
        var product: String?
        /// The container whose runtime holds the device, if any.
        var owner: String?
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var held: [UInt64: Held] = [:]
    private var lastRequest = ContinuousClock.now

    private nonisolated(unsafe) let listener = xpc_connection_create(nil, nil)
    private nonisolated(unsafe) var apiServer: xpc_connection_t?

    func start() {
        let server = XPCServer(
            connection: listener,
            routes: [listRoute: XPCServer.route(list)],
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
        _ = lock.withLock { held.removeValue(forKey: usbAccessory.registryID) }
        logger.info("device withdrawn: \(String(format: "0x%llx", usbAccessory.registryID), privacy: .public)")
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
        lock.withLock { held[accessory.registryID] = device }
        logger.info("holding \(String(format: "%04x:%04x", vendorID, productID), privacy: .public)")
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

    // MARK: Lifetime

    /// Hands the listener's endpoint to the API server. Checks in again when the API server
    /// restarts, and quits when it is gone for good.
    private func checkIn() {
        let connection = xpc_connection_create_mach_service(apiServerService, .main, 0)
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
                NSApplication.shared.terminate(nil)
                return
            }
            if let error = XPCMessage(object: reply).errorKeyDescription() {
                logger.error("check-in refused: \(error, privacy: .public)")
            } else {
                logger.info("checked in with the API server")
            }
        }
    }

    /// Quits after `idleTimeout` without a request while no container holds a device.
    private func watchIdle() {
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [self] _ in
            let idle = lock.withLock { held.values.allSatisfy { $0.owner == nil } && ContinuousClock.now - lastRequest > Self.idleTimeout }
            if idle {
                logger.info("idle; quitting")
                NSApplication.shared.terminate(nil)
            }
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
