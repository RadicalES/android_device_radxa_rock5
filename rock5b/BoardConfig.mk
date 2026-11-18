#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#

include device/radxa/rock5/BoardConfigCommon.mk

ROCK5_DTB := rk3588-rock-5b.dtb

# Device-tree overlays applied by U-Boot (extlinux fdtoverlays), relative to
# device/radxa/rock5; tools/mkimg.sh compiles them.
ROCK5_DTBOS := rock5b/overlays/no-sdio.dtso
