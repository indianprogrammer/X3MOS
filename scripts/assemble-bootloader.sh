#!/bin/bash
# (Re)build config/bootloaders/isolinux/ from pristine trixie packages.
#
# Usage: ./sdk/assemble-bootloader.sh [--help] [--force]
#
# Background: the isolinux templates shipped with this live-build vintage
# (2012) point isolinux.bin/vesamenu.c32 at /usr/lib/syslinux/* paths that
# no longer exist, and lack the ldlinux.c32 stack modern syslinux needs to
# boot. This script assembles a self-contained template dir with REAL
# trixie binaries, so the binary_syslinux stage works unmodified.
# Safe to re-run; skips work unless --force or files are missing.

source "$(dirname "$0")/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

TPL="$PROJECT_DIR/config/bootloaders/isolinux"
NEED="isolinux.bin vesamenu.c32 ldlinux.c32 libcom32.c32 libutil.c32 bootlogo"
missing=0
for f in $NEED install.cfg isolinux.cfg live.cfg.in menu.cfg splash.svg.in stdmenu.cfg; do
    [[ -f "$TPL/$f" ]] || missing=1
done
if [[ "$missing" -eq 0 && "$FORCE" -eq 0 ]]; then
    ok "bootloader template already complete ($TPL)"
    exit 0
fi

for cmd in dpkg-deb cpio curl; do
    have "$cmd" || die "$cmd missing"
done
[[ -d /usr/share/live/build/bootloaders/isolinux ]] \
    || die "host live-build templates missing (/usr/share/live/build/bootloaders/isolinux)"

DLDIR="$PROJECT_DIR/dl"
mkdir -p "$DLDIR"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

log "Fetching trixie syslinux debs into dl/ ..."
SYS_VER="6.04~git20190206.bf6db5b4+dfsg1-3.1"
for pkg in isolinux syslinux-common; do
    if [[ ! -s "$DLDIR/${pkg}_${SYS_VER}_all.deb" ]]; then
        curl -sf -o "$DLDIR/${pkg}_${SYS_VER}_all.deb" \
            "http://deb.debian.org/debian/pool/main/s/syslinux/${pkg}_${SYS_VER}_all.deb" \
            || die "download of $pkg deb failed"
    else
        log "cached: dl/${pkg}_${SYS_VER}_all.deb"
    fi
done

log "Assembling $TPL ..."
mkdir -p "$TPL"
cp /usr/share/live/build/bootloaders/isolinux/install.cfg \
   /usr/share/live/build/bootloaders/isolinux/isolinux.cfg \
   /usr/share/live/build/bootloaders/isolinux/live.cfg.in \
   /usr/share/live/build/bootloaders/isolinux/menu.cfg \
   /usr/share/live/build/bootloaders/isolinux/splash.svg.in \
   /usr/share/live/build/bootloaders/isolinux/stdmenu.cfg "$TPL/"
# NOTE: splash.svg.in is intentionally NOT shipped: trixie's librsvg2-bin
# provides rsvg-convert, not the `rsvg` frontend this live-build calls, so
# the splash-render step would fail. The menu works fine without a background.
rm -f "$TPL/splash.svg.in"

dpkg-deb --fsys-tarfile "$DLDIR/isolinux_${SYS_VER}_all.deb" \
    | tar -xO ./usr/lib/ISOLINUX/isolinux.bin > "$TPL/isolinux.bin"
for f in vesamenu.c32 ldlinux.c32 libcom32.c32 libutil.c32; do
    dpkg-deb --fsys-tarfile "$DLDIR/syslinux-common_${SYS_VER}_all.deb" \
        | tar -xO "./usr/lib/syslinux/modules/bios/$f" > "$TPL/$f"
done
# The gfxboot bootlogo repack step expects ${_TARGET}/bootlogo to exist but
# nothing references it at boot; seed a valid empty cpio archive.
cpio --quiet -o < /dev/null > "$TPL/bootlogo" 2>/dev/null

for f in $NEED; do
    [[ -s "$TPL/$f" ]] || die "assembly failed: $TPL/$f empty/missing"
done
ok "bootloader template assembled ($(ls "$TPL" | tr '\n' ' '))"
