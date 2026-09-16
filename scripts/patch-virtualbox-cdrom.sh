#!/bin/bash
# patch-virtualbox-cdrom.sh -- hotfix the CURRENT build for VirtualBox CD-ROMs,
# offline, no downloads.
#
# Makes the "Configuring apt / Scanning the mirror / Running setup" step
# unable to hang, so the installer always falls through to the GRUB
# boot-loader step (grub-installer):
#
#   1. refreshes the preseed (ISO root AND inside the initrd) with the
#      pkgsel/tasksel offline guards,
#   2. replaces the apt-cdrom-setup 40cdrom generator (no device probing),
#   3. replaces the apt-setup /usr/bin/apt-setup main script with the SKIP
#      variant (finishes the "Configure the package manager" step instantly,
#      always exits 0), so the installer falls through to the GRUB boot-loader
#      step (grub-installer),
#   4. refreshes the udeb Packages index hashes for both patched udebs,
#   5. re-signs the Release file,
#   6. rebuilds the ISO.
#
# Usage:  sudo ./scripts/patch-virtualbox-cdrom.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$PROJECT_DIR/.installer-build"
ISO="$WORK_DIR/iso"
SUITE="trixie"
ARCH="amd64"
DEBINST_COMP="main/debian-installer/binary-$ARCH"
GNUPGHOME="$WORK_DIR/.gnupg"
export GNUPGHOME

