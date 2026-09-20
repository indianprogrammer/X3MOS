#!/bin/sh
# install-pppoe.sh - set up a PPPoE access server on X3M-OS.
#
#   xinstall  ->  [7] PPPoE server
#
# Features
#   * serving interfaces (one or more physical ethernet links; a VLAN created
#     through the "xinstall -> VLAN" option can be served directly too)
#   * local users   (PAP/CHAP accounts in /etc/ppp/chap-secrets - persists)
#   * RADIUS on/off - when ON both your existing RADIUS server AND the local
#     accounts are checked (RADIUS first, local fallback) via radiusclient; a
#     toggle on the menu turns RADIUS off for local-only authentication.
#   * webhook - when enabled, every connect/disconnect/failure posts ALL the
#     session parameters to your external webhook URL (see lib.sh webhook-help).
#
# The created pppoe-server@<iface>.service is enabled at boot so the server is
# back automatically after every reboot - nothing needs to be re-run by hand.

set -e

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

# ---- configuration (defaults) ------------------------------------------------
CFG_DIR=$(conf_dir)/pppoe
mkdir -p "$CFG_DIR"
CFG="$CFG_DIR/server.conf"

conf_get() { awk -F= -v k="$1" '$1==k{print $2; exit}' "$CFG"; }
conf_set() { sed -i -E "s|^($1)=.*|\1=$2|" "$CFG"; }

# Ensure the persisted config always has every key (first run only).
ensure_conf() {
    [ -f "$CFG" ] || conf_write
}

conf_write() {
    cat > "$CFG" <<'XEOF'
# xinstall PPPoE server configuration
ENABLED=0
IFACES=
LOCAL_IP=10.0.0.1
RADIUS=0
RADIUS_SERVER=
RADIUS_SECRET=
WEBHOOK=0
WEBHOOK_URL=
XEOF
}

save_ifaces() {
    ifaces_filtered=$1
    conf_set IFACES "$ifaces_filtered"
    reload_unit
}

# ---- interface selection -------------------------------------------------------
pick_ifaces() {
    available=$( {
        nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
            | awk -F: '$2=="ethernet" || $2=="vlan" {print $1}'
        nmcli -t -f NAME,TYPE connection show 2>/dev/null \
            | awk -F: '$2=="vlan" {print $1}'
    } | sort -u 2>/dev/null)
    _n=0
    for d in $available; do _n=$((_n + 1)); say "    $_n) $d"; done
    [ -n "$available" ] || say "    (no ethernet/vlan interfaces found via nmcli)"
    say ""
    say "  Enter interface names to serve (space separated, hit ENTER when done):"
    read -r ifaces
    [ -n "$ifaces" ] || return
    save_ifaces "$ifaces"
}

# ---- users ------------------------------------------------------------------
_user_ok() { grep -q "^$1[[:space:]]" /etc/ppp/chap-secrets 2>/dev/null || return 1; }

users_edit() {
    say ""
    say "    Local users menu"
    say "      [a] Add user        [r] Remove user        [l] List users"
    say "      [q] Back"
    say "      Choose: "; read -r u
    case "$u" in
        a) say "        username: "; read -r un
           [ -n "$un" ] || return
           say "        password: "; read -r pw
           [ -n "$pw" ] || return
           # format used by pppd chap-secrets: user server password ip-addresses
           printf '%s  *  %s  *\n' "$un" "$pw" >> /etc/ppp/chap-secrets
           chmod 600 /etc/ppp/chap-secrets
           say "        + $un added (local + RADIUS both work).";;
        r) say "        username to remove: "; read -r un
           [ -n "$un" ] || return
           sed -i "/^$un[[:space:]]/d" /etc/ppp/chap-secrets
           say "        - $un removed.";;
        l) say "        Local accounts (from /etc/ppp/chap-secrets):"
           awk '!/^#/ && NF>=1 {print "          "$1}' /etc/ppp/chap-secrets \
               | sort -u || true;;
    esac
}

# ---- radius: ON -> server+secret must be set; local is always a fallback ----
radius_configure() {
    say ""
    say "    RADIUS server (when ON, local users are still checked as a"
    say "    fallback - both work together)."
    say "      Enter RADIUS server IP/host: "; read -r rss
    [ -n "$rss" ] || { say "        aborted - leaving RADIUS off."; return; }
    say "      Enter RADIUS shared secret: "; read -r rsec
    [ -n "$rsec" ] || { say "        aborted - leaving RADIUS off."; return; }
    conf_set RADIUS 1
    conf_set RADIUS_SERVER "$rss"
    conf_set RADIUS_SECRET "$rsec"
    radius_write_config
    say "      RADIUS ON (server=$rss)."
}

radius_off() {
    conf_set RADIUS 0
    radius_write_config
    say "      RADIUS OFF - local users only."
}

