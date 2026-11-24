#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Assemble a bootable SD card image from a finished Android build.
#
#   lunch aosp_rock5b-bp1a-userdebug && m
#   device/radxa/rock5/tools/mkimg.sh
#
# U-Boot comes from the prebuilt repo (device/radxa/rock5-kernel); set
# UBOOT=/path/to/u-boot-rockchip.bin to use another (bootloader/build-uboot.sh).
#
# Everything is built inside a sparse image file (no sudo, no loop devices).
# Partition names must match ramdisk/fstab.rock5 (mounted by-name).
#
#   sector 64      u-boot-rockchip.bin (boot ROM offset)
#   p1  boot       FAT: Image, DTB, overlays/*.dtbo, ramdisk.img,
#                  extlinux/extlinux.conf
#                  (built here; plain AOSP has no hook to replace boot.img)
#   p2  system     ext4
#   p3  vendor     ext4
#   p4  metadata   ext4 (empty)
#   p5  userdata   ext4 (empty), rest of the image
#
# INSTALLER=1 makes an installer card instead: the same image, but U-Boot's
# default entry boots installer.img (installer/installer.cpp), which copies
# the card to the internal storage and grows userdata to fill it.
#   INSTALL_TARGET  sysfs path part of the target disk (default fe2e0000.mmc,
#                   the eMMC); the copy boots from that controller
#   INSTALLER_ARGS  extra kernel arguments for the installer, e.g.
#                   rock5_installer.dry_run=1 or rock5_installer.countdown=5
# The image is 14 GiB (16 GB card), or the smallest that works (about 4.6 GiB,
# 8 GB card) with INSTALLER=1; IMG_SIZE_MIB overrides it. tools/mkinstaller.sh
# wraps INSTALLER=1, docs/INSTALLER.md explains the installer.

set -euo pipefail

die() { echo "!! $*"; exit 1; }

[ -n "${ANDROID_PRODUCT_OUT:-}" ] || die "ANDROID_PRODUCT_OUT is not set. Run lunch first."
OUT=$ANDROID_PRODUCT_OUT
TOP=${ANDROID_BUILD_TOP:?run lunch first}
for f in kernel ramdisk.img system.img vendor.img; do
  [ -f "$OUT/$f" ] || die "missing $OUT/$f; build it first"
done

# Board settings come from the build, so they match BoardConfig*.mk
eval "$(cd "$TOP" && build/soong/soong_ui.bash --dumpvars-mode \
  --vars="BOARD_KERNEL_CMDLINE ROCK5_DTB ROCK5_DTBOS KERNEL_PATH TARGET_ARCH TARGET_ARCH_VARIANT TARGET_CPU_VARIANT" 2>/dev/null)"
[ -n "${ROCK5_DTB:-}" ] && [ -n "${BOARD_KERNEL_CMDLINE:-}" ] || die "could not read board variables"
DTB_FILE=$TOP/$KERNEL_PATH/$ROCK5_DTB
[ -f "$DTB_FILE" ] || die "missing $DTB_FILE"
UBOOT=${UBOOT:-$TOP/$KERNEL_PATH/u-boot-rockchip.bin}
[ -f "$UBOOT" ] || die "missing $UBOOT"

INSTALLER=${INSTALLER:-0}
INSTALL_TARGET=${INSTALL_TARGET:-fe2e0000.mmc}
BOOT_DEVICE=$(sed -n 's/.*androidboot\.boot_devices=\([^ ]*\).*/\1/p' <<<"$BOARD_KERNEL_CMDLINE")
[ -n "$BOOT_DEVICE" ] || die "no androidboot.boot_devices in BOARD_KERNEL_CMDLINE"

DEVICE=$(basename "$OUT")
IMG=${IMG:-$OUT/aosp15-$DEVICE-$(date +%Y%m%d).img}

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
# A normal card fits a 16 GB card. An installer card copies only what comes
# before userdata, so it gets the smallest image (fits an 8 GB card).
if [ "$INSTALLER" = 1 ]; then
  IMG_SIZE_MIB=${IMG_SIZE_MIB:-$((USERDATA_START + 1025 + 1))}
else
  IMG_SIZE_MIB=${IMG_SIZE_MIB:-14336}
fi
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

echo ">> boot ($ROCK5_DTB${ROCK5_DTBOS:+ + ${ROCK5_DTBOS}})"
# Device-tree overlays (ROCK5_DTBOS, BoardConfig.mk), compiled with AOSP's dtc
DTC=$TOP/prebuilts/misc/linux-x86/dtc/dtc
mkdir -p "$TMP/overlays"
FDTOVERLAYS=
for src in ${ROCK5_DTBOS:-}; do
  dtbo=$(basename "${src%.dtso}").dtbo
  "$DTC" -q -@ -I dts -O dtb -o "$TMP/overlays/$dtbo" "$TOP/device/radxa/rock5/$src" \
    || die "dtc failed on $src"
  FDTOVERLAYS="$FDTOVERLAYS /overlays/$dtbo"
