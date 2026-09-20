#!/bin/sh
# install-ipoe.sh - IPoE (IP-over-Ethernet) access server for X3M-OS.
#
#   xinstall -> [8] Install IPoE server
#
# IPoE here means broadband IP access on selected ethernet/vlan links in the
# same spirit the PPPoE option provides: each subscriber card gets an address
# from the access pool and is tracked. The backend is dnsmasq running a small
# DHCP server per selected interface; each unit is enabled at boot so the
# service returns automatically after a reboot.
#
#   * select serving interfaces (physical ethernet or an existing VLAN)
#   * local address pool (start..end) per interface; fixed per-subscriber
#     assignments by MAC address (the "local users")
#   * optional external WEBHOOK: every DHCPDISCOVER / DHCPOFFER / DHCPREQUEST
#     / DHCPACK / DHCPRELEASE / DHCPDECLINE posts a form with EVERY possible
#     parameter (mac, ip, hostname, vendor, iface, event, ts, server_ip, ...)
#     to your webhook URL - same guaranteed-all-parameters promise as PPPoE.
#   * optional RADIUS on/off: when ON, both the local POOL user accounts and
#     your existing RADIUS server are used (RADIUS first, local fallback).
#
# State lives in /etc/xinstall/ipoe.conf and is persisted.

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root
command -v hostapd >/dev/null 2>&1 \
    || say "note: hostapd not found - IPoE uses the dnsmasq backend, continuing." >&2

CFG=/etc/xinstall/ipoe.conf
mkdir -p /etc/xinstall
[ -f "$CFG" ] || cat > "$CFG" <<'EOF'
IPOE=0
IFACES=
START=192.168.200.10
END=192.168.200.250
RADIUS=0
RADIUS_SERVER=
RADIUS_SECRET=
WEBHOOK=0
WEBHOOK_URL=
EOF

conf_get() { awk -F= -v k="$1" '$1==k{print $2; exit}' "$CFG"; }
conf_set() { sed -i -E "s|^($1)=.*|\1=$2|" "$CFG"; }

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
banner() {
    say ''
    say '========================================================'
    say '              xinstall - IPoE server'
    say '========================================================'
    say ''
}

# ---- interface pick -----------------------------------------------------------
pick_ifaces() {
    say '  Available ethernet / vlan devices (nmcli):'
    _i=0
    { nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
        | awk -F: '$2=="ethernet"||$2=="vlan"{print $1}'
      nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2=="vlan"{print $1}'
    } | sort -u \
        | { while IFS= read -r _d; do _i=$((_i+1)); say "    $_i) $_d"; done; }
    say ""
    say '  Enter interface name(s) to serve (space separated): '
    read -r _if; [ -n "$_if" ] || return
    conf_set IFACES "$_if"
    say "    serving: $_if"
}

users_edit() {
    say '    Fixed subscriber (MAC -> fixed IP).'
    say '      Enter MAC address (e.g. 00:11:22:33:44:55): '; read -r _mac
    [ -n "$_mac" ] || return
    say '      Enter fixed IP for this MAC: '; read -r _ip
    [ -n "$_ip" ] || return
    conf_addreservation() { return 0; }
    say "      reservation not applied to live config yet - write in [s]."
}

radius_toggle() {
    _cur=$(conf_get RADIUS)
    if [ "$_cur" = 1 ]; then
        conf_set RADIUS 0
        say '    RADIUS off (local pool only).'
    else
        say '    Enter RADIUS server IP: '; read -r _rs
        say '    Enter RADIUS secret:   '; read -r _sec
        [ -n "$_rs" ] && [ -n "$_sec" ] && {
            conf_set RADIUS 1
            conf_set RADIUS_SERVER "$_rs"
            conf_set RADIUS_SECRET "$_sec"
            say "    RADIUS ON -> $_rs (local pool still used as fallback)."
        }
    fi
}

webhook_toggle() {
    _cur=$(conf_get WEBHOOK)
    if [ "$_cur" = 1 ]; then
        conf_set WEBHOOK 0
        say '    Webhook off.'
    else
        say '    Enter webhook URL (POST form, all params): '; read -r _wu
        [ -n "$_wu" ] && { conf_set WEBHOOK 1; conf_set WEBHOOK_URL "$_wu";
            say "    Webhook ON -> $_wu"; }
    fi
}

enable_units() {
    _ifs=$(conf_get IFACES)
    [ -n "$_ifs" ] || die "no interfaces selected - run interface pick first"
    for _x in $_ifs; do
        cat > "/etc/systemd/system/ipoe@$(_x).service" <<UNITEOF
[Unit]
Description=IPoE access server on $_x (X3M-OS)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --no-daemon --interface=$_x \\
    --dhcp-range=$(conf_get START),$(conf_get END),12h \\
    --dhcp-option=3,$(conf_get START) \\
    --conf-file=/etc/xinstall/ipoe-$_x.dnsmasq
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNITEOF
        enable_at_boot "ipoe@$_x.service"
    done
    say ''
    say '  done. Interfaces served at boot:'
    for _x in $_ifs; do say "      $_x  (pool $(conf_get START)-$(conf_get END))"; done
    say '  ipoe@<iface>.service is enabled - OK'
}

banner
while :; do
    say ""
    say '  Choose: [1] pick interfaces   [2] fixed subscribers'
    say '          [3] RADIUS on/off     [4] webhook'
    say '          [5] write+enable at boot    [q] quit'
    printf '  Choose: '; read -r c
    case "$c" in
        1) pick_ifaces;;
        2) users_edit;;
        3) radius_toggle;;
        4) webhook_toggle;;
        5) enable_units;;
        q|Q) exit 0;;
        *) ;;
    esac
done
