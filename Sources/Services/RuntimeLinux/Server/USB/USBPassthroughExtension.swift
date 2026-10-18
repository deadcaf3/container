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
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import IOKit
import Logging
@preconcurrency import Virtualization

/// The runtime's handle on USB passthrough, independent of OS availability so it can be stored
/// by code that also runs on older systems.
protocol USBPassthroughControl: Sendable {
    /// Launches the USB broker for this container. Call once the VM is running.
    func start() throws
    /// Returns true once every requested device has attached, or false after `timeout`.
    func waitForRequested(timeout: Duration) async -> Bool
    /// Attaches an accessory forwarded by the broker. Returns a short status for the broker.
    func receive(xpcRepresentation: xpc_object_t) -> String
    /// IDs (`vvvv:pppp`, or `vvvv:pppp:serial` when the device reports a serial number) of
    /// devices assigned in the menu that match no `--usb` filter.
    func unrequestedDevices() -> [String]
    /// Detaches every passed-through device and quits the broker.
    func teardown() async

    /// Every device the broker has reported, with its current state.
    func devices() -> [USBDeviceState]
    /// Adds `filter` and attaches any assigned device that matches. Returns a message for the user.
    func attach(_ filter: USBDeviceFilter) async throws -> String
    /// Detaches the attached devices matching `filter` and drops the filter. Returns a message for the user.
    func detach(_ filter: USBDeviceFilter) async throws -> String
    /// Records that the broker lost the device (withdrawn in the menu or unplugged).
    func withdraw(registryID: UInt64)
}

/// Passes physical USB devices through to a container's VM.
///
/// AccessoryAccess only assigns devices to an ordinary, Dock-visible application, and this
/// runtime is a launchd service, so it cannot receive devices itself. It launches the
/// provisioned `container-usb` broker app, which receives devices assigned from the Virtual
/// Machine Accessories menu and forwards matching ones here as XPC representations. This
/// process needs no restricted entitlement to rebuild and attach them.
@available(macOS 27, *)
final class USBPassthroughExtension: NSObject, VZInstanceExtension, USBPassthroughControl, VZUSBController.Delegate, @unchecked Sendable {
    static let brokerPath = "libexec/container/usb/container-usb.app"

    /// The `--usb` filters plus any added by `container usb attach`. Mutated only under `lock`.
    private var filters: [USBDeviceFilter]
    private let containerID: String
    private let brokerURL: URL
    private let log: Logger
    private let lock = NSLock()

    // Guarded by `lock`.
    private var instance: VZVirtualMachineInstance?
    private var started = false
    private var broker: NSRunningApplication?
    /// The registration with the shared broker, when this container uses it instead of `broker`.
    private var brokerSession: USBBrokerSession?
    private var attached: [UInt64: (device: VZUSBPassthroughDevice, vendorID: UInt16, productID: UInt16, serialNumber: String?)] = [:]
    private var inFlight: Set<UInt64> = []
    private var unrequested: Set<String> = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Every accessory the broker has forwarded, keyed by registry ID, for `usb ls` and later attaches.
    private var known: [UInt64: KnownAccessory] = [:]

    private struct KnownAccessory {
        var accessory: AAUSBAccessory
        var vendorID: UInt16
        var productID: UInt16
        var serialNumber: String?
        var product: String?
        /// False once the broker reports the device withdrawn or unplugged.
        var assigned = true
    }

    init(filters: [USBDeviceFilter], containerID: String, log: Logger) throws {
        guard let installRoot = ProcessInfo.processInfo.environment["CONTAINER_INSTALL_ROOT"], !installRoot.isEmpty else {
            throw ContainerizationError(.invalidState, message: "CONTAINER_INSTALL_ROOT is not set; cannot locate the USB broker")
        }
        let brokerURL = URL(fileURLWithPath: installRoot).appendingPathComponent(Self.brokerPath)
        guard FileManager.default.fileExists(atPath: brokerURL.path) else {
            throw ContainerizationError(
                .notFound,
                message: "USB broker not found at \(brokerURL.path); build with USB_BUNDLE_ID and USB_PROFILE (see docs/usb-passthrough.md)"
            )
        }
        self.filters = filters
        self.containerID = containerID
        self.brokerURL = brokerURL
        self.log = log
    }

    // MARK: VZInstanceExtension

