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

# Stage the USB passthrough runtime as a provisioned app bundle.
#
#   scripts/usb/bundle-runtime.sh <staging-dir> <container-runtime-linux binary>
#
# Requires USB_BUNDLE_ID (an explicit App ID with the "Claim USB Accessory" capability) and
# USB_PROFILE (a macOS development provisioning profile for it). USB_IDENTITY defaults to the
# first "Apple Development" identity in the keychain.
#
# com.apple.developer.accessory-access.usb is a restricted entitlement: the binary must live in
# an app bundle with the profile embedded, signed by a certificate the profile lists, or AMFI
# kills it at launch. The plugin is separate from container-runtime-linux so a signing mistake
# only affects containers started with --usb.
set -euo pipefail

STAGING_DIR="${1:?usage: bundle-runtime.sh <staging-dir> <runtime-binary>}"
BINARY="${2:?usage: bundle-runtime.sh <staging-dir> <runtime-binary>}"
: "${USB_BUNDLE_ID:?set USB_BUNDLE_ID to your App ID (see docs/usb-passthrough.md)}"
: "${USB_PROFILE:?set USB_PROFILE to the .provisionprofile for USB_BUNDLE_ID}"
USB_IDENTITY="${USB_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}"
[ -n "$USB_IDENTITY" ] || { echo "no Apple Development identity found; set USB_IDENTITY" >&2; exit 1; }
[ -f "$USB_PROFILE" ] || { echo "USB_PROFILE not found: $USB_PROFILE" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME=container-runtime-linux-usb
APP="$STAGING_DIR/libexec/container/plugins/$NAME.app"
VERSION="${RELEASE_VERSION:-0.0.0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> staging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install "$BINARY" "$APP/Contents/MacOS/$NAME"
install -m 644 "$ROOT/Sources/Plugins/RuntimeLinux/usb/config.toml" "$APP/Contents/Resources/config.toml"
sed -e "s/@USB_BUNDLE_ID@/$USB_BUNDLE_ID/" -e "s/@VERSION@/$VERSION/" \
	"$ROOT/Sources/Plugins/RuntimeLinux/usb/Info.plist.in" > "$APP/Contents/Info.plist"
cp "$USB_PROFILE" "$APP/Contents/embedded.provisionprofile"

# A development build must carry the profile's application and team identifiers, plus
# get-task-allow. Derive them from the profile so they cannot drift.
security cms -D -i "$USB_PROFILE" -o "$WORK/profile.plist"
python3 - "$ROOT/signing/$NAME.entitlements" "$WORK/profile.plist" "$WORK/entitlements.plist" "$USB_BUNDLE_ID" <<'PY'
import plistlib, sys
entitlements_path, profile_path, out_path, bundle_id = sys.argv[1:5]
with open(entitlements_path, 'rb') as fh:
    ent = plistlib.load(fh)
with open(profile_path, 'rb') as fh:
    profile = plistlib.load(fh)
granted = profile.get('Entitlements', {})
team = granted.get('com.apple.developer.team-identifier')
if not team:
    sys.exit('profile has no team identifier')
app_id = granted.get('application-identifier') or granted.get('com.apple.application-identifier')
if app_id != f'{team}.{bundle_id}':
    sys.exit(f'profile is for {app_id}, not {team}.{bundle_id}')
if not granted.get('com.apple.developer.accessory-access.usb'):
    sys.exit('profile does not grant com.apple.developer.accessory-access.usb (Claim USB Accessory)')
ent['com.apple.developer.team-identifier'] = team
ent['com.apple.application-identifier'] = f'{team}.{bundle_id}'
ent['com.apple.security.get-task-allow'] = True
with open(out_path, 'wb') as fh:
    plistlib.dump(ent, fh)
print('    entitlements:', ', '.join(sorted(ent)))
PY

echo "==> signing with $USB_IDENTITY"
codesign --force --sign "$USB_IDENTITY" --entitlements "$WORK/entitlements.plist" --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
