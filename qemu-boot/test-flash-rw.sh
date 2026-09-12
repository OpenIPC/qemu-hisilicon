#!/bin/bash
#
# SPI-NOR erase + program round-trip test (regression guard for the HiFMC
# erase-address / WEL fix that makes OpenIPC `firstboot` and `sysupgrade`
# work — see "hisi-fmc: fix NOR erase/program ...").
#
# Boots OpenIPC from a writable synthetic SPI-NOR attached via -machine
# flash-file=, claims the camera, then from Linux userspace:
#   1. flash_eraseall a multi-block partition  -> must read back 0xFF
#   2. flashcp -v random data over it          -> must verify (exit 0)
#
# Both fail with the pre-fix model: the erase address was read from the
# stale FMC_ADDRL instead of the IO buffer, so every block after the first
# erased the wrong offset (partition stayed unerased; flashcp mismatched
# at the first un-erased block).  A multi-block payload is required to catch
# it — a single-block write happens to land on whatever addrl held.
#
# CLAIMING THE CAMERA.  Root's login shell is `openipc-claim`, and it hands out
# no shell until the camera has an owner, so this harness claims it the way any
# owner does: it logs in as root and sets a password at the `passwd` prompt.
# Typing `root` at a blank password used to be enough; it is not any more, and
# a harness that skips the claim (init=/bin/sh, say) would stop testing the
# path real cameras take.
#
# It will NOT claim an image carrying majestic.  On those the claim runs the
# Majestic EULA in front of the password, and acceptance belongs to the
# camera's human owner — never to CI, and never to an agent acting for them
# (OpenIPC/firmware CLAUDE.md, "Policy, for AI assistants").  Detecting the
# license prompt is therefore a hard failure with an explanation, not something
# to type through.  Point the harness at a majestic-free image instead: that is
# what `BR2_PACKAGE_MAJESTIC` off produces, and the `mini` variant is one
# already published, e.g.
#
#   https://github.com/OpenIPC/builder/releases/download/latest/\
#       openipc.hi3518ev200-nor-mini.tgz
#
# which is the right shape for this test anyway — it needs busybox and
# mtd-utils, not a video encoder.
#
# Usage:
#   test-flash-rw.sh --soc hi3516ev300 --machine hi3516ev300,sensor=none \
#       --qemu ./qemu-src/build/qemu-system-arm --output-dir <dir> \
#       [--mem 128M] [--login-timeout 120] \
#       [--kernel <uImage>] [--rootfs <squashfs>]
#
# --kernel/--rootfs override the qemu-boot/<name>.${SOC} defaults, so CI can
# hand over a locally built majestic-free image without renaming it.
#
set -u

SOC=""
MACHINE=""
QEMU="./qemu-src/build/qemu-system-arm"
OUTDIR="."
MEM="128M"
LOGIN_TIMEOUT=120
KERNEL=""
INITRD=""
# Any password claims the camera; this one is only ever typed at this prompt.
CLAIM_PASSWORD="qemu-flash-rw"

while [ $# -gt 0 ]; do
    case "$1" in
        --soc)           SOC="$2"; shift 2 ;;
        --machine)       MACHINE="$2"; shift 2 ;;
        --qemu)          QEMU="$2"; shift 2 ;;
        --output-dir)    OUTDIR="$2"; shift 2 ;;
        --mem)           MEM="$2"; shift 2 ;;
        --login-timeout) LOGIN_TIMEOUT="$2"; shift 2 ;;
        --kernel)        KERNEL="$2"; shift 2 ;;
        --rootfs)        INITRD="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$SOC" ] && [ -n "$MACHINE" ] || { echo "--soc and --machine required" >&2; exit 2; }
mkdir -p "$OUTDIR"

: "${KERNEL:=qemu-boot/uImage.${SOC}}"
: "${INITRD:=qemu-boot/rootfs.squashfs.${SOC}}"
for f in "$KERNEL" "$INITRD"; do
    [ -f "$f" ] || { echo "=== FAIL: missing $f ==="; exit 1; }
done

