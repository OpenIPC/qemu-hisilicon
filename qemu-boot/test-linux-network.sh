#!/bin/bash
#
# Reproduce the CI Linux ping+curl network check with explicit timing
# markers so slow guests can be diagnosed without relying on silent waits.
#
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  test-linux-network.sh --soc SOC --machine MACHINE --mem MEM_MB --append APPEND [options]

Options:
  --qemu PATH              QEMU binary path
  --tap IFACE              TAP interface name (default: tap0)
  --bridge IFACE           Bridge name when --setup-network is used (default: qbr0)
  --host-ip IP             Host bridge IP and gateway (default: 10.0.10.1)
  --dns-ip IP              Off-subnet host address advertised as the guest's
                           DNS server, so reaching it requires the default
                           route (default: 10.0.20.1)
  --setup-network          Create TAP/bridge/http/dnsmasq locally and tear it down
  --login-timeout SEC      Wait for login prompt (default: 240)
  --ping-timeout SEC       Wait for ping completion marker (default: 45)
  --curl-timeout SEC       Wait for curl completion marker (default: 100)
  --curl-max-time SEC      Guest curl --max-time value (default: 90)
  --output-dir DIR         Directory for diagnostic output (default: /tmp/linux-network-SOC-PID)
  --dnsmasq-log PATH       dnsmasq log to read the DHCP lease and DNS queries
                           from; must match the --log-facility of whoever
                           started dnsmasq (default: OUTPUT_DIR/dnsmasq.log)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
QEMU="$REPO_ROOT/qemu-src/build/qemu-system-arm"
TAP="tap0"
BRIDGE="qbr0"
HOST_IP="10.0.10.1"
# Deliberately off the guest's subnet: the guest can only reach it by way of
# the default route it was handed, so a query arriving here proves routing and
# not merely that the host shares a link with the guest.
DNS_IP="10.0.20.1"
LOGIN_TIMEOUT=240
PING_TIMEOUT=45
CURL_TIMEOUT=100
CURL_MAX_TIME=90
SETUP_NETWORK=0
OUTPUT_DIR=""
DNSMASQ_LOG_ARG=""
SOC=""
MACHINE=""
MEM_MB=""
APPEND=""

while [ $# -gt 0 ]; do
    case "$1" in
        --soc) SOC="$2"; shift 2 ;;
        --machine) MACHINE="$2"; shift 2 ;;
        --mem) MEM_MB="$2"; shift 2 ;;
        --append) APPEND="$2"; shift 2 ;;
        --qemu) QEMU="$2"; shift 2 ;;
        --tap) TAP="$2"; shift 2 ;;
        --bridge) BRIDGE="$2"; shift 2 ;;
        --host-ip) HOST_IP="$2"; shift 2 ;;
        --dns-ip) DNS_IP="$2"; shift 2 ;;
        --setup-network) SETUP_NETWORK=1; shift ;;
        --login-timeout) LOGIN_TIMEOUT="$2"; shift 2 ;;
        --ping-timeout) PING_TIMEOUT="$2"; shift 2 ;;
        --curl-timeout) CURL_TIMEOUT="$2"; shift 2 ;;
        --curl-max-time) CURL_MAX_TIME="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --dnsmasq-log) DNSMASQ_LOG_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$SOC" ] || [ -z "$MACHINE" ] || [ -z "$APPEND" ]; then
    usage >&2
    exit 2
fi

# --mem is optional — when omitted, QEMU uses the machine's default
# ram_size from the HisiSoCConfig table.
MEM_MB="${MEM_MB%M}"
MEM_ARG=""
[ -n "$MEM_MB" ] && MEM_ARG="-m ${MEM_MB}M"

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="/tmp/linux-network-${SOC}-$$"
fi

SER_PREFIX="/tmp/${SOC}.ser"
SER_IN="${SER_PREFIX}.in"
SER_OUT="${SER_PREFIX}.out"
SERIAL_LOG="/tmp/linux-ping.txt"
SUMMARY_LOG="/tmp/linux-network-summary.txt"
HTTP_LOG="${OUTPUT_DIR}/http.log"
DNSMASQ_LOG="${DNSMASQ_LOG_ARG:-${OUTPUT_DIR}/dnsmasq.log}"
QEMU_STDOUT="${OUTPUT_DIR}/qemu.stdout"
QEMU_STDERR="${OUTPUT_DIR}/qemu.stderr"
QEMU_PS_START="${OUTPUT_DIR}/qemu-ps-start.txt"
QEMU_PS_END="${OUTPUT_DIR}/qemu-ps-end.txt"
HOST_METRICS="${OUTPUT_DIR}/host-metrics.txt"

