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
    /// Detaches every passed-through device and quits the broker.
    func teardown() async
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

    private let filters: [USBDeviceFilter]
    private let containerID: String
    private let brokerURL: URL
    private let log: Logger
    private let lock = NSLock()

    // Guarded by `lock`.
    private var instance: VZVirtualMachineInstance?
    private var started = false
    private var broker: NSRunningApplication?
    private var attached: [UInt64: (device: VZUSBPassthroughDevice, vendorID: UInt16, productID: UInt16)] = [:]
    private var inFlight: Set<UInt64> = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

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
        var arguments = ["--service", service, "--container", containerID]
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
        return receive(accessory)
    }

    func teardown() async {
        let (instance, broker, waiting) = lock.withLock {
            defer {
                started = false
                self.broker = nil
                waiters.removeAll()
            }
            return (self.instance, self.broker, Array(waiters.values))
        }
        waiting.forEach { $0.resume(returning: false) }

        if let instance {
            await detachAll(from: instance)
        }
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
        guard filters.contains(where: { $0.matches(vendorID: vendorID, productID: productID) }) else {
            log.info("usb: accessory does not match --usb, ignoring", metadata: ["registryID": "\(registryID)", "ids": "\(ids)"])
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

        log.info("usb: attaching", metadata: ["registryID": "\(registryID)", "ids": "\(ids)"])
        instance.vmQueue.async { [self] in
            guard let controller = instance.vzVirtualMachine.usbControllers.first else {
                finishAttach(accessory.registryID, nil, vendorID, productID, error: "the VM has no USB controller")
                return
            }
            let device: VZUSBPassthroughDevice
            do {
                device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
            } catch {
                finishAttach(accessory.registryID, nil, vendorID, productID, error: "\(error)")
                return
            }
            controller.attach(device: device) { error in
                self.finishAttach(accessory.registryID, error == nil ? device : nil, vendorID, productID, error: error.map { "\($0)" })
            }
        }
        return "attaching \(ids)"
    }

    private func finishAttach(_ registryID: UInt64, _ device: VZUSBPassthroughDevice?, _ vendorID: UInt16, _ productID: UInt16, error: String?) {
        let ready: [CheckedContinuation<Bool, Never>] = lock.withLock {
            inFlight.remove(registryID)
            guard let device else {
                return []
            }
            attached[registryID] = (device, vendorID, productID)
            guard isSatisfied() else {
                return []
            }
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        let ids = String(format: "%04x:%04x", vendorID, productID)
        if let error {
            // Most often another container already holds the device.
            log.warning("usb: attach failed", metadata: ["registryID": "\(Self.hex(registryID))", "ids": "\(ids)", "error": "\(error)"])
        } else {
            log.info("usb: attached, device is now captured by the VM", metadata: ["registryID": "\(Self.hex(registryID))", "ids": "\(ids)"])
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

    /// Must be called with `lock` held.
    private func isSatisfied() -> Bool {
        filters.allSatisfy { filter in
            attached.values.contains { filter.matches(vendorID: $0.vendorID, productID: $0.productID) }
        }
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
