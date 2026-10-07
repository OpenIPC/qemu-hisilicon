#!/bin/bash
#
# Test CPU1 release through CRG REG_CPU_SRST_CRG on the dual Cortex-A7
# V4A parts, on the -bios mask-ROM boot path.
#
# Usage:  bash qemu/tests/test-hisi-smp-release.sh
#
# A tiny -bios image stands in for the mask-ROM + kernel and does what they
# do on silicon, on CPU0:
#   1. sets SC_CTRL bit 8 (the mask-ROM's "clear boot remap" handoff),
#      which must drop the mask-ROM alias at address 0;
#   2. writes "ldr pc, [pc, #-4]; .word cpu1" at physical 0, as
#      hi35xx_set_scu_boot_addr() does;
#   3. clears CPU1_SRST_REQ (bit 2) of CRG + 0x78.
# CPU1 must then leave reset at PC 0, take the trampoline, and store a
# marker into SRAM.  The image is generated here (no cross toolchain needed).
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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ELF32 ARM image at the mask-ROM base 0x04000000.  Code (GNU as):
#   0x000 cpu0: ldr r0,=SC_CTRL; ldr r1,[r0]; orr r1,#0x100; str r1,[r0]
#               mov r2,#0; ldr r1,=0xe51ff004; str r1,[r2]
#               ldr r1,=cpu1; str r1,[r2,#4]
#               ldr r0,=CRG+0x78; ldr r1,[r0]; bic r1,#4; str r1,[r0]
#               1: wfi; b 1b
#   0x100 cpu1: ldr r0,=0x04010000; ldr r1,=0xc0ffee01; str r1,[r0]
#               2: wfi; b 2b
python3 - "$TMP/smp.elf" <<'PY'
import struct, sys
cpu0 = [0xe59f0034, 0xe5901000, 0xe3811c01, 0xe5801000, 0xe3a02000,
        0xe59f1024, 0xe5821000, 0xe59f1020, 0xe5821004, 0xe59f001c,
        0xe5901000, 0xe3c11004, 0xe5801000, 0xe320f003, 0xeafffffd,
        0x12020000, 0xe51ff004, 0x04000100, 0x12010078]
cpu1 = [0xe59f000c, 0xe59f100c, 0xe5801000, 0xe320f003, 0xeafffffd,
        0x04010000, 0xc0ffee01]
words = cpu0 + [0] * (64 - len(cpu0)) + cpu1
code = struct.pack('<%dI' % len(words), *words)
base, off = 0x04000000, 0x54
ehdr = struct.pack('<16sHHIIIIIHHHHHH', b'\x7fELF\x01\x01\x01' + b'\0' * 9,
                   2, 40, 1, base, 52, 0, 0x05000000, 52, 32, 1, 0, 0, 0)
phdr = struct.pack('<IIIIIIII', 1, off, base, base, len(code), len(code),
                   5, 4)
img = ehdr + phdr
img += b'\0' * (off - len(img)) + code
open(sys.argv[1], 'wb').write(img)
PY

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc ($actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected $expected, got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# Run the image for a moment, then dump phys 0, 4 and the SRAM marker.
run() {
    local machine="$1" smp="$2"
    (sleep 2; printf 'xp/1xw 0x0\nxp/1xw 0x4\nxp/1xw 0x04010000\nquit\n') |
        timeout 15 "$QEMU" -M "$machine" -smp "$smp" -bios "$TMP/smp.elf" \
            -nodefaults -display none -serial null -monitor stdio \
            2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r' |
        grep -oP '[0-9a-f]+:\s+\K0x[0-9a-fA-F]+' || true
}

for machine in hi3516av300 hi3516cv500 hi3516dv300; do
    echo "--- $machine -smp 2 ---"
    vals=($(run "$machine" 2))
    check "phys 0 is the trampoline (remap cleared)" "0xe51ff004" "${vals[0]}"
    check "phys 4 is CPU1's entry" "0x04000100" "${vals[1]}"
    check "CPU1 ran from the trampoline" "0xc0ffee01" "${vals[2]}"

    echo "--- $machine -smp 1 ---"
    vals=($(run "$machine" 1))
    check "no CPU1 to release" "0x00000000" "${vals[2]}"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
