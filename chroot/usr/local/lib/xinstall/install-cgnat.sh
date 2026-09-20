#!/bin/bash
# Install an ISP-style CGNAT on Debian using nftables NAT44 + rsyslog NAT
# allocation logging.
#
# Reference: <repo>/cgnat.md
# Asks at install time:
#   PUBLIC pool   - the public IPv4 addresses to NAT into (CIDR, IP range, or
#                   single IP). A CIDR is expanded to the FULL subnet
#                   (network through broadcast, no reservations) by operator
#                   request (e.g. 103.69.44.0/25 -> 103.69.44.0-103.69.44.127).
#   PRIVATE pool  - the subscribers' source subnet (e.g. 100.64.0.0/10).
#   NATLOG server - remote syslog receiver for NAT events (ip[:port], UDP).
#
# What it does (per cgnat.md, with the logging stack adapted):
#   1. Installs nftables ulogd2 rsyslog iproute2 procps.
#   2. Applies high-concurrency netfilter sysctls (conntrack, buffers, JIT).
#   3. Installs cgnat-qos.service applying fq_codel qdisc on every non-lo
#      interface (bufferbloat / low-latency).
#   4. Binds the public subnet address to the WAN interface (default route).
#   5. Programs an nftables CGNAT ruleset: full-cone persistent SNAT of the
#      private range to the public pool plus a hairpinning rule so subscribers
#      can reach the public pool internally. Each new NAT mapping is streamed
#      to ulogd2 via nftables "log group 1" (nfnetlink, async, no kernel
#      printk) with the "CGNAT_ALLOC: " prefix.
#   6. Runs ulogd2 (NFLOG -> BASE -> IFINDEX -> IP2STR -> PRINTPKT -> SYSLOG)
#      emitting each allocation on facility local6, and configures rsyslog to
#      stream those local6 lines to the NATLOG server over UDP (omfwd),
#      suppressing local disk writes for them.
#
#   Note: cgnat.md's ulogd2 NFCT->SYSLOG stack cannot run on ulogd2 2.0.x (the
#   SYSLOG/PRINTPKT output plugins require oob.* keys that only the NFLOG
#   packet input provides). ulogd2 is therefore wired as an NFLOG consumer
#   (packet-based, group 1) instead of an NFCT consumer - the nftables "log
#   group 1" statement hands each new-mapping packet to userspace asynchronously
#   via nfnetlink, which avoids the per-packet kernel printk cost of plain
#   "log level info" under high subscriber throughput.

set -euo pipefail

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

# apt wrapper: wait out competing apt/dpkg/unattended-upgrades and give apt a
# long lock timeout, so a concurrent package manager cannot hard-fail install.
apty() {
    for _i in $(seq 1 30); do
        pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 \
            || pgrep -x unattended-upgrade >/dev/null 2>&1 || break
        sleep 5
    done
    apt-get -o DPkg::Lock::Timeout=300 "$@"
}

export DEBIAN_FRONTEND=noninteractive

IPRE='[0-9]{1,3}(\.[0-9]{1,3}){3}'
POOLRE="^${IPRE}(/[0-9]{1,2}|-${IPRE})?$"

say ""
say "==> ISP CGNAT (nftables) installation"
say ""
say "The installer needs three values:"
say "  PUBLIC   - the public IPv4 pool to NAT into (CIDR, range, or single IP)"
say "  PRIVATE  - the subscribers' source subnet (e.g. 100.64.0.0/10)"
say "  NATLOG   - remote syslog receiver for NAT events (ip[:port], UDP)"
say ""

PUBLIC_POOL="${PUBLIC_POOL:-}"
while ! printf '%s\n' "$PUBLIC_POOL" | grep -Eq "$POOLRE"; do
    [ -n "$PUBLIC_POOL" ] && say "Invalid public pool '$PUBLIC_POOL' - use CIDR, IP range, or single IP."
    printf 'Public IPv4 pool (CIDR 103.69.44.0/25 | range 103.69.44.0-103.69.44.127 | single 103.69.44.20): '
    read -r PUBLIC_POOL || { say "No pool supplied - aborting." >&2; exit 1; }
    [ -z "$PUBLIC_POOL" ] && continue
done

PRIVATE_POOL="${PRIVATE_POOL:-}"
while ! printf '%s\n' "$PRIVATE_POOL" | grep -Eq "$POOLRE"; do
    [ -n "$PRIVATE_POOL" ] && say "Invalid private pool '$PRIVATE_POOL' - use CIDR, IP range, or single IP."
    printf 'Private IPv4 pool (subscribers, e.g. 100.64.0.0/10): '
    read -r PRIVATE_POOL || { say "No pool supplied - aborting." >&2; exit 1; }
    [ -z "$PRIVATE_POOL" ] && continue
done

