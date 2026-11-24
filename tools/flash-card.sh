#!/bin/bash
#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#
# Write an image from mkimg.sh or mkinstaller.sh to an SD card, checking first
# that the disk is a removable or USB card reader, big enough, and not in use.
#
#   sudo device/radxa/rock5/tools/flash-card.sh IMG [DISK]
#
# Without DISK it lists the card readers it finds and uses the only one, or
# asks you to name one (e.g. sdc). It always shows the disk and asks before
# writing. Disks over 128 GB are refused (likely not a card) unless
# FLASH_ALLOW_BIG=1.

set -euo pipefail

die() { echo "!! $*"; exit 1; }

[ $# -ge 1 ] && [ $# -le 2 ] || { sed -n '/^#   sudo/p' "$0" | sed 's/^# *//'; exit 1; }
IMG=$1
[ -f "$IMG" ] || die "no image $IMG"
[ "$(id -u)" = 0 ] || die "run it with sudo"

# Whole disks on USB or marked removable, with a medium in them
cards() {
  # TRAN last: it is empty for some disks
  lsblk -dnpbo NAME,TYPE,RM,SIZE,TRAN | awk '$2 == "disk" && ($3 == 1 || $5 == "usb") && $4 > 0 {print $1}'
}

if [ $# -eq 2 ]; then
  DISK=/dev/${2#/dev/}
else
  mapfile -t FOUND < <(cards)
  case ${#FOUND[@]} in
    0) die "no card found: is the card in the reader?" ;;
    1) DISK=${FOUND[0]} ;;
    *) echo "Several card readers have a card:"
       lsblk -dpo NAME,SIZE,TRAN,MODEL "${FOUND[@]}"
       die "name the one to write, e.g. $0 $IMG $(basename "${FOUND[0]}")" ;;
  esac
fi

[ -b "$DISK" ] || die "$DISK is not a block device"
[ "$(lsblk -dno TYPE "$DISK")" = disk ] || die "$DISK is a partition: give the whole disk"
cards | grep -qx "$DISK" || die "$DISK is not a removable or USB disk"

DISK_SIZE=$(lsblk -bdno SIZE "$DISK")
IMG_SIZE=$(stat -c %s "$IMG")
[ "$DISK_SIZE" -ge "$IMG_SIZE" ] || die "$DISK is $(numfmt --to=iec "$DISK_SIZE"), the image needs $(numfmt --to=iec "$IMG_SIZE")"
[ "$DISK_SIZE" -le 128000000000 ] || [ "${FLASH_ALLOW_BIG:-0}" = 1 ] \
  || die "$DISK is $(numfmt --to=iec "$DISK_SIZE"): too big for a card? Set FLASH_ALLOW_BIG=1 if it really is one"

MOUNTED=$(lsblk -lnpo MOUNTPOINTS "$DISK" | sed '/^$/d' || true)
[ -z "$MOUNTED" ] || die "$DISK has mounted partitions ($(echo $MOUNTED)); unmount them first"

echo
lsblk -po NAME,SIZE,TRAN,MODEL,LABEL "$DISK"
echo
echo "Image: $IMG ($(numfmt --to=iec "$IMG_SIZE"))"
read -r -p "Erase $DISK and write the image? Type yes: " ANSWER
[ "$ANSWER" = yes ] || die "not written"

dd if="$IMG" of="$DISK" bs=4M conv=fsync status=progress
sync
echo ">> done: take the card out and put it in the board"