# -- helpers ---------------------------------------------------------
log()  { printf '\033[1;34m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# -- 0. Sanity -------------------------------------------------------
[[ $(id -u) -eq 0 ]] || die "run with sudo:  sudo $0"
for cmd in dpkg-deb md5sum sha1sum sha256sum sha512sum python3 gzip gpg xorriso cpio; do
    command -v "$cmd" >/dev/null || die "missing: $cmd"
done
[[ -f "$ISO/pool/main/a/apt-setup/apt-cdrom-setup_0.198_all.udeb" ]] || die "ISO tree missing (build first): $ISO"
[[ -f "$ISO/pool/main/a/apt-setup/apt-setup-udeb_0.198_amd64.udeb" ]] || die "ISO tree missing apt-setup-udeb"

TMPDIR=$(mktemp -d "$WORK_DIR/.hotfix-XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

# -- 1. Refresh preseed (ISO root + initrd copies) -------------------
log "1/6  Refreshing preseed.cfg (ISO root + initrd)"
cp "$PROJECT_DIR/preseed.cfg" "$ISO/preseed.cfg"
grep -q '^d-i pkgsel/run_tasksel boolean false' "$ISO/preseed.cfg" \
    || die "preseed.cfg missing pkgsel/run_tasksel guard"
ok "preseed.cfg refreshed at ISO root"

INITRD_SRC="$WORK_DIR/dl/initrd.gz"
INITRD_TMP="$TMPDIR/initrd"
mkdir -p "$INITRD_TMP"
( cd "$INITRD_TMP" && gzip -dc "$INITRD_SRC" | cpio -id 2>/dev/null || true )
[[ -d "$INITRD_TMP/etc" ]] || die "failed to unpack initrd"
mkdir -p "$INITRD_TMP/etc" "$INITRD_TMP/cdrom"
cp "$PROJECT_DIR/preseed.cfg" "$INITRD_TMP/preseed.cfg"
cp "$PROJECT_DIR/preseed.cfg" "$INITRD_TMP/etc/preseed.cfg" 2>/dev/null || true
cp "$PROJECT_DIR/preseed.cfg" "$INITRD_TMP/cdrom/preseed.cfg" 2>/dev/null || true
( cd "$INITRD_TMP" && find . | cpio --create --format=newc 2>/dev/null \
    | gzip -9 > "$WORK_DIR/initrd.gz.new" ) || die "failed to repack initrd"
mv "$WORK_DIR/initrd.gz.new" "$INITRD_SRC"
cp "$INITRD_SRC" "$ISO/install.amd64/initrd.gz"
ok "initrd rebuilt with fresh preseed"

# -- 2. Patch apt-cdrom-setup udeb ----------------------------------
log "2/6  Rebuilding apt-cdrom-setup udeb with patched 40cdrom"
CDSETUP_UDEB="$ISO/pool/main/a/apt-setup/apt-cdrom-setup_0.198_all.udeb"
mkdir -p "$TMPDIR/cdsetup/DEBIAN"
dpkg-deb -e "$CDSETUP_UDEB" "$TMPDIR/cdsetup/DEBIAN" >/dev/null
dpkg-deb -x "$CDSETUP_UDEB" "$TMPDIR/cdsetup" >/dev/null
cp "$PROJECT_DIR/patches/usr/lib/apt-setup/generators/40cdrom" \
   "$TMPDIR/cdsetup/usr/lib/apt-setup/generators/40cdrom" \
   || die "40cdrom patch file missing"
( cd "$TMPDIR/cdsetup" && find . -type f -not -path './DEBIAN/*' | sort | \
  while read -r f; do printf '%s  %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "${f#./}"; done \
  > DEBIAN/md5sums )
dpkg-deb -Zgzip --build "$TMPDIR/cdsetup" "$WORK_DIR/apt-cdrom-setup.patched.udeb" >/dev/null \
    || die "apt-cdrom-setup udeb rebuild failed"
cp "$WORK_DIR/apt-cdrom-setup.patched.udeb" "$CDSETUP_UDEB"
ok "apt-cdrom-setup udeb patched"

# -- 3. Patch apt-setup-udeb main script ----------------------------
log "3/6  Rebuilding apt-setup-udeb with bounded /usr/bin/apt-setup"
SETUP_UDEB="$ISO/pool/main/a/apt-setup/apt-setup-udeb_0.198_amd64.udeb"
mkdir -p "$TMPDIR/setupudeb/DEBIAN"
dpkg-deb -e "$SETUP_UDEB" "$TMPDIR/setupudeb/DEBIAN" >/dev/null
dpkg-deb -x "$SETUP_UDEB" "$TMPDIR/setupudeb" >/dev/null
cp "$PROJECT_DIR/patches/usr/bin/apt-setup" "$TMPDIR/setupudeb/usr/bin/apt-setup" \
    || die "apt-setup patch file missing"
chmod 755 "$TMPDIR/setupudeb/usr/bin/apt-setup"
( cd "$TMPDIR/setupudeb" && find . -type f -not -path './DEBIAN/*' | sort | \
  while read -r f; do printf '%s  %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "${f#./}"; done \
  > DEBIAN/md5sums )
dpkg-deb -Zgzip --build "$TMPDIR/setupudeb" "$WORK_DIR/apt-setup-udeb.patched.udeb" >/dev/null \
    || die "apt-setup udeb rebuild failed"
cp "$WORK_DIR/apt-setup-udeb.patched.udeb" "$SETUP_UDEB"
ok "apt-setup-udeb patched (SKIP no-op: step completes instantly)"

# -- 4. Refresh the udeb Packages index stanzas ---------------------
log "4/6  Updating dists/$SUITE/$DEBINST_COMP/Packages hashes"
_PPKG="$ISO/dists/$SUITE/$DEBINST_COMP/Packages"
for _PNAME in apt-cdrom-setup apt-setup-udeb; do
    case "$_PNAME" in
        apt-cdrom-setup) _PUD="$CDSETUP_UDEB";;
        apt-setup-udeb)  _PUD="$SETUP_UDEB";;
    esac
    python3 - "$_PPKG" "$_PNAME" \
        "$(stat -c%s "$_PUD")" \
        "$(md5sum "$_PUD" | cut -d' ' -f1)" \
        "$(sha1sum "$_PUD" | cut -d' ' -f1)" \
        "$(sha256sum "$_PUD" | cut -d' ' -f1)" \
        "$(sha512sum "$_PUD" | cut -d' ' -f1)" <<'PY'
import sys
p,name,size,md5,sha1,sha256,sha512 = (sys.argv[1],sys.argv[2],sys.argv[3],
                                     sys.argv[4],sys.argv[5],sys.argv[6],
                                     sys.argv[7])
out=[]; st=False
for ln in open(p):
    if ln.startswith('Package: '+name):
        st=True
    if st and ln.startswith('Size:'):           ln=f'Size: {size}\n'
    elif st and ln.startswith('MD5sum:'):       ln=f'MD5sum: {md5}\n'
    elif st and ln.startswith('SHA1:'):         ln=f'SHA1: {sha1}\n'
    elif st and ln.startswith('SHA256:'):       ln=f'SHA256: {sha256}\n'
    elif st and ln.startswith('SHA512:'):       ln=f'SHA512: {sha512}\n'
    elif st and ln=='\n':                       st=False
    out.append(ln)
open(p,'w').write(''.join(out))
PY
    gzip -kf "$_PPKG"
    ok "refreshed $_PNAME in udeb Packages index"
done

# -- 5. Regenerate + sign Release -----------------------------------
log "5/6  Regenerating Release + InRelease"
RELEASE="$ISO/dists/$SUITE"
( cd "$RELEASE" && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Debian" \
    -o APT::FTPArchive::Release::Label="Debian" \
    -o APT::FTPArchive::Release::Suite="$SUITE" \
    -o APT::FTPArchive::Release::Codename="$SUITE" \
    -o APT::FTPArchive::Release::Architectures="$ARCH" \
    -o APT::FTPArchive::Release::Components="main" \
    -o APT::FTPArchive::Release::Description="Debian trixie offline installer pool" \
    release . > Release )
( cd "$RELEASE" \
    && gpg --homedir "$GNUPGHOME" --batch --yes \
        --detach-sign --armor -o Release.gpg Release \
    && gpg --homedir "$GNUPGHOME" --batch --yes \
        --clear-sign -o InRelease Release ) \
    || die "Release signing failed"
ok "Release + InRelease signed"

# -- 6. Rebuild ISO --------------------------------------------------
log "6/6  Rebuilding ISO"
ISOHDPFX="$WORK_DIR/dl/isohdpfx.bin"
[[ -s "$ISOHDPFX" ]] || die "isohdpfx.bin not found"

OUT="$PROJECT_DIR/debian-trixie-netinst-amd64.iso"
xorriso -as mkisofs -o "$OUT" \
    -isohybrid-mbr "$ISOHDPFX" \
    -c isolinux/boot.cat -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -iso-level 3 -J -joliet-long \
    -V "DEBIAN_TRIXIE_NETINST" -A "Debian trixie offline installer" \
    -p "Custom build" \
    "$ISO" 2>&1 | tail -3 \
    || die "xorriso failed"

echo
SIZE=$(du -h "$OUT" | cut -f1)
sha256sum "$OUT" | tee "$OUT.sha256" >/dev/null
ok "Patched ISO ready: $OUT ($SIZE)"
echo
echo "  Fully power-cycle your VirtualBox VM (hard stop, not suspend),"
echo "  detach any old ISO, attach the new one, and start a fresh install."
echo "  If apt-setup still times out, the installer now auto-falls through"
echo "  to the GRUB boot-loader step (grub-installer) instead of hanging."
