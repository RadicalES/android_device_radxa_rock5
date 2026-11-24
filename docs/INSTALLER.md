# Installer SD card

An installer card puts the system on the board's internal storage: put the card in, power on, and it copies
the system from the card to the eMMC. Pull the card out when it says so, and the board restarts into the new
system. The installer is `installer/installer.cpp`; the card is made by `tools/mkinstaller.sh`.

Only the eMMC is supported for now. NVMe needs U-Boot in the SPI flash, because the RK3588 boot ROM cannot
read NVMe.

## 1. Make the card image

On the build host, after a finished build of the product you want to install:

```sh
. build/envsetup.sh
lunch <product>-bp1a-userdebug        # e.g. aosp_rock5b-bp1a-userdebug
m
device/radxa/rock5/tools/mkinstaller.sh
```

This writes `out/target/product/rock5b/<product>-installer-<date>-<time>.img`. The size is chosen for you:
the image is about 4.6 GiB and fits **any card of 8 GB or more**.

| Option | |
|---|---|
| `-o IMG` | write the image to `IMG` instead |
| `--dry-run` | a card that only checks the card and the eMMC, and writes nothing |
| `--countdown N` | seconds to pull the card before the eMMC is erased (default 10, `0` = no wait) |

`mkinstaller.sh` is `INSTALLER=1 tools/mkimg.sh`; to set the size by hand, `IMG_SIZE_MIB` still works with
either.

## 2. Write it to a card

Put the card in the build host's card reader, then:

```sh
sudo device/radxa/rock5/tools/flash-card.sh out/target/product/rock5b/<product>-installer-<date>-<time>.img
```

`mkinstaller.sh` prints this line with the real name when it finishes. `flash-card.sh` finds the card reader by
itself (only USB or removable disks, so it cannot pick a system disk), checks that the card is big enough and not
mounted, shows the disk, and writes only after you type `yes`. With more than one reader, name the disk:
`flash-card.sh IMG sdc`. It works for normal `mkimg.sh` images too (those need a 16 GB card).

## 3. Install

1. With the board **off**, put the card in. The card boots first, even when the eMMC already has a system.
2. Power on. The screen (HDMI) and the serial console show:

   ```
   === OS installer ===
   From: mmcblk1, 7580 MiB  (...fe2c0000.mmc...)
   To:   mmcblk0, 29820 MiB  (...fe2e0000.mmc...)
   ...
   ALL DATA ON mmcblk0 WILL BE ERASED.
   Remove the card now to cancel.
     Installing in 10 s
   ```

   **To cancel, pull the card during the countdown.** Nothing has been written yet.
3. It copies U-Boot, boot, system and vendor, then reads them back and compares them, with a percentage
   for each step. This takes a few minutes.
4. `=== INSTALL COMPLETE ===` and `Remove the card`: pull the card. The board restarts from the eMMC.
5. The first boot formats userdata, which now fills the whole eMMC, so it takes a little longer.

Everything on the eMMC is erased, including userdata: the board starts as new.

## If it goes wrong

`*** INSTALL FAILED: <reason>` stops the installer and the board waits. Power off and act on the reason:

| Message | Meaning |
|---|---|
| `no internal storage found (fe2e0000.mmc). Is the eMMC module fitted?` | no eMMC module, or not seated |
| `internal storage too small` | the eMMC is smaller than the system |
| `no source disk` / `the card has no '…' partition` | the card is not an installer card, or came out |
| `… differs after writing … bad storage?` | the read-back did not match: retry once, then replace the eMMC module |

A failed install after the countdown leaves the eMMC incomplete; it will not boot until an install
succeeds. Run the card again.

To check a card and a board without touching the eMMC, make the card with `--dry-run`: it reads the whole card,
checks that the eMMC is there and big enough, and stops.

## What the card holds

The installer card is a normal `mkimg.sh` card with three files added to its boot partition, so the same card
also carries the system to copy:

- `installer.img`: a small ramdisk whose `/init` is the installer (a static binary, no Android).
- `extlinux/extlinux.conf`: boots the installer by default (`label install`); `label android` is still there.
- `extlinux/extlinux.conf.target`: the boot configuration the eMMC gets, the card's one with
  `androidboot.boot_devices` set to the eMMC controller.

The installer copies the partitions up to and including vendor, writes a new partition table with userdata
stretched to the end of the eMMC, clears the start of metadata and userdata (Android formats them on first
boot), and puts `extlinux.conf.target` in place on the eMMC as `extlinux.conf`. It does not copy the card's
userdata, which is why the installer image can be small.

Kernel options read by the installer (set by `mkinstaller.sh`, or `INSTALLER_ARGS` with `mkimg.sh`):

| Option | Default | |
|---|---|---|
| `rock5_installer.source` | `fe2c0000.mmc` | sysfs path part of the card (the SD controller) |
| `rock5_installer.target` | `fe2e0000.mmc` | sysfs path part of the target (the eMMC controller) |
| `rock5_installer.countdown` | `10` | seconds before writing |
| `rock5_installer.dry_run` | `0` | `1` = check only |

## Testing the installer from Android

As root on a running board, the same binary can install to another disk without rebooting, e.g. to a USB stick
as a stand-in for the eMMC. Build it with
`m out/soong/.intermediates/device/radxa/rock5/installer/rock5_installer/android_arm64_armv8-2a_cortex-a76/rock5_installer`,
push it to `/data/local/tmp`, then:

```sh
rock5_installer --test sda --dry-run   # check only
rock5_installer --test sda             # ERASES sda
```

It reads from the card the board booted from. The write test also needs `extlinux/extlinux.conf.target` on that
card's boot partition.
