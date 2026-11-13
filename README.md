# AOSP for Radxa ROCK 5

An open, mainline-based Android (AOSP 15) port for the Radxa ROCK 5 family (RK3588 / RK3588S).

Rockchip's own Android BSPs are vendor kernels with closed GPU blobs, and Radxa publishes no Android 15
for RK3588. This port goes the other way: **mainline Linux LTS kernel, mainline U-Boot, and Mesa
(Panfrost/PanVK) for the Mali-G610**, much as [raspberry-vanilla](https://github.com/raspberry-vanilla)
does for the Raspberry Pi. raspberry-vanilla's `device/brcm/rpi5` tree is the structural template.

> **Status: early bring-up.** Only the ROCK 5B is being worked on. Nothing boots Android yet.

## Supported boards

| Board | SoC | Status |
|---|---|---|
| ROCK 5B | RK3588 | bring-up |
| ROCK 5B+, 5T, 5A, 5C, 5 ITX | RK3588 / RK3588S | planned: the mainline kernel and U-Boot already support them |

## Milestones

1. **Boot to Android home screen** over HDMI, shell on the debug UART, booting from microSD.
   - [x] Mainline U-Boot (+ TF-A) builds
   - [x] Mainline kernel builds with Android + board config (`kernel/`)
   - [ ] U-Boot boots the kernel on hardware
   - [ ] Device tree (`device/radxa/rock5`), ramdisk, fstab, image script
   - [ ] Mesa Panfrost + minigbm + drm_hwcomposer → SurfaceFlinger up
2. Ethernet, USB, adb, audio over HDMI.
3. UVC cameras (external camera HAL), hardware video decode (`v4l2_codec2`/hantro, rkvdec).
4. More boards; eMMC/NVMe boot.

## Layout

This repo is checked out at `device/radxa/rock5`. The prebuilt kernel goes in `device/radxa/rock5-kernel`
(`Image` + DTBs), as raspberry-vanilla does with `rpi5-kernel`.

```
AndroidProducts.mk          lunch targets
BoardConfigCommon.mk        shared RK3588 board config: arch, partitions, kernel cmdline, boot image
device-common.mk            shared RK3588 product config
mkbootimg.mk                boot.img = FAT {Image, DTB, ramdisk.img, extlinux/extlinux.conf}
boot/extlinux.conf          template U-Boot reads; @DTB@ and @CMDLINE@ are filled in at build time
ramdisk/                    fstab.rock5, init.rock5.rc, ueventd.rock5.rc (shared, androidboot.hardware=rock5)
manifest.xml, vendor.prop
rock5b/                     ROCK 5B: BoardConfig.mk (picks the DTB), device.mk, aosp_rock5b.mk
bootloader/build-uboot.sh   mainline U-Boot + TF-A BL31 (+ rkbin DDR blob) -> u-boot-rockchip.bin
kernel/build-kernel.sh      mainline LTS kernel built with AOSP clang
kernel/rock5.config         board config fragment, merged over defconfig + AOSP android-base.config
tools/mksdcard-kernel-test.sh  SD image with U-Boot + kernel + DTB only, for kernel bring-up
```

The fstab mounts by GPT partition name, and `androidboot.boot_devices` says which controller holds them
(`fe2c0000.mmc` = microSD), so the same layout can later boot from eMMC or NVMe.

Adding a board = a new `<board>/` with its own DTB and product file. Planned: a `local_manifest` for the
Mesa/minigbm/drm_hwcomposer forks; the kernel and manifest will probably move to their own repos.

## Building

Both scripts write to `out/`.

```sh
# Kernel: AOSP provides the clang toolchain and kernel/configs fragments
# (needs libssl-dev libelf-dev)
AOSP=/path/to/aosp-15 kernel/build-kernel.sh

# Bootloader: needs gcc-aarch64-linux-gnu swig python3-pyelftools libgnutls28-dev uuid-dev
bootloader/build-uboot.sh
sudo dd if=out/bootloader/u-boot-rockchip.bin of=/dev/sdX seek=64 conv=notrunc,fsync
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
