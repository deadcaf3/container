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
        ("1366:0105:000123456789", USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "000123456789")),
        ("1366:0105:", USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "")),
        ("303a:1001:AA:BB:CC:DD:EE:FF", USBDeviceFilter(vendorID: 0x303a, productID: 0x1001, serialNumber: "AA:BB:CC:DD:EE:FF")),
        ("0x1366:0x0105:0x1", USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "0x1")),
    ])
    func parsesValidSpecs(text: String, expected: USBDeviceFilter) {
        #expect(USBDeviceFilter(parsing: text) == expected)
    }

    @Test(arguments: ["", ":", "1366:", ":0101", "zz", "12345", "0x", "13 66", "1366::ABC", "1366::", "::ABC", "1366:zz:ABC"])
    func rejectsInvalidSpecs(text: String) {
        #expect(USBDeviceFilter(parsing: text) == nil)
    }

    @Test func matchesVendorOnlyAndExactProduct() {
        let vendor = USBDeviceFilter(vendorID: 0x1366)
        let exact = USBDeviceFilter(vendorID: 0x1366, productID: 0x0101)
        #expect(vendor.matches(vendorID: 0x1366, productID: 0x1015, serialNumber: nil))
        #expect(vendor.matches(vendorID: 0x1366, productID: 0x1015, serialNumber: "000123456789"))
        #expect(exact.matches(vendorID: 0x1366, productID: 0x0101, serialNumber: nil))
        #expect(exact.matches(vendorID: 0x1366, productID: 0x0101, serialNumber: "000123456789"))
        #expect(!exact.matches(vendorID: 0x1366, productID: 0x1015, serialNumber: nil))
        #expect(!vendor.matches(vendorID: 0x0483, productID: 0x0101, serialNumber: nil))
    }

    @Test func matchesSerialExactly() {
        let filter = USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "000123456789")
        #expect(filter.matches(vendorID: 0x1366, productID: 0x0105, serialNumber: "000123456789"))
        #expect(!filter.matches(vendorID: 0x1366, productID: 0x0105, serialNumber: "000987654321"))
        #expect(!filter.matches(vendorID: 0x1366, productID: 0x0105, serialNumber: nil))
        #expect(!filter.matches(vendorID: 0x1366, productID: 0x0105, serialNumber: ""))
        #expect(!filter.matches(vendorID: 0x1366, productID: 0x0101, serialNumber: "000123456789"))
        #expect(!filter.matches(vendorID: 0x0483, productID: 0x0105, serialNumber: "000123456789"))
    }

    @Test func matchesSerialCaseSensitively() {
        let filter = USBDeviceFilter(vendorID: 0x303a, productID: 0x1001, serialNumber: "AA:BB:CC:DD:EE:FF")
        #expect(filter.matches(vendorID: 0x303a, productID: 0x1001, serialNumber: "AA:BB:CC:DD:EE:FF"))
        #expect(!filter.matches(vendorID: 0x303a, productID: 0x1001, serialNumber: "aa:bb:cc:dd:ee:ff"))
        #expect(!filter.matches(vendorID: 0x303a, productID: 0x1001, serialNumber: "AA:BB:CC:DD:EE:FF "))
    }

    @Test func emptySerialMatchesOnlyDevicesWithoutOne() {
        let filter = USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "")
        #expect(filter.matches(vendorID: 0x1366, productID: 0x0105, serialNumber: nil))
        #expect(filter.matches(vendorID: 0x1366, productID: 0x0105, serialNumber: ""))
        #expect(!filter.matches(vendorID: 0x1366, productID: 0x0105, serialNumber: "000123456789"))
    }

    @Test func describesAsHex() {
        #expect(USBDeviceFilter(vendorID: 0x1366).description == "1366")
        #expect(USBDeviceFilter(vendorID: 0x2e8a, productID: 0x000c).description == "2e8a:000c")
        #expect(USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "000123456789").description == "1366:0105:000123456789")
        #expect(USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "").description == "1366:0105:")
    }

    @Test(arguments: ["1366", "1366:0105", "1366:0105:000123456789", "1366:0105:", "303a:1001:AA:BB:CC:DD:EE:FF"])
    func descriptionRoundTrips(text: String) throws {
        let filter = try #require(USBDeviceFilter(parsing: text))
        #expect(USBDeviceFilter(parsing: filter.description) == filter)
    }

    @Test func decodesFilterWithoutSerialNumber() throws {
        let data = Data(#"{"vendorID":4966,"productID":261}"#.utf8)
        let decoded = try JSONDecoder().decode(USBDeviceFilter.self, from: data)
        #expect(decoded == USBDeviceFilter(vendorID: 0x1366, productID: 0x0105))
    }
}

struct ContainerConfigurationUSBTests {
    @Test func roundTripsUSBDevices() throws {
        var config = makeTestConfiguration()
        config.usbDevices = [
            USBDeviceFilter(vendorID: 0x1366, productID: 0x0101), USBDeviceFilter(vendorID: 0x2e8a),
            USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "000123456789"),
        ]
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
