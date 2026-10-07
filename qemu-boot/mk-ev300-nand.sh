#!/bin/bash
#
# Assemble a bootable SPI-NAND image for the emulated Hi3516EV300 from the
# OpenIPC hi3516ev300 NAND release, then boot it with run-ev300-nand.sh.
#
# OpenIPC ships the NAND build as:
#   u-boot-hi3516ev300-nand.bin           (U-Boot, gzip-loader format)
#   openipc.hi3516ev300-nand-ultimate.tgz -> rootfs.ubi (+ fitImage, rootfs.ubifs)
# rootfs.ubi holds a UBIFS "rootfs" volume carrying the kernel as
# /boot/fitImage, plus an empty autoresize "rootfs_data".  U-Boot's default
# bootcmd mounts ubi0:rootfs, ubifsloads /boot/fitImage and boots it with
# root=ubi0:rootfs, so the image is just what a real flash holds — no
# repacking — laid out per the default env
# (mtdparts=hinand:768k(boot),256k(env),-(ubi)):
#   0x000000  boot  (u-boot)
#   0x0C0000  env   (blank -> U-Boot default env)
#   0x100000  ubi   (release rootfs.ubi, written as-is)
#
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/ev300-nand-mk}"
DL="https://github.com/OpenIPC/firmware/releases/download/latest"

mkdir -p "$WORK"; cd "$WORK"
[ -f u-boot-hi3516ev300-nand.bin ] || curl -sL -o u-boot-hi3516ev300-nand.bin "$DL/u-boot-hi3516ev300-nand.bin"
[ -f nand.tgz ]                    || curl -sL -o nand.tgz "$DL/openipc.hi3516ev300-nand-ultimate.tgz"
tar xzf nand.tgz rootfs.ubi.hi3516ev300

python3 - <<PY
img = bytearray(b'\xff' * 0x2000000)          # 32 MiB image (model pads to 128 MiB)
ub  = open('u-boot-hi3516ev300-nand.bin', 'rb').read(); img[0:len(ub)] = ub
ubi = open('rootfs.ubi.hi3516ev300', 'rb').read();       img[0x100000:0x100000+len(ubi)] = ubi
open('$SCRIPT_DIR/ev300-nand.img', 'wb').write(img)
print('wrote ev300-nand.img (%d bytes, ubi %d)' % (len(img), len(ubi)))
PY
echo "Done: $SCRIPT_DIR/ev300-nand.img — boot with: bash qemu-boot/run-ev300-nand.sh"
