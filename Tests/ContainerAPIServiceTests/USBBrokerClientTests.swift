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
import Testing

@testable import ContainerAPIService

struct USBBrokerClientTests {
    static let log = Logger(label: "com.apple.container.test.usb-broker")

    /// Serves `routes` on an anonymous listener and returns its endpoint.
    static func serve(_ routes: [String: XPCServer.RouteHandler]) -> (endpoint: xpc_endpoint_t, task: Task<Void, Error>) {
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: routes, log: log)
        let task = Task { try await server.listen() }
        return (xpc_endpoint_create(listener), task)
    }

    @Test func listReachesTheBrokerThatCheckedIn() async throws {
        let device = USBDeviceState(
            registryID: 0x1234, vendorID: 0x1366, productID: 0x0105, serialNumber: "000000000001", product: "Probe", containerID: "", status: .assigned)
        let broker = Self.serve([
            USBBrokerRoutes.list.rawValue: XPCServer.route { message in
                let reply = message.reply()
                reply.set(key: XPCKeys.usbDevices.rawValue, value: try JSONEncoder().encode([device]))
                return reply
            }
        ])
        defer { broker.task.cancel() }

        let client = USBBrokerClient(installRoot: URL(fileURLWithPath: "/nonexistent"), log: Self.log)
        let apiServer = Self.serve([XPCRoute.usbBrokerCheckIn.rawValue: XPCServer.route { try await client.checkIn($0) }])
        defer { apiServer.task.cancel() }

        let checkIn = XPCMessage(route: XPCRoute.usbBrokerCheckIn.rawValue)
        checkIn.set(key: XPCKeys.usbBrokerEndpoint.rawValue, value: broker.endpoint)
        let brokerSide = XPCClient(connection: xpc_connection_create_from_endpoint(apiServer.endpoint), label: "test-api-server")
        _ = try await brokerSide.send(checkIn, responseTimeout: .seconds(10))

        #expect(try await client.list() == [device])

        // A runtime asking for the endpoint gets one that reaches the same broker.
        let apiServerForRuntime = Self.serve([XPCRoute.usbBrokerEndpoint.rawValue: XPCServer.route { try await client.endpoint($0) }])
        defer { apiServerForRuntime.task.cancel() }
        let runtimeSide = XPCClient(connection: xpc_connection_create_from_endpoint(apiServerForRuntime.endpoint), label: "test-runtime")
        let reply = try await runtimeSide.send(XPCMessage(route: XPCRoute.usbBrokerEndpoint.rawValue), responseTimeout: .seconds(10))
        let endpoint = try #require(reply.endpoint(key: XPCKeys.usbBrokerEndpoint.rawValue))
        let direct = XPCClient(connection: xpc_connection_create_from_endpoint(endpoint), label: "test-broker")
        let listed = try await direct.send(XPCMessage(route: USBBrokerRoutes.list.rawValue), responseTimeout: .seconds(10))
        #expect(listed.dataNoCopy(key: XPCKeys.usbDevices.rawValue) != nil)
    }

    @Test func checkInWithoutEndpointIsRefused() async throws {
        let client = USBBrokerClient(installRoot: URL(fileURLWithPath: "/nonexistent"), log: Self.log)
        let apiServer = Self.serve([XPCRoute.usbBrokerCheckIn.rawValue: XPCServer.route { try await client.checkIn($0) }])
        defer { apiServer.task.cancel() }

        let brokerSide = XPCClient(connection: xpc_connection_create_from_endpoint(apiServer.endpoint), label: "test-api-server")
        await #expect(throws: ContainerizationError.self) {
            _ = try await brokerSide.send(XPCMessage(route: XPCRoute.usbBrokerCheckIn.rawValue), responseTimeout: .seconds(10))
        }
    }

    @Test func listWithoutInstalledBrokerFails() async throws {
        let client = USBBrokerClient(installRoot: URL(fileURLWithPath: "/nonexistent"), log: Self.log)
        let error = await #expect(throws: ContainerizationError.self) {
            _ = try await client.list()
        }
        #expect(error?.code == .notFound)
    }
}
