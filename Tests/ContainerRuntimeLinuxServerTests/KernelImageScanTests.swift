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

@testable import ContainerRuntimeLinuxServer

struct KernelImageScanTests {
    private let marker = Data("usbcore".utf8)

    /// Writes `bytes` to a temporary file and runs the scan over it with a small chunk size so
    /// short buffers exercise the chunk-boundary handling.
    private func scan(_ bytes: [UInt8], chunkSize: Int = 8) throws -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernel-image-scan-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try KernelImageScan.contains(marker, inFileAt: url, chunkSize: chunkSize)
    }

    private func bytes(_ parts: String...) -> [UInt8] {
        Array(parts.joined().utf8)
    }

    @Test func emptyFileHasNoMarker() throws {
        #expect(try scan([]) == false)
    }

    @Test func absentMarkerIsNotFound() throws {
        #expect(try scan(bytes("xhci", "\0", "quirk_ryzen_xhci_d3hot", "\0", "usbcor", "\0", "sbcore")) == false)
    }

    @Test func markerAtStartIsFound() throws {
        #expect(try scan(bytes("usbcore.nousb", "\0", "padding")) == true)
    }

    @Test func markerAtEndIsFound() throws {
        #expect(try scan(bytes("padding padding ", "usbcore")) == true)
    }

    @Test func markerSpanningChunkBoundaryIsFound() throws {
        // With an 8-byte chunk, "usbcore" starting at offset 5 covers bytes 5..<12.
        #expect(try scan(bytes("12345", "usbcore", "67890"), chunkSize: 8) == true)
    }

    @Test func markerSplitAcrossEveryChunkSizeIsFound() throws {
        let image = bytes("0123456789", "usbcore", "9876543210")
        for chunkSize in 1...(image.count + 1) {
            #expect(try scan(image, chunkSize: chunkSize) == true, "chunk size \(chunkSize)")
        }
    }

    @Test func shorterThanMarkerIsNotFound() throws {
        #expect(try scan(bytes("usb")) == false)
    }

    @Test func binaryNoiseAroundMarkerIsFound() throws {
        var image = [UInt8](repeating: 0xff, count: 37)
        image.append(contentsOf: marker)
        image.append(contentsOf: [UInt8](repeating: 0x00, count: 11))
        #expect(try scan(image, chunkSize: 5) == true)
    }

    @Test func usbHostSupportUsesTheUSBCoreMarker() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernel-image-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes("\0", "xhci", "\0")).write(to: url)
        #expect(try KernelImageScan.hasUSBHostSupport(at: url) == false)
        try Data(bytes("\0", "usbcore.autosuspend", "\0")).write(to: url)
        #expect(try KernelImageScan.hasUSBHostSupport(at: url) == true)
    }
}
