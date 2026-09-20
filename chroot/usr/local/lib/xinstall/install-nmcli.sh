#!/bin/bash
# install-nmcli - ensure NetworkManager is present and enabled, then show
# device status and the most useful nmcli commands.
#
# network-manager is preinstalled on fresh X3M-OS installs (preseed). This
# option installs it when missing (offline pool may lack it on older ISOs),
# enables the service and prints current device state + a usage hint.

set -euo pipefail

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root

say() { printf '%s\n' "$*"; }

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

say "==> NetworkManager (nmcli)..."
if ! command -v nmcli >/dev/null 2>&1; then
    say "    network-manager not found - attempting install..."
    if apty install -y --no-install-recommends network-manager 2>/dev/null; then
        say "    installed."
    else
        say "    WARNING: could not install network-manager (apt offline / not in pool)."
    fi
fi

if command -v nmcli >/dev/null 2>&1; then
    systemctl enable --now NetworkManager >/dev/null 2>&1 \
        || systemctl restart NetworkManager >/dev/null 2>&1 || true
    sleep 1
    say "    active devices:"
    say ""
    nmcli device status
    say ""
    say "    useful commands:"
    say "      nmcli device                                    - list devices/state"
    say "      nmcli device wifi list                          - scan APs"
    say "      nmcli device wifi connect SSID password PASS    - join a WLAN"
    say "      nmcli connection up 'Wired connection 1'        - bring a profile up"
    say "      nmcli -t -f IP4.ADDRESS connection show <name>  - show IP of a profile"
    say "      nmcli networking off/on                         - hard-disable/enable"
else
    say "    nmcli is not available on this system."
fi
say ""
exit 0