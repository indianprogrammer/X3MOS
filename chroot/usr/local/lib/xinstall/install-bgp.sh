#!/bin/bash
# install-bgp - install FRRouting (bgpd + zebra) and hand off to vtysh.
#
# Installs frr (NOT frr-pythontools: it would pull the whole python3 runtime
# onto the box for vtysh tab-completion only), enables the zebra and bgpd
# daemons in /etc/frr/daemons, starts frr.service and drops into vtysh (the
# FRR CLI) so BGP neighbors/prefixes can be configured interactively.
# The package comes from the live Debian sources (it is intentionally NOT part
# of the ISO pool / preseed - BGP is installed only when this option runs).

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

say "==> Installing FRRouting (frr)..."
apt-get update || die "apt-get update failed (check apt sources)"
apty install -y frr || die "apt-get install frr failed"

DAEMONS=/etc/frr/daemons
if [ -f "$DAEMONS" ]; then
    sed -i 's/^bgpd=no$/bgpd=yes/; s/^zebra=no$/zebra=yes/' "$DAEMONS"
fi

if [ ! -s /etc/frr/frr.conf ]; then
    cat > /etc/frr/frr.conf <<'EOF'
frr defaults traditional
!
hostname $(hostname)
!
log file /var/log/frr/frr.log
!
EOF
fi

say "==> Enabling and starting frr.service (zebra + bgpd)..."
systemctl enable --now frr >/dev/null 2>&1 || true
systemctl restart frr >/dev/null 2>&1 || true
sleep 2
if systemctl is-active --quiet frr; then
    say "    frr.service is active."
else
    say "    WARNING: frr.service is not active - check 'systemctl status frr'."
fi

if command -v vtysh >/dev/null 2>&1; then
    say "    opening vtysh (FRR CLI) - configure BGP e.g.:"
    say "      configure terminal"
    say "      router bgp 65001"
    say "      neighbor 192.0.2.1 remote-as 65002"
    say "      address-family ipv4 unicast"
    say "      network 103.69.44.0/25"
    say ""
    if [ -t 0 ]; then
        vtysh || true
    else
        say "    (no interactive terminal - run 'sudo vtysh' manually)"
    fi
else
    say "    vtysh not found."
fi
say ""
exit 0