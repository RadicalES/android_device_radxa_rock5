#
# Copyright (C) 2026 RadicalES
#
# SPDX-License-Identifier: Apache-2.0
#

# boot.img is a FAT partition holding the kernel, the board's DTB, the Android
# ramdisk and an extlinux.conf; U-Boot's standard boot flow picks that up.

ROCK5_BOOT_OUT := $(PRODUCT_OUT)/rock5boot
$(ROCK5_BOOT_OUT): $(INSTALLED_RAMDISK_TARGET) $(INSTALLED_KERNEL_TARGET)
	rm -rf $@
	mkdir -p $@/extlinux
	cp $(KERNEL_PATH)/Image $@/
	cp $(KERNEL_PATH)/$(ROCK5_DTB) $@/
	cp $(PRODUCT_OUT)/ramdisk.img $@/
	sed -e 's|@DTB@|$(ROCK5_DTB)|' -e 's|@CMDLINE@|$(BOARD_KERNEL_CMDLINE)|' \
	    $(COMMON_PATH)/boot/extlinux.conf > $@/extlinux/extlinux.conf

$(INSTALLED_BOOTIMAGE_TARGET): $(ROCK5_BOOT_OUT)
	$(call pretty,"Target boot image: $@")
	dd if=/dev/zero of=$@ bs=1M count=128
	mkfs.fat -F 32 -n "boot" $@
	mcopy -s -i $@ $(ROCK5_BOOT_OUT)/* ::
