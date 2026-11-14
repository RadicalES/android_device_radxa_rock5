#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Assemble a bootable SD card image from a finished Android build.
#
#   lunch aosp_rock5b-bp1a-userdebug && m
#   UBOOT=/path/to/u-boot-rockchip.bin device/radxa/rock5/tools/mkimg.sh
#
# Everything is built inside a sparse image file (no sudo, no loop devices).
# Partition names must match ramdisk/fstab.rock5 (mounted by-name).
#
#   sector 64      u-boot-rockchip.bin (boot ROM offset)
#   p1  boot       FAT: Image, DTB, ramdisk.img, extlinux/extlinux.conf
#                  (built here; plain AOSP has no hook to replace boot.img)
#   p2  system     ext4
#   p3  vendor     ext4
#   p4  metadata   ext4 (empty)
#   p5  userdata   ext4 (empty), rest of the image

set -euo pipefail

die() { echo "!! $*"; exit 1; }

[ -n "${ANDROID_PRODUCT_OUT:-}" ] || die "ANDROID_PRODUCT_OUT is not set. Run lunch first."
OUT=$ANDROID_PRODUCT_OUT
TOP=${ANDROID_BUILD_TOP:?run lunch first}
UBOOT=${UBOOT:?set UBOOT to u-boot-rockchip.bin (bootloader/build-uboot.sh)}
[ -f "$UBOOT" ] || die "missing $UBOOT"
for f in kernel ramdisk.img system.img vendor.img; do
  [ -f "$OUT/$f" ] || die "missing $OUT/$f; build it first"
done

# Board settings come from the build, so they match BoardConfig*.mk
eval "$(cd "$TOP" && build/soong/soong_ui.bash --dumpvars-mode \
  --vars="BOARD_KERNEL_CMDLINE ROCK5_DTB KERNEL_PATH" 2>/dev/null)"
[ -n "${ROCK5_DTB:-}" ] && [ -n "${BOARD_KERNEL_CMDLINE:-}" ] || die "could not read board variables"
DTB_FILE=$TOP/$KERNEL_PATH/$ROCK5_DTB
[ -f "$DTB_FILE" ] || die "missing $DTB_FILE"

DEVICE=$(basename "$OUT")
IMG=${IMG:-$OUT/aosp15-$DEVICE-$(date +%Y%m%d).img}
IMG_SIZE_MIB=${IMG_SIZE_MIB:-14336}   # fits a 16 GB card

# Sizes in MiB; must match BoardConfigCommon.mk
BOOT_START=32
BOOT=128
SYSTEM=3072
VENDOR=384
METADATA=16

# lunch puts AOSP's own host sgdisk first on PATH; it lacks -o and friends.
SGDISK=${SGDISK:-$(PATH=/usr/sbin:/sbin:/usr/bin:/bin command -v sgdisk)} \
  || die "sgdisk not found (apt install gdisk)"

[ -e "$IMG" ] && die "$IMG already exists"
[ $(( $(stat -c %s "$UBOOT") + 64 * 512 )) -le $((BOOT_START * 1024 * 1024)) ] \
  || die "u-boot-rockchip.bin overlaps the boot partition"

SYSTEM_START=$((BOOT_START + BOOT))
VENDOR_START=$((SYSTEM_START + SYSTEM))
METADATA_START=$((VENDOR_START + VENDOR))
USERDATA_START=$((METADATA_START + METADATA))
USERDATA=$((IMG_SIZE_MIB - USERDATA_START - 1))   # 1 MiB left for the backup GPT
[ "$USERDATA" -gt 1024 ] || die "image too small for userdata"

echo ">> creating $IMG (${IMG_SIZE_MIB} MiB)"
truncate -s ${IMG_SIZE_MIB}M "$IMG"
# Attribute bit 2 (legacy BIOS bootable) on boot: U-Boot looks there for extlinux.conf
"$SGDISK" -o \
  -n 1:${BOOT_START}M:+${BOOT}M         -c 1:boot     -t 1:8300 -A 1:set:2 \
  -n 2:${SYSTEM_START}M:+${SYSTEM}M     -c 2:system   -t 2:8300 \
  -n 3:${VENDOR_START}M:+${VENDOR}M     -c 3:vendor   -t 3:8300 \
  -n 4:${METADATA_START}M:+${METADATA}M -c 4:metadata -t 4:8300 \
  -n 5:${USERDATA_START}M:+${USERDATA}M -c 5:userdata -t 5:8300 \
  "$IMG" >/dev/null
"$SGDISK" -i 5 "$IMG" | grep -q "Partition name: 'userdata'" || die "partitioning failed"

put() {  # put <file> <start MiB>
  dd if="$1" of="$IMG" bs=1M seek="$2" conv=notrunc,sparse status=none
}

echo ">> u-boot"
dd if="$UBOOT" of="$IMG" seek=64 conv=notrunc status=none
TMP=$(mktemp -d "$OUT/mkimg.XXXXXX")   # next to the output, not /tmp
trap 'rm -rf "$TMP"' EXIT

echo ">> boot ($ROCK5_DTB)"
sed -e "s|@DTB@|$ROCK5_DTB|" -e "s|@CMDLINE@|$BOARD_KERNEL_CMDLINE|" \
  "$TOP/device/radxa/rock5/boot/extlinux.conf" > "$TMP/extlinux.conf"
mkfs.fat -F 32 -n BOOT -C "$TMP/boot.vfat" $((BOOT * 1024)) >/dev/null
mmd -i "$TMP/boot.vfat" ::extlinux
mcopy -i "$TMP/boot.vfat" "$OUT/kernel" ::Image
mcopy -i "$TMP/boot.vfat" "$DTB_FILE" "$OUT/ramdisk.img" ::
mcopy -i "$TMP/boot.vfat" "$TMP/extlinux.conf" ::extlinux/extlinux.conf
put "$TMP/boot.vfat" $BOOT_START
rm -f "$TMP/boot.vfat"

echo ">> system, vendor"
put "$OUT/system.img" $SYSTEM_START
put "$OUT/vendor.img" $VENDOR_START

echo ">> metadata, userdata (empty ext4)"
truncate -s ${METADATA}M "$TMP/metadata.img"
truncate -s ${USERDATA}M "$TMP/userdata.img"
mkfs.ext4 -q -F -I 512 -L metadata "$TMP/metadata.img"
mkfs.ext4 -q -F -I 512 -L userdata "$TMP/userdata.img"
put "$TMP/metadata.img" $METADATA_START
put "$TMP/userdata.img" $USERDATA_START

echo ">> done: $IMG"
"$SGDISK" -p "$IMG" | sed -n '/^Number/,$p'
