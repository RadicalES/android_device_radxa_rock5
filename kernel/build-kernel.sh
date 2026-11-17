#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Build a mainline LTS kernel for the Rock 5 family.
#
#   AOSP=/path/to/aosp-15 kernel/build-kernel.sh
#
# The AOSP tree provides the clang toolchain (prebuilts/clang) and the Android
# kernel config fragment (kernel/configs). Output lands in out/kernel/:
# Image, the rock-5 DTBs and the final .config.

set -euo pipefail

KERNEL_VERSION=${KERNEL_VERSION:-6.18.63}
AOSP=${AOSP:?set AOSP to an AOSP tree (used for clang + kernel/configs)}

TOP=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$TOP/out}
SRC=$WORK/linux-$KERNEL_VERSION
BUILD=$WORK/kernel-build
FWDIR=$WORK/firmware
DIST=$WORK/kernel

CLANG_DIR=${CLANG_DIR:-$(ls -d "$AOSP"/prebuilts/clang/host/linux-x86/clang-r* | sort -V | tail -1)}
ANDROID_FRAG=${ANDROID_FRAG:-$AOSP/kernel/configs/w/android-6.12/android-base.config}

# Firmware a built-in driver needs before /vendor is mounted.
FIRMWARE="arm/mali/arch10.8/mali_csffw.bin rtl_nic/rtl8125b-2.fw"
# RTL8852B / 8852BT USB Bluetooth (the 8852B needs no config file)
FIRMWARE+=" rtl_bt/rtl8852bu_fw.bin rtl_bt/rtl8852btu_fw.bin"
FW_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain

missing=""
[ -e /usr/include/openssl/bio.h ] || missing+=" libssl-dev"
[ -e /usr/include/libelf.h ] || missing+=" libelf-dev"
if [ -n "$missing" ]; then
  echo "!! missing build dependencies, install with:"
  echo "   sudo apt install$missing"
  exit 1
fi

export PATH=$CLANG_DIR/bin:$PATH
MAKE=(make -C "$SRC" O="$BUILD" ARCH=arm64 LLVM=1 -j"$(nproc)")

echo ">> kernel $KERNEL_VERSION, clang $(basename "$CLANG_DIR")"
mkdir -p "$WORK" "$BUILD" "$FWDIR" "$DIST"

# Upstream fixes not yet in this LTS release, applied in order to a fresh
# source tree. The tree records which series it carries and is re-extracted
# when kernel/patches/ changes.
PATCHES=("$TOP"/kernel/patches/*.patch)
[ -e "${PATCHES[0]}" ] || PATCHES=()
STAMP=$(cat "${PATCHES[@]}" /dev/null | sha256sum | cut -d' ' -f1)
if [ -d "$SRC" ] && [ "$(cat "$SRC/.rock5-patches" 2>/dev/null)" != "$STAMP" ]; then
  echo ">> kernel/patches changed, re-extracting linux-$KERNEL_VERSION"
  rm -rf "$SRC"
fi

TARBALL=$WORK/linux-$KERNEL_VERSION.tar.xz
if [ ! -d "$SRC" ]; then
  if [ ! -f "$TARBALL" ]; then
    echo ">> fetching linux-$KERNEL_VERSION"
    curl -fL -o "$TARBALL.tmp" \
      "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-$KERNEL_VERSION.tar.xz"
    mv "$TARBALL.tmp" "$TARBALL"
  fi
  tar -xJf "$TARBALL" -C "$WORK"
  for p in "${PATCHES[@]}"; do
    echo ">> applying $(basename "$p")"
    patch -d "$SRC" -p1 -s --no-backup-if-mismatch < "$p"
  done
  echo "$STAMP" > "$SRC/.rock5-patches"
fi

for f in $FIRMWARE; do
  if [ ! -f "$FWDIR/$f" ]; then
    echo ">> fetching firmware $f"
    mkdir -p "$FWDIR/$(dirname "$f")"
    curl -fsL -o "$FWDIR/$f" "$FW_URL/$f"
  fi
done

cat > "$BUILD/firmware.config" <<EOF
CONFIG_EXTRA_FIRMWARE="$FIRMWARE"
CONFIG_EXTRA_FIRMWARE_DIR="$FWDIR"
EOF

echo ">> configuring"
"${MAKE[@]}" defconfig
(cd "$SRC" && ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "$BUILD" \
  "$BUILD/.config" "$ANDROID_FRAG" "$TOP/kernel/rock5.config" "$BUILD/firmware.config")
"${MAKE[@]}" olddefconfig

# Every option the board fragment sets must survive olddefconfig; a symbol
# that was renamed or has an unmet dependency silently drops out otherwise.
missing=$(grep -E '^CONFIG_[A-Z0-9_]+=' "$TOP/kernel/rock5.config" | while read -r opt; do
  grep -qxF "$opt" "$BUILD/.config" || echo "  $opt (got: $(grep -E "^(# )?${opt%%=*}[= ]" "$BUILD/.config" || echo unset))"
done)
if [ -n "$missing" ]; then
  echo "!! board config options did not apply:"
  echo "$missing"
  exit 1
fi

# The android-base fragment targets the Android Common Kernel; on mainline some
# options don't exist (ashmem, UID_SYS_STATS, quota2, ...). Report, don't fail,
# so a new gap is noticed.
dropped=$(grep -E '^CONFIG_[A-Z0-9_]+=' "$ANDROID_FRAG" | while read -r opt; do
  grep -qxF "$opt" "$BUILD/.config" || echo "  $opt (got: $(grep -E "^(# )?${opt%%=*}[= ]" "$BUILD/.config" || echo unset))"
done)
if [ -n "$dropped" ]; then
  echo ">> note: android-base options not applied:"
  echo "$dropped"
fi

echo ">> building"
"${MAKE[@]}" Image dtbs

cp "$BUILD/arch/arm64/boot/Image" "$BUILD/.config" "$BUILD/System.map" "$DIST/"
cp "$BUILD"/arch/arm64/boot/dts/rockchip/*rock-5*.dtb "$DIST/"
echo "$KERNEL_VERSION" > "$DIST/version"
echo ">> done: $DIST"
ls -l "$DIST"
