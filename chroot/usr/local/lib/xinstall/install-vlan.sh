#!/bin/bash
# install-vlan - manage IEEE 802.1Q VLAN tagged interfaces.
#
# NetworkManager owns networking on X3M-OS, so VLANs are created as
# NetworkManager "vlan" connection profiles via nmcli (the parent link stays
# under NM control - no systemd-networkd, no dhclient race). A submenu lets the
# user add a tagged interface, delete one, or show the current VLAN inventory.
#
#   create:  nmcli connection add type vlan dev <parent> id <vid> ...
#   result:  a new <parent>.<vid> interface brought up by NetworkManager.

set -euo pipefail

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

# vlan_connections - names of every vlan connection profile managed by NM.
vlan_connections() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2=="vlan"{print $1}'
}

# parent_devices - physical links (ethernet/bond/team/bridge) NM can tag.
parent_devices() {
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
        | awk -F: '$2=="ethernet"||$2=="bond"||$2=="team"||$2=="bridge"{print $1}'
}

valid_vid() { [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 4094 ] 2>/dev/null; }

# nth - print the Nth positional parameter (1-based). POSIX substitute for
# bash indexed-array access "${arr[$k]}", usable by both dash and bash.
nth() {
    _n=$1; shift
    for _x do
        [ "$_n" -eq 1 ] && { printf '%s\n' "$_x"; return 0; }
        _n=$((_n - 1))
    done
    return 1
}

# collect - run $1, store its line-output as positional params ($1..$n).
# dash has no arrays, so this replaces mapfile+process-substitution.
collect() {
    _c_tmp=$(mktemp) || return 1
    "$1" > "$_c_tmp"
    set --
    while IFS= read -r _c_line; do
        set -- "$@" "$_c_line"
    done < "$_c_tmp"
    rm -f "$_c_tmp"
}

cmd_add_vlan() {
    say "==> Add a VLAN tagged interface"
    set -- $(parent_devices)
    collect parent_devices
    if [ "$#" -eq 0 ]; then
        say "    no ethernet/bond/bridge devices found under NetworkManager"
        say "    is NetworkManager active? (option 1 enables it)"
    else
        say ""
        say "    parent interfaces:"
        i=1
        for p in "$@"; do
            say "      [$i] $p  ($(nmcli -g GENERAL.STATE device show "$p" 2>/dev/null || echo unknown))"
            i=$((i+1))
        done
        say "      [$i] Other (type the interface name)"
        say "      [$((i+1))] Cancel"
        while :; do
            printf '    select parent [1-%d]: ' "$((i+1))"
            read -r pick
            case "$pick" in
                '') continue;;
                "$((i+1))") return 0;;
                "$i")
                    printf '    parent interface name: '
                    read -r parent || true
                    [ -n "$parent" ] && [ -e "/sys/class/net/$parent" ] && break
                    say "    invalid or unknown interface '$parent'"
                    ;;
                *)
                    [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "$i" ] 2>/dev/null \
                        && parent=$(nth "$pick" "$@") && break
                    say "    invalid choice"
                    ;;
            esac
        done
    fi
    [ -z "${parent:-}" ] && return 0

    while :; do
        printf '    VLAN ID [1-4094]: '
        read -r vid || true
        valid_vid "$vid" && break
        say "    invalid VLAN ID '$vid'"
    done

    say "    IP addressing:"
    say "      [1] DHCP  (auto address from the VLAN's own DHCP server)"
    say "      [2] Static (manual IP/CIDR, gateway, DNS)"
    say "      [3] Cancel"
    while :; do
        printf '    select [1-3]: '
        read -r mode || true
        case "$mode" in
            1) ipmode=auto; break;;
            2) ipmode=manual; break;;
            3) return 0;;
            *) say "    invalid choice";;
        esac
    done

    cidr=
    gw=
    dns=
    if [ "$ipmode" = manual ]; then
        while :; do
            printf '    IP address (CIDR, e.g. 192.168.100.10/24): '
            read -r cidr || true
            [ -n "$cidr" ] && [ "${cidr#*/}" != "$cidr" ] && [ "${cidr#*/}" -ge 1 ] 2>/dev/null && break
            say "    invalid address (need 'IP/prefixlen')"
        done
        printf '    gateway (optional, e.g. 192.168.100.1): '
        read -r gw || true
        printf '    DNS servers (optional, space separated): '
        read -r dns || true
    fi

    con="${parent}.${vid}"
    if nmcli connection show "$con" >/dev/null 2>&1; then
        say "    WARNING: connection '$con' already exists - not creating again."
        return 0
    fi

    say "    creating '$con' (vlan $vid on $parent)..."
    nmcli connection add type vlan con-name "$con" ifname "$con" \
        dev "$parent" id "$vid" || die "nmcli failed to create the VLAN profile"
    if [ "$ipmode" = manual ]; then
        nmcli connection modify "$con" ipv4.method manual \
            ipv4.addresses "$cidr" ${gw:+ipv4.gateway "$gw"} ${dns:+ipv4.dns "$dns"} \
            || die "nmcli failed to apply IP settings"
    else
        nmcli connection modify "$con" ipv4.method auto || true
    fi
    nmcli connection up "$con" >/dev/null 2>&1 \
        || say "    WARNING: created but could not activate - check 'nmcli connection up $con'"

    say ""
    say "    done. Verify:"
    say "      ip link show dev $con"
    say "      nmcli -f IP4.ADDRESS connection show $con"
}

