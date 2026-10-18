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

/// Streamed byte-string scans of a guest kernel image.
///
/// The arm64 `Image` format carries no symbol table, so the only cheap way to tell what a kernel
/// was built with is to look for strings that a given subsystem embeds. The image is read in
/// fixed-size chunks with an overlap of one marker length, so a match that straddles a chunk
/// boundary is still found and the whole image is never resident at once.
enum KernelImageScan {
    /// Present when `CONFIG_USB` (the USB host stack, `drivers/usb/core`) is built in: it is the
    /// driver name and the module parameter prefix (`usbcore.nousb`, `usbcore.autosuspend`, ...).
    /// Kernels without USB host support do not contain it; the bare word `xhci` does appear in
    /// such kernels (PCI quirk tables), so it is not a usable marker.
    static let usbHostMarker = Data("usbcore".utf8)

    /// Whether the kernel image at `url` contains the USB host stack.
    static func hasUSBHostSupport(at url: URL) throws -> Bool {
        try contains(usbHostMarker, inFileAt: url)
    }

    /// Whether the file at `url` contains `marker`, reading it `chunkSize` bytes at a time.
    static func contains(_ marker: Data, inFileAt url: URL, chunkSize: Int = 1 << 20) throws -> Bool {
        precondition(!marker.isEmpty && chunkSize > 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var window = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            window.append(chunk)
            if window.range(of: marker) != nil {
                return true
            }
            // Keep the last marker.count - 1 bytes: a match may begin in them and finish in the
            // next chunk.
            window = window.suffix(marker.count - 1)
        }
        return false
    }
}
