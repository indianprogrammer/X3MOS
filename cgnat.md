#!/usr/bin/env bash
# ==============================================================================
# Production ISP CGNAT Deployment Script for Debian (corrected/validated)
# Configuration Summary:
#   - Public Pool:  103.69.44.0/25 (NAT Range: 103.69.44.0 - 103.69.44.127,
#                    full subnet, operator-forced)
#   - Private Subnet: 100.64.0.0/10
#   - Remote Syslog: 192.168.99.10:1812 (UDP)
#   - Features: Low-Latency fq_codel, Conntrack Tuning, ulogd2(NFLOG) + rsyslog
#
# Corrections vs the original reference (all validated on Debian trixie):
#   1. NAT rules live only in postrouting. The original prerouting
#      "ip daddr <pub> ct status dnat masquerade" hairpin rule is invalid:
#      nftables rejects masquerade outside postrouting
#      ("Could not process rule: Operation not supported"). Hairpinning is a
#      postrouting masquerade rule instead; return traffic is un-NAT'd by
#      conntrack automatically.
#   2. The log and SNAT rules are separate and guarded with
#      "ip daddr != <pub subnet>" so hairpin egress is handled exclusively by
#      the masquerade rule (deterministic rule order, no double NAT). The log
#      also uses "log group 1" (nfnetlink -> ulogd2, async, no per-packet
#      kernel printk) instead of "log level info" kernel-text logging.
#   3. ulogd2 is an NFLOG (packet) consumer, not an NFCT (flow) consumer. On
#      ulogd2 2.0.x the NFCT->SYSLOG stack cannot build (SYSLOG/PRINTPKT need
#      oob.* keys only the packet input provides). The working stack is
#      NFLOG -> BASE -> IFINDEX -> IP2STR -> PRINTPKT -> SYSLOG; note the
#      plugin filename is ulogd_inppkt_NFLOG.so and it registers as "NFLOG".
#   4. ulogd2's systemd unit lacks RuntimeDirectory: /run/ulog is pre-created
#      and kept via /etc/tmpfiles.d/ulogd.conf.
#   5. NAT CIDR expansion uses the ENTIRE allocated subnet (network through
#      broadcast, no reservations), per operator requirement.
# ==============================================================================

set -euo pipefail

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Error: Please run this script as root or with sudo."
  exit 1
fi

PUBLIC_POOL="${PUBLIC_POOL:-103.69.44.0/25}"
PUB_RANGE="${PUB_RANGE:-103.69.44.0-103.69.44.127}"
PRIV_SUBNET="${PRIV_SUBNET:-100.64.0.0/10}"
NATLOG_IP="${NATLOG_IP:-192.168.99.10}"
NATLOG_PORT="${NATLOG_PORT:-1812}"

echo "[+] Starting ISP CGNAT Installation and Optimization..."

# 0. ulogd2 runtime directory (unit has no RuntimeDirectory)
echo "[+] Ensuring /run/ulog exists for ulogd2..."
printf 'd /run/ulog 0755 ulog ulog -\n' > /etc/tmpfiles.d/ulogd.conf
systemd-tmpfiles --create /etc/tmpfiles.d/ulogd.conf > /dev/null 2>&1 || install -d -o ulog -g ulog /run/ulog
install -d -o ulog -g ulog /run/ulog

# 1. Update Repositories and Install Dependencies
echo "[+] Installing required packages..."
apt-get update -qq
apt-get install -y -qq nftables ulogd2 rsyslog iproute2 procps

# 2. Kernel and System Tuning (Sysctl)
echo "[+] Applying high-concurrency netfilter sysctl optimizations..."
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

# 3. Configure fq_codel Service for Low Latency / Zero Bufferbloat
echo "[+] Configuring fq_codel Traffic Control systemd service..."
WAN_IF="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
IFACES="$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' || true)"
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
systemctl enable --now cgnat-qos.service

# 4. Bind Public IPv4 Subnet to WAN Interface
echo "[+] Binding public subnet $PUBLIC_POOL to $WAN_IF..."
ip addr add "$PUBLIC_POOL" dev "$WAN_IF" 2>/dev/null || true

# 5. Configure nftables CGNAT Ruleset
echo "[+] Creating nftables CGNAT ruleset..."
tee /etc/nftables.conf > /dev/null <<EOF
#!/usr/sbin/nft -f

flush ruleset

define CGNAT_PUB_SUBNET = $PUBLIC_POOL
define CGNAT_PUB_RANGE = $PUB_RANGE
define CGNAT_PRIV_SUBNET = $PRIV_SUBNET

table ip cgnat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # Hairpinning: private clients reach the public pool internally
        ip saddr \$CGNAT_PRIV_SUBNET ip daddr \$CGNAT_PUB_SUBNET masquerade

        # Stream every new NAT mapping to ulogd2 via nfnetlink (group 1);
        # outbound (non-hairpin) allocations only.
        ip saddr \$CGNAT_PRIV_SUBNET ip daddr != \$CGNAT_PUB_SUBNET oifname "$WAN_IF" ct state new log group 1 prefix "CGNAT_ALLOC: "

        # Full-cone NAT mapping (outbound only; hairpin above is separate)
        ip saddr \$CGNAT_PRIV_SUBNET ip daddr != \$CGNAT_PUB_SUBNET oifname "$WAN_IF" snat to \$CGNAT_PUB_RANGE persistent,fully-random
    }
}
EOF

nft -f /etc/nftables.conf
systemctl enable --now nftables

# 6. Configure ulogd2 Daemon (NFLOG packet input -> SYSLOG)
echo "[+] Configuring ulogd2 netfilter event logging..."
tee /etc/ulogd.conf > /dev/null <<'EOF'
# ulogd2: consume nftables "log group 1" (nfnetlink), format and emit each
# packet on facility local6 for rsyslog -> NATLOG server forwarding.
# NOTE: NFCT flow input cannot feed SYSLOG/PRINTPKT on ulogd2 2.0.x; the
# packet-based NFLOG input is required.
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
systemctl is-active --quiet ulogd2 || {
  echo "[-] ulogd2 failed to start (check journalctl -u ulogd2, /etc/ulogd.conf)" >&2
  exit 1
}

# 7. Configure rsyslog Remote Dispatch
echo "[+] Configuring rsyslog to stream events to $NATLOG_IP:$NATLOG_PORT..."
tee /etc/rsyslog.d/40-cgnat-remote.conf > /dev/null <<EOF
# Stream CGNAT allocation logs (ulogd2 emits each new mapping on facility
# local6 as a "CGNAT_ALLOC" message) to the NATLOG server over UDP,
# suppressing local disk writes for these lines.
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

# 8. Restart Logging Daemons
echo "[+] Restarting rsyslog services..."
systemctl restart rsyslog
systemctl enable rsyslog

echo "=============================================================================="
echo "[SUCCESS] CGNAT deployment complete!"
echo "  - Active Rules: Run 'sudo nft list ruleset' to inspect firewall state."
echo "  - Remote Log Stream: Run 'sudo tcpdump -n -i any host $NATLOG_IP and port $NATLOG_PORT' to test."
echo "=============================================================================="