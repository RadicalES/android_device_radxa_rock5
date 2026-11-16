#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Rebuild the kernel and/or U-Boot and copy them into the prebuilt repo
# (device/radxa/rock5-kernel), ready to commit there.
#
#   device/radxa/rock5/tools/update-prebuilts.sh            # kernel and U-Boot
#   device/radxa/rock5/tools/update-prebuilts.sh kernel     # kernel only
#   device/radxa/rock5/tools/update-prebuilts.sh uboot      # U-Boot only
#
# Run inside a synced AOSP tree; the kernel is built with that tree's clang and
# kernel/configs fragment. Versions are pinned in kernel/build-kernel.sh and
# bootloader/build-uboot.sh. Work files go to out/rock5-prebuilts (top-level
# out/ is not scanned by Soong; override with WORK=).

set -euo pipefail

die() { echo "!! $*"; exit 1; }

DEV=$(cd "$(dirname "$0")/.." && pwd)
TOP=$(cd "$DEV/../../.." && pwd)
PREBUILT=$TOP/device/radxa/rock5-kernel
WORK=${WORK:-$TOP/out/rock5-prebuilts}

[ -d "$TOP/prebuilts/clang/host/linux-x86" ] || die "$TOP is not an AOSP tree"
git -C "$PREBUILT" rev-parse --git-dir >/dev/null 2>&1 || die "missing $PREBUILT (repo sync device/radxa/rock5-kernel)"

what=${*:-kernel uboot}
for w in $what; do
  case $w in
    kernel)
      AOSP=$TOP WORK=$WORK "$DEV/kernel/build-kernel.sh"
      cp "$WORK/kernel/Image" "$WORK"/kernel/*.dtb "$WORK/kernel/version" "$PREBUILT/"
      cp "$WORK/kernel/.config" "$PREBUILT/config"
      ;;
    uboot)
      WORK=$WORK "$DEV/bootloader/build-uboot.sh"
      cp "$WORK/bootloader/u-boot-rockchip.bin" "$PREBUILT/"
      ;;
    *) die "unknown target '$w' (kernel, uboot)" ;;
  esac
done

dev_rev=$(git -C "$DEV" describe --always --dirty --abbrev=7)
pin() { sed -n "s/^$1=\${$1:-\(.*\)}$/\1/p" "$DEV/bootloader/build-uboot.sh"; }

echo
echo ">> $PREBUILT:"
git -C "$PREBUILT" status --short
cat <<EOF

Test the image on hardware, then commit in $PREBUILT, e.g.:

  Linux $(cat "$PREBUILT/version") and U-Boot $(pin UBOOT_VERSION) for the ROCK 5 family

  - Image, DTBs, config: kernel/build-kernel.sh from android_device_radxa_rock5 $dev_rev
  - u-boot-rockchip.bin: bootloader/build-uboot.sh, U-Boot $(pin UBOOT_VERSION),
    TF-A $(pin TFA_VERSION), $(pin DDR_BLOB)

(Drop the lines for whatever was not rebuilt. A "-dirty" device revision means
uncommitted changes: commit them first so the prebuilt names a real commit.)
EOF
