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

# Dalvik heap sizes. Without them the app heap limit is 16 MB and SystemUI
# dies with OutOfMemoryError.
$(call inherit-product, frameworks/native/build/tablet-7in-xhdpi-2048-dalvik-heap.mk)

# API level
PRODUCT_SHIPPING_API_LEVEL := 35

# Mainline LTS kernel (6.18) is newer than Android 15's kernel requirements list
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false

# Kernel
PRODUCT_COPY_FILES += \
    $(KERNEL_PATH)/Image:$(PRODUCT_OUT)/kernel

# Graphics: Mesa PanVK (Vulkan on the Mali-G610, panthor kernel driver) under
# ANGLE (GLES), minigbm gralloc on rockchip-drm dumb buffers, drm_hwcomposer
# on VOP2.
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm \
    android.hardware.composer.hwc3-service.drm \
    desktop-mesa3d_panvk_libvulkan_panfrost

PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=angle \
    ro.hardware.vulkan=panfrost \
    ro.opengles.version=196608

# NPU: Mesa's Teflon TFLite delegate on the Rocket driver (/dev/accel/accel0),
# built from the same Mesa as PanVK. A vendor public library, so apps can load
# it as a LiteRT external delegate.
PRODUCT_PACKAGES += \
    desktop-mesa3d_panvk_libteflon
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/ml/public.libraries.txt:$(TARGET_COPY_OUT_VENDOR)/etc/public.libraries.txt

# No lock screen by default. A system property: set from the vendor
# build.prop it is applied with vendor_init's permissions and refused.
PRODUCT_SYSTEM_PROPERTIES += \
    ro.lockscreen.disable.default=true

# Bring-up: a larger log buffer, so early HAL logs survive until they are read,
# and logcat persisted to /data/misc/logd, so a hang still leaves a log behind
PRODUCT_SYSTEM_PROPERTIES += \
    ro.logd.size=16M \
    persist.logd.logpersistd=logcatd

# Camera: USB (UVC) cameras through AOSP's external camera HAL
PRODUCT_PACKAGES += \
    com.android.hardware.camera.external.rock5

PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/camera/external/external_camera_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/external_camera_config.xml \
    frameworks/native/data/etc/android.hardware.camera.external.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.external.xml

# Media: the software codecs (swcodec APEX) as an AIDL Codec2 service. This
# board has no hwservicemanager, and the codec client only lists AIDL Codec2
# services when selected (the default is HIDL): without it MediaCodecList is
# empty and no audio or video decodes.
PRODUCT_VENDOR_PROPERTIES += \
    media.c2.hal.selection=aidl

# Audio: AOSP reference AIDL HAL (stub primary module, remote submix, USB) so
# audioserver can start; AudioFlinger crashes without any audio HAL.
PRODUCT_PACKAGES += \
    com.android.hardware.audio

PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/audio/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    $(COMMON_PATH)/audio/primary_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/primary_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/bluetooth_audio_policy_configuration_7_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_audio_policy_configuration_7_0.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml \
    hardware/interfaces/audio/aidl/default/audio_effects_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_effects_config.xml

# Health: AOSP example HAL. BatteryService in system_server needs an IHealth
# instance and aborts the boot without one; a board with no battery reports none.
PRODUCT_PACKAGES += \
    android.hardware.health-service.example

# Lights: HDMI monitors have no backlight device; the backlight level goes to
# the monitor over DDC/CI (hardware/radicales). See rock5b/overlays/hdmi0-ddc-gpio.dtso.
PRODUCT_PACKAGES += \
    android.hardware.lights-service.ddc

# Power: AOSP example HAL. HintManagerService in system_server aborts the boot
# without an IPower instance (null SupportInfo).
PRODUCT_PACKAGES += \
    com.android.hardware.power

# Keystore / lock screen (software implementations)
PRODUCT_PACKAGES += \
    com.android.hardware.gatekeeper.nonsecure \
    com.android.hardware.keymint.rust_nonsecure

# Overlays: settings defaults
DEVICE_PACKAGE_OVERLAYS += $(COMMON_PATH)/overlay

# Connectivity (runtime overlay: the module is updatable): eth0 is the uplink
PRODUCT_PACKAGES += \
    Rock5ConnectivityOverlay

# Device features (app widgets, etc.). Launcher3 crashes without
# android.software.app_widgets: AppWidgetManager is null. AOSP's tablet list
# minus Bluetooth, which is optional hardware (below).
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/permissions/rock5_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/rock5_core_hardware.xml

# Bluetooth: optional (USB adapter, e.g. on an M.2 E-key module). AOSP's
# generic AIDL HAL drives it over the kernel's HCI user channel; its rfkill
# handling is fixed in RadicalES/android_hardware_interfaces (local manifest). The
# features start out empty and are enabled at boot only when
# init.rock5.hwdetect.sh finds an adapter (init.rock5.rc), so a board without
# one has no Bluetooth stack running.
PRODUCT_PACKAGES += \
    android.hardware.bluetooth-service.default

PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/permissions/rock5_bluetooth_absent.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/rock5_bluetooth.xml \
    $(COMMON_PATH)/permissions/rock5_bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/rock5/rock5_bluetooth.xml \
    $(COMMON_PATH)/ramdisk/init.rock5.hwdetect.sh:$(TARGET_COPY_OUT_VENDOR)/bin/init.rock5.hwdetect.sh

# Wi-Fi: optional too (PCIe, the same M.2 module's WLAN side), see BoardConfigCommon.mk.
# Features are enabled at boot only when init.rock5.hwdetect.sh finds an
# adapter, like Bluetooth; the framework starts the supplicant only then.
PRODUCT_PACKAGES += \
    hostapd \
    wpa_supplicant \
    wpa_supplicant.conf.rock5 \
    wpa_supplicant_overlay.conf.rock5

PRODUCT_PACKAGES_DEBUG += \
    hostapd_cli \
    wpa_cli

PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/permissions/rock5_wifi_absent.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/rock5_wifi.xml \
    $(COMMON_PATH)/permissions/rock5_wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/rock5/rock5_wifi.xml

# Ethernet
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml

# USB host: without the feature SystemServer starts no USB service, and
# UsbManager is null for apps. Host only: the USB-C device side (gadget) is not
# set up, so no android.hardware.usb.accessory.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml

# Ramdisk
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/ramdisk/fstab.rock5:$(TARGET_COPY_OUT_RAMDISK)/fstab.rock5 \
    $(COMMON_PATH)/ramdisk/fstab.rock5:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.rock5 \
    $(COMMON_PATH)/ramdisk/init.rock5.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.rock5.rc \
    $(COMMON_PATH)/ramdisk/ueventd.rock5.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc

# Network adb switch (Settings fork): init actions on system properties, which
# must live outside /vendor.
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/system_ext/init.adb-tcp.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/init.adb-tcp.rc

# Soong
PRODUCT_SOONG_NAMESPACES += $(COMMON_PATH)

# Mesa PanVK (Vulkan for Mali-G610), Android.bp generated by ninja-to-soong.
# Location is provisional.
PRODUCT_SOONG_NAMESPACES += vendor/google/graphics/desktop/mesa3d/panvk

# Storage
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)
