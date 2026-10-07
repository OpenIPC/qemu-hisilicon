#!/bin/bash
#
# Test SPI-NAND block erase + page program addressing in hisi-fmc.
#
# Usage:  bash qemu/tests/test-hisi-fmc-nand-erase.sh
#
# hifmc100/fmc100 write a register-mode erase's ADDRL as the raw row address
# (block * 64), while page DMA uses row << 16.  Decoding the erase like a DMA
# address sent every erase to block 0, so U-Boot `saveenv` on NAND wiped the
# bootloader in the backing file.  This drives the controller through qtest
# on a patterned 128 MiB image: erase block 5, program its first page, and
# check that only block 5 changed in the file.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
QEMU="$REPO_ROOT/qemu-src/build/qemu-system-arm"

if [ ! -x "$QEMU" ]; then
    echo "FAIL: QEMU binary not found at $QEMU"
    echo "      Run 'bash qemu/setup.sh' first."
    exit 1
fi

IMG="$(mktemp /tmp/hisi-fmc-nand.XXXXXX.img)"
trap 'rm -f "$IMG"' EXIT

# Block N is filled with byte N, so any misdirected erase/program shows up.
python3 - "$IMG" <<'EOF'
import sys
with open(sys.argv[1], 'wb') as f:
    for b in range(1024):
        f.write(bytes([b & 0xff]) * 131072)
EOF

# hi3516ev300: FMC at 0x10000000, DDR at 0x40000000.
# FMC_OP: CMD1_EN 0x80 | ADDR_EN 0x40 | REG_OP_START 0x1
printf '%s\n' \
    "writel 0x10000024 0x06" "writel 0x1000003c 0x81" \
    "writel 0x10000024 0xd8" "writel 0x1000002c 0x140" \
    "writel 0x1000003c 0xc1" \
    "memset 0x41000000 2048 0xa5" \
    "writel 0x10000024 0x06" "writel 0x1000003c 0x81" \
    "writel 0x1000002c 0x01400000" "writel 0x1000004c 0x41000000" \
    "writel 0x10000068 0x3" |
    timeout 5 "$QEMU" -M hi3516ev300,sensor=none,flash-file="$IMG" \
        -accel qtest -qtest stdio -display none -serial null \
        -monitor none >/dev/null 2>&1 || rc=$?
# qtest does not exit on stdin EOF, so timeout's 124 is the normal end; the
# write-back is a synchronous fwrite, so the image is complete by then.
if [ "${rc:-0}" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "FAIL: QEMU exited with status $rc"
    exit 1
fi

python3 - "$IMG" <<'EOF'
import sys
B, P = 131072, 2048
d = open(sys.argv[1], 'rb').read()
fail = 0

def check(desc, ok):
    global fail
    print(("  PASS: " if ok else "  FAIL: ") + desc)
    fail += not ok

blk = lambda n: d[n * B:(n + 1) * B]
check("block 0 untouched by erase of block 5", blk(0) == bytes([0]) * B)
check("block 4 untouched", blk(4) == bytes([4]) * B)
check("block 6 untouched", blk(6) == bytes([6]) * B)
check("block 5 page 0 programmed", blk(5)[:P] == b'\xa5' * P)
check("block 5 rest erased", blk(5)[P:] == b'\xff' * (B - P))
print("Result:", "FAIL" if fail else "PASS")
sys.exit(1 if fail else 0)
EOF