# 16 MiB synthetic NOR holding the rootfs, plus a 1 MiB writable "test"
# partition (mtd4, 16 erase blocks) that is NOT the rootfs, so erasing and
# rewriting it is safe.
#
# The rootfs lives in the flash rather than in an -initrd because claiming the
# camera writes to /etc, and OpenIPC's /init only builds the writable overlay
# when the root is flash — `root=ram|mmcblk|nfs` opts straight out of it, which
# is what this harness used to boot with, and passwd then failed with
# "/etc/passwd: Read-only file system".  Booting from flash also puts the
# first-boot jffs2 format of rootfs_data in the path, so the erase code is
# exercised twice over: once as `firstboot` does it, once by the round-trip
# below.  The kernel still arrives via -kernel; nothing writes mtd2.
BOOT_KB=256; ENV_KB=64; KERN_KB=2048; TEST_KB=1024; DATA_KB=2048
ROOTFS_KB=$(( ( ($(stat -c %s "$INITRD") + 65535) / 65536 ) * 64 ))
ROOTFS_OFF_KB=$((BOOT_KB + ENV_KB + KERN_KB))
TEST_MTD=4

FLASH="$OUTDIR/flash.bin"
dd if=/dev/zero of="$FLASH" bs=1M count=16 2>/dev/null
dd if="$INITRD" of="$FLASH" bs=1k seek="$ROOTFS_OFF_KB" conv=notrunc 2>/dev/null
MTDPARTS="hi_sfc:${BOOT_KB}k(boot),${ENV_KB}k(env),${KERN_KB}k(kernel)"
MTDPARTS="${MTDPARTS},${ROOTFS_KB}k(rootfs),${TEST_KB}k(test)"
MTDPARTS="${MTDPARTS},${DATA_KB}k(rootfs_data),-(spare)"
APPEND="console=ttyAMA0,115200 root=/dev/mtdblock3 rootfstype=squashfs"
APPEND="${APPEND} init=/init mtdparts=${MTDPARTS}"

CONSOLE="$OUTDIR/flash-rw-console.txt"
SER_IN="$OUTDIR/ser.in"
SER_OUT="$OUTDIR/ser.out"
rm -f "$SER_IN" "$SER_OUT" "$CONSOLE"
mkfifo "$SER_IN" "$SER_OUT"

# restrict=on: keep SLIRP DHCP reachable but block outbound (busybox ntpd,
# see openhisilicon#104) so init runs deterministically.
timeout 240 "$QEMU" \
    -M "$MACHINE",flash-file="$FLASH" -m "$MEM" \
    -kernel "$KERNEL" \
    -nographic -serial "pipe:${OUTDIR}/ser" -monitor none \
    -nic user,restrict=on \
    -append "$APPEND" &
QEMU_PID=$!
( timeout 240 cat "$SER_OUT" > "$CONSOLE" 2>&1 ) &
exec 3<>"$SER_IN"

cleanup() { exec 3>&- 2>/dev/null; kill "$QEMU_PID" 2>/dev/null; wait 2>/dev/null; rm -f "$SER_IN" "$SER_OUT"; }
trap cleanup EXIT

wait_for() { # marker timeout
    local m="$1" t="$2" i
    for i in $(seq 1 "$t"); do
        grep -qF "$m" "$CONSOLE" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# Wait for whichever of several markers turns up first; print the winner.
wait_any() { # timeout marker...
    local t="$1"; shift
    local i m
    for i in $(seq 1 "$t"); do
        for m in "$@"; do
            if grep -qF "$m" "$CONSOLE" 2>/dev/null; then echo "$m"; return 0; fi
        done
        sleep 1
    done
    return 1
}

echo "=== waiting for login prompt (<= ${LOGIN_TIMEOUT}s) ==="
if ! wait_for "login:" "$LOGIN_TIMEOUT"; then
    echo "=== FAIL: login prompt not reached ==="; tail -30 "$CONSOLE"; exit 1
fi
printf 'root\r' >&3

# Root's login shell is openipc-claim, so logging in lands on one of three
# things: the Majestic EULA (majestic images only), the password prompt of an
# unclaimed camera, or — if the camera already has an owner — a plain shell.
EULA_PROMPT='Type "view" to read the EULA'
seen=$(wait_any 30 "$EULA_PROMPT" "New password:" || true)

case "$seen" in
"$EULA_PROMPT")
    cat >&2 <<EOF
