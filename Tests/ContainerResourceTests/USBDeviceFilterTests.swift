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

struct USBDeviceFilterTests {
    @Test(arguments: [
        ("1366", USBDeviceFilter(vendorID: 0x1366)),
        ("1366:0101", USBDeviceFilter(vendorID: 0x1366, productID: 0x0101)),
        ("0x2E8A:0x000c", USBDeviceFilter(vendorID: 0x2e8a, productID: 0x000c)),
        ("d28:204", USBDeviceFilter(vendorID: 0x0d28, productID: 0x0204)),
    ])
    func parsesValidSpecs(text: String, expected: USBDeviceFilter) {
        #expect(USBDeviceFilter(parsing: text) == expected)
    }

    @Test(arguments: ["", ":", "1366:", ":0101", "zz", "12345", "1366:0101:1", "0x", "13 66"])
    func rejectsInvalidSpecs(text: String) {
        #expect(USBDeviceFilter(parsing: text) == nil)
    }

    @Test func matchesVendorOnlyAndExactProduct() {
        let vendor = USBDeviceFilter(vendorID: 0x1366)
        let exact = USBDeviceFilter(vendorID: 0x1366, productID: 0x0101)
        #expect(vendor.matches(vendorID: 0x1366, productID: 0x1015))
        #expect(exact.matches(vendorID: 0x1366, productID: 0x0101))
        #expect(!exact.matches(vendorID: 0x1366, productID: 0x1015))
        #expect(!vendor.matches(vendorID: 0x0483, productID: 0x0101))
    }

    @Test func describesAsHex() {
        #expect(USBDeviceFilter(vendorID: 0x1366).description == "1366")
        #expect(USBDeviceFilter(vendorID: 0x2e8a, productID: 0x000c).description == "2e8a:000c")
    }
}

struct ContainerConfigurationUSBTests {
    @Test func roundTripsUSBDevices() throws {
        var config = makeTestConfiguration()
        config.usbDevices = [USBDeviceFilter(vendorID: 0x1366, productID: 0x0101), USBDeviceFilter(vendorID: 0x2e8a)]
        config.usbWaitSeconds = 30
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.usbDevices == config.usbDevices)
        #expect(decoded.usbWaitSeconds == 30)
    }

    @Test func decodesConfigurationWithoutUSBFields() throws {
        let data = try JSONEncoder().encode(makeTestConfiguration())
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "usbDevices")
        obj.removeValue(forKey: "usbWaitSeconds")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.usbDevices.isEmpty)
        #expect(decoded.usbWaitSeconds == nil)
    }
}
