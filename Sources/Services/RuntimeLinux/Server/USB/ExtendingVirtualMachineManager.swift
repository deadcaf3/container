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

import Containerization

/// Adds VM instance extensions to every VM created by a base manager.
///
/// `LinuxContainer.Configuration` has no `extensions` field, but `VMConfiguration` does and
/// `VZVirtualMachineManager` forwards it to the instance. Wrapping the manager is the one place
/// a container runtime can inject a `VZInstanceExtension` without changing Containerization.
struct ExtendingVirtualMachineManager: VirtualMachineManager {
    let base: any VirtualMachineManager
    let extensions: [any Sendable]

    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        var configuration = config.configuration
        configuration.extensions.append(contentsOf: extensions)
        return try await base.create(config: StandardVMConfig(configuration: configuration))
    }
}
