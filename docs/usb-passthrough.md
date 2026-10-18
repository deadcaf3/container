# USB passthrough (experimental proof of concept)

> **Status: proof of concept on the `usb-passthrough-poc` branch of
> [deadcaf3/container](https://github.com/deadcaf3/container).** Not part of apple/container.
> Verified on macOS 27.0 (`26A428`) with Xcode 27.0 and a SEGGER J-Link. Based on Jonathan Beri's
> original proof of concept in [beriberikix/container](https://github.com/beriberikix/container).

`container run --usb <vid[:pid[:serial]]>` passes a physical USB device — a debug probe, a serial
adapter — through to the Linux VM backing a container, using the macOS 27
`VZUSBPassthroughDevice` API. Inside the container the device appears under `/dev/bus/usb`
and tools like `lsusb` and `probe-rs` use it directly. The capture is exclusive: macOS cannot
use the device while the container holds it.

Background: [beriberikix/usb-macos-vm](https://github.com/beriberikix/usb-macos-vm) and
[apple/container#640](https://github.com/apple/container/issues/640).

## Requirements

- Apple silicon, **macOS 27** or later, **Xcode 27** (the macOS 27 SDK).
- A **paid Apple Developer membership.** `com.apple.developer.accessory-access.usb` is a
  restricted entitlement, so part of the build is signed with your Apple Development
  certificate and a provisioning profile. A [Developer ID build](#distribution-build-developer-id)
  signed by one team runs on any Mac without this, but none is published yet.
- A guest kernel with USB host support — the default kernel has USB disabled. See
  [Guest kernel](#guest-kernel).
- Run `container` from a Terminal in your logged-in GUI session, not over SSH.

## 1. Create an App ID and profile

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources):

1. **Identifiers → +** → App IDs → App → an **explicit** Bundle ID, for example
   `com.example.container-usb`. Under Capabilities tick **Claim USB Accessory** — that is
   `com.apple.developer.accessory-access.usb`; the portal does not list it under that name.
2. **Devices → +** → macOS, with your Mac's **Provisioning UDID**
   (`system_profiler SPHardwareDataType | grep "Provisioning UDID"`) — not the Hardware UUID.
3. **Certificates → +** → **Apple Development**, if you don't already have one whose private
   key is in your login keychain.
4. **Profiles → +** → **macOS App Development** → your App ID, certificate and Mac. Download the
   `.provisionprofile`.

If `security find-identity -v -p codesigning` shows no Apple Development identity after
importing the certificate, install the
[Apple WWDR G3 intermediate](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer).

## 2. Build

```bash
git clone -b usb-passthrough-poc https://github.com/deadcaf3/container
cd container
make USB_BUNDLE_ID=com.example.container-usb \
     USB_PROFILE=/path/to/profile.provisionprofile
```

This builds everything as usual and additionally stages `libexec/container/usb/container-usb.app`,
signed with the first Apple Development identity in your keychain (override with
`USB_IDENTITY="Apple Development: …"`). Use the in-tree build (`bin/container`) rather than
`make install`. Without `USB_PROFILE` the build is unchanged and `--usb` reports that the broker
is not installed.

## Distribution build (Developer ID)

A development profile only works on the Macs registered in it. A Developer ID profile has no
device list, so one build signed by one team runs on any Mac, and once notarized, Gatekeeper
accepts it after a download. People who install that build need no Apple Developer membership.

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources), with the
App ID from step 1:

1. **Certificates → +** → **Developer ID Application**, and **Developer ID Installer** to sign the
   package. Choose the **G2 Sub-CA**. If `security find-identity -v` does not list them after
   importing, install the
   [Developer ID G2 intermediate](https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer).
2. **Profiles → +** → under Distribution, **Developer ID** → your App ID and Developer ID
   Application certificate. There is no device step. Download the `.provisionprofile`.

Build and sign the package:

```bash
make release SIGN_IDENTITY="Developer ID Application: <name> (<team-id>)" \
     INSTALLER_IDENTITY="Developer ID Installer: <name> (<team-id>)" \
     USB_BUNDLE_ID=com.example.container-usb \
     USB_PROFILE=/path/to/developer-id.provisionprofile
```

`SIGN_IDENTITY` signs every binary with the hardened runtime and a secure timestamp.
`bundle-broker.sh` sees that the profile provisions all devices and signs `container-usb.app` the
same way, without `get-task-allow`. `INSTALLER_IDENTITY` signs the package, which is written to
`bin/release/container-installer.pkg`. Without it the package is unsigned and cannot be
notarized.

Notarize and staple the package:

```bash
# Once: save notary credentials (prompts for an app-specific password from account.apple.com).
xcrun notarytool store-credentials <keychain-profile> --apple-id <apple-id> --team-id <team-id>

xcrun notarytool submit bin/release/container-installer.pkg --keychain-profile <keychain-profile> --wait
xcrun stapler staple bin/release/container-installer.pkg
spctl -a -t install -vv bin/release/container-installer.pkg   # accepted, source=Notarized Developer ID
```

The package installs into `/usr/local` with the same identifiers as an apple/container release,
so it replaces an existing installation.

Verified so far: on a debug build, the signed package notarizes with no issues and, once
stapled, a quarantined copy passes Gatekeeper. A release build signed with `SIGN_IDENTITY` and
installed into `/usr/local` with `make BUILD_CONFIGURATION=release ... install` starts, runs
containers, and passes a J-Link through, including selection by serial. That install used an
unsigned package without notarization; notarizing a release package has not been tested.

## Guest kernel

Download `vmlinux-arm64-usb` from the fork's
[releases](https://github.com/beriberikix/container/releases), or build it locally (uses
`container` itself, ~10 GB RAM for the build VM):

```bash
scripts/usb/build-kernel.sh      # → bin/vmlinux-arm64-usb
```

The kernel is containerization's guest kernel config plus
[`kernel/usb/config-arm64-usb.fragment`](../kernel/usb/config-arm64-usb.fragment): the XHCI host
controller, USB core and usbfs (`/dev/bus/usb`), CDC ACM, common USB serial adapters, and HID.
Pass it per container with `--kernel` so other containers keep the default kernel. If `--usb` is
used with a kernel that has no USB host support (such as the default kernel), the runtime still
starts the container but prints a warning saying the devices cannot appear in the guest.

## 3. Run

```bash
bin/container system start
bin/container build -t usb-tools examples/usb
bin/container run -d --name probe --usb 1366 --kernel bin/vmlinux-arm64-usb usb-tools sleep infinity
```

A **container** icon appears in the Dock while the USB broker runs. One broker serves every
container; the first `--usb` container or `container usb ls` starts it. The first time, open
the **Virtual Machine Accessories** menu bar item and choose **Use with container** for the
device. The choice persists, so later runs pick the device up without a click. The menu bar
item is only there while the broker runs; it quits 60 s after the last `--usb` container
stopped. Then:

```bash
bin/container exec probe lsusb
bin/container exec probe probe-rs list
```

`--usb` takes a hex vendor ID (`1366`), vendor and product (`1366:0105`) or vendor, product and
serial number (`1366:0105:000123456789`) and can be repeated. A vendor ID alone is the safer
choice: product IDs differ between models of the same probe (SEGGER J-Links report `0101`,
`0105`, `1061` and others), and only devices you assigned in the menu are attached either way.
Add the serial when two devices of the same model are plugged in and each container must get
its own; it is matched exactly, case-sensitive, and may itself contain colons (the ESP32
USB-JTAG serial is its MAC address). An empty serial (`1366:0105:`) matches a device that
reports none. Some devices report a placeholder (hubs show `000000000`), so the serial only
helps when it is unique. To look up a device's IDs and serial:

```bash
system_profiler SPUSBHostDataType | grep -E "^ +[^ ].*:$|Vendor ID|Product ID|Serial Number"
```

The runtime waits briefly for devices before starting the container (`--usb-wait <seconds>`,
default 5) and never fails if a device is missing: one assigned later is attached while the
container runs. `container stop` detaches the device and returns it to the broker, which hands
it to another running container whose filter matches; macOS gets it back when the broker quits.

## Devices as a resource

Devices can be listed, and moved between running containers without restarting them:

```bash
bin/container usb ls                     # ID, serial, product and state of every device assigned to the broker
bin/container usb attach 1366 probe      # request a device for a running container, moving it if another holds it
bin/container usb detach 1366 [probe]    # return it to the broker; the container is optional when only one holds it
```

`usb ls` works with no container running, and shows each device as `attached to <container>` or
`assigned` (chosen in the menu but attached to no container, usually because it matches no
filter). A device withdrawn in the menu or unplugged drops out of the list. The device argument
is the `--usb` selector. `attach` is a no-op with a message when the container already requests
a filter covering the device; when another container holds the device, that container detaches
it and the broker hands it over. `detach` fails when no attached device matches. Both need a
running container that was started with `--usb`, since only those VMs have a USB controller. A
newly assigned device goes to the earliest registered running container whose filter matches;
a device a container gives up goes to the next match, never straight back.

## How it works

The path from the USB port to a process in the container, using only Apple frameworks and the
Linux kernel:

1. The device is plugged into the Mac. macOS owns it.
2. `container-usb.app`, the broker, registers with AccessoryAccess and the user assigns the
   device to it in the **Virtual Machine Accessories** menu (`AAUSBAccessory`, macOS 27).
3. The broker forwards the accessory over XPC to the `container-runtime-linux` of the container
   whose `--usb` filter matches.
4. The runtime attaches it to the container's VM as a `VZUSBPassthroughDevice`
   (Virtualization framework).
5. The guest kernel enumerates it and creates `/dev/bus/usb/<bus>/<dev>`, plus class nodes such
   as `/dev/ttyACM0` for a CDC ACM interface.
6. Any Linux tool in the container opens those nodes as usual: `lsusb`, `probe-rs`, `JLinkExe`,
   `openocd`, `west flash`, `screen /dev/ttyACM0`.

Nothing in the container is aware of the passthrough; `probe-rs` appears above only as the smoke
test in the examples.

Three constraints on macOS 27 shape the design, each found by experiment:

1. **AccessoryAccess only assigns devices to an ordinary, Dock-visible application**
   (`AAUSBAccessoryManager.h`). The runtime helper, `container-runtime-linux`, is started by
   launchd and classified as a background service, so the assignment menu never appears for it —
   even if it checks in as a regular application.
2. **A restricted entitlement needs an app bundle with the profile embedded.** A bare
   executable carrying `com.apple.developer.accessory-access.usb` is killed at launch
   ("No matching profile found").
3. **`accessoryaccessd` only surrenders an assigned device to its client application.** When the
   VM tries to open the device it checks the requestor, and a process whose executable is outside
   the client's bundle is refused ("Invalid seize request. The device is not available for the
   requestor.") — even with the same team and signing identifier.

So a USB build stages one provisioned app, `container-usb.app`, containing two executables:

- **`container-usb-broker`** (the app): one instance for every container, launched on demand by
  the API server. It holds the AccessoryAccess listener and every device assigned from the
  menu. Runtimes register their container, mach service, pid and `--usb` filters with it, and
  it forwards each device as an XPC representation (`AAUSBAccessory`
  `createXPCRepresentation`) to the runtime whose filter matches. It also runs a tiny idle VM
  with an XHCI controller: the assignment menu has only appeared while the registering
  application was itself running one.
- **`container-runtime-linux`**: the unchanged runtime helper, signed with the app's identifier
  but no restricted entitlements. The runtime plugin's binary is a symlink to it, so launchd
  runs it from inside the bundle. It rebuilds each forwarded accessory, attaches it to the
  container's VM with `VZUSBPassthroughDevice` through a `VZInstanceExtension`, and detaches it
  on stop.

An app launched by LaunchServices cannot check in a launchd mach service, and a broker that
launchd starts is a background service that is never offered a device, so the broker has no
fixed mach service of its own. It serves an anonymous XPC listener and checks its endpoint in
with the API server (`com.apple.container.apiserver`), which launches the broker on demand and
hands the endpoint to runtimes; a runtime then talks to the broker directly, so an API server
restart does not interrupt it. The broker checks in again when the API server restarts, drops
a registration when its runtime exits, and quits after 60 s without a request once no runtime
is registered.

A device that a VM lets go (`usb detach`, a move, `container stop`) re-enumerates on the Mac:
AccessoryAccess withdraws its accessory and, because the menu assignment persists, offers the
same device again as a new accessory, with a new registry ID, a few hundred milliseconds later
(300 to 420 ms with a J-Link). A second `createXPCRepresentation` of the withdrawn accessory is
useless: the receiving runtime cannot rebuild it. So the broker remembers the release for 10 s
and gives the device's new accessory to the next matching container, excluding the one that let
it go; if the device has not re-enumerated after 2 s, it offers the old accessory instead.

The guest kernel needs USB host support built in; the container's `/dev` is a devtmpfs, so
`/dev/bus/usb` nodes appear without udev.

## Limitations

- macOS 27+ only; one container per device.
- The broker shows a Dock icon while it runs.
- The broker registers for all devices (empty matching criteria), so the menu may offer
  unrelated devices; only those matching `--usb` are attached, and `run` names assigned devices
  that match no filter.
  `AAUSBAccessoryMatchingCriteria` accepts only the legacy `IOUSBDevice` matching dictionary
  (FB24018643).
- AccessoryAccess releases devices on logout and fast user switching.
- Logs: `bin/container system logs` shows the runtime (`usb:`) and broker (`USBBroker`) lines;
  the guest kernel's USB messages are in `container logs --boot <id>`.

## Open blockers

What stands between this proof of concept and `--usb` working out of the box.

### 1. Signing and distribution

- **Problem:** a development build needs each user's own paid membership, App ID, registered Mac
  and provisioning profile, which is about 30 minutes in the developer portal before anything
  runs.
- **Status:** solved in the fork, not yet published. A
  [Developer ID signed and notarized package](#distribution-build-developer-id) passes
  Gatekeeper, and a release build installed into `/usr/local` passes a J-Link through.
- **Remaining:** notarize the release package and publish it as a release asset. Users then
  trust the fork's team instead of Apple.
- **Who can fix it:** the fork's maintainer. Upstream, Apple would sign its own release with the
  entitlement.

### 2. Custom guest kernel

- **Problem:** the default kernel has USB disabled, so every `--usb` run also needs
  `--kernel` with a kernel the user downloaded or built.
- **Status:** open. The default kernel is the Kata Containers static release
  (`KernelConfig.defaultURL` in `ContainerSystemConfig.swift`), not containerization's
  `kernel/config-arm64`, so upstreaming `config-arm64-usb.fragment` into containerization
  would not change what `container` boots.
- **Fix, short term (fork):** `vmlinux-arm64-usb` is already a release asset
  (`usb-kernel-0.1`), and `--usb` already warns when the kernel has no USB host support. Have
  that warning point at the asset, or fetch it and use it when `--usb` is given without `--kernel`.
- **Fix, long term:** add USB host support to Kata's kernel config fragments, which would reach
  `container` when it next bumps the Kata release. The fallback is for apple/container to host a
  USB kernel of its own and select it when `--usb` is given.
- **Who can fix it:** the fork for pointing at the asset or the automatic download;
  kata-containers for the kernel config; apple/container for a hosted USB kernel.
