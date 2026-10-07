#!/bin/bash
#
# Boot OpenIPC on emulated Hi3516EV300 ENTIRELY FROM a SPI-NAND image
# (no -kernel / -initrd / -dtb).  The synthetic boot ROM runs U-Boot from
# NAND; U-Boot reports the boot device as SPI-NAND (SYSSTAT strap), attaches
# UBI, ubifsloads /boot/fitImage from the UBIFS rootfs and bootm's it; the
# kernel attaches UBI and mounts ubi0:rootfs as UBIFS — all from the emulated
# SPI-NAND.
#
# Build the image first:
#   bash qemu-boot/mk-ev300-nand.sh        # assembles ev300-nand.img
#
# The image is >16 MiB so the FMC auto-selects SPI-NAND mode.  nand-jedec
# presents the universally-supported Winbond W25N01GV (the OpenIPC ev300
# U-Boot SPI-NAND ID table predates GD5F1GM7); nand-oob-size matches it.
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
QEMU="$REPO_ROOT/qemu-src/build/qemu-system-arm"

FLASH="${FLASH:-$SCRIPT_DIR/ev300-nand.img}"
if [ ! -f "$FLASH" ]; then
    echo "Error: NAND image not found: $FLASH" >&2
    echo "Build it first:  bash qemu-boot/mk-ev300-nand.sh" >&2
    exit 1
fi

# Boot from a throwaway copy: U-Boot's saveenv / UBI writes back to NAND.
IMG="$(mktemp /tmp/ev300-nand.XXXXXX.img)"
cp -f "$FLASH" "$IMG"

# sensor=none skips the SoC-default IMX335 attach so OpenIPC's load_hisilicon
# doesn't insmod the vendor MPP blob (which hangs on QEMU before login).
"$QEMU" -M hi3516ev300,sensor=none,flash-file="$IMG" \
    -global hisi-fmc.nand-jedec=0xEFAA21 \
    -global hisi-fmc.nand-oob-size=64 \
    -nographic -serial mon:stdio -nic user,restrict=on \
    -d unimp,guest_errors -D "$SCRIPT_DIR/qemu-ev300-nand.log" \
    "$@"
rc=$?
rm -f "$IMG"
exit $rc
