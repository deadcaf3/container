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
import Foundation

extension Application.USBCommand {
    public struct USBList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the USB devices known to running containers",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the device IDs")
        var quiet: Bool = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let devices = try await ContainerClient().usbList()
            try Output.render(payload: devices, display: devices, format: format, quiet: quiet)
        }
    }
}

extension USBDeviceState: ListDisplayable {
    public static var tableHeader: [String] {
        ["ID", "SERIAL", "PRODUCT", "STATE"]
    }

    public var tableRow: [String] {
        let state: String
        switch status {
        case .attached: state = "attached to \(containerID)"
        case .assigned: state = "assigned"
        case .unassigned: state = "unassigned"
        }
        return [ids, serialNumber ?? "", product ?? "", state]
    }

    public var quietValue: String {
        ids
    }
}
