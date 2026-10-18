# USB passthrough (experimental proof of concept)

> **Status: proof of concept on the `usb-passthrough-poc` branch of
> [beriberikix/container](https://github.com/beriberikix/container).** Not part of apple/container.
> Verified on macOS 27.0 (`26A428`) with Xcode 27.0 and a SEGGER J-Link.

`container run --usb <vid[:pid]>` passes a physical USB device — a debug probe, a serial
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
  certificate and a provisioning profile. There is no prebuilt package for that reason.
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
git clone -b usb-passthrough-poc https://github.com/beriberikix/container
cd container
make USB_BUNDLE_ID=com.example.container-usb \
     USB_PROFILE=/path/to/profile.provisionprofile
```

This builds everything as usual and additionally stages `libexec/container/usb/container-usb.app`,
signed with the first Apple Development identity in your keychain (override with
`USB_IDENTITY="Apple Development: …"`). Use the in-tree build (`bin/container`) rather than
`make install`. Without `USB_PROFILE` the build is unchanged and `--usb` reports that the broker
is not installed.

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
Pass it per container with `--kernel` so other containers keep the default kernel.

## 3. Run

```bash
bin/container system start
bin/container build -t usb-tools examples/usb
bin/container run -d --name probe --usb 1366 --kernel bin/vmlinux-arm64-usb usb-tools sleep infinity
```

A **container** icon appears in the Dock while the container runs — that is the USB broker.
The first time, open the **Virtual Machine Accessories** menu bar item and choose
**Use with container** for the device. The choice persists, so later runs pick the device up
without a click. The menu bar item is only there while a `--usb` container runs; once every
one has stopped it disappears until the next. Then:

```bash
bin/container exec probe lsusb
bin/container exec probe probe-rs list
```

`--usb` takes a hex vendor ID (`1366`) or vendor and product (`1366:0105`) and can be repeated.
A vendor ID alone is the safer choice: product IDs differ between models of the same probe
(SEGGER J-Links report `0101`, `0105`, `1061` and others), and only devices you assigned in the
menu are attached either way. To look up a device's IDs:

```bash
system_profiler SPUSBHostDataType | grep -E "^ +[^ ].*:$|Vendor ID|Product ID"
```

The runtime waits briefly for devices before starting the container (`--usb-wait <seconds>`,
default 5) and never fails if a device is missing: one assigned later is attached while the
container runs. `container stop` detaches the device, quits the broker and returns the device
to macOS.

## How it works

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

- **`container-usb-broker`** (the app): launched by the runtime when a `--usb` container boots.
  It holds the AccessoryAccess listener, receives devices assigned from the menu, and forwards
  them to the runtime as XPC representations (`AAUSBAccessory` `createXPCRepresentation`) over
  the runtime's mach service; the runtime attaches the ones matching `--usb`. It quits when the container stops.
  It also runs a tiny idle VM with an XHCI controller: the assignment menu has only appeared
  while the registering application was itself running one.
- **`container-runtime-linux`**: the unchanged runtime helper, signed with the app's identifier
  but no restricted entitlements. The runtime plugin's binary is a symlink to it, so launchd
  runs it from inside the bundle. It rebuilds each forwarded accessory, attaches it to the
  container's VM with `VZUSBPassthroughDevice` through a `VZInstanceExtension`, and detaches it
  on stop.

The guest kernel needs USB host support built in; the container's `/dev` is a devtmpfs, so
`/dev/bus/usb` nodes appear without udev.

## Limitations

- macOS 27+ only; one container per device.
- The broker shows a Dock icon while a USB container runs.
- The broker registers for all devices (empty matching criteria), so the menu may offer
  unrelated devices; only those matching `--usb` are attached, and `run` names assigned devices
  that match no filter.
  `AAUSBAccessoryMatchingCriteria` accepts only the legacy `IOUSBDevice` matching dictionary
  (FB24018643).
- AccessoryAccess releases devices on logout and fast user switching.
- Logs: `bin/container system logs` shows the runtime (`usb:`) and broker (`USBBroker`) lines;
  the guest kernel's USB messages are in `container logs --boot <id>`.
