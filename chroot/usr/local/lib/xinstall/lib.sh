#!/bin/sh
# Shared helpers for the xinstall menu.
#
# Every option performs a system-wide installation, so the whole menu (and
# each install-*.sh it invokes) runs elevated. lib.sh deliberately defines
# only tiny, dependency-free primitives - anything larger lives in the
# per-feature installers.

# Re-exec under sudo if not root.
require_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    exec sudo "$0" "$@"
}

# require <command> [hint]
require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "xinstall: required command '$1' not found${2:+ ($2)}" >&2
        exit 1
    }
}

# online <host> -> true/false
online() {
    getent hosts "$1" >/dev/null 2>&1 \
        || ping -c1 -W2 "$1" >/dev/null 2>&1
}

# --- console -----------------------------------------------------------------
# term_rows -> number of console rows currently available (fallback 24).
term_rows() {
    if [ -t 0 ] || [ -t 1 ]; then
        stty size 2>/dev/null | awk '{print $1; exit}'
    else
        echo 24
    fi
}

# --- enable at boot -----------------------------------------------------------
# enable_at_boot <unit> [unit ...]
# Start the unit now and - the whole point - make it come back up by itself
# after a reboot. Every service the xinstall menu creates must be handed to
# this helper so the user never has to remember to enable anything.
enable_at_boot() {
    for unit in "$@"; do
        say "    Enabling '$unit' for automatic start at boot ..."
        if systemctl enable --now "$unit" >/dev/null 2>&1; then
            say "      -> enabled + started."
        elif systemctl enable "$unit" >/dev/null 2>&1; then
            say "      -> enabled for boot (not started now - starts at boot)."
        else
            say "      !! could not enable '$unit' - run: systemctl status $unit"
        fi
    done
}

# --- webhook -----------------------------------------------------------------
# webhook_send <event> [key=value ...]
# POST a form body (<event> plus every key=value) to the external webhook URL
# recorded by the feature installers in /etc/xinstall/webhook.conf:
#
#   WEBHOOK=1|0
#   WEBHOOK_URL=http://isp.example.com/hook/pod
#   WEBHOOK_TOKEN=optional-bearer
#
# Best-effort: never fails the callerholism. All parameters that the caller can
# see are forwarded verbatim so the remote script can pick what it needs.
webhook_send() {
    _hook=/etc/xinstall/webhook.conf
    [ -r "$_hook" ] || return 0
    _on=$(awk -F= '$1=="WEBHOOK"{print $2;exit}' "$_hook")
    [ "$_on" = 1 ] || return 0
    _url=$(awk -F= '$1=="WEBHOOK_URL"{print $2;exit}' "$_hook")
    _tok=$(awk -F= '$1=="WEBHOOK_TOKEN"{print $2;exit}' "$_hook")
    [ -n "$_url" ] || return 0

    _ev=$1; shift
    _body="event=$_ev"
    for _kv in "$@"; do
        case "$_kv" in
            *=*) _body="$_body&$_kv";;
        esac
    done

    _hdr=
    [ -n "$_tok" ] && _hdr="-H Authorization: Bearer $_tok"
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 8 -o /dev/null $_hdr \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "$_body" "$_url" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 8 -O /dev/null --post-data="$_body" \
            ${_tok:+--header="Authorization: Bearer $_tok"} \
            "$_url" 2>/dev/null || true
    fi
}

# --- persistent key=value config ----------------------------------------------
# Features store their runtime state in /etc/xinstall/<feat>.conf so settings
# survive reboots. Keys are uppercased, one per line ("KEY=value").
conf_dir()  { echo /etc/xinstall; }
conf_file() { echo "$(conf_dir)/$1.conf"; }

conf_set()  { # conf_set <file> <key> <value>
    _f=$1; _k=$2; _v=$3
    mkdir -p "$(conf_dir)"
    if grep -q "^$_k=" "$_f" 2>/dev/null; then
        sed -i "s|^$_k=.*|$_k=$_v|" "$_f"
    else
        echo "$_k=$_v" >> "$_f"
    fi
}
conf_get()  { # conf_get <file> <key>
    awk -F= -v k="$2" '$1==k{print $2; exit}' "$1" 2>/dev/null
}

# --- trivial output helpers ---------------------------------------------------
say(){    printf '%s\n' "$*"; }
die(){    say "xinstall: $*" >&2; exit 1; }
banner(){ printf '%s\n' "${BOLD:-}====================================${NORM:-}" \
                          "${BOLD:-}  $*${NORM:-}" \
                          "${BOLD:-}====================================${NORM:-}"; }

# pppoe_status / ipoe_status : installed-state probes for menu rows 7 and 8.
pppoe_status() {
    if [ -x /usr/sbin/pppoe-server ] || command -v pppoe-server >/dev/null 2>&1; then
        printf 'installed'
    else
        printf 'not installed'
    fi
}

ipoe_status() {
    if [ -x /usr/sbin/dnsmasq ] || command -v dnsmasq >/dev/null 2>&1; then
        printf 'installed'
    else
        printf 'not installed'
    fi
}
