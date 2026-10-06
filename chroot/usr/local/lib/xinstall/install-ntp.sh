#!/bin/sh
# install-ntp - install NTP Server (ntpsec) on X3M-OS.
#
#   xinstall -> [9] Install NTP Server
#
# Installs the ntpsec package from the live Debian sources (it is
# intentionally NOT part of the ISO pool / preseed - NTP is installed
# only when this option runs), then enables and starts the service.
#
# Everything is POSIX sh (dash), no bash-only features.

set -eu

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root

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

say "==> Installing NTP Server (ntpsec)..."
apt-get update || die "apt-get update failed (check apt sources)"
apty install -y ntpsec || die "apt-get install ntpsec failed"

say "==> Enabling and starting ntpsec.service..."
enable_at_boot ntpsec
sleep 1
if systemctl is-active --quiet ntpsec; then
    say "    ntpsec.service is active."
    if command -v ntpq >/dev/null 2>&1; then
        say ""
        say "    peers:"
        ntpq -p || true
    fi
else
    say "    WARNING: ntpsec.service is not active - check 'systemctl status ntpsec'."
fi
say ""
exit 0
