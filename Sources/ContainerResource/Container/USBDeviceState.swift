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

/// A physical USB device known to a running container's USB broker, as reported by
/// `container usb ls`.
public struct USBDeviceState: Sendable, Codable, Equatable {
    /// Where the device stands relative to the container that reports it.
    public enum Status: String, Sendable, Codable {
        /// Passed through to the container's VM.
        case attached
        /// Assigned to the broker in the Virtual Machine Accessories menu, but not attached.
        case assigned
        /// Assigned once, then withdrawn in the menu or unplugged.
        case unassigned
    }

    /// The IOKit registry entry ID of the device; changes when the device is replugged.
    public var registryID: UInt64
    public var vendorID: UInt16
    public var productID: UInt16
    public var serialNumber: String?
    public var product: String?
    /// The container whose broker reported the device.
    public var containerID: String
    public var status: Status

    public init(
        registryID: UInt64,
        vendorID: UInt16,
        productID: UInt16,
        serialNumber: String? = nil,
        product: String? = nil,
        containerID: String,
        status: Status
    ) {
        self.registryID = registryID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.product = product
        self.containerID = containerID
        self.status = status
    }

    /// `vvvv:pppp`.
    public var ids: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// Whether `filter` selects this device.
    public func matches(_ filter: USBDeviceFilter) -> Bool {
        filter.matches(vendorID: vendorID, productID: productID, serialNumber: serialNumber)
    }
}

extension USBDeviceFilter {
    /// Whether every device `other` selects is also selected by this filter, so adding `other`
    /// to a container that already has this filter changes nothing.
    public func covers(_ other: USBDeviceFilter) -> Bool {
        vendorID == other.vendorID
            && (productID == nil || productID == other.productID)
            && (serialNumber == nil || serialNumber == other.serialNumber)
    }
}
