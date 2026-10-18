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

import Foundation
import IOKit

/// String descriptors of a USB device, read from the IOKit registry entry an accessory names.
enum USBDeviceProperties {
    /// The product string of the device with `registryID`, if the registry still has it.
    static func product(registryID: UInt64) -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard entry != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, "USB Product Name" as CFString, kCFAllocatorDefault, 0)
        guard let text = (value?.takeRetainedValue() as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        return text
    }
}