mkdir -p "$OUTPUT_DIR"
rm -f "$SER_IN" "$SER_OUT" "$SERIAL_LOG" "$SUMMARY_LOG"

QEMU_PID=""
HTTP_PID=""
CAT_PID=""

cleanup() {
    set +e
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
    [ -n "$CAT_PID" ] && kill "$CAT_PID" 2>/dev/null || true
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    rm -f "$SER_IN" "$SER_OUT"
    if [ "$SETUP_NETWORK" = "1" ]; then
        sudo ip addr del "${DNS_IP}/24" dev "$BRIDGE" 2>/dev/null || true
        # --no-daemon dnsmasq never writes the pid file, so killing by it is a
        # no-op and the instance outlives the run, holding the listen address:
        # the next run's dnsmasq then dies with "Address already in use" and
        # writes no log, which reads as a DHCP failure in a guest that in fact
        # leased fine.  Match the command line instead.
        sudo pkill -f "dnsmasq --interface=${BRIDGE}" 2>/dev/null || true
        sudo kill "$(cat /tmp/dnsmasq.pid 2>/dev/null)" 2>/dev/null || true
        sudo iptables -D INPUT -i "$BRIDGE" -j ACCEPT 2>/dev/null || true
        sudo ip link del "$BRIDGE" 2>/dev/null || true
        sudo ip tuntap del dev "$TAP" mode tap 2>/dev/null || true
    fi
}
trap cleanup EXIT

start_ts=$(date +%s)

{
    echo "soc=$SOC"
    echo "machine=$MACHINE"
    echo "mem_mb=$MEM_MB"
    echo "append=$APPEND"
    echo "qemu=$QEMU"
    echo "host_start=$(date --iso-8601=seconds)"
    echo "host_uptime_start=$(uptime)"
    echo "host_nproc=$(nproc)"
} > "$SUMMARY_LOG"

{
    echo "=== host start ==="
    uptime
    ps -eo pid,pcpu,pmem,etime,cmd --sort=-pcpu | sed -n '1,12p'
} > "$HOST_METRICS"

if [ "$SETUP_NETWORK" = "1" ]; then
    sudo ip link del "$BRIDGE" 2>/dev/null || true
    sudo ip tuntap del dev "$TAP" mode tap 2>/dev/null || true
    sudo pkill -f "dnsmasq --interface=${BRIDGE}" 2>/dev/null || true
    sudo kill "$(cat /tmp/dnsmasq.pid 2>/dev/null)" 2>/dev/null || true
    sudo iptables -D INPUT -i "$BRIDGE" -j ACCEPT 2>/dev/null || true

    sudo ip tuntap add dev "$TAP" mode tap user "$(whoami)"
    sudo ip link add "$BRIDGE" type bridge
    sudo ip link set "$BRIDGE" type bridge stp_state 0
    sudo ip link set "$TAP" master "$BRIDGE"
    sudo ip link set "$BRIDGE" up
    sudo ip link set "$TAP" up
    sudo ip addr add "${HOST_IP}/24" dev "$BRIDGE"
    sudo ip addr add "${DNS_IP}/24" dev "$BRIDGE"
    sudo iptables -I INPUT -i "$BRIDGE" -j ACCEPT

    python3 -m http.server 8080 --bind "$HOST_IP" >"$HTTP_LOG" 2>&1 &
    HTTP_PID=$!

    sudo dnsmasq --interface="$BRIDGE" --bind-interfaces \
        --listen-address="$HOST_IP" --listen-address="$DNS_IP" \
        --dhcp-range=10.0.10.50,10.0.10.99,255.255.255.0,1h \
        --dhcp-option=3,"$HOST_IP" --dhcp-option=6,"$DNS_IP" \
        --no-resolv --server=8.8.8.8 \
        --no-daemon --log-dhcp --log-queries --log-facility="$DNSMASQ_LOG" \
        --pid-file=/tmp/dnsmasq.pid >"${DNSMASQ_LOG}.stderr" 2>&1 &
    sleep 1
