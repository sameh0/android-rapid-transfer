#!/bin/sh
# .deb/.rpm post-install and post-remove: makes udev pick up (or drop) the
# package's rule for phones that are already plugged in. Never fails the
# package operation (containers and chroots have no running udev).
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --subsystem-match=usb --action=change >/dev/null 2>&1 || true
fi
exit 0
