#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Build the kernel for the Rock 5 family: a mainline LTS release plus the
# patches RadicalES carries (upstream backports, Android drivers), kept as
# commits in RadicalES/android_kernel_rockchip_rk3588.
#
#   AOSP=/path/to/aosp-15 kernel/build-kernel.sh
#
# The AOSP tree provides the clang toolchain (prebuilts/clang) and the Android
# kernel config fragment (kernel/configs). Output lands in out/kernel/:
# Image, the rock-5 DTBs and the final .config.

set -euo pipefail

# The kernel source: a commit of the fork's android-6.18 branch (v6.18.63 +
# our patches). Pinned, so a build is reproducible; bump it to take changes.
KERNEL_REPO=${KERNEL_REPO:-https://github.com/RadicalES/android_kernel_rockchip_rk3588.git}
KERNEL_REV=${KERNEL_REV:-140f10a0ced750b81e87f9c14ce6abde00b3496a}
AOSP=${AOSP:?set AOSP to an AOSP tree (used for clang + kernel/configs)}

TOP=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$TOP/out}
SRC=$WORK/linux
BUILD=$WORK/kernel-build
FWDIR=$WORK/firmware
DIST=$WORK/kernel

CLANG_DIR=${CLANG_DIR:-$(ls -d "$AOSP"/prebuilts/clang/host/linux-x86/clang-r* | sort -V | tail -1)}
ANDROID_FRAG=${ANDROID_FRAG:-$AOSP/kernel/configs/w/android-6.12/android-base.config}

# Firmware a built-in driver needs before /vendor is mounted.
FIRMWARE="arm/mali/arch10.8/mali_csffw.bin rtl_nic/rtl8125b-2.fw"
# RTL8852B / 8852BT USB Bluetooth (the 8852B needs no config file)
FIRMWARE+=" rtl_bt/rtl8852bu_fw.bin rtl_bt/rtl8852btu_fw.bin"
# RTL8852BE PCIe Wi-Fi
FIRMWARE+=" rtw89/rtw8852b_fw-1.bin"
FW_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain
# cfg80211's signed wireless regulatory database, from wireless-regdb
REGDB="regulatory.db regulatory.db.p7s"
REGDB_URL=https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git/plain

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

mkdir -p "$WORK" "$BUILD" "$FWDIR" "$DIST"

# Fetch only the pinned commit (no history), into a git tree that is reused.
if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$KERNEL_REPO"
fi
if [ "$(git -C "$SRC" rev-parse -q --verify HEAD 2>/dev/null)" != "$KERNEL_REV" ]; then
  echo ">> fetching kernel $KERNEL_REV"
  git -C "$SRC" fetch -q --depth 1 origin "$KERNEL_REV"
  git -C "$SRC" checkout -q --force --detach FETCH_HEAD
fi
[ -z "$(git -C "$SRC" status --porcelain)" ] || { echo "!! $SRC has local changes"; exit 1; }
KERNEL_VERSION=$(make -s -C "$SRC" kernelversion)
echo ">> kernel $KERNEL_VERSION (${KERNEL_REV:0:12}), clang $(basename "$CLANG_DIR")"

fetch() {  # fetch <base url> <file>
  if [ ! -f "$FWDIR/$2" ]; then
    echo ">> fetching firmware $2"
    mkdir -p "$FWDIR/$(dirname "$2")"
    curl -fsL -o "$FWDIR/$2" "$1/$2"
  fi
}
for f in $FIRMWARE; do fetch "$FW_URL" "$f"; done
for f in $REGDB; do fetch "$REGDB_URL" "$f"; done
FIRMWARE+=" $REGDB"

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
