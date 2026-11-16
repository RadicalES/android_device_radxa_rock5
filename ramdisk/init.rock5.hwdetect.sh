#!/vendor/bin/sh
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Detect optional hardware and report it in vendor.rock5.* properties. Runs
# once from init.rock5.rc (exec_start in post-fs-data); init.rock5.rc then
# enables the features of what is present, before zygote starts and
# system_server reads /vendor/etc/permissions. (Only init may mount over
# /vendor files, so the script itself does not.)
#
# Bluetooth: an M.2 E-key module (e.g. RTL8852BE) is a USB Bluetooth adapter.
# Its features are declared only if the kernel has an HCI device, so a board
# without one has no Bluetooth stack at all rather than one that cannot start.

log() { echo "rock5-hwdetect: $*" > /dev/kmsg; }

has_hci() { ls /sys/class/bluetooth/ 2>/dev/null | grep -q '^hci'; }

# A USB interface of class e0 (wireless controller) is a Bluetooth adapter
# that the kernel may still be setting up; give it a few seconds.
has_bt_usb() { cat /sys/bus/usb/devices/*/bInterfaceClass 2>/dev/null | grep -q '^e0$'; }

if ! has_hci && has_bt_usb; then
  for i in 1 2 3 4 5 6 7 8 9 10; do
    has_hci && break
    sleep 0.5
  done
fi

if has_hci; then
  setprop vendor.rock5.bluetooth present
  log "bluetooth: adapter present"
else
  setprop vendor.rock5.bluetooth absent
  log "bluetooth: no adapter"
fi
exit 0