NATLOG="${NATLOG_SERVER:-}"
while ! printf '%s\n' "$NATLOG" | grep -Eq "^${IPRE}(:[0-9]{1,5})?$"; do
    [ -n "$NATLOG" ] && say "Invalid NATLOG server '$NATLOG' - use IP or IP:PORT."
    printf 'NATLOG server (e.g. 192.168.99.10 or 192.168.99.10:1816): '
    read -r NATLOG || { say "No NATLOG server supplied - aborting." >&2; exit 1; }
    [ -z "$NATLOG" ] && continue
done

say ""
say "  public pool : $PUBLIC_POOL"
say "  private pool: $PRIVATE_POOL"
say "  NATLOG      : $NATLOG"
say ""

if [[ "$NATLOG" == *:* ]]; then
    NATLOG_IP="${NATLOG%:*}"
    NATLOG_PORT="${NATLOG#*:}"
else
    NATLOG_IP="$NATLOG"
    NATLOG_PORT="1816"
fi

ip2int() {
    _sip_ifs=$IFS; IFS=.; set -- $1; IFS=$_sip_ifs
    printf '%d\n' $(( ($1<<24) + ($2<<16) + ($3<<8) + $4 ))
}
int2ip() {
    local v=$1
    printf '%d.%d.%d.%d\n' $(( (v>>24)&255 )) $(( (v>>16)&255 )) $(( (v>>8)&255 )) $(( v&255 ))
}
# CIDR -> NAT range "a.b.c.d-e.f.g.h" using the ENTIRE allocated subnet
# (network address through broadcast), operator override — no reservations:
# 103.69.44.0/25 -> .0-.127, /26 -> .0-.63, /32 -> single address.
nat_range() {
    local cidr=$1 prefix net mask netint brdint lo hi
    net="$(ip2int "${cidr%%/*}")"
    prefix="${cidr##*/}"
    mask=$(( ( (1<<prefix) - 1 ) << (32-prefix) ))
    netint=$(( net & mask ))
    brdint=$(( netint | ( ~mask & 0xFFFFFFFF ) ))
    lo=$netint; hi=$brdint
    printf '%s-%s\n' "$(int2ip "$lo")" "$(int2ip "$hi")"
}
# Smallest CIDR block covering [lo,hi] (ints).
cover_cidr() {
    local lo=$1 hi=$2 l size net brd
    for l in $(seq 32 -1 0); do
        size=$(( 1 << (32-l) ))
        net=$(( (lo >> (32-l)) << (32-l) ))
        brd=$(( net + size - 1 ))
        if [ "$net" -le "$lo" ] && [ "$brd" -ge "$hi" ]; then
            printf '%s/%d\n' "$(int2ip "$net")" "$l"
            return 0
        fi
    done
    return 1
}

