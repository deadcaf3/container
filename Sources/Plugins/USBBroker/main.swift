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

/// USB broker for `container run --usb`.
///
/// AccessoryAccess only presents its assignment UI for an ordinary, Dock-visible application
/// (AAUSBAccessoryManager.h). The runtime helper is started by launchd and is classified as a
/// background service, so it can never be offered a device. The runtime launches this app
/// instead; it receives devices assigned from the Virtual Machine Accessories menu and forwards
/// the ones matching `--usb` to the runtime as XPC representations, which the runtime attaches
/// to the container's VM.
///
///   container-usb-broker --service <runtime mach service> --container <id> --usb <vid[:pid]>...

@preconcurrency import AccessoryAccess
import AppKit
import ContainerResource
import ContainerXPC
import Foundation
import os
@preconcurrency import Virtualization

let logger = Logger(subsystem: "com.apple.container", category: "USBBroker")

/// Must match `RuntimeRoutes.usbAccessory`.
let usbAccessoryRoute = "com.apple.container.runtime/usbAccessory"

struct BrokerArguments: Sendable {
    var service: String
    var containerID: String
    var filters: [USBDeviceFilter]

    static func parse(_ arguments: [String]) -> BrokerArguments? {
        var service: String?
        var containerID: String?
        var filters: [USBDeviceFilter] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--service": service = iterator.next()
            case "--container": containerID = iterator.next()
            case "--usb":
                guard let value = iterator.next(), let filter = USBDeviceFilter(parsing: value) else {
                    return nil
                }
                filters.append(filter)
            default: continue  // LaunchServices may add its own arguments.
            }
        }
        guard let service, let containerID, !filters.isEmpty else {
            return nil
        }
        return BrokerArguments(service: service, containerID: containerID, filters: filters)
    }
}

/// Holds the AccessoryAccess listener and forwards matching accessories to the runtime.
@available(macOS 27, *)
final class Broker: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    private let arguments: BrokerArguments
    private let client: XPCClient
    private let lock = NSLock()
    private var forwarded: Set<UInt64> = []
    private var watchingRuntime = false

    init(arguments: BrokerArguments) {
        self.arguments = arguments
        self.client = XPCClient(service: arguments.service)
    }

    func register() {
        // Empty criteria: the one configuration that has produced the assignment menu.
        // FB24018643 limits real criteria to vendor IDs anyway; --usb is applied on arrival.
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [self] connected, error in
            if let error {
                logger.error("registerListener failed: \(error, privacy: .public)")
                return
            }
            logger.info("listener registered; \(connected.count) device(s) already assigned")
            connected.forEach(forward)
        }
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        forward(usbAccessory)
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        _ = lock.withLock { forwarded.remove(usbAccessory.registryID) }
        logger.info("device withdrawn: \(String(format: "0x%llx", usbAccessory.registryID), privacy: .public)")
    }

    private func forward(_ accessory: AAUSBAccessory) {
        let bytes = [UInt8](accessory.deviceDescriptorData)
        guard bytes.count >= 12 else {
            return
        }
        let vendorID = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        let productID = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
        let ids = String(format: "%04x:%04x", vendorID, productID)
        guard arguments.filters.contains(where: { $0.matches(vendorID: vendorID, productID: productID) }) else {
            logger.info("\(ids, privacy: .public) assigned but not requested by --usb; ignoring")
            return
        }
        guard lock.withLock({ forwarded.insert(accessory.registryID).inserted }) else {
            return
        }

        let message = XPCMessage(route: usbAccessoryRoute)
        message.set(key: "accessory", xpcDictionary: accessory.createXPCRepresentation())
        logger.info("forwarding \(ids, privacy: .public) to container \(self.arguments.containerID, privacy: .public)")
        Task { [self] in
            do {
                let reply = try await client.send(message, responseTimeout: .seconds(30))
                logger.info("runtime: \(reply.string(key: "result") ?? "accepted", privacy: .public)")
                watchRuntime()
            } catch {
                logger.error("forwarding \(ids, privacy: .public) failed: \(error, privacy: .public)")
                _ = lock.withLock { forwarded.remove(accessory.registryID) }
            }
        }
    }

    /// Quit when the runtime goes away, so a crashed or stopped container never leaves a broker
    /// holding its devices.
    private func watchRuntime() {
        guard lock.withLock({ () -> Bool in
            defer { watchingRuntime = true }
            return !watchingRuntime
        }) else {
            return
        }
        client.setDisconnectHandler {
            logger.info("runtime disconnected; quitting")
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@available(macOS 27, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: BrokerArguments
    private var broker: Broker?
    private var virtualMachine: VZVirtualMachine?
    private var vmDirectory: URL?

    init(arguments: BrokerArguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("broker for container \(self.arguments.containerID, privacy: .public): \(self.arguments.filters, privacy: .public)")
        startPlaceholderVM()
        let broker = Broker(arguments: arguments)
        self.broker = broker
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            broker.register()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let vmDirectory {
            try? FileManager.default.removeItem(at: vmDirectory)
        }
    }

    /// A minimal VM with an XHCI controller in this process. The assignment menu has only
    /// appeared when the registering application was itself running such a VM.
    private func startPlaceholderVM() {
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("container-usb-broker-\(arguments.containerID)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            vmDirectory = dir
            let diskURL = dir.appendingPathComponent("scratch.img")
            FileManager.default.createFile(atPath: diskURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: diskURL)
            try handle.truncate(atOffset: 16 * 1024 * 1024)
            try handle.close()

            let config = VZVirtualMachineConfiguration()
            config.cpuCount = 1
            config.memorySize = VZVirtualMachineConfiguration.minimumAllowedMemorySize
            config.platform = VZGenericPlatformConfiguration()
            let loader = VZEFIBootLoader()
            loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: dir.appendingPathComponent("efivars"), options: [.allowOverwrite])
            config.bootLoader = loader
            config.storageDevices = [
                VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false))
            ]
            config.usbControllers = [VZXHCIControllerConfiguration()]
            try config.validate()

            let vm = VZVirtualMachine(configuration: config)
            virtualMachine = vm
            vm.start { result in
                if case .failure(let error) = result {
                    logger.error("placeholder VM failed to start: \(error, privacy: .public)")
                }
            }
        } catch {
            logger.error("placeholder VM configuration failed: \(error, privacy: .public)")
        }
    }
}

guard let arguments = BrokerArguments.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: container-usb-broker --service <name> --container <id> --usb <vid[:pid]>...\n".utf8))
    exit(64)
}

@available(macOS 27, *)
@MainActor
func runBroker(arguments: BrokerArguments) {
    let application = NSApplication.shared
    // NSApplication holds its delegate weakly; this binding keeps it alive for run().
    let delegate = AppDelegate(arguments: arguments)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

if #available(macOS 27, *) {
    runBroker(arguments: arguments)
} else {
    FileHandle.standardError.write(Data("container-usb-broker requires macOS 27 or newer\n".utf8))
    exit(1)
}
