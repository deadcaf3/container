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

import ContainerResource
import Testing

@testable import ContainerAPIService

struct USBHandoffTests {
    static func device(_ registryID: UInt64, serial: String, in containerID: String = "", _ status: USBDeviceState.Status) -> USBDeviceState {
        USBDeviceState(registryID: registryID, vendorID: 0x1366, productID: 0x0105, serialNumber: serial, containerID: containerID, status: status)
    }

    static let probe = USBDeviceFilter(vendorID: 0x1366)

    @Test func movesADeviceHeldByAnotherContainer() {
        let held = Self.device(1, serial: "000000000001", in: "a", .attached)
        #expect(ContainersService.usbHandoffSource(for: Self.probe, to: "b", devices: [held]) == held)
    }

    @Test func leavesAFreeDeviceToTheBroker() {
        let devices = [Self.device(1, serial: "000000000001", in: "a", .attached), Self.device(2, serial: "000000000002", .assigned)]
        #expect(ContainersService.usbHandoffSource(for: Self.probe, to: "b", devices: devices) == nil)
    }

    @Test func doesNothingWhenTheTargetAlreadyHoldsOne() {
        let devices = [Self.device(1, serial: "000000000001", in: "a", .attached), Self.device(2, serial: "000000000002", in: "b", .attached)]
        #expect(ContainersService.usbHandoffSource(for: Self.probe, to: "b", devices: devices) == nil)
    }

    @Test func honoursTheSerialInTheFilter() {
        let devices = [Self.device(1, serial: "000000000001", in: "a", .attached), Self.device(2, serial: "000000000002", in: "c", .attached)]
        let filter = USBDeviceFilter(vendorID: 0x1366, productID: 0x0105, serialNumber: "000000000002")
        #expect(ContainersService.usbHandoffSource(for: filter, to: "b", devices: devices)?.containerID == "c")
    }

    @Test func arrivalIsFoundUnderANewRegistryID() {
        let moved = Self.device(1, serial: "000000000001", in: "a", .attached)
        let back = Self.device(7, serial: "000000000001", in: "b", .attached)
        #expect(ContainersService.usbHandoffArrived(moved, at: "b", devices: [back]))
    }

    @Test func arrivalNeedsTheSameSerialAndTarget() {
        let moved = Self.device(1, serial: "000000000001", in: "a", .attached)
        let devices = [Self.device(7, serial: "000000000002", in: "b", .attached), Self.device(8, serial: "000000000001", in: "a", .attached)]
        #expect(!ContainersService.usbHandoffArrived(moved, at: "b", devices: devices))
        #expect(!ContainersService.usbHandoffArrived(moved, at: "b", devices: [Self.device(7, serial: "000000000001", .assigned)]))
    }

    @Test func ignoresNonMatchingDevices() {
        let other = USBDeviceState(registryID: 3, vendorID: 0x0483, productID: 0x3748, containerID: "a", status: .attached)
        #expect(ContainersService.usbHandoffSource(for: Self.probe, to: "b", devices: [other]) == nil)
    }
}
