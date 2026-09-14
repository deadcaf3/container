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

/// A physical USB device to pass through to the container's VM, matched by vendor and
/// optionally product ID.
public struct USBDeviceFilter: Sendable, Codable, Equatable, CustomStringConvertible {
    /// The runtime plugin that handles USB passthrough. It is a separate, provisioned plugin
    /// so that a signing problem cannot affect containers that don't request USB devices.
    public static let runtimeHandler = "container-runtime-linux-usb"

    public var vendorID: UInt16
    public var productID: UInt16?

    public init(vendorID: UInt16, productID: UInt16? = nil) {
        self.vendorID = vendorID
        self.productID = productID
    }

    /// Parses `vid` or `vid:pid`, each 1–4 hex digits with an optional `0x` prefix.
    public init?(parsing text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
            let vendorID = Self.hex(parts[0])
        else {
            return nil
        }
        if parts.count == 2 {
            guard let productID = Self.hex(parts[1]) else {
                return nil
            }
            self.init(vendorID: vendorID, productID: productID)
        } else {
            self.init(vendorID: vendorID)
        }
    }

    /// Whether a device with these IDs satisfies the filter.
    public func matches(vendorID: UInt16, productID: UInt16) -> Bool {
        vendorID == self.vendorID && (self.productID == nil || productID == self.productID)
    }

    public var description: String {
        let vendor = String(format: "%04x", vendorID)
        guard let productID else {
            return vendor
        }
        return vendor + ":" + String(format: "%04x", productID)
    }

    private static func hex(_ text: Substring) -> UInt16? {
        var digits = text
        if digits.lowercased().hasPrefix("0x") {
            digits = digits.dropFirst(2)
        }
        guard (1...4).contains(digits.count), digits.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return UInt16(digits, radix: 16)
    }
}
