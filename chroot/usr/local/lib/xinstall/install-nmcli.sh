#!/bin/sh
# install-nmcli - ensure NetworkManager is installed and running, then open
# the interactive text UI (nmtui) so the user can manage devices and WLANs.
#
# Behaviour:
#   * if nmcli/nmtui are missing they are installed (apt; offline-safe no-op)
#   * NetworkManager service is enabled at boot and started now
#   * "is it working?" is checked with `systemctl is-active NetworkManager`
#     (and nmcli device status), then:
#       - interactive terminal  -> launch nmtui (quit with Quit)
#       - headless / CI         -> print device status + the useful nmcli commands
#
# Everything is POSIX sh (dash), no bash-only features.

set -eu

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1

say() { printf '%s\n' "$*"; }

# wait out competing apt/dpkg and give apt a long lock timeout so a concurrent
# package manager cannot hard-fail this install.
apty() {
    for _i in $(seq 1 30); do
        pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 \
            || pgrep -x unattended-upgrade >/dev/null 2>&1 || break
        sleep 5
    done
    apt-get -o DPkg::Lock::Timeout=300 "$@"
}

say "==> NetworkManager (nmcli)"
say ""

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

    # --- is it actually working? -------------------------------------------------
    if systemctl is-active --quiet NetworkManager; then
        say "    NetworkManager service: ACTIVE (working)"
    else
        say "    WARNING: NetworkManager did not come up; trying to start it:"
        systemctl restart NetworkManager >/dev/null 2>&1 || true
        sleep 1
        if systemctl is-active --quiet NetworkManager; then
            say "    NetworkManager service: ACTIVE (working)"
        else
            say "    STILL not active - check 'journalctl -u NetworkManager'"
        fi
    fi

    say ""
    say "    current devices:"
    say ""
    nmcli device status
    say ""

    # --- interactive TUI when a console is attached ------------------------------
    if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${XIH_HEADLESS:-}" ]; then
        if command -v nmtui >/dev/null 2>&1; then
            say "    opening the NetworkManager text user interface (nmtui)..."
            say "    (edit connections, activate links, set hostname; quit with Quit)"
            say ""
            nmtui
            say ""
            say "    done. verify current state again:"
            say ""
            nmcli device status
        else
            say "    nmtui is not installed on this system; starting it via:"
            say "    apty install -y nmtui 2>/dev/null"
            if apty install -y --no-install-recommends nmtui 2>/dev/null; then
                say "    nmtui installed; opening it now..."
                say ""
                nmtui
            else
                say "    could not install nmtui (offline). Printing device status"
                say "    and the most useful nmcli commands instead:"
                say ""
                nmcli device status
                say ""
                say "    useful commands:"
                say "      nmcli device                                  - list devices"
                say "      nmcli device wifi list                        - scan APs"
                say "      nmcli device wifi connect SSID password PASS  - join a WLAN"
                say "      nmcli device wifi connect SSID                - join an open WLAN"
                say "      nmcli connection up 'Wired connection 1'      - bring a profile up"
                say "      nmcli -g IP4.ADDRESS connection show <name>   - show IP of a profile"
                say "      nmcli networking off/on                       - hard-disable/enable"
            fi
        fi
    else
        say "    (headless: not launching the interactive TUI)"
        say ""
        say "    useful commands:"
        say "      nmcli device                                  - list devices"
        say "      nmcli device wifi list                        - scan APs"
        say "      nmcli device wifi connect SSID password PASS  - join a WLAN"
        say "      nmcli connection up 'Wired connection 1'      - bring a profile up"
        say "      nmcli -g IP4.ADDRESS connection show <name>   - show IP of a profile"
        say "      nmcli networking off/on                       - hard-disable/enable"
    fi
else
    say "    nmcli is not available on this system."
fi
say ""
exit 0
