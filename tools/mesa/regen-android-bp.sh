#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Regenerate Mesa PanVK's Soong build (Android.bp + meson_generated/) with
# ninja-to-soong, then apply the rock5 changes (fixup-android-bp.py).
#
#   N2S_NDK_PATH=/path/to/android-ndk-r27d device/radxa/rock5/tools/mesa/regen-android-bp.sh
#
# Run inside a synced AOSP tree. Mesa (RadicalES/android_external_mesa) must be checked out at
# vendor/google/graphics/desktop/mesa3d/panvk, the path ninja-to-soong
# generates for. Host requirements: see docs/BUILDING.md, "Regenerating Mesa's
# Android.bp". Work files go to out/rock5-n2s (override with WORK=).
#
# The result is left uncommitted in the Mesa checkout: build it, test it, then
# commit the generated files and the fixups as separate commits.

set -euo pipefail

die() { echo "!! $*"; exit 1; }

# ninja-to-soong revision the Mesa branch was generated with. It is in the
# archived rjodinchr repo only; google/ninja-to-soong (its successor) has a
# different history.
N2S_REPO=${N2S_REPO:-https://github.com/rjodinchr/ninja-to-soong}
N2S_REV=${N2S_REV:-f75165a48a3b875e3a5cbcf06c7604757f7f986d}

DEV=$(cd "$(dirname "$0")/../.." && pwd)
TOP=$(cd "$DEV/../../.." && pwd)
MESA=$TOP/vendor/google/graphics/desktop/mesa3d/panvk
WORK=${WORK:-$TOP/out/rock5-n2s}
N2S_NDK_PATH=${N2S_NDK_PATH:?set N2S_NDK_PATH to an Android NDK r27d}

git -C "$MESA" rev-parse --git-dir >/dev/null 2>&1 || die "missing Mesa checkout at $MESA"
[ -d "$N2S_NDK_PATH/toolchains/llvm" ] || die "$N2S_NDK_PATH is not an NDK"

missing=""
for t in cargo meson ninja ccache glslangValidator llvm-config-19 envsubst pkg-config; do
  command -v $t >/dev/null || missing+=" $t"
done
python3 -c 'import mako, ply, yaml' 2>/dev/null || missing+=" python:mako/ply/yaml"
[ -e /usr/include/xf86drm.h ] || missing+=" libdrm-dev"
[ -n "$missing" ] && die "missing host tools:$missing (see docs/BUILDING.md)"

mkdir -p "$WORK"
if [ ! -d "$WORK/ninja-to-soong" ]; then
  git clone -q "$N2S_REPO" "$WORK/ninja-to-soong"
fi
git -C "$WORK/ninja-to-soong" checkout -q "$N2S_REV"

echo ">> Mesa $(cat "$MESA/VERSION") at $(git -C "$MESA" log -1 --format=%h)"
# Start from scratch so files the generator no longer emits do not linger
rm -rf "$MESA/Android.bp" "$MESA/meson_generated"

mkdir -p "$WORK/tmp"
(cd "$WORK/ninja-to-soong" &&
  N2S_NDK_PATH=$N2S_NDK_PATH N2S_TMP_PATH=$WORK/tmp \
  cargo run --release -- -p "$TOP" -a desktop/mesa3d/panvk)

python3 -I "$DEV/tools/mesa/fixup-android-bp.py" "$MESA"

echo ">> done; changes in $MESA:"
git -C "$MESA" status --short | head -20
