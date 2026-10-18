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

/// Routes served by the shared USB broker on the endpoint it checks in with the API server.
/// The broker (Sources/Plugins/USBBroker) spells them out; keep the two in step.
public enum USBBrokerRoutes: String {
    /// Every accessory the broker holds, as a JSON `[USBDeviceState]` under `usbDevices`.
    case list = "com.apple.container.usb-broker/list"
}
