#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Kernel bring-up card: U-Boot + kernel + DTB, no Android.
#
#   tools/mksdcard-kernel-test.sh [dtb]      # default: rk3588-rock-5b.dtb
#
# Output: out/rock5-kernel-test.img. Write it with
#   sudo dd if=out/rock5-kernel-test.img of=/dev/sdX bs=4M conv=fsync
#
# There is no root filesystem, so a working kernel ends in
#   "VFS: Unable to mount root fs" / "No working init found"
# on the debug UART (1500000 baud). Getting there proves the kernel, DTB,
# clocks, PMIC and storage come up.

set -euo pipefail

DTB=${1:-rk3588-rock-5b.dtb}
TOP=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$TOP/out}
UBOOT=$WORK/bootloader/u-boot-rockchip.bin
KDIR=$WORK/kernel
IMG=$WORK/rock5-kernel-test.img
BOOTFS=$WORK/kernel-test-boot.vfat

for f in "$UBOOT" "$KDIR/Image" "$KDIR/$DTB"; do
  [ -f "$f" ] || { echo "!! missing $f (run kernel/build-kernel.sh and bootloader/build-uboot.sh)"; exit 1; }
done

# Layout: U-Boot at sector 64 (boot ROM offset, ~10 MiB), boot partition from 32 MiB.
BOOT_START_MIB=32
BOOT_SIZE_MIB=128
IMG_SIZE_MIB=$((BOOT_START_MIB + BOOT_SIZE_MIB + 1))
if [ $(( $(stat -c %s "$UBOOT") + 64 * 512 )) -gt $((BOOT_START_MIB * 1024 * 1024)) ]; then
  echo "!! u-boot-rockchip.bin overlaps the boot partition"; exit 1
fi

cat > "$WORK/extlinux.conf" <<EOF
default kernel-test
timeout 1

label kernel-test
    kernel /Image
    fdt /$DTB
    append console=ttyS2,1500000 earlycon no_console_suspend panic=0
EOF

rm -f "$BOOTFS" "$IMG"
mkfs.fat -F 32 -n BOOT -C "$BOOTFS" $((BOOT_SIZE_MIB * 1024)) >/dev/null
mmd -i "$BOOTFS" ::extlinux
mcopy -i "$BOOTFS" "$KDIR/Image" "$KDIR/$DTB" ::
mcopy -i "$BOOTFS" "$WORK/extlinux.conf" ::extlinux/extlinux.conf

truncate -s ${IMG_SIZE_MIB}M "$IMG"
# Attribute bit 2 = legacy BIOS bootable, which U-Boot uses to find extlinux.conf
sgdisk -o \
  -n 1:${BOOT_START_MIB}M:+${BOOT_SIZE_MIB}M -c 1:boot -t 1:8300 -A 1:set:2 \
  "$IMG" >/dev/null
sgdisk -i 1 "$IMG" | grep -q "Partition name: 'boot'" || { echo "!! partitioning failed"; exit 1; }
dd if="$UBOOT" of="$IMG" seek=64 conv=notrunc status=none
dd if="$BOOTFS" of="$IMG" bs=1M seek=$BOOT_START_MIB conv=notrunc status=none
rm -f "$BOOTFS"

echo ">> $IMG ($DTB, kernel $(cat "$KDIR/version"))"
