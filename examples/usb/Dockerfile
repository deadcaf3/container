# USB passthrough example: lsusb and probe-rs for debug probes passed through with --usb.
FROM ubuntu:24.04

ARG PROBE_RS_VERSION=0.32.0

RUN apt-get update \
&&  apt-get install -y --no-install-recommends ca-certificates curl libudev1 usbutils xz-utils \
&&  rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/probe-rs/probe-rs/releases/download/v${PROBE_RS_VERSION}/probe-rs-tools-aarch64-unknown-linux-gnu.tar.xz" \
        | tar -xJ -C /tmp \
&&  install -m 755 "$(find /tmp -type f -name probe-rs | head -1)" /usr/local/bin/probe-rs \
&&  rm -rf /tmp/probe-rs-tools-*

CMD ["probe-rs", "list"]
