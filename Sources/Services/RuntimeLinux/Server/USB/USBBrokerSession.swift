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

/// This runtime's registration with the shared USB broker.
///
/// The broker has no mach service of its own; the API server hands out its endpoint. The
/// connection is direct, so it keeps working while the API server restarts. When the broker
/// itself is gone (a send fails with a connection error), the next send fetches the endpoint of
/// a new broker and registers again first.
final class USBBrokerSession: @unchecked Sendable {
    private let containerID: String
    /// The runtime's mach service, where the broker sends accessories.
    private let service: String
    private let log: Logger
    private let lock = NSLock()
    // Guarded by `lock`.
    private var client: XPCClient?
    private var filters: [USBDeviceFilter] = []

    init(containerID: String, service: String, log: Logger) {
        self.containerID = containerID
        self.service = service
        self.log = log
    }

    /// Registers for `filters`; the broker then sends every held device that matches.
    func register(filters: [USBDeviceFilter]) async throws {
        lock.withLock { self.filters = filters }
        _ = try await send(registration())
    }

    /// Replaces the filters the broker matches new and released devices against.
    func updateFilters(_ filters: [USBDeviceFilter]) async {
        lock.withLock { self.filters = filters }
        let message = request(.updateFilters)
        message.set(key: XPCKeys.usbFilters.rawValue, value: (try? JSONEncoder().encode(filters)) ?? Data())
        await sendLogging(message)
    }

    /// Tells the broker this VM gave up the device, so it can be handed to another container.
    func released(registryID: UInt64) async {
        let message = request(.released)
        message.set(key: XPCKeys.usbRegistryID.rawValue, value: registryID)
        await sendLogging(message)
    }

    /// Drops the registration; the broker frees every device this container held.
    func unregister() async {
        guard let client = lock.withLock({ self.client }) else {
            return
        }
        do {
            _ = try await client.send(request(.unregister), responseTimeout: .seconds(10))
        } catch {
            log.warning("usb: unregister from the broker failed", metadata: ["error": "\(error)"])
        }
        lock.withLock { self.client = nil }
    }

    private func request(_ route: USBBrokerRoutes) -> XPCMessage {
        let message = XPCMessage(route: route.rawValue)
        message.set(key: XPCKeys.id.rawValue, value: containerID)
        return message
    }

    private func registration() throws -> XPCMessage {
        let message = request(.register)
        message.set(key: XPCKeys.usbRuntimeService.rawValue, value: service)
        message.set(key: XPCKeys.usbRuntimePID.rawValue, value: Int64(getpid()))
        message.set(key: XPCKeys.usbFilters.rawValue, value: try JSONEncoder().encode(lock.withLock { filters }))
        return message
    }

    private func sendLogging(_ message: XPCMessage) async {
        do {
            _ = try await send(message)
        } catch {
            let route = message.string(key: XPCMessage.routeKey) ?? ""
            log.warning("usb: request to the broker failed", metadata: ["route": "\(route)", "error": "\(error)"])
        }
    }

    private func send(_ message: XPCMessage) async throws -> XPCMessage {
        if let client = lock.withLock({ self.client }) {
            do {
                return try await client.send(message, responseTimeout: .seconds(30))
            } catch let error as ContainerizationError where error.code == .interrupted {
                log.info("usb: lost the broker; registering with a new one")
                lock.withLock { self.client = nil }
            }
        }
        let client = XPCClient(connection: xpc_connection_create_from_endpoint(try await ContainerClient().usbBrokerEndpoint()), label: "container-usb-broker")
        lock.withLock { self.client = client }
        let registration = try registration()
        let reply = try await client.send(registration, responseTimeout: .seconds(30))
        if message.string(key: XPCMessage.routeKey) == registration.string(key: XPCMessage.routeKey) {
            return reply
        }
        return try await client.send(message, responseTimeout: .seconds(30))
    }
}
