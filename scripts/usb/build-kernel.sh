#!/bin/bash
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build an arm64 guest kernel with USB host support for --usb.
#
#   scripts/usb/build-kernel.sh [output-dir]
#
# Uses containerization's kernel tooling (which builds inside `container`) with the config
# fragment in kernel/usb appended. The stock guest kernel has USB disabled entirely.
# The build directory must be under $HOME: the build container cannot read /tmp.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/bin}"
TAG="${CONTAINERIZATION_TAG:-$(sed -n 's/^let scVersion = "\(.*\)"/\1/p' "$ROOT/Package.swift")}"
BUILD="${KERNEL_BUILD_DIR:-$HOME/.cache/container-usb-kernel}"
CPUS="${KERNEL_BUILD_CPUS:-6}"
MEMORY="${KERNEL_BUILD_MEMORY:-10g}"
FRAGMENT="$ROOT/kernel/usb/config-arm64-usb.fragment"

echo "==> containerization $TAG kernel tooling into $BUILD"
rm -rf "$BUILD"
git clone -q --depth 1 --branch "$TAG" --filter=blob:none --sparse https://github.com/apple/containerization "$BUILD/src"
git -C "$BUILD/src" sparse-checkout set kernel
K="$BUILD/src/kernel"

cat "$FRAGMENT" >> "$K/config-arm64"
sed -i '' "s/--cpus [0-9]*/--cpus $CPUS/; s/--memory [0-9a-z]*/--memory $MEMORY/" "$K/Makefile"
sed -i '' 's#cp "${IMAGE_PATH}" "/kernel/${OUTPUT_NAME}"#cp "${IMAGE_PATH}" "/kernel/${OUTPUT_NAME}" \&\& cp .config /kernel/config-final#' "$K/build.sh"

echo "==> building (this takes a while)"
make -C "$K"

missing=0
for option in $(grep -oE '^CONFIG_[A-Z0-9_]+' "$FRAGMENT"); do
	grep -q "^$option=y" "$K/config-final" || { echo "missing from final config: $option" >&2; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

mkdir -p "$OUT"
cp "$K/vmlinux-arm64" "$OUT/vmlinux-arm64-usb"
cp "$K/config-final" "$OUT/vmlinux-arm64-usb.config"
( cd "$OUT" && shasum -a 256 vmlinux-arm64-usb > vmlinux-arm64-usb.sha256 )
echo "==> $OUT/vmlinux-arm64-usb"
