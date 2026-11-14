#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#

# Shared by every Rock 5 board (RK3588 / RK3588S). Each board's BoardConfig.mk
# includes this and sets ROCK5_DTB.

COMMON_PATH := device/radxa/rock5
KERNEL_PATH := device/radxa/rock5-kernel

# Architecture (4x Cortex-A76 + 4x Cortex-A55)
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := cortex-a76

# Bootloader: mainline U-Boot lives outside the Android partitions
TARGET_NO_BOOTLOADER := true
TARGET_NO_RECOVERY := true

# The boot partition is a FAT filesystem U-Boot reads through extlinux.conf.
# tools/mkimg.sh assembles it from the kernel, DTB and ramdisk.img; the Android
# boot.img the build still makes is not used.

# Kernel log on HDMI and UART; the last console= (UART) becomes /dev/console.
# fe2c0000.mmc is the microSD controller; it makes /dev/block/by-name/* point there
BOARD_KERNEL_CMDLINE := console=tty0 console=ttyS2,1500000 earlycon no_console_suspend
BOARD_KERNEL_CMDLINE += androidboot.hardware=rock5 androidboot.boot_devices=fe2c0000.mmc
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive

# Manifest
DEVICE_MANIFEST_FILE := $(COMMON_PATH)/manifest.xml

# Partitions (same sizes as raspberry-vanilla rpi5)
BOARD_FLASH_BLOCK_SIZE := 4096
BOARD_USES_METADATA_PARTITION := true
BOARD_BOOTIMAGE_PARTITION_SIZE := 134217728 # 128M
BOARD_METADATAIMAGE_PARTITION_SIZE := 16777216 # 16M
BOARD_SYSTEMIMAGE_PARTITION_SIZE := 3221225472 # 3072M
BOARD_USERDATAIMAGE_PARTITION_SIZE := 134217728 # 128M
BOARD_VENDORIMAGE_PARTITION_SIZE := 402653184 # 384M
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_USERIMAGES_SPARSE_EXT_DISABLED := true
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_COPY_OUT_VENDOR := vendor

# Platform
TARGET_BOARD_PLATFORM := rk3588
TARGET_BOOTLOADER_BOARD_NAME := rk3588

# Properties
TARGET_VENDOR_PROP += $(COMMON_PATH)/vendor.prop