fi

# No console driving.  Root's login shell is `openipc-claim`, which hands out
# no shell until the camera has an owner, and on a majestic image claiming
# shows the Majestic EULA first -- acceptance that belongs to the camera's
# human owner and never to CI (OpenIPC/firmware CLAUDE.md, "Policy, for AI
# assistants").  Rather than swap in an image that has no gate, this asserts
# the network from outside the guest: everything the check needs is done by
# the guest's own init, long before any login exists.
#
#   S40network  -> udhcpc on eth0
#   S49ntpd     -> busybox ntpd resolves its pool
#   S50dropbear -> listens on 22 ("-R -B -k -p 22 -K 300")
#
# so the four assertions below cover both directions with no shell at all:
#
#   1. a full DHCP DORA in the dnsmasq log -- guest TX *and* RX over UDP: the
#      guest only sends REQUEST once it has received and parsed our OFFER
#   2. host -> guest ICMP -- the request is guest RX, the reply is guest TX
#   3. host -> guest TCP on 22 -- dropbear's version banner arrives before any
#      authentication, so real payload crosses in both directions
#   4. a DNS query from the guest's address -- guest-*initiated* traffic that
#      had to be routed: the DNS server handed out over DHCP sits on a subnet
#      the guest is not connected to, so the packet only arrives if the guest
#      installed and used the advertised default route
#
# What this gives up, and the console-driven version had, is the guest acting
# as a TCP client (curl).  Nothing in a stock boot opens an outbound TCP
# connection by itself, and arranging one would mean a shell, which means the
# claim.  Checks 1 and 4 keep guest-initiated traffic covered over UDP.
"$QEMU" \
    -M "$MACHINE" $MEM_ARG \
    -kernel "$REPO_ROOT/qemu-boot/uImage.${SOC}" \
    -initrd "$REPO_ROOT/qemu-boot/rootfs.squashfs.${SOC}" \
    -nographic -serial file:"$SERIAL_LOG" \
    -append "$APPEND" \
    -nic "tap,ifname=${TAP},script=no,downscript=no" \
    -monitor none >"$QEMU_STDOUT" 2>"$QEMU_STDERR" &
QEMU_PID=$!
ps -o pid,ppid,pcpu,pmem,etime,cmd -p "$QEMU_PID" > "$QEMU_PS_START"

# dnsmasq runs as root and its log file is created 0600, so make it readable
# rather than needing sudo for every poll.  Harmless if it does not exist yet.
sudo chmod 0644 "$DNSMASQ_LOG" 2>/dev/null || true

FAIL=0
say() { printf '%-42s %s\n' "$1" "$2"; }
# The --*-timeout options name seconds, so spend seconds rather than counting
# iterations: a retry count multiplied by its sleep (and by a connect timeout)
# overran the workflow's step limit, and a step killed mid-check prints no
# diagnostics at all.
deadline() { echo $(( $(date +%s) + $1 )); }
before()   { [ "$(date +%s)" -lt "$1" ]; }

# 1 --- DHCP -----------------------------------------------------------------
GUEST_IP=""
dhcp_deadline=$(deadline "$LOGIN_TIMEOUT")
while before "$dhcp_deadline"; do
    sudo chmod 0644 "$DNSMASQ_LOG" 2>/dev/null || true
    GUEST_IP=$(grep -aoE 'DHCPACK\([^)]*\) ([0-9]{1,3}\.){3}[0-9]{1,3}' "$DNSMASQ_LOG" 2>/dev/null \
               | tail -1 | awk '{print $2}') || true
    [ -n "$GUEST_IP" ] && break
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
if [ -n "$GUEST_IP" ]; then
    say "1. DHCP lease (guest TX+RX, UDP)" "PASS -> $GUEST_IP"
    echo "guest_ip=$GUEST_IP" >> "$SUMMARY_LOG"
    echo "dhcp_elapsed=$(( $(date +%s) - start_ts ))" >> "$SUMMARY_LOG"
    grep -aoE 'DHCP(DISCOVER|OFFER|REQUEST|ACK)' "$DNSMASQ_LOG" | sort -u | tr '\n' ' ' || true
    echo
