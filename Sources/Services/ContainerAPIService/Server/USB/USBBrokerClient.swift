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

import ContainerAPIClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

/// The API server's connection to the shared USB broker (`container-usb.app`).
///
/// The broker is an app launched by LaunchServices, so it cannot own a launchd mach service.
/// It checks an anonymous XPC endpoint in here instead (`XPCRoute.usbBrokerCheckIn`). This
/// actor launches the broker when a request finds none, and serializes launches so concurrent
/// requests start a single broker.
public actor USBBrokerClient {
    public static let appPath = "libexec/container/usb/container-usb.app"
    static let checkInTimeout: Duration = .seconds(20)

    private let appURL: URL
    private let log: Logger
    private var client: XPCClient?
    /// The endpoint `client` connects to, handed to runtimes.
    private var endpoint: xpc_endpoint_t?
    private var launch: Task<XPCClient, Error>?
    private var waiters: [UUID: CheckedContinuation<XPCClient?, Never>] = [:]

    public init(installRoot: URL, log: Logger) {
        self.appURL = installRoot.appendingPathComponent(Self.appPath)
        self.log = log
    }

    /// Handles `XPCRoute.usbBrokerCheckIn`: the broker started and serves `usbBrokerEndpoint`.
    public func checkIn(_ message: XPCMessage) throws -> XPCMessage {
        guard let endpoint = message.endpoint(key: XPCKeys.usbBrokerEndpoint.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing USB broker endpoint")
        }
        let client = XPCClient(connection: xpc_connection_create_from_endpoint(endpoint), label: "container-usb-broker")
        self.client = client
        self.endpoint = endpoint
        log.info("usb: broker checked in")
        let waiting = waiters.values
        waiters.removeAll()
        waiting.forEach { $0.resume(returning: client) }
        return message.reply()
    }

    /// Every device the broker holds; the broker starts if it is not running.
    public func list() async throws -> [USBDeviceState] {
        let reply = try await send(XPCMessage(route: USBBrokerRoutes.list.rawValue))
        guard let data = reply.dataNoCopy(key: XPCKeys.usbDevices.rawValue) else {
            throw ContainerizationError(.internalError, message: "the USB broker returned no device data")
        }
        return try JSONDecoder().decode([USBDeviceState].self, from: data)
    }

    /// Handles `XPCRoute.usbBrokerEndpoint`: replies with the endpoint of a running broker.
    public func endpoint(_ message: XPCMessage) async throws -> XPCMessage {
        // A list round trip proves the broker is still there, and starts a new one if it quit.
        _ = try await list()
        guard let endpoint else {
            throw ContainerizationError(.invalidState, message: "the USB broker has no endpoint")
        }
        let reply = message.reply()
        reply.set(key: XPCKeys.usbBrokerEndpoint.rawValue, value: endpoint)
        return reply
    }

    /// Sends `message` to the broker, starting it first if needed. A broker that quit since it
    /// checked in shows up as a connection error; the request is then sent once more to a new one.
    func send(_ message: XPCMessage) async throws -> XPCMessage {
        let client = try await connected()
        do {
            return try await client.send(message, responseTimeout: .seconds(30))
        } catch let error as ContainerizationError where error.code == .interrupted {
            if self.client === client {
                self.client = nil
            }
            return try await connected().send(message, responseTimeout: .seconds(30))
        }
    }

    private func connected() async throws -> XPCClient {
        if let client {
            return client
        }
        if let launch {
            return try await launch.value
        }
        let task = Task { try await self.start() }
        launch = task
        defer { launch = nil }
        return try await task.value
    }

    private func start() async throws -> XPCClient {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw ContainerizationError(
                .notFound,
                message: "USB broker not found at \(appURL.path); build with USB_BUNDLE_ID and USB_PROFILE (see docs/usb-passthrough.md)"
            )
        }
        log.info("usb: launching shared broker", metadata: ["app": "\(appURL.path)"])
        // `open` asks LaunchServices, so the broker runs as an ordinary app that AccessoryAccess
        // offers devices to; this actor makes sure only one is started.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", appURL.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw ContainerizationError(.internalError, message: "failed to launch the USB broker (open exited \(open.terminationStatus))")
        }

        if let client {
            return client
        }
        let id = UUID()
        let client = await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(for: Self.checkInTimeout)
                self.timeOut(id)
            }
        }
        guard let client else {
            throw ContainerizationError(.timeout, message: "the USB broker did not check in within \(Self.checkInTimeout)")
        }
        return client
    }

    private func timeOut(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}
