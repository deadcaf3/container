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
/// background service, so it can never be offered a device. This app receives devices assigned
/// from the Virtual Machine Accessories menu instead and forwards them to the runtimes of the
/// containers whose `--usb` filters match, as XPC representations; each runtime attaches them to
/// its container's VM. One broker serves every container (`SharedBroker`); the API server
/// launches it on demand.

import AppKit
import Foundation
@preconcurrency import Virtualization
import os

let logger = Logger(subsystem: "com.apple.container", category: "USBBroker")

/// Must match `RuntimeRoutes.usbAccessory` and `RuntimeRoutes.usbAccessoryWithdrawn`.
let usbAccessoryRoute = "com.apple.container.runtime/usbAccessory"
let usbAccessoryWithdrawnRoute = "com.apple.container.runtime/usbAccessoryWithdrawn"

@available(macOS 27, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var broker: SharedBroker?
    private var virtualMachine: VZVirtualMachine?
    private var vmDirectory: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("shared broker")
        startPlaceholderVM()
        let broker = SharedBroker()
        self.broker = broker
        broker.start()
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
                .appendingPathComponent("container-usb-broker", isDirectory: true)
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

@available(macOS 27, *)
@MainActor
func runBroker() {
    let application = NSApplication.shared
    // NSApplication holds its delegate weakly; this binding keeps it alive for run().
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

if #available(macOS 27, *) {
    runBroker()
} else {
    FileHandle.standardError.write(Data("container-usb-broker requires macOS 27 or newer\n".utf8))
    exit(1)
}
