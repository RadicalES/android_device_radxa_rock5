#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#

# Shared by every Rock 5 board. Milestone 1 keeps this to what Android needs to
# reach init and mount its partitions; HALs get added as they are brought up.

COMMON_PATH := device/radxa/rock5
KERNEL_PATH := device/radxa/rock5-kernel

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)

# API level
PRODUCT_SHIPPING_API_LEVEL := 35

# Mainline LTS kernel (6.18) is newer than Android 15's kernel requirements list
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false

# Kernel
PRODUCT_COPY_FILES += \
    $(KERNEL_PATH)/Image:$(PRODUCT_OUT)/kernel

# Keystore / lock screen (software implementations)
PRODUCT_PACKAGES += \
    com.android.hardware.gatekeeper.nonsecure \
    com.android.hardware.keymint.rust_nonsecure

# Ethernet
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml

# Ramdisk
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/ramdisk/fstab.rock5:$(TARGET_COPY_OUT_RAMDISK)/fstab.rock5 \
    $(COMMON_PATH)/ramdisk/fstab.rock5:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.rock5 \
    $(COMMON_PATH)/ramdisk/init.rock5.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.rock5.rc \
    $(COMMON_PATH)/ramdisk/ueventd.rock5.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc

# Soong
PRODUCT_SOONG_NAMESPACES += $(COMMON_PATH)

# Storage
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)