else
    say "1. DHCP lease (guest TX+RX, UDP)" "FAIL (no DHCPACK)"
    echo "dhcp_elapsed=timeout" >> "$SUMMARY_LOG"
    echo "--- last 40 serial lines ---"; tail -40 "$SERIAL_LOG" 2>/dev/null || true
    echo "--- dnsmasq ---"; sudo tail -20 "$DNSMASQ_LOG" 2>/dev/null || true
    exit 1
fi

# 2 --- ICMP, host -> guest ---------------------------------------------------
if ping -c 3 -W 5 "$GUEST_IP" > "${OUTPUT_DIR}/ping.txt" 2>&1; then
    say "2. host->guest ICMP" "PASS ($(grep -o '[0-9]*% packet loss' "${OUTPUT_DIR}/ping.txt"))"
else
    say "2. host->guest ICMP" "FAIL"; cat "${OUTPUT_DIR}/ping.txt" || true; FAIL=1
fi

# 3 --- TCP, host -> guest ----------------------------------------------------
# bash's /dev/tcp, so no nc dependency.  Dropbear answers with its version
# banner before any authentication, so this needs no credentials and does not
# touch the claim.
ssh_banner() {
    local line="" rc=0
    exec 3<>/dev/tcp/"$GUEST_IP"/22 2>/dev/null || return 1
    IFS= read -r -t 5 line <&3 || rc=$?
    exec 3<&- 3>&- 2>/dev/null || true
    # Only a complete, terminated line counts.  A read that timed out leaves
    # whatever bytes had arrived in $line, and half a banner still starts with
    # "SSH-" -- so checking the prefix alone would accept a truncated one.
    [ "$rc" -eq 0 ] || return 1
    printf '%s' "$line"
}
BANNER=""
tcp_deadline=$(deadline "$PING_TIMEOUT")
while before "$tcp_deadline"; do
    BANNER=$(ssh_banner || true)
    # RFC 4253: the identification string opens with "SSH-".  Anything else --
    # a replacement service, startup noise, half a line from a read that timed
    # out -- is not dropbear answering, and must not pass for it.
    case "$BANNER" in SSH-*) break ;; *) BANNER="" ;; esac
    sleep 2
done
if [ -n "$BANNER" ]; then
    say "3. host->guest TCP :22" "PASS -> ${BANNER%$'\r'}"
else
    say "3. host->guest TCP :22" "FAIL (no SSH- identification)"; FAIL=1
fi

# 4 --- guest-initiated outbound ----------------------------------------------
# busybox ntpd resolves its peers at S49.  The resolver it was given is
# $DNS_IP, which is NOT on the guest's subnet, so the query can only reach us
# through the advertised gateway -- an absent or wrong default route fails the
# check rather than sneaking past on a connected-link delivery.  Any name will
# do; which server the image is configured with is not this test's business.
QUERY=""
dns_deadline=$(deadline "$CURL_TIMEOUT")
while before "$dns_deadline"; do
    sudo chmod 0644 "$DNSMASQ_LOG" 2>/dev/null || true
    QUERY=$(grep -a "query\[" "$DNSMASQ_LOG" 2>/dev/null | grep -a "from ${GUEST_IP}" | head -1) || true
    [ -n "$QUERY" ] && break
    sleep 2
done
if [ -n "$QUERY" ]; then
    say "4. guest->routed DNS query" "PASS -> ${QUERY#*: }"
else
    say "4. guest->routed DNS query" "FAIL (no query from $GUEST_IP to $DNS_IP)"; FAIL=1
fi

ps -o pid,ppid,pcpu,pmem,etime,cmd -p "$QEMU_PID" > "$QEMU_PS_END" 2>/dev/null || true
{
    echo "=== host end ==="
    uptime
    ps -eo pid,pcpu,pmem,etime,cmd --sort=-pcpu | sed -n '1,12p'
} >> "$HOST_METRICS"
{
    echo "host_uptime_end=$(uptime)"
    echo "host_end=$(date --iso-8601=seconds)"
    echo "output_dir=$OUTPUT_DIR"
} >> "$SUMMARY_LOG"

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

cat "$SUMMARY_LOG"

if [ "$FAIL" -ne 0 ]; then
    echo "=== FAIL: Linux network ==="
    exit 1
fi
echo "=== PASS: Linux network (DHCP + ICMP + TCP + routed DNS) ==="
