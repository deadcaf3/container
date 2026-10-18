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

extension Application {
    public struct USBCommand: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "usb",
            abstract: "[EXPERIMENTAL] List USB devices and move them between running containers (requires macOS 27)",
            subcommands: [
                USBList.self,
                USBAttach.self,
                USBDetach.self,
            ]
        )

        public init() {}

        @OptionGroup
        public var logOptions: Flags.Logging

        /// Parses the `VID[:PID]` selector shared with `--usb`.
        static func filter(parsing selector: String) throws -> USBDeviceFilter {
            guard let filter = USBDeviceFilter(parsing: selector) else {
                throw ContainerizationError(
                    .invalidArgument, message: "invalid USB device '\(selector)': expected hex vid or vid:pid, e.g. 1366 or 1366:0101")
            }
            return filter
        }
    }
}
