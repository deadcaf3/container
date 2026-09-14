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

# Stage the USB broker as a provisioned app bundle.
#
#   scripts/usb/bundle-broker.sh <staging-dir> <container-usb-broker binary>
#
# Requires USB_BUNDLE_ID (an explicit App ID with the "Claim USB Accessory" capability) and
# USB_PROFILE (a macOS development provisioning profile for it). USB_IDENTITY defaults to the
# first "Apple Development" identity in the keychain.
#
# AccessoryAccess only assigns devices to an ordinary, Dock-visible application, and
# com.apple.developer.accessory-access.usb is a restricted entitlement that needs an app bundle
# with the profile embedded. The broker is that app; the runtime helper stays unprovisioned.
set -euo pipefail

STAGING_DIR="${1:?usage: bundle-broker.sh <staging-dir> <broker-binary> <runtime-binary>}"
BINARY="${2:?usage: bundle-broker.sh <staging-dir> <broker-binary> <runtime-binary>}"
RUNTIME_BINARY="${3:?usage: bundle-broker.sh <staging-dir> <broker-binary> <runtime-binary>}"
: "${USB_BUNDLE_ID:?set USB_BUNDLE_ID to your App ID (see docs/usb-passthrough.md)}"
: "${USB_PROFILE:?set USB_PROFILE to the .provisionprofile for USB_BUNDLE_ID}"
USB_IDENTITY="${USB_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)}"
[ -n "$USB_IDENTITY" ] || { echo "no Apple Development identity found; set USB_IDENTITY" >&2; exit 1; }
[ -f "$USB_PROFILE" ] || { echo "USB_PROFILE not found: $USB_PROFILE" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME=container-usb-broker
APP="$STAGING_DIR/libexec/container/usb/container-usb.app"
VERSION="${RELEASE_VERSION:-0.0.0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> staging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
install "$BINARY" "$APP/Contents/MacOS/$NAME"
sed -e "s/@USB_BUNDLE_ID@/$USB_BUNDLE_ID/" -e "s/@VERSION@/$VERSION/" \
	"$ROOT/Sources/Plugins/USBBroker/Info.plist.in" > "$APP/Contents/Info.plist"
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
# accessoryaccessd hands an assigned device only to a requestor it attributes to the client
# app ("Invalid seize request. The device is not available for the requestor."), and that
# attribution follows the executable's enclosing bundle. So the runtime helper that attaches
# devices lives inside this bundle, signed with its identifier but no restricted entitlements
# (AMFI cannot pair a bare Mach-O with the embedded profile), and the runtime plugin's binary
# is a relative symlink to it.
RUNTIME_IN_BUNDLE="$APP/Contents/MacOS/container-runtime-linux"
install "$RUNTIME_BINARY" "$RUNTIME_IN_BUNDLE"
cat > "$WORK/runtime.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.virtualization</key>
	<true/>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.get-task-allow</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --sign "$USB_IDENTITY" --identifier "$USB_BUNDLE_ID" --entitlements "$WORK/runtime.entitlements" --timestamp=none "$RUNTIME_IN_BUNDLE"
PLUGIN_BIN="$STAGING_DIR/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux"
rm -f "$PLUGIN_BIN"
ln -s ../../../usb/container-usb.app/Contents/MacOS/container-runtime-linux "$PLUGIN_BIN"

codesign --force --sign "$USB_IDENTITY" --entitlements "$WORK/entitlements.plist" --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
