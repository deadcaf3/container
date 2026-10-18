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
import Testing

@testable import ContainerResource

struct USBDeviceStateTests {
    private let probe = USBDeviceState(
        registryID: 0x1000_0abc, vendorID: 0x1366, productID: 0x0105, serialNumber: "000123", product: "J-Link",
        containerID: "probe", status: .attached)

    @Test func formatsIDs() {
        #expect(probe.ids == "1366:0105")
        #expect(USBDeviceState(registryID: 1, vendorID: 0x0d28, productID: 0x0204, containerID: "c", status: .assigned).ids == "0d28:0204")
    }

    @Test func matchesVendorAndExactFilters() {
        #expect(probe.matches(USBDeviceFilter(vendorID: 0x1366)))
        #expect(probe.matches(USBDeviceFilter(vendorID: 0x1366, productID: 0x0105)))
        #expect(!probe.matches(USBDeviceFilter(vendorID: 0x1366, productID: 0x0101)))
        #expect(!probe.matches(USBDeviceFilter(vendorID: 0x0483)))
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode([probe])
        #expect(try JSONDecoder().decode([USBDeviceState].self, from: data) == [probe])
    }

    @Test func vendorFilterCoversNarrowerFilters() {
        let vendor = USBDeviceFilter(vendorID: 0x1366)
        let exact = USBDeviceFilter(vendorID: 0x1366, productID: 0x0105)
        let other = USBDeviceFilter(vendorID: 0x1366, productID: 0x0101)
        #expect(vendor.covers(vendor))
        #expect(vendor.covers(exact))
        #expect(exact.covers(exact))
        #expect(!exact.covers(vendor))
        #expect(!exact.covers(other))
        #expect(!vendor.covers(USBDeviceFilter(vendorID: 0x0483)))
    }
}
