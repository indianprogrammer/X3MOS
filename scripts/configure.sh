#!/bin/bash
# (Re)generate the live-build config tree from config_trixie.sh and sanity
# check the options this SDK depends on.
#
# Usage: ./sdk/configure.sh [--help]
# Build options themselves live in ./config_trixie.sh - edit that file to
# change mirrors, packages are in config/package-lists/.

source "$(dirname "$0")/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

cd "$PROJECT_DIR"

[[ -x config_trixie.sh ]] || die "config_trixie.sh not found/executable in $PROJECT_DIR"

log "Generating live-build config..."
sudo ./config_trixie.sh >/tmp/sdk-configure.log 2>&1 || { tail -20 /tmp/sdk-configure.log; die "lb config failed"; }
rm -f /tmp/sdk-configure.log

log "Installing feeds (layers -> package/ -> config/)..."
"$SDK_DIR/feeds" install -a

log "Syncing package selection into the config tree..."
"$SDK_DIR/package" sync

log "Checking package dependencies..."
"$SDK_DIR/package" check

log "Sanity-checking generated config..."
check_var() { # file var expected
    local val
    val="$(grep -E "^$2=" "$1" | cut -d= -f2 | tr -d '"')"
    [[ "$val" == "$3" ]] || die "$1: $2 is '$val', expected '$3' (edit config_trixie.sh)"
    ok "$2=$val"
}
want_bootloader="${CONFIG_SDK_BOOTLOADER:-syslinux}"
check_var config/bootstrap LB_DISTRIBUTION trixie
check_var config/bootstrap LB_PARENT_DISTRIBUTION trixie
check_var config/common    LB_INITSYSTEM systemd
check_var config/binary    LB_BOOTLOADER "$want_bootloader"
check_var config/chroot    LB_LINUX_FLAVOURS amd64
check_var config/chroot    LB_SECURITY false
check_var config/chroot    LB_VOLATILE false

for f in config/package-lists/core.list.chroot \
         config/package-lists/70-sdk-selection.list.chroot \
         config/hooks/0900-live-network.chroot \
         config/includes.chroot/etc/systemd/network/10-live-dhcp.network \
         config/includes.chroot/etc/apt/sources.list.d/trixie-security.list; do
    [[ -f "$f" ]] || die "missing $f (feeds install / package sync broken?)"
done
ok "package lists, hook and includes present"

# OS-internal selection (optional): when .config.os-packages exists, sync
# must have produced the OS artifacts - the 71 list for genuine OS additions
# plus a purge hook for chroot-side removals. Bootstrap-side removals are
# exported natively by config_trixie.sh (LB_BOOTSTRAP_EXCLUDE); verify the
# generated config/bootstrap actually carries them.
if [[ -f .config.os-packages ]]; then
    for f in config/package-lists/71-os-selection.list.chroot \
             config/hooks/0910-os-purge.chroot; do
        [[ -f "$f" ]] || die "missing $f (package sync OS step broken?)"
    done
    expected_excl="$(grep -E '^# CONFIG_OS_.+ is not set' .config.os-packages \
        | sed 's/^# CONFIG_OS_//; s/ is not set$//' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
    actual_excl="$(grep -E '^LB_BOOTSTRAP_EXCLUDE=' config/bootstrap | cut -d= -f2 | tr -d '"')"
    # normalize (order-insensitive) before comparing
    norm() { tr ' ' '\n' <<< "$1" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
    [[ "$(norm "$expected_excl")" == "$(norm "$actual_excl")" ]] \
        || die "config/bootstrap LB_BOOTSTRAP_EXCLUDE='$actual_excl' != OS removals '$expected_excl' (re-run configure)"
    ok "OS-internal selection artifacts present (bootstrap-exclude: '${actual_excl:-(empty)}')"
fi

[[ -d config/bootloaders/isolinux ]] || die "missing config/bootloaders/isolinux (run sdk/assemble-bootloader.sh)"
for f in isolinux.bin vesamenu.c32 ldlinux.c32 libcom32.c32 libutil.c32; do
    [[ -f "config/bootloaders/isolinux/$f" ]] || die "config/bootloaders/isolinux/$f missing (run sdk/assemble-bootloader.sh)"
done
ok "local isolinux template complete"

ok "configure done"