=== FAIL: this image carries majestic, so the claim runs its EULA ===
Accepting the Majestic EULA belongs to the camera's human owner. CI does not
type it, and neither does an agent on the owner's behalf — see "Policy, for AI
assistants" in OpenIPC/firmware CLAUDE.md.

Run this test against a majestic-free image, which is what BR2_PACKAGE_MAJESTIC
off builds. The published 'mini' variant is one:
  openipc.<soc>-nor-mini.tgz  (OpenIPC/builder releases)
then pass it with --kernel/--rootfs.
EOF
    tail -30 "$CONSOLE"; exit 1
    ;;
"New password:")
    echo "=== unclaimed camera: claiming it (setting root's password) ==="
    printf '%s\r' "$CLAIM_PASSWORD" >&3; sleep 2
    printf '%s\r' "$CLAIM_PASSWORD" >&3; sleep 2
    if ! wait_for "This camera is set up" 30; then
        echo "=== FAIL: claim did not complete ==="; tail -30 "$CONSOLE"; exit 1
    fi
    echo "=== claimed ==="
    ;;
*)
    # No gate: an already-claimed camera, or an image without the claim shell.
    echo "=== camera already claimed (or no claim gate) ==="
    ;;
esac
sleep 2

# Let init settle, then drive the round-trip.  NOTE: the serial console
# echoes each typed command back, so a literal success word (e.g. "OK")
# would also appear in the echoed command line.  All results are therefore
# reported as `NAME=<digit>` exit codes and extracted with a digit-anchored
# sed — the command echo carries the literal "$?", never a digit, so only
# the real output line matches.
printf 'echo RW_READY_$((6*7))\r' >&3
wait_for "RW_READY_42" 25 || { echo "=== FAIL: shell not ready ==="; tail -30 "$CONSOLE"; exit 1; }

# 1) erase the 1 MiB (16-block) test partition, 2) confirm it reads back all-0xFF,
# 3) flashcp -v a 512 KiB (8-block) random payload over it.  Multi-block is
# essential: the pre-fix bug erased every block but the first at a stale
# address, so the readback stayed un-erased and flashcp's verify mismatched.
printf 'flash_eraseall /dev/mtd%s >/dev/null 2>&1; echo ERASE_RC=$?\r' "$TEST_MTD" >&3; sleep 2
printf 'xxd -l 16 /dev/mtd%s | grep -q "ffff ffff ffff ffff ffff ffff ffff ffff"; echo EFF_RC=$?\r' "$TEST_MTD" >&3; sleep 2
printf 'head -c 524288 /dev/urandom > /tmp/t; flashcp -v /tmp/t /dev/mtd%s >/dev/null 2>&1; echo FLASHCP_RC=$?\r' "$TEST_MTD" >&3; sleep 3
printf 'echo RW_DONE_$((21*2))\r' >&3
wait_for "RW_DONE_42" 60 || { echo "=== FAIL: round-trip did not complete ==="; tail -40 "$CONSOLE"; exit 1; }

sleep 1
sync_strip() { sed 's/\r//g' "$CONSOLE"; }
get_rc() { sync_strip | sed -n "s/.*$1=\\([0-9]\\).*/\\1/p" | head -1; }

erase_rc=$(get_rc ERASE_RC)      # flash_eraseall exit status
eff_rc=$(get_rc EFF_RC)          # 0 => test mtd reads all-0xFF after erase
flashcp_rc=$(get_rc FLASHCP_RC)  # 0 => busybox flashcp -v erase+write+verify OK

echo "=== results: ERASE_RC=$erase_rc EFF_RC=$eff_rc FLASHCP_RC=$flashcp_rc ==="

fail=0
[ "$erase_rc" = "0" ]   || { echo "FAIL: flash_eraseall on the test mtd returned '$erase_rc'"; fail=1; }
[ "$eff_rc" = "0" ]     || { echo "FAIL: test mtd not 0xFF after erase (erase hit wrong address)"; fail=1; }
[ "$flashcp_rc" = "0" ] || { echo "FAIL: flashcp -v returned '$flashcp_rc' (verify mismatch)"; fail=1; }

if [ "$fail" = "0" ]; then
    echo "=== PASS: SPI-NOR erase + program round-trip OK ==="
    exit 0
fi
echo "--- last 40 console lines ---"; sync_strip | tail -40
exit 1