cmd_delete_vlan() {
    say "==> Delete a VLAN interface"
    set -- $(vlan_connections)
    if [ "$#" -eq 0 ]; then
        say "    no VLAN connections configured."
        return 0
    fi
    say ""
    i=1
    for c in "$@"; do
        say "      [$i] $c"
        i=$((i+1))
    done
    say "      [$i] Cancel"
    while :; do
        printf '    select to delete [1-%d]: ' "$i"
        read -r pick || true
        case "$pick" in
            '') continue;;
            "$i") return 0;;
            *)
                if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -lt "$i" ] 2>/dev/null; then
                    nmcli connection delete "$(nth "$pick" "$@")" \
                        && say "    deleted $(vlan_nth "$pick")."
                    return 0
                fi
                say "    invalid choice"
                ;;
        esac
    done
}

cmd_show_vlan() {
    say "==> VLAN interfaces (NetworkManager)"
    say ""
    set -- $(vlan_connections)
    if [ "$#" -eq 0 ]; then
        say "    no VLAN connections configured."
        return 0
    fi
    printf '    %-16s %-12s %-5s %-10s %s\n' NAME DEVICE ID PARENT ADDRESS
    for c in "$@"; do
        dev=$(nmcli -g connection.interface-name connection show "$c" 2>/dev/null | grep -v '^$' | head -1)
        [ -z "$dev" ] && dev="-"
        vid=$(nmcli -g vlan.id connection show "$c" 2>/dev/null | grep -v '^$' | head -1)
        parent=$(nmcli -g vlan.parent connection show "$c" 2>/dev/null | grep -v '^$' | head -1)
        addr=$(nmcli -g IP4.ADDRESS connection show "$c" 2>/dev/null | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')
        [ -z "$addr" ] && addr="(down)"
        printf '    %-16s %-12s %-5s %-10s %s\n' "$c" "$dev" "${vid:-?}" "${parent:-?}" "$addr"
    done
    say ""
    say "    create/delete via this menu; bring one up with:"
    say "      nmcli connection up <name>"
}

while :; do
    clear
    say ""
    say "================================================================"
    say "                 X3M-OS VLAN management"
    say "================================================================"
    say ""
    say "  [1] Add a VLAN tagged interface"
    say "  [2] Delete a VLAN tagged interface"
    say "  [3] Show VLAN interfaces"
    say ""
    say "  [4] Back to the xinstall menu"
    say ""
    printf 'Choose an option [1-4]: '
    read -r choice || true
    case "$choice" in
        1) cmd_add_vlan;;
        2) cmd_delete_vlan;;
        3) cmd_show_vlan;;
        4) exit 0;;
        *) continue;;
    esac
    printf '\nPress ENTER to return...'
    read -r _ 2>/dev/null || true
done