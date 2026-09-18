#!/bin/bash
# Install and configure Carrier-Grade NAT (CGNAT) on Debian using Jool.
#
# Reference: <repo>/cgnat.sh
#   - Private (RFC 6598 /100.64.0.0/10) pool is fixed.
#   - Source port range defaults to 1024-65535.
#   - The public IP pool is asked interactively at install time (single IP
#     or a range, e.g. 103.69.44.1-103.69.44.30).

set -euo pipefail

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

PRIVATE_POOL="100.64.0.0/10"
PORTS="1024-65535"
INSTANCE="cgnat1"

say ""
say "==> Carrier-Grade NAT (Jool) installation"
say ""
say "Private pool will be $PRIVATE_POOL and the source port range $PORTS."
say ""

# Ask for the public IP pool (single IP or aaa.bbb.ccc.ddd-eee.fff.ggg.hhh).
IPRE='[0-9]{1,3}(\.[0-9]{1,3}){3}'
while :; do
    printf 'Enter the public IP pool (single IP or range, e.g. 103.69.44.1-103.69.44.30): '
    read -r PUBLIC_POOL
    [ -z "$PUBLIC_POOL" ] && continue
    if printf '%s\n' "$PUBLIC_POOL" | grep -Eq "^${IPRE}(-${IPRE})?\$"; then
        break
    fi
    say "Invalid pool '$PUBLIC_POOL' - use 1.2.3.4 or 1.2.3.4-1.2.3.10."
done

say ""
say "==> Installing jool-dkms and jool-tools ..."
apt-get update || die "apt-get update failed (check apt sources)"
apt-get -y install jool-dkms jool-tools || die "could not install jool packages"

say "==> Enabling IPv4 forwarding ..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

say "==> Writing /etc/jool/jool.conf ..."
mkdir -p /etc/jool
cat > /etc/jool/jool.conf <<EOF
{
    "comment": "CGNAT Deployment",
    "instance": "$INSTANCE",
    "framework": "netfilter",
    "global": {
        "pool6": "$PRIVATE_POOL"
    }
}
EOF

say "==> Writing /usr/local/bin/init-cgnat.sh ..."
cat > /usr/local/bin/init-cgnat.sh <<EOF
#!/bin/bash
# Clear any existing instance to avoid conflicts
jool instance remove $INSTANCE 2>/dev/null

# Add the stateful NAT44 instance (netfilter framework)
jool instance add $INSTANCE --type NAT44 --framework netfilter

# Add the public IP pool + default source port range
jool pool4 add $INSTANCE $PUBLIC_POOL --port $PORTS
EOF
chmod +x /usr/local/bin/init-cgnat.sh

say "==> Registering and starting the cgnat systemd service ..."
cat > /etc/systemd/system/cgnat.service <<UNIT
[Unit]
Description=Carrier-Grade NAT via Jool
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/init-cgnat.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable cgnat.service >/dev/null 2>&1
systemctl restart cgnat.service

if systemctl is-active --quiet cgnat.service; then
    say "    service 'cgnat' is active."
else
    say "    WARN: service did not start; check 'systemctl status cgnat'."
fi

say ""
say "CGNAT setup complete."
say "  Service:   systemctl status cgnat"
say "  Instance:  jool instance display $INSTANCE"
say "  Pools:     jool pool4 display $INSTANCE"
say "  Sessions:  jool session display"
say ""
say "Public pool:   $PUBLIC_POOL"
say "Source ports:  $PORTS"
say "Private pool:  $PRIVATE_POOL"
say ""
say "Make sure $PUBLIC_POOL is routed to this host and that the interfaces"
say "behind NAT use RFC 6598 addressing (100.64.0.0/10)."
exit 0