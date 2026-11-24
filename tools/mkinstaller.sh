#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Make an installer SD card image from a finished Android build: a card that,
# booted in the board, copies the system to the eMMC (docs/INSTALLER.md).
#
#   lunch <product>-bp1a-userdebug && m
#   device/radxa/rock5/tools/mkinstaller.sh [options]
#
#   -o IMG          output image (default $OUT/<product>-installer-<date>-<time>.img)
#   --dry-run       the card only checks the card and the eMMC, writes nothing
#   --countdown N   seconds to pull the card before the eMMC is erased (default 10)
#
# The image is the smallest that works (about 4.6 GiB) and fits any card of
# 8 GB or more. Write it with tools/flash-card.sh.

set -euo pipefail

die() { echo "!! $*"; exit 1; }
usage() { sed -n '/^#   lunch/,/^# 8 GB/s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

[ -n "${ANDROID_PRODUCT_OUT:-}" ] || die "ANDROID_PRODUCT_OUT is not set. Run lunch first."

IMG=
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) [ $# -ge 2 ] || usage 1; IMG=$2; shift ;;
    --dry-run) ARGS+=(rock5_installer.dry_run=1) ;;
    --countdown)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || die "--countdown needs a number of seconds"
      ARGS+=(rock5_installer.countdown=$2); shift ;;
    -h|--help) usage ;;
    *) echo "!! unknown option: $1"; usage 1 ;;
  esac
  shift
done

PRODUCT=${TARGET_PRODUCT:-$(basename "$ANDROID_PRODUCT_OUT")}
IMG=${IMG:-$ANDROID_PRODUCT_OUT/$PRODUCT-installer-$(date +%Y%m%d-%H%M).img}

INSTALLER=1 IMG="$IMG" INSTALLER_ARGS="${ARGS[*]}" \
  "$(dirname "$(readlink -f "$0")")/mkimg.sh"

SIZE=$(stat -c %s "$IMG")
cat <<EOF

Installer card image: $IMG
  $((SIZE / 1024 / 1024)) MiB, fits a card of 8 GB or more.
  $([ ${#ARGS[@]} -gt 0 ] && echo "Options: ${ARGS[*]}" || echo "Erases the eMMC 10 s after boot unless the card is pulled.")

Write it to a card:
  sudo $(dirname "$(readlink -f "$0")")/flash-card.sh $IMG
EOF