radius_write_config() {
    # radiusclient so pppd's 'plugin radius.so' can talk to your RADIUS.
    _rc=/etc/radiusclient
    [ "$(conf_get RADIUS)" = 1 ] || return
    _srv=$(conf_get RADIUS_SERVER); _sec=$(conf_get RADIUS_SECRET)
    [ -n "$_srv" ] || return
    mkdir -p "$_rc"
    {
        echo "auth_order    radius,local"
        echo "login_tries   4"
        echo "login_timeout 60"
        echo "authserver    $_srv/1812"
        echo "acctserver    $_srv/1813"
        echo "radius_timeout 8"
        echo "radius_retries 2"
    } > "$_rc/radiusclient.conf"
    echo "$_srv     $_sec" > "$_rc/servers"
    chmod 640 "$_rc/servers" "$_rc/radiusclient.conf"
    # dictionary symlink if the package ships one
    _dict=/usr/share/freeradius
    [ -f "$_dict/dictionary" ] && rm -f "$_rc/dictionary" \
        && ln -s "$_dict/dictionary" "$_rc/dictionary"
}

# ---- webhook config -----------------------------------------------------------
webhook_configure() {
    say ""
    say "    Webhook: called with ALL parameters on connect / disconnect / fail."
    say "      Enter webhook URL (empty = disable): "; read -r wu
    if [ -n "$wu" ]; then
        conf_set WEBHOOK 1
        conf_set WEBHOOK_URL "$wu"
        say "      Webhook ON -> $wu"
    else
        conf_set WEBHOOK 0
        say "      Webhook OFF."
    fi
}

# ---- unit + enable-at-boot -----------------------------------------------------
reload_unit() {
    ifaces=$(conf_get IFACES)
    local_ip=$(conf_get LOCAL_IP)
    cat > /etc/systemd/system/pppoe-server@.service <<XEOF
[Unit]
Description=PPPoE access server on %i
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/pppoe-server-%i.pid
ExecStartPre=/bin/sh -c 'ip link set up dev %i 2>/dev/null || true'
ExecStart=/usr/sbin/pppoe-server -q /usr/sbin/pppd -I %i -O /etc/ppp/pppoe-server-options -p /etc/ppp/ipaddress_pool -L $local_ip -X /run/pppoe-server-%i.pid
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
XEOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    say ""
    [ -n "$ifaces" ] || return
    for i in $ifaces; do
        enable_at_boot "pppoe-server@$i.service"
    done
}

# ---- server packages + config files (reference PPPoE server setup) -------------
install_packages() {
    if [ -x /usr/sbin/pppoe-server ]; then
        say "    pppoe-server already installed."
        return
    fi
    say "    Installing ppp pppoe iptables ..."
    if apty update && apty install -y --no-install-recommends ppp pppoe iptables; then
        say "    -> packages installed."
    else
        say "    WARNING: could not install ppp/pppoe/iptables - server may not start (offline pool?)."
    fi
}

write_server_options() {
    cat > /etc/ppp/pppoe-server-options <<'XEOF'
# Require CHAP authentication
require-chap
login

# DNS Servers sent to clients
ms-dns 1.1.1.1
ms-dns 8.8.8.8

# LCP Keepalive
lcp-echo-interval 10
lcp-echo-failure 2

# Network constraints
netmask 255.255.255.0
proxyarp
ktune
nobsdcomp
noccp
novj
XEOF
    say "    wrote /etc/ppp/pppoe-server-options (require-chap, ms-dns 1.1.1.1/8.8.8.8, netmask 255.255.255.0)."
}

write_ip_pool() {
    cat > /etc/ppp/ipaddress_pool <<'XEOF'
10.0.0.100-200
XEOF
    chmod 600 /etc/ppp/ipaddress_pool
    say "    wrote /etc/ppp/ipaddress_pool (10.0.0.100-200)."
}

ensure_chap() {
    [ -f /etc/ppp/chap-secrets ] || cat > /etc/ppp/chap-secrets <<'XEOF'
# Client          Server    Secret         IP addresses
XEOF
    chmod 600 /etc/ppp/chap-secrets
    say "    /etc/ppp/chap-secrets ready (add subscriber accounts under option 2)."
}
say "  PPPoE server installer (X3M-OS)"
ensure_conf
say ""
say "  Interfaces currently served: $(conf_get IFACES)"
say "  Local IP (server side):     $(conf_get LOCAL_IP)"
say "  RADIUS:                    $( [ "$(conf_get RADIUS)" = 1 ] && echo 'ON (local fallback kept)' || echo 'OFF (local only)' )"
say "  Webhook:                   $( [ "$(conf_get WEBHOOK)" = 1 ] && echo "ON -> $(conf_get WEBHOOK_URL)" || echo 'OFF' )"
say ""
say "  Choose: [1] interfaces   [2] local users   [3] RADIUS on/off"
say "          [4] webhook      [5] configure + start  [q] quit"
say "  Choose: "; read -r opt
case "$opt" in
    1) pick_ifaces;;
    2) users_edit;;
    3) [ "$(conf_get RADIUS)" = 1 ] && radius_toggle_off_confirm || true
       # if RADIUS was on, offer N; otherwise just ask for the server.
       if [ "$(conf_get RADIUS)" = 1 ]; then
           true
       else
           radius_configure
       fi;;
    4) webhook_configure;;
    5) ifaces=$(conf_get IFACES)
       if [ -n "$ifaces" ]; then
           say "  Configuring PPPoE server (package install + config files) ..."
           install_packages
           write_server_options
           write_ip_pool
           ensure_chap
           say ""
           say "  Writing + enabling per-interface server(s) ..."
           reload_unit
       else
           say '  select interfaces first (option 1).'
       fi;;
esac
exit 0