    func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Mount]]
    ) throws {
        if config.usbControllers.isEmpty {
            config.usbControllers = [VZXHCIControllerConfiguration()]
        }
    }

    func didCreate(_ instance: VZVirtualMachineInstance) throws {
        lock.withLock { self.instance = instance }
        instance.vmQueue.async {
            instance.vzVirtualMachine.usbControllers.first?.delegate = self
        }
    }

    func willStop(_ instance: VZVirtualMachineInstance) async throws {
        await teardown()
    }

    // MARK: USBPassthroughControl

    func start() throws {
        let first = lock.withLock {
            defer { started = true }
            return !started
        }
        guard first else {
            return
        }

        // The broker reaches this runtime on its mach service, which clients derive from the
        // plugin name and container ID.
        let plugin = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        let service = "com.apple.container.runtime.\(plugin).\(containerID)"
        var arguments = ["--service", service, "--container", containerID, "--runtime-pid", "\(getpid())"]
        for filter in filters {
            arguments += ["--usb", filter.description]
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = arguments

        log.info("usb: launching broker", metadata: ["broker": "\(brokerURL.path)", "filters": "\(filters)"])
        NSWorkspace.shared.openApplication(at: brokerURL, configuration: configuration) { [self] application, error in
            if let error {
                log.error("usb: broker failed to launch", metadata: ["error": "\(error)"])
                return
            }
            guard let application else {
                return
            }
            let stillWanted = lock.withLock {
                if started {
                    broker = application
                }
                return started
            }
            if stillWanted {
                log.info("usb: broker running", metadata: ["pid": "\(application.processIdentifier)"])
            } else {
                application.terminate()
            }
        }
    }

    func waitForRequested(timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let satisfied = lock.withLock {
                if isSatisfied() {
                    return true
                }
                waiters[id] = continuation
                return false
            }
            if satisfied {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                if let waiter = self.lock.withLock({ self.waiters.removeValue(forKey: id) }) {
                    waiter.resume(returning: false)
                }
            }
        }
    }

    func receive(xpcRepresentation: xpc_object_t) -> String {
        guard let accessory = AAUSBAccessory(xpcRepresentation: xpcRepresentation) else {
            log.warning("usb: broker sent an invalid accessory representation")
            return "rejected: invalid accessory representation"
        }
        remember(accessory)
        return receive(accessory)
    }

    func unrequestedDevices() -> [String] {
        lock.withLock { unrequested.sorted() }
    }

    // MARK: Devices as a resource (container usb ls / attach / detach)

    func devices() -> [USBDeviceState] {
        lock.withLock {
            known.map { registryID, device in
                USBDeviceState(
                    registryID: registryID,
                    vendorID: device.vendorID,
                    productID: device.productID,
                    serialNumber: device.serialNumber,
                    product: device.product,
                    containerID: containerID,
                    status: attached[registryID] != nil ? .attached : device.assigned ? .assigned : .unassigned
                )
            }
            .sorted { ($0.ids, $0.registryID) < ($1.ids, $1.registryID) }
        }
    }

    func attach(_ filter: USBDeviceFilter) async throws -> String {
        enum Plan {
            case alreadyRequested(USBDeviceFilter)
            case attach([AAUSBAccessory])
        }
        let plan: Plan = lock.withLock {
            if let existing = filters.first(where: { $0.covers(filter) }) {
                return .alreadyRequested(existing)
            }
            filters.append(filter)
            let candidates = known.filter { registryID, device in
                device.assigned && attached[registryID] == nil
                    && filter.matches(vendorID: device.vendorID, productID: device.productID, serialNumber: device.serialNumber)
            }
            return .attach(candidates.values.map(\.accessory))
        }

        switch plan {
        case .alreadyRequested(let existing):
            return "\(containerID) already requests \(existing); nothing to do"
        case .attach(let candidates):
            log.info("usb: filter added", metadata: ["filter": "\(filter)", "candidates": "\(candidates.count)"])
            await updateBrokerFilters()
            var attachedIDs: [String] = []
            var failed: [String] = []
            for accessory in candidates {
                // The broker's path does the matching, attach and bookkeeping; the filter now covers it.
                _ = receive(accessory)
                let ids = lock.withLock { known[accessory.registryID].map { String(format: "%04x:%04x", $0.vendorID, $0.productID) } } ?? "\(filter)"
                if await settled(accessory.registryID) {
                    attachedIDs.append(ids)
                } else {
                    failed.append(ids)
                }
            }
            var message = "\(containerID) now requests \(filter)"
            if !attachedIDs.isEmpty {
                message += "; attached \(attachedIDs.joined(separator: ", "))"
            }
            if !failed.isEmpty {
                message += "; attach of \(failed.joined(separator: ", ")) failed, see `container system logs`"
            }
            if attachedIDs.isEmpty && failed.isEmpty {
                message +=
                    "; no assigned device matches yet. Choose \"Use with container\" for it in the Virtual Machine Accessories menu bar item and it attaches on its own."
            }
            return message
        }
    }

    func detach(_ filter: USBDeviceFilter) async throws -> String {
        nonisolated(unsafe) let targets: [(registryID: UInt64, device: VZUSBPassthroughDevice, ids: String)] = lock.withLock {
            let matching = attached.filter { filter.matches(vendorID: $0.value.vendorID, productID: $0.value.productID, serialNumber: $0.value.serialNumber) }
            guard !matching.isEmpty else {
                return []
            }
            for registryID in matching.keys {
                attached.removeValue(forKey: registryID)
            }
            filters.removeAll { $0 == filter }
            return matching.map { ($0.key, $0.value.device, String(format: "%04x:%04x", $0.value.vendorID, $0.value.productID)) }
        }
        guard !targets.isEmpty else {
            throw ContainerizationError(.notFound, message: "no attached USB device matches \(filter)")
        }
        guard let instance = lock.withLock({ self.instance }) else {
            throw ContainerizationError(.invalidState, message: "the VM is not running")
        }

        var errors: [String] = []
        for target in targets {
            let error: String? = await withCheckedContinuation { continuation in
                instance.vmQueue.async {
                    guard let controller = instance.vzVirtualMachine.usbControllers.first else {
                        continuation.resume(returning: "the VM has no USB controller")
                        return
                    }
                    controller.detach(device: target.device) { error in
                        continuation.resume(returning: error.map { "\($0)" })
                    }
                }
            }
            if let error {
                log.warning("usb: detach failed", metadata: ["registryID": "\(Self.hex(target.registryID))", "ids": "\(target.ids)", "error": "\(error)"])
                errors.append("\(target.ids): \(error)")
            } else {
                log.info("usb: detached by request, device returned to macOS", metadata: ["registryID": "\(Self.hex(target.registryID))", "ids": "\(target.ids)"])
            }
        }
        await updateBrokerFilters()
        if let session = lock.withLock({ brokerSession }) {
            for target in targets {
                await session.released(registryID: target.registryID)
            }
        }
        guard errors.isEmpty else {
            throw ContainerizationError(.internalError, message: "detach failed for \(errors.joined(separator: "; "))")
        }
        return "detached \(targets.map(\.ids).joined(separator: ", ")) from \(containerID)"
    }

    func withdraw(registryID: UInt64) {
        let known = lock.withLock {
            guard self.known[registryID] != nil else {
                return false
            }
            self.known[registryID]?.assigned = false
            return true
        }
        if known {
            log.info("usb: device withdrawn by the broker", metadata: ["registryID": "\(Self.hex(registryID))"])
        }
    }

    /// Records a forwarded accessory so `usb ls` can show it and a later `usb attach` can use it.
    private func remember(_ accessory: AAUSBAccessory) {
        guard let (vendorID, productID) = Self.ids(from: accessory.deviceDescriptorData) else {
            return
        }
        let serialNumber = Self.serialNumber(registryID: accessory.registryID)
        let product = USBDeviceProperties.product(registryID: accessory.registryID)
        lock.withLock {
            known[accessory.registryID] = KnownAccessory(
                accessory: accessory, vendorID: vendorID, productID: productID, serialNumber: serialNumber, product: product)
        }
    }

    /// Waits for an attach started by `receive` to finish; true if the device ended up attached.
    private func settled(_ registryID: UInt64, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (pending, isAttached) = lock.withLock { (inFlight.contains(registryID), attached[registryID] != nil) }
            if !pending {
                return isAttached
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func teardown() async {
        let (instance, broker, session, waiting) = lock.withLock {
            defer {
                started = false
                self.broker = nil
                brokerSession = nil
                waiters.removeAll()
            }
            return (self.instance, self.broker, brokerSession, Array(waiters.values))
        }
        waiting.forEach { $0.resume(returning: false) }

        if let instance {
            await detachAll(from: instance)
        }
        await session?.unregister()
        if let broker {
            broker.terminate()
            log.info("usb: broker terminated", metadata: ["pid": "\(broker.processIdentifier)"])
        }
    }

    // MARK: VZUSBController.Delegate

    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        let removed = lock.withLock {
            let match = attached.first { $0.value.device === device }
            if let match {
                attached.removeValue(forKey: match.key)
            }
            return match
        }
        if let removed {
            log.info("usb: device unplugged, detached by the framework", metadata: ["registryID": "\(Self.hex(removed.key))"])
        }
    }

    // MARK: Attach

    private func receive(_ accessory: AAUSBAccessory) -> String {
        let registryID = Self.hex(accessory.registryID)
        guard let (vendorID, productID) = Self.ids(from: accessory.deviceDescriptorData) else {
            log.warning("usb: unparseable device descriptor, ignoring", metadata: ["registryID": "\(registryID)"])
            return "rejected: unparseable device descriptor"
        }
        let ids = String(format: "%04x:%04x", vendorID, productID)
        let serialNumber = Self.serialNumber(registryID: accessory.registryID)
        let serial = serialNumber ?? ""
        guard filters.contains(where: { $0.matches(vendorID: vendorID, productID: productID, serialNumber: serialNumber) }) else {
            log.info("usb: accessory does not match --usb, ignoring", metadata: ["registryID": "\(registryID)", "ids": "\(ids)", "serial": "\(serial)"])
            _ = lock.withLock { unrequested.insert(serial.isEmpty ? ids : ids + ":" + serial) }
            return "ignored: \(ids) not requested"
        }

        let instance: VZVirtualMachineInstance? = lock.withLock {
            guard attached[accessory.registryID] == nil, !inFlight.contains(accessory.registryID) else {
                return nil
            }
            inFlight.insert(accessory.registryID)
            return self.instance
        }
        guard let instance else {
            return "ignored: \(ids) already attached or VM not ready"
        }

        log.info("usb: attaching", metadata: ["registryID": "\(registryID)", "ids": "\(ids)", "serial": "\(serial)"])
        instance.vmQueue.async { [self] in
            guard let controller = instance.vzVirtualMachine.usbControllers.first else {
                finishAttach(accessory.registryID, nil, vendorID, productID, serialNumber, error: "the VM has no USB controller")
                return
            }
            let device: VZUSBPassthroughDevice
            do {
                device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
            } catch {
                finishAttach(accessory.registryID, nil, vendorID, productID, serialNumber, error: "\(error)")
                return
            }
            controller.attach(device: device) { error in
                self.finishAttach(accessory.registryID, error == nil ? device : nil, vendorID, productID, serialNumber, error: error.map { "\($0)" })
            }
        }
        return "attaching \(ids)"
    }

    private func finishAttach(
        _ registryID: UInt64, _ device: VZUSBPassthroughDevice?, _ vendorID: UInt16, _ productID: UInt16, _ serialNumber: String?, error: String?
    ) {
        let (ready, session): ([CheckedContinuation<Bool, Never>], USBBrokerSession?) = lock.withLock {
            inFlight.remove(registryID)
            guard let device else {
                return ([], brokerSession)
            }
            attached[registryID] = (device, vendorID, productID, serialNumber)
            guard isSatisfied() else {
                return ([], nil)
            }
            defer { waiters.removeAll() }
            return (Array(waiters.values), nil)
        }
        let ids = String(format: "%04x:%04x", vendorID, productID)
        let serial = serialNumber ?? ""
        if let error {
            // Most often another container already holds the device.
            log.warning("usb: attach failed", metadata: ["registryID": "\(Self.hex(registryID))", "ids": "\(ids)", "serial": "\(serial)", "error": "\(error)"])
            // The shared broker may hand it to another container.
            if let session {
                Task { await session.released(registryID: registryID) }
            }
        } else {
            log.info("usb: attached, device is now captured by the VM", metadata: ["registryID": "\(Self.hex(registryID))", "ids": "\(ids)", "serial": "\(serial)"])
        }
        ready.forEach { $0.resume(returning: true) }
    }

    private func detachAll(from instance: VZVirtualMachineInstance) async {
        nonisolated(unsafe) let devices = lock.withLock {
            defer { attached.removeAll() }
            return attached.values.map(\.device)
        }
        guard !devices.isEmpty else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            instance.vmQueue.async {
                guard let controller = instance.vzVirtualMachine.usbControllers.first else {
                    continuation.resume()
                    return
                }
                var remaining = devices.count
                for device in devices {
                    controller.detach(device: device) { _ in
                        remaining -= 1
                        if remaining == 0 {
                            continuation.resume()
                        }
                    }
                }
            }
        }
        log.info("usb: detached devices", metadata: ["count": "\(devices.count)"])
    }

    // MARK: Helpers

    /// Sends the current filters to the shared broker, if this container uses it.
    private func updateBrokerFilters() async {
        let (session, filters) = lock.withLock { (brokerSession, filters) }
        await session?.updateFilters(filters)
    }

    /// Must be called with `lock` held.
    private func isSatisfied() -> Bool {
        filters.allSatisfy { filter in
            attached.values.contains { filter.matches(vendorID: $0.vendorID, productID: $0.productID, serialNumber: $0.serialNumber) }
        }
    }

    /// The device's "USB Serial Number" from the IORegistry, or nil when the device reports
    /// none or has already gone. Reading the property needs no open of the device.
    private static func serialNumber(registryID: UInt64) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        guard let serial = property as? String, !serial.isEmpty else {
            return nil
        }
        return serial
    }

    private static func ids(from descriptor: Data) -> (UInt16, UInt16)? {
        let bytes = [UInt8](descriptor)
        guard bytes.count >= 12 else {
            return nil
        }
        return (UInt16(bytes[8]) | UInt16(bytes[9]) << 8, UInt16(bytes[10]) | UInt16(bytes[11]) << 8)
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%llx", value)
    }
}