case "$PUBLIC_POOL" in
    */*) PUB_RANGE="$(nat_range "$PUBLIC_POOL")"; PUB_SUBNET="$PUBLIC_POOL" ;;
    *-*) RLO="$(ip2int "${PUBLIC_POOL%%-*}")"; RHI="$(ip2int "${PUBLIC_POOL##*-}")"
         PUB_RANGE="$PUBLIC_POOL"
         PUB_SUBNET="$(cover_cidr "$RLO" "$RHI")" ;;
    *)   PUB_RANGE="$PUBLIC_POOL"; PUB_SUBNET="$PUBLIC_POOL/32" ;;
esac
say "  NAT range  : $PUB_RANGE"
say "  NAT subnet : $PUB_SUBNET"

WAN_IF="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
[ -n "$WAN_IF" ] || WAN_IF="eth0"
IFACES="$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' || true)"
[ -n "$IFACES" ] || IFACES="$WAN_IF"
say "  WAN iface  : $WAN_IF (qdisc applies to: $IFACES)"
say ""

say "==> Installing packages (nftables, ulogd2, rsyslog, iproute2, procps) ..."
apty update || die "apt-get update failed (configure online apt sources first)"
apty -y install nftables ulogd2 rsyslog iproute2 procps \
    || die "could not install CGNAT packages"

say "==> Applying netfilter/socket sysctls (/etc/sysctl.d/99-isp-cgnat.conf) ..."
tee /etc/sysctl.d/99-isp-cgnat.conf > /dev/null <<'EOF'
# Enable IPv4 Packet Forwarding
net.ipv4.ip_forward=1
net.ipv4.ip_local_port_range=1024 65535

# High Throughput and Socket Memory Tuning
net.core.netdev_max_backlog=250000
net.core.somaxconn=65535
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.bpf_jit_enable=1

# Conntrack High-Concurrency & Fast UDP/TCP Teardown Tuning
net.netfilter.nf_conntrack_max=2097152
net.netfilter.nf_conntrack_udp_timeout=10
net.netfilter.nf_conntrack_udp_timeout_stream=120
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait=10
net.netfilter.nf_conntrack_tcp_timeout_close_wait=10
EOF
sysctl --system > /dev/null

say "==> Installing fq_codel QoS service (cgnat-qos.service) ..."
{
    echo "[Unit]"
    echo "Description=Bufferbloat Elimination via FQ-CoDel"
    echo "After=network.target"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    for iface in $IFACES; do
        echo "ExecStart=-/sbin/tc qdisc replace dev $iface root fq_codel quantum 300 limit 10240 target 5ms interval 100ms"
    done
    echo "RemainAfterExit=yes"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
} > /etc/systemd/system/cgnat-qos.service
systemctl daemon-reload
systemctl enable --now cgnat-qos.service || true

say "==> Binding public subnet $PUB_SUBNET to $WAN_IF ..."
ip addr add "$PUB_SUBNET" dev "$WAN_IF" 2>/dev/null || true

say "==> Writing /etc/nftables.conf (CGNAT ruleset) ..."
tee /etc/nftables.conf > /dev/null <<EOF
#!/usr/sbin/nft -f

flush ruleset

define CGNAT_PUB_SUBNET = $PUB_SUBNET
define CGNAT_PUB_RANGE = $PUB_RANGE
define CGNAT_PRIV_SUBNET = $PRIVATE_POOL

table ip cgnat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # Hairpinning: private clients reach the public pool internally
        ip saddr \$CGNAT_PRIV_SUBNET ip daddr \$CGNAT_PUB_SUBNET masquerade

        # Stream every new NAT mapping to ulogd2 via nfnetlink (group 1) for
        # async userspace reporting; only outbound (non-hairpin) allocations.
        ip saddr \$CGNAT_PRIV_SUBNET ip daddr != \$CGNAT_PUB_SUBNET oifname "$WAN_IF" ct state new log group 1 prefix "CGNAT_ALLOC: "

        # Full-cone NAT mapping (outbound only; hairpin above is a separate path)
        ip saddr \$CGNAT_PRIV_SUBNET ip daddr != \$CGNAT_PUB_SUBNET oifname "$WAN_IF" snat to \$CGNAT_PUB_RANGE persistent,fully-random
    }
}
EOF
nft -f /etc/nftables.conf || die "nft rejected /etc/nftables.conf (run nft -c -f /etc/nftables.conf to debug)"
systemctl enable --now nftables

say "==> Configuring ulogd2 (NFLOG -> SYSLOG) ..."
# ulogd2's unit has no RuntimeDirectory; make the runtime dir + pidfile dir
# survive reboots via tmpfiles.d, and create it now.
printf 'd /run/ulog 0755 ulog ulog -\n' > /etc/tmpfiles.d/ulogd.conf
systemd-tmpfiles --create /etc/tmpfiles.d/ulogd.conf > /dev/null 2>&1 || install -d -o ulog -g ulog /run/ulog
install -d -o ulog -g ulog /run/ulog

tee /etc/ulogd.conf > /dev/null <<'EOF'
# ulogd2: consume nftables "log group 1" (nfnetlink), format and emit each
# packet on facility local6 for rsyslog -> NATLOG server forwarding.
[global]
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_inppkt_NFLOG.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_raw2packet_BASE.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_filter_IFINDEX.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_filter_IP2STR.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_filter_PRINTPKT.so"
plugin="/usr/lib/x86_64-linux-gnu/ulogd/ulogd_output_SYSLOG.so"
stack=log1:NFLOG,base1:BASE,ifi1:IFINDEX,ip2str1:IP2STR,print1:PRINTPKT,sys1:SYSLOG
[log1]
group=1
[sys1]
facility=LOG_LOCAL6
level=LOG_INFO
prefix="CGNAT_ALLOC: "
EOF
systemctl enable --now ulogd2 > /dev/null 2>&1 || systemctl restart ulogd2
systemctl is-active --quiet ulogd2 || die "ulogd2 failed to start (check journalctl -u ulogd2, /etc/ulogd.conf)"

say "==> Configuring rsyslog to stream CGNAT events to $NATLOG_IP:$NATLOG_PORT ..."
tee /etc/rsyslog.d/40-cgnat-remote.conf > /dev/null <<EOF
# Stream CGNAT allocation logs (ulogd2 emits each new mapping on facility
# local6 as a "CGNAT_ALLOC" message, prefix configured in /etc/ulogd.conf) to
# the NATLOG server over UDP, suppressing local disk writes for these lines.
:msg, contains, "CGNAT_ALLOC" action(type="omfwd"
    target="$NATLOG_IP"
    port="$NATLOG_PORT"
    protocol="udp"
    template="RSYSLOG_TraditionalFileFormat"
    queue.type="LinkedList"
    queue.size="200000"
    queue.dequeuebatchsize="1000"
    action.resumeRetryCount="-1"
)
& stop
EOF

say "==> Restarting rsyslog ..."
systemctl restart rsyslog
systemctl enable rsyslog

say ""
say "CGNAT deployment complete."
say "  Ruleset:   sudo nft list ruleset"
say "  Services:  systemctl status nftables ulogd2 rsyslog cgnat-qos"
say "  NATLOG:    CGNAT events stream to    $NATLOG_IP:$NATLOG_PORT (UDP)"
say "  Test:      sudo tcpdump -n -i any host $NATLOG_IP and port $NATLOG_PORT"
say ""
exit 0