#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#

$(call inherit-product, device/radxa/rock5/rock5b/device.mk)

PRODUCT_CHARACTERISTICS := tablet,nosdcard

$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)

# Device identifier. This must come after all inclusions.
PRODUCT_DEVICE := rock5b
PRODUCT_NAME := aosp_rock5b
PRODUCT_BRAND := Radxa
PRODUCT_MODEL := ROCK 5B
PRODUCT_MANUFACTURER := Radxa
