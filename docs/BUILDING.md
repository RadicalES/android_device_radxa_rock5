# Building AOSP 15 for the Radxa ROCK 5

The full recipe, from a bare build host to a flashed SD card, plus how to rebuild the pieces that come in
prebuilt or generated: the kernel, U-Boot and Mesa's Soong build.

Tested on Ubuntu 24.04 (x86-64). A full AOSP build needs roughly 300 GB of disk and 32 GB+ of RAM.

## 1. Host packages

AOSP's own requirements (see [source.android.com](https://source.android.com/docs/setup/start/requirements)),
plus `repo`, plus these for the scripts in this repo:

```sh
sudo apt install git-core gnupg flex bison build-essential zip curl zlib1g-dev libc6-dev-i386 \
    x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig \
    repo bc libssl-dev libelf-dev \
    gcc-aarch64-linux-gnu swig python3-pyelftools libgnutls28-dev uuid-dev \
    gdisk mtools dosfstools e2fsprogs
```

| Packages | Needed by |
|---|---|
| `bc libssl-dev libelf-dev flex bison` | `kernel/build-kernel.sh` (the compiler is AOSP's clang) |
| `gcc-aarch64-linux-gnu swig python3-pyelftools libgnutls28-dev uuid-dev` | `bootloader/build-uboot.sh` |
| `gdisk mtools dosfstools e2fsprogs` | `tools/mkimg.sh` (SD image, no sudo) |

Only regenerating Mesa's `Android.bp` needs more; see [section 6](#6-regenerating-mesas-androidbp).

## 2. Source

```sh
mkdir aosp-15-rock5 && cd aosp-15-rock5
repo init -u https://android.googlesource.com/platform/manifest -b android-15.0.0_r32
git clone https://github.com/RadicalES/android_local_manifest_rock5 .repo/local_manifests -b android-15.0
repo sync -c -j8
```

The local manifest adds:

| Path | Repository |
|---|---|
| `device/radxa/rock5` | this repo |
| `device/radxa/rock5-kernel` | prebuilt kernel (`Image`, DTBs, `config`) and `u-boot-rockchip.bin` |
| `vendor/google/graphics/desktop/mesa3d/panvk` | Mesa 26.0 with a generated Soong build |
| `external/minigbm` | minigbm with the rock5 gralloc change (replaces AOSP's) |
| `hardware/interfaces` | AOSP's, with the Bluetooth HAL rfkill fix (replaces AOSP's) |

## 3. Build and SD image

```sh
. build/envsetup.sh
lunch aosp_rock5b-bp1a-userdebug
m
device/radxa/rock5/tools/mkimg.sh
```

`mkimg.sh` writes `out/target/product/rock5b/aosp15-rock5b-<date>.img` (14 GiB, sparse, fits a 16 GB card),
taking U-Boot from `device/radxa/rock5-kernel` (override with `UBOOT=`) and the output name from `IMG=`.

## 4. Flash and debug

```sh
sudo dd if=out/target/product/rock5b/aosp15-rock5b-<date>.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Copy with `cp --sparse=always` when moving images around, or each copy takes the full 14 GiB.

- **Serial console:** 3.3 V TTL UART on the 40-pin header (pin 8 TX, pin 10 RX, pin 6 GND), 1500000 baud.
  The console is a shell; run `su` for root.
- **Logs after a failed boot:** logcat is persisted to `/data/misc/logd`. With the card in the build host,
  copy it out of the userdata partition (p5) without mounting it:

  ```sh
  mkdir card     # must be empty: debugfs rdump does not overwrite
  sudo debugfs -c -R "rdump /misc/logd $PWD/card" /dev/sdX5
  sudo debugfs -c -R "rdump /tombstones $PWD/card" /dev/sdX5
  ```

- **DRM state** (display, planes) from the console: `mount -t debugfs none /sys/kernel/debug`, then
  `cat /sys/kernel/debug/dri/*/state`.

## 5. Updating the kernel and U-Boot prebuilts

The kernel source is [RadicalES/android_kernel_rockchip_rk3588](https://github.com/RadicalES/android_kernel_rockchip_rk3588),
a fork of the stable tree: branch `android-6.18` is a mainline LTS release (v6.18.63) with our patches as commits
on top: upstream fixes not yet in the LTS release (each naming the mainline commit it was cherry-picked from;
drop one once the LTS has it) and, later, the Android drivers mainline lacks. `kernel/build-kernel.sh` builds the
commit pinned in `KERNEL_REV` (fetched shallow), configured from defconfig + AOSP's
`kernel/configs/w/android-6.12/android-base.config` + `kernel/rock5.config`. To change the kernel, commit and push
to the fork, then bump `KERNEL_REV`. To move to a new LTS release, rebase the branch onto its tag. U-Boot, TF-A and
the Rockchip DDR blob are pinned in `bootloader/build-uboot.sh`. To change any of them, edit the script or config here, then:

```sh
device/radxa/rock5/tools/update-prebuilts.sh            # or: ... kernel / ... uboot
```

It builds with the tree's own clang into `out/rock5-prebuilts/`, copies the results into
`device/radxa/rock5-kernel/` and prints a commit message naming the versions and this repo's commit. Then:

1. Rebuild and flash an image (section 3), and test it on hardware.
2. Commit the change here first, then the prebuilts in `device/radxa/rock5-kernel`, and push both.

`kernel/build-kernel.sh` fails if an option in `rock5.config` does not survive `olddefconfig` (renamed
symbol, unmet dependency) and lists the `android-base.config` options mainline does not have.

For a kernel-only bring-up card (U-Boot + kernel + DTB, no Android), use `tools/mksdcard-kernel-test.sh`.

## 6. Regenerating Mesa's Android.bp

Mesa is built by Soong from an `Android.bp` that [ninja-to-soong](https://github.com/rjodinchr/ninja-to-soong)
generates from Mesa's meson build, cross-compiled with the NDK. Regenerate it when moving to a new Mesa
version or changing Mesa build options; it is checked in to RadicalES/android_external_mesa, so a normal build never needs this.

**Host requirements** (in addition to section 1):

```sh
sudo apt install pipx ninja-build python3-mako python3-ply python3-yaml pkg-config gettext-base ccache \
    libdrm-dev glslang-tools \
    llvm-19-dev llvm-19-tools libclang-19-dev libclang-cpp19-dev libclc-19 libclc-19-dev libllvmspirvlib-19-dev
pipx install meson     # Mesa 26.0 needs meson >= 1.4; Ubuntu 24.04 ships 1.3.2
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal   # cargo
curl -fLO https://dl.google.com/android/repository/android-ndk-r27d-linux.zip && unzip -q android-ndk-r27d-linux.zip
```

LLVM 19 and libclc build the host shader compilers (`mesa_clc`, `panfrost_compile`) that precompile PanVK's internal shaders.

**Run** (inside the synced tree):

```sh
N2S_NDK_PATH=$PWD/android-ndk-r27d device/radxa/rock5/tools/mesa/regen-android-bp.sh
```

It clones ninja-to-soong at the pinned revision into `out/rock5-n2s/`, deletes and regenerates `Android.bp` and
`meson_generated/` in the Mesa checkout, then runs `tools/mesa/fixup-android-bp.py`, which applies the two
rock5 changes:

- `astc_spv.h` is generated with the host `glslangValidator` and checked in (Android 15 has no glslang module).
- Mesa's IMapper gralloc backend is added and `vulkan.panfrost` links `libui`. Without it Mesa uses its fallback
  gralloc, which reports an invalid modifier for every buffer, and PanVK crashes importing SurfaceFlinger's buffers.

Then build `m desktop-mesa3d_panvk_libvulkan_panfrost` (the module name; `vulkan.panfrost.so` is its output),
build an image and test it. Commit in the Mesa checkout as two commits, so the next regeneration diffs cleanly:
the generator's output first (`Android.bp` as generated, `meson_generated/` without `astc_spv.h`), then the
fixups.

**Moving to a new Mesa version:** fetch the new upstream tag
(`git fetch https://gitlab.freedesktop.org/mesa/mesa.git tag mesa-X.Y.Z`), start a branch from it, regenerate
as above and push the branch to RadicalES/android_external_mesa; point the local manifest at it once tested. Mesa 27 and later
need Rust 1.85, which Android 15's toolchain (1.81) does not have; 26.0 builds no Rust code.
