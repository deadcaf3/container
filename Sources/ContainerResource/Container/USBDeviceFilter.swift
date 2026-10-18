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
/// optionally product ID and serial number.
public struct USBDeviceFilter: Sendable, Codable, Equatable, CustomStringConvertible {
    public var vendorID: UInt16
    public var productID: UInt16?
    /// Exact, case-sensitive serial number to match. An empty string matches devices that
    /// report no serial number. Requires `productID`.
    public var serialNumber: String?

    public init(vendorID: UInt16, productID: UInt16? = nil, serialNumber: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    /// Parses `vid`, `vid:pid` or `vid:pid:serial`. IDs are 1–4 hex digits with an optional
    /// `0x` prefix; the serial is everything after the second colon and may itself contain
    /// colons, so `vid::serial` is rejected rather than read as a product ID.
    public init?(parsing text: String) {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
            let vendorID = Self.hex(parts[0])
        else {
            return nil
        }
        var productID: UInt16?
        if parts.count >= 2 {
            guard let parsed = Self.hex(parts[1]) else {
                return nil
            }
            productID = parsed
        }
        let serialNumber = parts.count == 3 ? String(parts[2]) : nil
        self.init(vendorID: vendorID, productID: productID, serialNumber: serialNumber)
    }

    /// Whether a device with these IDs and serial number satisfies the filter. Pass `nil`
    /// for a device that reports no serial number.
    public func matches(vendorID: UInt16, productID: UInt16, serialNumber: String?) -> Bool {
        guard vendorID == self.vendorID, self.productID == nil || productID == self.productID else {
            return false
        }
        guard let wanted = self.serialNumber else {
            return true
        }
        return (serialNumber ?? "") == wanted
    }

    public var description: String {
        let vendor = String(format: "%04x", vendorID)
        guard let productID else {
            return vendor
        }
        let ids = vendor + ":" + String(format: "%04x", productID)
        guard let serialNumber else {
            return ids
        }
        return ids + ":" + serialNumber
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
