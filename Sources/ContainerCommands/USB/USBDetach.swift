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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationError

extension Application.USBCommand {
    public struct USBDetach: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "detach",
            abstract: "Return a USB device from a running container to macOS"
        )

        @Argument(help: "Device to detach, as hex vid, vid:pid or vid:pid:serial (the --usb selector)")
        var device: String

        @Argument(help: "Container ID or name (default: the container the device is attached to)")
        var container: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let filter = try Application.USBCommand.filter(parsing: device)
            let client = ContainerClient()
            let id: String
            if let container {
                id = container
            } else {
                id = try await Self.holder(of: filter, client: client)
            }
            print(try await client.usbDetach(id: id, filter: filter))
        }

        /// The one container holding a device that matches `filter`.
        static func holder(of filter: USBDeviceFilter, client: ContainerClient) async throws -> String {
            let holders = Set(
                try await client.usbList()
                    .filter { $0.status == .attached && $0.matches(filter) }
                    .map(\.containerID)
            ).sorted()
            switch holders.count {
            case 0:
                throw ContainerizationError(.notFound, message: "no attached USB device matches \(filter)")
            case 1:
                return holders[0]
            default:
                throw ContainerizationError(
                    .invalidArgument, message: "\(filter) is attached to several containers (\(holders.joined(separator: ", "))); name one")
            }
        }
    }
}
