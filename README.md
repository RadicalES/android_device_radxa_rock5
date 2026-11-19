# AOSP for Radxa ROCK 5

An open, mainline-based Android (AOSP 15) port for the Radxa ROCK 5 family (RK3588 / RK3588S).

Rockchip's own Android BSPs are vendor kernels with closed GPU blobs, and Radxa publishes no Android 15
for RK3588. This port goes the other way: **mainline Linux LTS kernel, mainline U-Boot, and Mesa
(Panfrost/PanVK) for the Mali-G610**, much as [raspberry-vanilla](https://github.com/raspberry-vanilla)
does for the Raspberry Pi. raspberry-vanilla's `device/brcm/rpi5` tree is the structural template.

> **Status: early bring-up.** Only the ROCK 5B is being worked on. It boots to the Android home screen
> over HDMI with GPU rendering (Mesa PanVK + ANGLE) and USB touch; most other hardware is not wired up yet.

## Supported boards

| Board | SoC | Status |
|---|---|---|
| ROCK 5B | RK3588 | bring-up |
| ROCK 5B+, 5T, 5A, 5C, 5 ITX | RK3588 / RK3588S | planned: the mainline kernel and U-Boot already support them |

## Milestones

1. **Boot to Android home screen** over HDMI, shell on the debug UART, booting from microSD.
   - [x] Mainline U-Boot (+ TF-A) builds
   - [x] Mainline kernel builds with Android + board config (`kernel/`)
   - [x] U-Boot boots the kernel on hardware (ROCK 5B, 8 GB: 8 CPUs, PMIC, Panthor, HDMI console, RTL8125B, USB + HID touch)
   - [x] Device tree (`device/radxa/rock5`), ramdisk, fstab, image script: boots to zygote,
     SurfaceFlinger aborts for lack of a GLES driver
   - [x] Software rendering (SwiftShader + ANGLE, minigbm, drm_hwcomposer): home screen on HDMI at 1080p.
     Stub HALs from AOSP (audio, health, power, keymint, gatekeeper)
   - [x] Mesa PanVK (26.0.0) replaces SwiftShader: ANGLE runs GLES on Vulkan on the Mali-G610 (see "Mesa" below)
2. Ethernet, USB, adb, audio over HDMI.
3. UVC cameras (external camera HAL), hardware video decode (`v4l2_codec2`/hantro, rkvdec).
   - [x] UVC cameras: AOSP's external camera provider as a vendor APEX (`camera/external`), stock
     `external_camera_config.xml` (a product may replace it, e.g. with per-camera `<Sensor>` facing and
     orientation); hardware-tested with a USB camera on the ROCK 5B
4. More boards; eMMC/NVMe boot.

## Layout

This repo is checked out at `device/radxa/rock5`. The prebuilt kernel (`Image`, DTBs) and U-Boot come from
[android_device_radxa_rock5-kernel](https://github.com/RadicalES/android_device_radxa_rock5-kernel) at
`device/radxa/rock5-kernel`, as raspberry-vanilla does with `rpi5-kernel`; the scripts below rebuild them.

```
AndroidProducts.mk          lunch targets
BoardConfigCommon.mk        shared RK3588 board config: arch, partitions, kernel cmdline, boot image
device-common.mk            shared RK3588 product config
boot/extlinux.conf          template U-Boot reads; @DTB@ and @CMDLINE@ are filled in at build time
ramdisk/                    fstab.rock5, init.rock5.rc, ueventd.rock5.rc (shared, androidboot.hardware=rock5)
manifest.xml, vendor.prop
audio/                      audio policy for the reference AIDL audio HAL
sepolicy/                   vendor SELinux policy: file labels for the HALs (boot is still permissive)
overlay/                    resource overlays (settings defaults: no screen timeout)
rock5b/                     ROCK 5B: BoardConfig.mk (picks the DTB), device.mk, aosp_rock5b.mk
bootloader/build-uboot.sh   mainline U-Boot + TF-A BL31 (+ rkbin DDR blob) -> u-boot-rockchip.bin
kernel/build-kernel.sh      mainline LTS kernel built with AOSP clang
kernel/rock5.config         board config fragment, merged over defconfig + AOSP android-base.config
docs/BUILDING.md            full build recipe, prebuilt updates, Mesa regeneration
tools/update-prebuilts.sh   rebuild kernel and/or U-Boot into device/radxa/rock5-kernel
tools/mesa/                 regenerate Mesa's Android.bp (ninja-to-soong) and apply the rock5 fixups
tools/mksdcard-kernel-test.sh  SD image with U-Boot + kernel + DTB only, for kernel bring-up
tools/mkimg.sh              full SD image from an Android build (no sudo): U-Boot + boot/system/vendor/metadata/userdata;
                            boot = FAT {Image, DTB, ramdisk.img, extlinux/extlinux.conf}
```

The fstab mounts by GPT partition name, and `androidboot.boot_devices` says which controller holds them
(`fe2c0000.mmc` = microSD), so the same layout can later boot from eMMC or NVMe.

Adding a board = a new `<board>/` with its own DTB and product file.

The tree is assembled with the local manifest in
[android_local_manifest_rock5](https://github.com/RadicalES/android_local_manifest_rock5) (this repo plus
Mesa) on top of AOSP `android-15.0.0_r32`; its README has the `repo init`/`sync` steps.

### Changes to other AOSP projects

These live in forks that the local manifest swaps in for AOSP's projects:

- `external/minigbm` ([RadicalES/android_external_minigbm](https://github.com/RadicalES/android_external_minigbm), `android-15-rock5`): gralloc
  drops DRM master after opening a card node. RK3588's render node (panthor) has no minigbm backend, so
  gralloc opens the display node, and the first opener becomes DRM master; without the change
  drm_hwcomposer can't take the display and falls back to a headless null display.

### Mesa

PanVK is built from Mesa 26.0.0 (newer Mesa needs Rust 1.85; AOSP 15 ships 1.81) with an `Android.bp`
generated by [ninja-to-soong](https://github.com/google/ninja-to-soong) (`desktop/mesa3d/panvk`), from
[RadicalES/android_external_mesa](https://github.com/RadicalES/android_external_mesa) branch `android-15-rock5`, checked out at
`vendor/google/graphics/desktop/mesa3d/panvk` (the path ninja-to-soong generates for). Two changes to the
generated file:

- `astc_spv.h` is pre-generated with the host `glslangValidator`, since AOSP 15 has no glslang module.
- Mesa's IMapper gralloc backend (`u_gralloc_imapper5_api.cpp`, linked with `libui`) is added. Without it
  Mesa falls back to a gralloc stub that reports an invalid modifier for every buffer, and PanVK crashes
  importing SurfaceFlinger's buffers.

## Building

See **[docs/BUILDING.md](docs/BUILDING.md)** for the full recipe: host packages, `repo` setup, build, SD image,
flashing and reading logs off the card, plus rebuilding the prebuilt kernel and U-Boot
(`tools/update-prebuilts.sh`) and regenerating Mesa's `Android.bp` (`tools/mesa/`). In short:

```sh
repo init -u https://android.googlesource.com/platform/manifest -b android-15.0.0_r32
git clone https://github.com/RadicalES/android_local_manifest_rock5 .repo/local_manifests -b android-15.0
repo sync -c -j8
. build/envsetup.sh && lunch aosp_rock5b-bp1a-userdebug && m
device/radxa/rock5/tools/mkimg.sh
```

Debug UART: 3.3 V TTL on the 40-pin header (pin 8 TX, pin 10 RX, pin 6 GND), **1500000 baud**.

## Choices and caveats

- **Kernel 6.18 LTS.** RK3588 HDMI output reached mainline in 6.13 and Panthor in 6.10, so the 6.6 kernel
  that Android 15 qualifies is too old. The build will need `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false`.
- **Built-in, not modules,** for milestone 1. The GPU and NIC firmware is embedded in the kernel image
  (`CONFIG_EXTRA_FIRMWARE`), because the drivers probe before `/vendor` is mounted.
- **The DDR init blob is closed** (Rockchip `rkbin`). Everything else in the boot chain is open source.

## License

Apache-2.0, see [LICENSE](LICENSE). Kernel sources and patches carry their own (GPL-2.0) licences.