done
if [ -n "$FDTOVERLAYS" ]; then
  OVL_SED="s|^@FDTOVERLAYS@\$|    fdtoverlays$FDTOVERLAYS|"
else
  OVL_SED="/^@FDTOVERLAYS@\$/d"
fi
sed -e "s|@DTB@|$ROCK5_DTB|" -e "s|@CMDLINE@|$BOARD_KERNEL_CMDLINE|" -e "$OVL_SED" \
  "$TOP/device/radxa/rock5/boot/extlinux.conf" > "$TMP/extlinux.conf"
if [ "$INSTALLER" = 1 ]; then
  echo ">> installer (target $INSTALL_TARGET)"
  # Not installed on any partition, so built by its output path
  INSTALLER_OUT=out/soong/.intermediates/device/radxa/rock5/installer/rock5_installer
  INSTALLER_OUT=$INSTALLER_OUT/android_${TARGET_ARCH}_${TARGET_ARCH_VARIANT}_${TARGET_CPU_VARIANT}/rock5_installer
  (cd "$TOP" && build/soong/soong_ui.bash --make-mode "$INSTALLER_OUT" >/dev/null) \
    || die "building rock5_installer failed"
  INSTALLER_BIN=$TOP/$INSTALLER_OUT
  [ -f "$INSTALLER_BIN" ] || die "missing $INSTALLER_BIN"
  mkdir -p "$TMP/installer-root"
  install -m 0755 "$INSTALLER_BIN" "$TMP/installer-root/init"
  "$TOP/out/host/linux-x86/bin/mkbootfs" "$TMP/installer-root" | gzip -9 > "$TMP/installer.img"
  # What the installed system boots: this config, on the target's controller
  sed "s|androidboot.boot_devices=$BOOT_DEVICE|androidboot.boot_devices=$INSTALL_TARGET|" \
    "$TMP/extlinux.conf" > "$TMP/extlinux.conf.target"
  # The card itself boots the installer by default; "android" still runs the
  # system from the card
  INSTALLER_APPEND="console=ttyS2,1500000 earlycon loglevel=4 logo.nologo vt.global_cursor_default=0"
  INSTALLER_APPEND="$INSTALLER_APPEND rock5_installer.source=$BOOT_DEVICE rock5_installer.target=$INSTALL_TARGET"
  INSTALLER_APPEND="$INSTALLER_APPEND ${INSTALLER_ARGS:-}"
  # Two passes: collect the android entry, then print it as "install" first
  awk -v append="$INSTALLER_APPEND" '
    NR == FNR {
      if (/^label /) grab = ($0 ~ /^label android/)
      else if (grab && /^[ \t]/) {
        line = $0
        if (line ~ /^[ \t]*initrd /) line = "    initrd /installer.img"
        if (line ~ /^[ \t]*append /) line = "    append " append
        body[n++] = line
      }
      next
    }
    /^default / { print "default install"; next }
    /^label / && !done {
      print "label install"
      for (i = 0; i < n; i++) print body[i]
      print ""
      done = 1
    }
    { print }
  ' "$TMP/extlinux.conf" "$TMP/extlinux.conf" > "$TMP/extlinux.conf.install"
  grep -q "^label install" "$TMP/extlinux.conf.install" || die "installer extlinux.conf"
fi
mkfs.fat -F 32 -n BOOT -C "$TMP/boot.vfat" $((BOOT * 1024)) >/dev/null
mmd -i "$TMP/boot.vfat" ::extlinux ::overlays
mcopy -i "$TMP/boot.vfat" "$OUT/kernel" ::Image
mcopy -i "$TMP/boot.vfat" "$DTB_FILE" "$OUT/ramdisk.img" ::
if [ "$INSTALLER" = 1 ]; then
  mcopy -i "$TMP/boot.vfat" "$TMP/extlinux.conf.install" ::extlinux/extlinux.conf
  mcopy -i "$TMP/boot.vfat" "$TMP/extlinux.conf.target" ::extlinux/extlinux.conf.target
  mcopy -i "$TMP/boot.vfat" "$TMP/installer.img" ::installer.img
else
  mcopy -i "$TMP/boot.vfat" "$TMP/extlinux.conf" ::extlinux/extlinux.conf
fi
if [ -n "$FDTOVERLAYS" ]; then
  mcopy -i "$TMP/boot.vfat" "$TMP"/overlays/*.dtbo ::overlays/
fi
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
