#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Build mainline U-Boot (+ mainline TF-A BL31) for a Rock 5 board.
#
#   bootloader/build-uboot.sh [defconfig]     # default: rock5b-rk3588 (5B/5B+/5T)
#
# Output: out/bootloader/u-boot-rockchip.bin. Write it to an SD card at
# sector 64 (32 KiB), the boot ROM's load offset:
#
#   dd if=out/bootloader/u-boot-rockchip.bin of=/dev/sdX seek=64 conv=notrunc,fsync
#
# The only closed piece is the DDR init blob (ROCKCHIP_TPL) from rkbin; mainline
# has no open-source LPDDR4/5 training for RK3588 yet.

set -euo pipefail

DEFCONFIG=${1:-rock5b-rk3588}_defconfig
UBOOT_VERSION=${UBOOT_VERSION:-v2026.10}
TFA_VERSION=${TFA_VERSION:-v2.15.0}
DDR_BLOB=${DDR_BLOB:-rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
export CROSS_COMPILE

TOP=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$TOP/out}
DIST=$WORK/bootloader

missing=""
command -v "${CROSS_COMPILE}gcc" >/dev/null || missing+=" gcc-aarch64-linux-gnu"
command -v swig >/dev/null || missing+=" swig"
python3 -c 'import elftools' 2>/dev/null || missing+=" python3-pyelftools"
[ -e /usr/include/gnutls/gnutls.h ] || missing+=" libgnutls28-dev"
[ -e /usr/include/uuid/uuid.h ] || missing+=" uuid-dev"
if [ -n "$missing" ]; then
  echo "!! missing build dependencies, install with:"
  echo "   sudo apt install$missing"
  exit 1
fi

mkdir -p "$WORK" "$DIST"
cd "$WORK"

[ -d tf-a ] || git clone -q --depth 1 -b "$TFA_VERSION" https://github.com/ARM-software/arm-trusted-firmware tf-a
[ -d u-boot ] || git clone -q --depth 1 -b "$UBOOT_VERSION" https://source.denx.de/u-boot/u-boot.git u-boot
[ -f "$DDR_BLOB" ] || curl -fsL -o "$DDR_BLOB" \
  "https://raw.githubusercontent.com/rockchip-linux/rkbin/master/bin/rk35/$DDR_BLOB"

echo ">> TF-A $TFA_VERSION (rk3588)"
make -C tf-a -j"$(nproc)" PLAT=rk3588 bl31
BL31=$WORK/tf-a/build/rk3588/release/bl31/bl31.elf

echo ">> U-Boot $UBOOT_VERSION ($DEFCONFIG)"
make -C u-boot "$DEFCONFIG"
make -C u-boot -j"$(nproc)" BL31="$BL31" ROCKCHIP_TPL="$WORK/$DDR_BLOB"

cp u-boot/u-boot-rockchip.bin "$DIST/"
echo ">> done: $DIST/u-boot-rockchip.bin"
