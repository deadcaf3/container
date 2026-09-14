# USB passthrough (experimental proof of concept)

> **Status: work in progress on the `usb-passthrough-poc` branch of
> [beriberikix/container](https://github.com/beriberikix/container).** Not part of apple/container.
> This page is updated as each step is verified end to end.

`container run --usb <vid[:pid]>` passes a physical USB device — a debug probe, a serial
adapter — through to the Linux VM backing a container, using the macOS 27
`VZUSBPassthroughDevice` API. The device is captured exclusively: macOS cannot use it while the
container holds it.

Background and the requirements this is built on:
[beriberikix/usb-macos-vm](https://github.com/beriberikix/usb-macos-vm) and
[apple/container#640](https://github.com/apple/container/issues/640).

## Requirements

- Apple silicon, **macOS 27** or later, **Xcode 27** (the macOS 27 SDK).
- A **paid Apple Developer membership.** `com.apple.developer.accessory-access.usb` is a
  restricted entitlement: the USB runtime must be signed with an Apple Development certificate
  and a provisioning profile. There is no prebuilt package for that reason — you build it with
  your own team.
- A guest kernel with USB host support. The default kernel has USB disabled; see
  [Guest kernel](#guest-kernel).
- Run `container` from a Terminal in your logged-in GUI session (not over SSH): the device is
  handed over through a menu bar item.

## 1. Create an App ID and profile

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources):

1. **Identifiers → +** → App IDs → App → an **explicit** Bundle ID, for example
   `com.example.container-runtime-usb`. Under Capabilities tick **Claim USB Accessory** — that
   is `com.apple.developer.accessory-access.usb`; the portal does not list it under that name.
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
make USB_BUNDLE_ID=com.example.container-runtime-usb \
     USB_PROFILE=/path/to/profile.provisionprofile
```

This builds everything as usual and additionally stages
`libexec/container/plugins/container-runtime-linux-usb.app`, signed with the first Apple
Development identity in your keychain (override with `USB_IDENTITY="Apple Development: …"`).
Containers without `--usb` keep using the normal `container-runtime-linux`.

Use the in-tree build (`make`, then `bin/container`) rather than `make install`.

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
bin/container run -d --name probe --usb 1366:0101 --kernel bin/vmlinux-arm64-usb usb-tools sleep infinity
```

The first time, open the **Virtual Machine Accessories** menu bar item and choose
**Use with container** for the device. The choice persists for your App ID, so later runs pick
the device up without a click. Then:

```bash
bin/container exec probe lsusb
bin/container exec probe probe-rs list
```

`--usb` takes a hex vendor ID (`1366`) or vendor and product (`1366:0101`) and can be repeated.
The runtime waits up to 5 seconds for already-assigned devices before starting the container
(`--usb-wait <seconds>` to change it) and never fails if a device is missing — a device assigned
later is attached while the container runs.

## Limitations

- macOS 27+ only; one container per device (the second attach fails with a warning).
- Capture is exclusive for as long as the container runs.
- AccessoryAccess releases devices on logout and fast user switching.
- Matching is by vendor in AccessoryAccess and by product in the runtime, because
  `AAUSBAccessoryMatchingCriteria` only accepts the legacy `IOUSBDevice` matching dictionary
  (FB24018643).
- Runtime logs (listener, attach, detach) are in the helper log for the container; the guest
  kernel's USB messages are in `container logs --boot <id>`.
