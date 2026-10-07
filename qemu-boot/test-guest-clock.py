#!/usr/bin/env python3
"""
Guest clock-rate regression test: does guest time advance at wall-clock speed?

Boots an OpenIPC kernel + squashfs rootfs with init=/bin/sh (no getty, no
login, no first-boot setup), mounts /proc, and reads /proc/uptime twice
INTERVAL seconds of host time apart.  The guest/host ratio must be ~1.0.

It catches the guest timebase disagreeing with the rate the kernel was
told in the DTB:
  - SP804 counting at QEMU's 1 MHz default under a 3 MHz clk_3m (0.33x),
  - the ARM generic timer at QEMU's 62.5 MHz under an arm,armv7-timer
    clock-frequency of 50 MHz (1.25x) or 24 MHz (2.6x),
  - SP804 at 24 MHz under a 3 MHz kernel clock (8x, and time goes
    backwards when the 32-bit counter wraps faster than expected).
A login prompt still appears in every one of those cases, so the boot test
alone does not notice; userspace just sleeps 3x too long or 8x too short.

Usage:
    python3 qemu-boot/test-guest-clock.py \\
        --qemu ./qemu-src/build/qemu-system-arm --machine hi3516cv500 \\
        --kernel qemu-boot/uImage.hi3516cv500 \\
        --initrd qemu-boot/rootfs.squashfs.hi3516cv500 [--smp 2]
"""

import argparse
import os
import re
import select
import subprocess
import sys
import time


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--qemu', required=True)
    ap.add_argument('--machine', required=True)
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--initrd', required=True)
    ap.add_argument('--smp', default='1')
    ap.add_argument('--interval', type=float, default=20.0,
                    help='host seconds between the two samples')
    ap.add_argument('--tolerance', type=float, default=0.10,
                    help='allowed |ratio - 1|')
    ap.add_argument('--boot-timeout', type=float, default=180.0)
    ap.add_argument('--log', help='write the raw serial log here')
    args = ap.parse_args()

    cmd = [args.qemu, '-M', args.machine, '-smp', args.smp,
           '-kernel', args.kernel, '-initrd', args.initrd,
           '-nographic', '-serial', 'stdio', '-monitor', 'none',
           '-nic', 'none', '-append',
           'console=ttyAMA0,115200 root=/dev/ram0 rootfstype=squashfs '
           'init=/bin/sh']
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    buf = bytearray()

    def read_until(pred, timeout):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if pred(buf):
                return True
            r, _, _ = select.select([p.stdout], [], [], 0.1)
            if r:
                d = os.read(p.stdout.fileno(), 4096)
                if not d:
                    return pred(buf)
                buf.extend(d)
        return pred(buf)

    def send(s):
        p.stdin.write(s.encode())
        p.stdin.flush()

    def fail(msg):
        p.kill()
        if args.log:
            open(args.log, 'wb').write(buf)
        print('FAIL: %s' % msg)
        print('--- last serial output ---')
        print(bytes(buf[-1500:]).decode(errors='replace'))
        sys.exit(1)

    # /bin/sh as PID 1 prints this once it owns the console.  Don't wait
    # for the prompt itself: late kernel messages can follow it, so the
    # buffer need not end with "# ".  The /proc round trip below is the
    # real readiness check; it retries in case early keystrokes are lost.
    if not read_until(lambda b: b'job control turned off' in b,
                      args.boot_timeout):
        fail('no shell within %.0f s' % args.boot_timeout)
    for _ in range(5):
        send('mount -t proc proc /proc 2>/dev/null; '
             'echo PROC_$(test -r /proc/uptime && echo OK)\n')
        if read_until(lambda b: b'PROC_OK' in b, 10):
            break
        time.sleep(2)
    else:
        fail('could not mount /proc')

    seq = [0]

    def sample():
        # Host time is the midpoint of the request/response round trip;
        # a slow round trip (loaded host) would skew it, so retry.
        for _ in range(5):
            seq[0] += 1
            tag = 'UPT%d' % seq[0]
            pat = re.compile((tag + r' ([0-9]+\.[0-9]+)').encode())
            t0 = time.monotonic()
            send('echo %s $(cut -d" " -f1 /proc/uptime)\n' % tag)
            if not read_until(lambda b: pat.search(b), 30):
                fail('no reply to uptime sample %s' % tag)
            t1 = time.monotonic()
            if t1 - t0 < 1.0:
                return (t0 + t1) / 2, float(pat.search(buf).group(1))
        fail('uptime round trips stayed above 1 s; host too loaded')

    h0, g0 = sample()
    time.sleep(args.interval)
    h1, g1 = sample()
    p.kill()
    if args.log:
        open(args.log, 'wb').write(buf)

    ratio = (g1 - g0) / (h1 - h0)
    cs = re.findall(rb'[Ss]witched to clocksource (\S+)', buf)
    print('%s: guest %.2f s over host %.2f s, ratio %.3f (clocksource %s)'
          % (args.machine, g1 - g0, h1 - h0, ratio,
             cs[-1].decode() if cs else 'unknown'))
    if abs(ratio - 1.0) > args.tolerance:
        print('FAIL: guest clock runs at %.3fx wall-clock speed' % ratio)
        sys.exit(1)
    print('PASS')


if __name__ == '__main__':
    main()
