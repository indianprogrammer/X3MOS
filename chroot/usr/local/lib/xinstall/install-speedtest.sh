#!/bin/bash
# Install an Ookla Speedtest Server daemon from the official installer, then
# register a systemd unit so it auto-starts at boot.
#
# References:
#   https://srijit.com/ookla-speedtest-server-installation-guide/
#   https://support.ookla.com/hc/en-us/articles/234578528-OoklaServer-Installation-Linux-Unix
#
# The install dir is /opt/ooklaserver; the daemon listens on TCP 8080.

set -euo pipefail

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

DEST=/opt/ooklaserver
URL=https://install.speedtest.net/ooklaserver/ooklaserver.sh

require wget 'apt-get install wget'

say ""
say "==> Ookla Speedtest Server installation"
say ""
say "Before starting: Ookla review requires a public IPv4+IPv6 address, a"
say "DNS name (A + AAAA record) and plenty of spare bandwidth (~500 Mbps+)."
say "Local/functional testing works without all of that."
say ""

online install.speedtest.net || die "no network to install.speedtest.net - check the connection"

mkdir -p "$DEST"
cd "$DEST"

if [ ! -x "$DEST/OoklaServer" ]; then
    say "==> Downloading the official install script ..."
    wget -q "$URL" -O ooklaserver.sh || die "download of ooklaserver.sh failed"
    chmod a+x ooklaserver.sh

    say "==> Running ./ooklaserver.sh install (accept the prompts) ..."
    if [ -t 0 ]; then
        ./ooklaserver.sh install
    else
        echo y | ./ooklaserver.sh install
    fi
    [ -x "$DEST/OoklaServer" ] || die "OoklaServer daemon was not installed"

    # Stop the instance the installer may have auto-started; systemd will own it.
    ./ooklaserver.sh stop >/dev/null 2>&1 || true

    # Recommended configuration (the guide's Section C values).
    PROPS="$DEST/OoklaServer.properties"
    [ -f "$PROPS" ] || touch "$PROPS"
    printf '%s\n' \
        'OoklaServer.useIPv6 = true' \
        'OoklaServer.allowedDomains = *.ookla.com, *.speedtest.net' \
        'OoklaServer.enableAutoUpdate = true' \
        'OoklaServer.ssl.useLetsEncrypt = true' \
        >> "$PROPS"
fi

say "==> Registering the systemd service (auto-start at boot) ..."
cat > /etc/systemd/system/ooklaserver.service <<UNIT
[Unit]
Description=Ookla Speedtest Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=$DEST
ExecStart=$DEST/ooklaserver.sh start
ExecStop=$DEST/ooklaserver.sh stop
KillMode=process
TimeoutStartSec=30
TimeoutStopSec=60
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable ooklaserver.service >/dev/null 2>&1

say "==> Starting the speedtest server ..."
systemctl restart ooklaserver.service
sleep 1

if systemctl is-active --quiet ooklaserver.service; then
    say "    service 'ooklaserver' is running."
else
    say "    WARN: service did not start; check 'systemctl status ooklaserver'."
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say ""
say "Ookla Speedtest Server installed in $DEST."
say "  Open:  http://${IP:-<this-host-ip>}:8080"
say "  Test:  https://www.speedtest.net/host-tester   (enter <ip>:8080)"
say ""
say "Manage it with:"
say "   systemctl status ooklaserver"
say "   systemctl restart ooklaserver"
say "   $DEST/ooklaserver.sh start|stop|restart"
say ""
say "Next steps for an official Ookla listing (see the guide's Section D):"
say "   1. Point a DNS name at this host (A and AAAA)."
say "   2. Verify geolocation in MaxMind for the IP."
say "   3. Submit the server at https://account.ookla.com/servers - HTTPS is"
say "      then enabled automatically via Let's Encrypt after review."
exit 0