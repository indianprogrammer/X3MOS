#!/bin/bash
# Build a minimal OFFLINE Debian trixie installer ISO (NOT a live ISO).
#
# This produces a netinst-style ISO that boots directly into the Debian
# Installer (d-i). No live system, no squashfs, no live-boot. Just the
# installer + a pool of .deb/.udeb packages for complete offline installation.
#
# Usage: sudo ./scripts/build-installer.sh [--help] [--force]
#
# The ISO structure (mirrors the official Debian CD layout so the
# Debian Installer's cdrom-retriever can resolve installer udebs):
#   /isolinux/           syslinux boot menu
#   /install.amd64/      d-i kernel + initrd (cdrom variant)
#   /pool/main/          offline .deb + .udeb packages
#   /dists/trixie/       Release + binary Packages index (.deb)
#   /dists/trixie/main/debian-installer/binary-amd64/
#                       udeb Packages index (.udeb) used by anna
#   /preseed.cfg         auto-install preseed
#   /.disk/              d-i metadata markers
#
# Requirements: debootstrap, xorriso, curl, cpio, apt-ftparchive, sudo

set -euo pipefail

# Turn silent `set -e` aborts into a visible message pointing at the culprit.
trap 'warn "FATAL: dead at line $LINENO: $BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common helpers
source "$SCRIPT_DIR/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Configuration
MIRROR="http://deb.debian.org/debian"
SUITE="trixie"
ARCH="amd64"
INSTALLER_BASE="$MIRROR/dists/$SUITE/main/installer-$ARCH/current/images"
ISO_NAME="debian-trixie-netinst-amd64.iso"
VOLUME="DEBIAN_TRIXIE_NETINST"
WORK_DIR="$PROJECT_DIR/.installer-build"

cd "$PROJECT_DIR"
sudo_warmup

# Keep sudo alive for the whole build
( while true; do sleep 50; sudo -v; done ) &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true' EXIT

log "=== [1/5] preflight ==="
for cmd in debootstrap xorriso curl cpio apt-ftparchive dpkg-deb sha256sum gpg; do
    have "$cmd" || die "$cmd missing (apt-get install $cmd)"
done
ok "preflight passed"

log "=== [2/5] fetch d-i cdrom images + installer udebs ==="
DLDIR="$WORK_DIR/dl"
mkdir -p "$DLDIR"

fetch() {
    local url="$1" dest="$2"
    if [[ -s "$dest" && "$FORCE" -eq 0 ]]; then
        log "cached: $(basename "$dest")"
        return 0
    fi
    log "downloading $(basename "$dest") ..."
    curl -sfL --retry 3 -o "$dest" "$url" || die "download failed: $url"
}

# IMPORTANT: use the "cdrom" installer (not "netboot"). The cdrom initrd
# bundles the cdrom-retriever + cdrom-detect udebs, which know how to load
# installer components from /cdrom/dists/<suite>/main/debian-installer/...
fetch "$INSTALLER_BASE/cdrom/vmlinuz" "$DLDIR/linux"
fetch "$INSTALLER_BASE/cdrom/initrd.gz" "$DLDIR/initrd.gz"

# The installer also needs the udeb pool + index (dists/trixie/main/debian-installer/...)
# so that anna (the component loader) can fetch each installer component.
# We always resolve a fresh closure of udebs (--force overwrites).
UDEB_PKGS="$WORK_DIR/dl/udeb-Packages"
DEBINST_COMP="main/debian-installer/binary-$ARCH"

if [[ "$FORCE" -eq 1 || ! -s "$UDEB_PKGS" ]]; then
    log "fetching udeb Packages index from mirror..."
    curl -sfL --retry 3 \
        -o "$UDEB_PKGS.xz" \
        "$MIRROR/dists/$SUITE/$DEBINST_COMP/Packages.xz" \
        || die "failed to fetch udeb Packages.xz"
    xz -dc "$UDEB_PKGS.xz" > "$UDEB_PKGS"
fi
UDEB_COUNT=$(grep -c '^Package:' "$UDEB_PKGS" || true)
ok "udeb index ready ($UDEB_COUNT udebs)"

log "injecting preseed.cfg into initrd at /preseed.cfg..."
INITRD_TMP="$(mktemp -d)"
(cd "$INITRD_TMP" && gzip -dc "$DLDIR/initrd.gz" | cpio -id 2>/dev/null || true)
[[ -f "$INITRD_TMP/etc" || -d "$INITRD_TMP/etc" ]] || \
    { rm -rf "$INITRD_TMP"; die "failed to unpack initrd"; }

# The cdrom installer initrd already bundles cdrom-retriever + cdrom-detect.
# Confirm and log; the mount point /cdrom must exist in the initrd.
if [[ -f "$INITRD_TMP/usr/lib/debian-installer/retriever/cdrom-retriever" ]]; then
    ok "initrd bundles cdrom-retriever (official cdrom d-i image)"
else
    warn "cdrom-retriever NOT found in initrd — anna cannot load components from /cdrom!"
fi
mkdir -p "$INITRD_TMP/etc" "$INITRD_TMP/cdrom"
cp "$PROJECT_DIR/preseed.cfg" "$INITRD_TMP/preseed.cfg"
cp "$PROJECT_DIR/preseed.cfg" "$INITRD_TMP/etc/preseed.cfg" 2>/dev/null || true
cp "$PROJECT_DIR/preseed.cfg" "$INITRD_TMP/cdrom/preseed.cfg" 2>/dev/null || true

# First-boot "press ENTER to reboot" helper: a systemd unit + script that are
# copied into the installed target by the preseed late_command. Loading them
# in the initrd keeps preseed.cfg free of heredocs.
mkdir -p "$INITRD_TMP/usr/share/press-to-reboot"
cp "$PROJECT_DIR/patches/usr/share/press-to-reboot/press-to-reboot" \
   "$INITRD_TMP/usr/share/press-to-reboot/press-to-reboot" \
    || die "press-to-reboot helper missing"
cp "$PROJECT_DIR/patches/usr/share/press-to-reboot/press-to-reboot.service" \
   "$INITRD_TMP/usr/share/press-to-reboot/press-to-reboot.service" \
    || die "press-to-reboot unit missing"
chmod 755 "$INITRD_TMP/usr/share/press-to-reboot/press-to-reboot"
ok "press-to-reboot target files embedded in initrd"

# Target overlay: everything under <repo>/chroot/ is applied verbatim on top
# of the installed system (the installer equivalent of live-build's
# includes.chroot). Embedded into the initrd as /overlay and copied onto
# /target by the preseed late_command.
if [[ -d "$PROJECT_DIR/chroot" ]] \
    && [[ -n "$(find "$PROJECT_DIR/chroot" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    mkdir -p "$INITRD_TMP/overlay"
    cp -a "$PROJECT_DIR"/chroot/. "$INITRD_TMP/overlay/"
    ok "target overlay embedded in initrd ($(find "$INITRD_TMP/overlay" -type f | wc -l) files)"
else
    log "no target overlay (chroot/ is empty or missing) - skipping"
fi

# Sign the CD Release so apt-cdrom / apt in the target TRUSTS the medium.
# Without a valid signature, apt on trixie refuses the cdrom source and
# apt-setup dies at "50mirror ... sources.list.new: No such file" exactly as
# observed. Official d-i CDs are signed; we sign ours the same way.
log "creating CD archive signing key..."
GNUPGHOME="$WORK_DIR/.gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
if ! gpg --homedir "$GNUPGHOME" --list-keys --with-colons 2>/dev/null \
    | grep -q '^pub:' ; then
    gpg --homedir "$GNUPGHOME" --batch --pinentry-mode loopback --passphrase '' \
        --quick-gen-key 'Debian CD Release Signing Key (offline installer) <cd@localhost>' \
        rsa2048 sign 1y >/dev/null 2>&1 \
        || die "failed to create CD signing key (is gnupg set up?)"
fi
KEYID=$(gpg --homedir "$GNUPGHOME" --list-keys --with-colons 2>/dev/null \
    | awk -F: '$1=="pub"{print $5; exit}')
[[ -n "$KEYID" ]] || die "could not read back CD signing key"
gpg --homedir "$GNUPGHOME" --export "$KEYID" > "$WORK_DIR/cd-archive-keyring.gpg"

# Trusted keyring + hook: the base-installer copies the key into the newly
# installed target (post-base-installer.d runs right after the base system),
# so apt-cdrom add and all later target apt operations accept the CD.
mkdir -p "$INITRD_TMP/etc/apt/trusted.gpg.d" "$INITRD_TMP/usr/lib/post-base-installer.d"
cp "$WORK_DIR/cd-archive-keyring.gpg" \
   "$INITRD_TMP/etc/apt/trusted.gpg.d/cd-archive-keyring.gpg"
cat > "$INITRD_TMP/usr/lib/post-base-installer.d/90cd-archive-key" <<'HOOK'
#!/bin/sh
set -e

# Trust the signed CD: copy our archive keyring into the freshly installed
# target so apt-cdrom/apt accept the medium. Copy from the initrd first (it is
# always present); /cdrom may not be mounted when these hooks run.
dest=/target/etc/apt/trusted.gpg.d/cd-archive-keyring.gpg
mkdir -p /target/etc/apt/trusted.gpg.d

if [ -f /etc/apt/trusted.gpg.d/cd-archive-keyring.gpg ]; then
	cp /etc/apt/trusted.gpg.d/cd-archive-keyring.gpg "$dest"
	logger -t cd-archive-key "installed CD keyring from initrd into target"
	exit 0
fi

logger -t cd-archive-key "initrd keyring missing - falling back to /cdrom"
if [ -f /cdrom/.disk/cd-archive-keyring.gpg ]; then
	cp /cdrom/.disk/cd-archive-keyring.gpg "$dest"
	logger -t cd-archive-key "installed CD keyring from /cdrom into target"
fi
exit 0
HOOK
chmod 755 "$INITRD_TMP/usr/lib/post-base-installer.d/90cd-archive-key"
ok "trusted CD archive key embedded in initrd + post-base-installer hook"

(cd "$INITRD_TMP" && find . | cpio --create --format=newc 2>/dev/null | gzip -9 > "$DLDIR/initrd.gz.new") \
    || { rm -rf "$INITRD_TMP"; die "failed to repack initrd"; }
mv "$DLDIR/initrd.gz.new" "$DLDIR/initrd.gz"
rm -rf "$INITRD_TMP"
ok "preseed injected into initrd (and /etc/preseed.cfg + /cdrom/preseed.cfg)"

log "=== [3/5] debootstrap to resolve package closure ==="
STAGE="$WORK_DIR/stage"
if [[ -d "$STAGE/var/lib/dpkg" && "$FORCE" -eq 0 ]]; then
    log "reusing existing debootstrap stage"
else
    sudo rm -rf "$STAGE"
    mkdir -p "$STAGE"
    log "running debootstrap trixie (a few minutes)..."
    sudo debootstrap \
        --variant=minbase \
        "$SUITE" "$STAGE" "$MIRROR" \
        2>&1 | tail -5 \
        || die "debootstrap failed"
fi
ok "debootstrap stage ready"

log "=== [4/5] build offline package pool ==="
POOL="$WORK_DIR/pool"
mkdir -p "$POOL"

if [[ "$FORCE" -eq 1 ]]; then
    rm -f "$POOL"/*.deb
fi

# A pool cached before the busybox/zstd/helper fixes (or from an older mirror
# snapshot) may be missing packages base-installer needs; and a run interrupted
# mid-download can leave truncated .debs that pass an empty-size check. Only
# reuse a pool that is intact: markers present AND every .deb is a valid
# ar archive (dpkg-deb -c). Otherwise flush it and re-resolve.
POOL_OK=0
if ls "$POOL"/*.deb >/dev/null 2>&1 && ls "$POOL"/busybox_*.deb >/dev/null 2>&1 \
    && ls "$POOL"/zstd_*.deb >/dev/null 2>&1 \
    && ls "$POOL"/libext2fs2t64_*.deb >/dev/null 2>&1 \
    && [[ "$FORCE" -eq 0 ]]; then
    log "validating cached pool (dpkg-deb -c each)..."
    BAD="$(for f in "$POOL"/*.deb; do
        dpkg-deb -c "$f" >/dev/null 2>&1 || echo "$f"
    done)"
    if [[ -n "$BAD" ]]; then
        warn "cached pool contains corrupt/truncated debs:"
        log "$(echo "$BAD" | sed 's/^/  corrupt: /')"
    else
        POOL_OK=1
    fi
fi
if [[ "$POOL_OK" -eq 1 ]]; then
    log "reusing cached pool ($(ls "$POOL"/*.deb | wc -l) debs)"
else
    if ls "$POOL"/*.deb >/dev/null 2>&1; then
        warn "pool stale/corrupt (missing busybox, zstd or base helpers, or bad archive) - re-resolving closure"
        rm -f "$POOL"/*.deb
    fi
    log "resolving package closure for offline install..."
    # Give apt a hard timeout so a dead network can't hang the build forever.
    sudo chroot "$STAGE" timeout 300 apt-get update \
        -o Acquire::AllowInsecureRepositories=true >/dev/null 2>&1 \
        || die "stage apt-get update failed (check network)"

    # What giveth a reproducible barebone offline install: the essential base
    # already in the stage + linux-image + grub-pc + networking tools. The
    # RESOLVED set (this list is exactly what base-installer will install on a
    # physical box with install-recommends=false) is found via --print-uris.
    # NOTE: busybox and zstd are deliberately listed. Recent d-i base-installer
    # always installs busybox and zstd into the target (rescue shell, and zstd
    # compression for initramfs-tools) before the kernel; without their .deb in
    # the pool the installer dies at "Unable to install <pkg>".
    log "collecting URIs (kernel/grub closure)..."
    URIS=$(sudo chroot "$STAGE" apt-get install --print-uris --no-install-recommends \
        -y linux-image-amd64 grub-pc ifupdown iproute2 kmod busybox zstd \
        console-setup keyboard-configuration sudo \
        2>/dev/null | grep -oE "'http[s]?://[^']+\.deb'" | tr -d "'" || true)

    # Also collect the base packages already installed in the stage.
    NEW=""
    STAGE_NAMES=$(sudo chroot "$STAGE" dpkg-query -W -f='${Package}\n' 2>/dev/null \
        | grep -v '^$' || true)
    [[ -n "$STAGE_NAMES" ]] && \
        NEW=$(sudo chroot "$STAGE" apt-get download --print-uris $STAGE_NAMES \
            2>/dev/null | grep -oE 'http[s]?://[^ "]+\.deb' || true)
    URIS="$URIS
$NEW"

    # Belt and braces: d-i's base-installer installs the full "base system" -
    # every package with Priority required or important (the debootstrap
    # minbase set that it computes against the on-CD index) + busybox. Collect
    # those too so the pool never falls short of what base-installer requests.
    log "collecting URIs (required/important set)..."
    BASE_SET=$(sudo chroot "$STAGE" sh -c \
        'apt-cache dumpavail 2>/dev/null \
            | awk "/^Package:/{p=\$2} /^Priority: (required|important)/{print p}"' \
        2>/dev/null | sort -u)
    NEW=$(sudo chroot "$STAGE" apt-get download --print-uris $BASE_SET busybox zstd \
        2>/dev/null | grep -oE 'http[s]?://[^ "]+\.deb' || true)
    URIS="$URIS
$NEW"

    # apt-get download only emits the NAMED package, never its dependencies,
    # and apt's resolver prunes anything already installed inside the stage.
    # So optional-priority helper deps of the (required|important) base set
    # (e.g. libext2fs2t64 and libss2, the Pre-Depends of e2fsprogs) would never
    # reach the pool, and d-i's debootstrap dies at "Unpacking the base
    # system". Compute the FULL Depends/Pre-Depends closure of the base set
    # directly from the archive index (immune to stage state) and fetch each.
    CLOSURE_PY="$WORK_DIR/closure.py"
    if command -v python3 >/dev/null 2>&1; then
        cat > "$CLOSURE_PY" <<'PY'
import sys, re
pk = {}
cur = {}
def flush():
    if cur:
        pk[cur["Package"]] = cur
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        flush(); cur = {}
        continue
    m = re.match(r"^([\w-]+):\s*(.*)", line)
    if m:
        cur[m.group(1)] = m.group(2).strip()
flush()

def bare(a):
    return a.split()[0].split(":")[0]

done = set(p for p, x in pk.items()
           if x.get("Priority") in ("required", "important"))

def satisfied(alts):
    return any(bare(a) in done for a in alts)

q = list(done)
while q:
    n = q.pop()
    pkg = pk.get(n)
    if not pkg:
        continue
    for key in ("Depends", "Pre-Depends"):
        for chunk in pkg.get(key, "").split(", "):
            alts = [a.strip() for a in chunk.split("|") if a.strip()]
            if not alts or satisfied(alts):
                continue
            add = bare(alts[0])
            if add not in done:
                done.add(add)
                q.append(add)
print("\n".join(sorted(done)))
PY
        log "collecting URIs (archive closure of base set)..."
        BASE_CLOSURE=$(sudo chroot "$STAGE" sh -c 'apt-cache dumpavail 2>/dev/null' \
            2>/dev/null | python3 "$CLOSURE_PY") || BASE_CLOSURE=
        if [[ -n "$BASE_CLOSURE" ]]; then
            NEW=$(sudo chroot "$STAGE" apt-get download --print-uris $BASE_CLOSURE \
                2>/dev/null | grep -oE 'http[s]?://[^ "]+\.deb' || true)
            URIS="$URIS
$NEW"
        else
            warn "archive-closure pass returned nothing (python died?)"
        fi
    else
        warn "python3 not installed - skipping archive-closure pass"
    fi

    URIS=$(echo "$URIS" | sed 's|http://deb.debian.org/debian/|http://deb.debian.org/debian/|' \
        | sort -u | grep -v '^$')

    total=$(echo "$URIS" | wc -l)
    log "downloading $total unique debs into pool (resilient, per-file)..."
    mkdir -p "$POOL"
    fails=0
    i=0
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        i=$((i+1))
        # Restore the real pool filename: apt URL-encodes some chars
        # (%3a -> :, %2b -> +). apt-ftparchive + d-i need the dpkg names.
        fname="$(basename "${url%%\#*}" | sed 's/%3a/:/Ig; s/%3A/:/Ig; s/%2b/+/Ig; s/%2B/+/Ig')"
        dest="$POOL/$fname"
        if [[ -s "$dest" ]]; then
            continue
        fi
        if [[ $((i % 25)) -eq 0 ]]; then
            log "  ... $i/$total downloaded"
        fi
        if ! curl -sfL --retry 5 --retry-delay 2 -o "$dest" "$url" \
            || ! dpkg-deb -c "$dest" >/dev/null 2>&1; then
            rm -f "$dest"
            warn "download failed/corrupt: $(basename "$url")"
            fails=$((fails+1))
        fi
    done <<< "$URIS"
    [[ "$fails" -eq 0 ]] || die "pool download incomplete ($fails failures)"
    ok "pool: $(ls "$POOL"/*.deb 2>/dev/null | wc -l) debs ($(du -sh "$POOL" | cut -f1))"
fi

# --- installer udeb pool ---
# anna's cdrom-retriever reads the udeb Packages index and fetches each
# "Filename:" path from /cdrom/<filename>. We mirror the official pool
# layout: pool/main/<letter>/<source>/<file>.udeb  so that Filename:
# entries resolve on the ISO.
log "building installer udeb pool (closures pulled from mirror)..."
UDEB_POOLROOT="$WORK_DIR/udeb-pool"     # top-level (will be copied into ISO /)
mkdir -p "$UDEB_POOLROOT"
UD_DEBINST_COMP="main/debian-installer/binary-$ARCH"

# Download udebs, preserving the official directory structure.
FAILS=0
N=0
while IFS= read -r fn; do
    [[ -n "$fn" ]] || continue
    # fn = "pool/main/a/acl/acl-udeb_..._amd64.udeb"
    dest="$UDEB_POOLROOT/$fn"
    N=$((N+1))
    if [[ -s "$dest" ]]; then
        continue
    fi
    mkdir -p "$(dirname "$dest")"
    if ! curl -sfL --retry 5 --retry-delay 2 -o "$dest" "$MIRROR/$fn"; then
        rm -f "$dest"
        warn "udeb download failed: $fn"
        FAILS=$((FAILS+1))
    fi
done < <(grep '^Filename:' "$UDEB_PKGS" | awk '{print $2}')
[[ "$FAILS" -eq 0 ]] || die "udeb pool incomplete ($FAILS failures)"
UDEB_N=$(find "$UDEB_POOLROOT" -name '*.udeb' 2>/dev/null | wc -l)
ok "udeb pool: $UDEB_N udebs ($(du -sh "$UDEB_POOLROOT" | cut -f1))"

# --- patch apt-cdrom-setup for VirtualBox compatibility -------------
# apt-cdrom add hangs on VirtualBox SATA/IDE CD-ROMs: inside the /target
# chroot it probes for a CD device and blocks waiting for a disc even
# though the CD is already mounted at /cdrom. Replace its 40cdrom
# generator with a direct sources.list writer that never probes devices.
log "patching apt-cdrom-setup/40cdrom (VirtualBox-safe sources.list)..."
CDSETUP_UDEB="$UDEB_POOLROOT/pool/main/a/apt-setup/apt-cdrom-setup_0.198_all.udeb"
CDSETUP_TMP="$WORK_DIR/apt-cdrom-setup.patch"
rm -rf "$CDSETUP_TMP"; mkdir -p "$CDSETUP_TMP/DEBIAN"
dpkg-deb -e "$CDSETUP_UDEB" "$CDSETUP_TMP/DEBIAN" >/dev/null || die "udeb control extract failed"
dpkg-deb -x "$CDSETUP_UDEB" "$CDSETUP_TMP" >/dev/null || die "udeb data extract failed"
cp "$PROJECT_DIR/patches/usr/lib/apt-setup/generators/40cdrom" \
   "$CDSETUP_TMP/usr/lib/apt-setup/generators/40cdrom" || die "patch file missing"
( cd "$CDSETUP_TMP" && find . -type f -not -path './DEBIAN/*' | sort | \
  while read -r f; do printf '%s  %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "${f#./}"; done \
  > DEBIAN/md5sums )
dpkg-deb -Zgzip --build "$CDSETUP_TMP" "$WORK_DIR/apt-cdrom-setup_0.198_all.udeb" >/dev/null \
    || die "udeb rebuild failed"
cp "$WORK_DIR/apt-cdrom-setup_0.198_all.udeb" "$CDSETUP_UDEB" || die "replace udeb failed"
ok "apt-cdrom-setup patched: $(md5sum "$WORK_DIR/apt-cdrom-setup_0.198_all.udeb" | cut -d' ' -f1)"

# --- patch apt-setup-udeb so "Configure the package manager" is SKIPPED -----
# The stock apt-setup main script (/usr/bin/apt-setup) runs every generator
# to completion with NO timeout. A generator that blocks - cdrom/device
# probing, mirror scans with no network - freezes the whole install on
# "Configuring apt / Scanning the mirror / Running setup" and the GRUB
# boot-loader step (grub-installer) is never reached. Replace it with the
# skip variant from patches/usr/bin/apt-setup: it exits 0 immediately (still
# writing the cdrom sources.list line), so d-i jumps straight to pkgsel ->
# grub-installer -> finish. grub-installer fetches grub-pc itself via
# apt-install from /cdrom, so no target-side apt sources are required.
log "patching apt-setup-udeb/usr/bin/apt-setup (skip no-op, auto-fallthrough)..."
SETUP_UDEB="$UDEB_POOLROOT/pool/main/a/apt-setup/apt-setup-udeb_0.198_amd64.udeb"
SETUP_TMP="$WORK_DIR/apt-setup-udeb.patch"
rm -rf "$SETUP_TMP"; mkdir -p "$SETUP_TMP/DEBIAN"
dpkg-deb -e "$SETUP_UDEB" "$SETUP_TMP/DEBIAN" >/dev/null || die "apt-setup udeb control extract failed"
dpkg-deb -x "$SETUP_UDEB" "$SETUP_TMP" >/dev/null || die "apt-setup udeb data extract failed"
cp "$PROJECT_DIR/patches/usr/bin/apt-setup" "$SETUP_TMP/usr/bin/apt-setup" \
    || die "apt-setup patch file missing"
chmod 755 "$SETUP_TMP/usr/bin/apt-setup"
( cd "$SETUP_TMP" && find . -type f -not -path './DEBIAN/*' | sort | \
  while read -r f; do printf '%s  %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "${f#./}"; done \
  > DEBIAN/md5sums )
dpkg-deb -Zgzip --build "$SETUP_TMP" "$WORK_DIR/apt-setup-udeb_0.198_patched_amd64.udeb" >/dev/null \
    || die "apt-setup udeb rebuild failed"
cp "$WORK_DIR/apt-setup-udeb_0.198_patched_amd64.udeb" "$SETUP_UDEB" || die "replace apt-setup udeb failed"
ok "apt-setup udeb patched: $(md5sum "$WORK_DIR/apt-setup-udeb_0.198_patched_amd64.udeb" | cut -d' ' -f1)"

log "=== [5/5] assemble ISO ==="
ISO="$WORK_DIR/iso"
sudo rm -rf "$ISO"
mkdir -p "$ISO/isolinux" "$ISO/install.amd64" "$ISO/pool/main" \
         "$ISO/dists/$SUITE/main/binary-$ARCH" \
         "$ISO/dists/$SUITE/$DEBINST_COMP" \
         "$ISO/.disk"

# Isolinux bootloader
TPL="$PROJECT_DIR/config/bootloaders/isolinux"
cp "$TPL/isolinux.bin" "$TPL/ldlinux.c32" "$TPL/libcom32.c32" \
   "$TPL/libutil.c32" "$TPL/vesamenu.c32" "$ISO/isolinux/"

# d-i kernel + initrd (binaries: linux/initrd.gz; ISO: vmlinuz standard names)
cp "$DLDIR/linux" "$ISO/install.amd64/vmlinuz"
cp "$DLDIR/initrd.gz" "$ISO/install.amd64/initrd.gz"

# Pool (.deb)
cp "$POOL"/*.deb "$ISO/pool/main/"

# Preseed
cp "$PROJECT_DIR/preseed.cfg" "$ISO/preseed.cfg"

# .disk metadata
echo "Custom Debian trixie offline installer - $(date -u +%Y%m%d)" > "$ISO/.disk/info"
touch "$ISO/.disk/base_installable"
echo "main" > "$ISO/.disk/base_components"
echo "full_cd/single" > "$ISO/.disk/cd_type"
# d-i marker: this is a full (netinst) CD layout for anna/cdrom-detect
touch "$ISO/.disk/debian-installer"
touch "$ISO/.disk/mini"

# Disk info for installer
cat > "$ISO/.disk/cdrom_autodetect" <<'EOF'
EOF

# Package index (.deb)
log "generating binary Packages index..."
( cd "$ISO" && apt-ftparchive \
    -o APT::FTPArchive::Architecture="$ARCH" \
    packages pool/main > dists/$SUITE/main/binary-$ARCH/Packages )
gzip -kf "$ISO/dists/$SUITE/main/binary-$ARCH/Packages"

# udeb pool (official pool/ layout so cdrom-retriever resolves Filename: entries).
# MUST be after the binary Packages index above, so apt-ftparchive only indexed .deb.
cp -a "$UDEB_POOLROOT"/pool "$ISO/"

# udeb Packages index (d-i / anna needs this exact path).
# We mirror the official pool layout and downloaded the exact mirror udebs,
# so the authoritative index from the mirror is copied verbatim (its Filename:
# and SHA256 fields match our pool precisely).
log "generating installer udeb Packages index..."
cp "$UDEB_PKGS" "$ISO/dists/$SUITE/$DEBINST_COMP/Packages"

# The patched apt-cdrom-setup and apt-setup-udeb udebs differ from the mirror
# ones, so their Size/MD5sum/SHA hashes in the index must be refreshed or
# anna refuses them.
log "refreshing patched udeb hashes in the udeb Packages index..."
_PPKG="$ISO/dists/$SUITE/$DEBINST_COMP/Packages"
for _PNAME in apt-cdrom-setup apt-setup-udeb; do
    case "$_PNAME" in
        apt-cdrom-setup) _PUD="$ISO/pool/main/a/apt-setup/apt-cdrom-setup_0.198_all.udeb";;
        apt-setup-udeb)  _PUD="$ISO/pool/main/a/apt-setup/apt-setup-udeb_0.198_amd64.udeb";;
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

# Release file
log "generating Release file..."
( cd "$ISO/dists/$SUITE" && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Debian" \
    -o APT::FTPArchive::Release::Label="Debian" \
    -o APT::FTPArchive::Release::Suite="$SUITE" \
    -o APT::FTPArchive::Release::Codename="$SUITE" \
    -o APT::FTPArchive::Release::Architectures="$ARCH" \
    -o APT::FTPArchive::Release::Components="main" \
    -o APT::FTPArchive::Release::Description="Debian trixie offline installer pool" \
    release . > Release )
# Sign the Release (apt uses InRelease); without it apt rejects the cdrom.
( cd "$ISO/dists/$SUITE" \
    && gpg --homedir "$GNUPGHOME" --default-key "$KEYID" --batch --yes \
        --detach-sign --armor -o Release.gpg Release \
    && gpg --homedir "$GNUPGHOME" --default-key "$KEYID" --batch --yes \
        --clear-sign -o InRelease Release ) \
    || die "failed to sign Release file"
cp "$WORK_DIR/cd-archive-keyring.gpg" "$ISO/.disk/cd-archive-keyring.gpg"
mkdir -p "$ISO/dists/$SUITE/main/binary-$ARCH"
cat > "$ISO/dists/$SUITE/main/binary-$ARCH/Release" <<EOF
Archive: $SUITE
Origin: Debian
Label: Debian
Version: 13
Suite: $SUITE
Codename: $SUITE
Date: $(date -Ru)
Architectures: $ARCH
Components: main
Description: Debian trixie offline installer pool
EOF

# Isolinux config
cat > "$ISO/isolinux/isolinux.cfg" <<'ISOLINUX_CFG'
# Debian trixie offline installer
# All questions preseeded - just press Enter or wait for auto-boot.
# Default boots to VGA console. Serial is an option for headless boxes.
#
# NOTE: no `serial 0 115200` here. ISOLINUX hangs in some VMs
# (VirtualBox/VMware without a mapped COM1, qemu without -serial)
# when it initializes the serial port at boot. The serial *kernel*
# entries below still give you ttyS0 output.

default install
prompt 0
timeout 100
ontimeout install

menu title Debian Trixie Offline Installer

label install
    menu label ^Install (default, 10s auto-boot)
    menu default
    kernel /install.amd64/vmlinuz
    append auto=true priority=critical debian-installer/language=en debian-installer/country=IN debian-installer/locale=en_US.UTF-8 locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us netcfg/enable=false preseed/file=/preseed.cfg vga=normal initrd=/install.amd64/initrd.gz --- quiet

label installserial
    menu label Install on ^serial console (ttyS0, headless)
    kernel /install.amd64/vmlinuz
    append auto=true priority=critical debian-installer/language=en debian-installer/country=IN debian-installer/locale=en_US.UTF-8 locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us netcfg/enable=false preseed/file=/preseed.cfg console=ttyS0,115200n8 vga=normal initrd=/install.amd64/initrd.gz --- quiet

label expert
    menu label ^Expert install (interactive, no preseed)
    kernel /install.amd64/vmlinuz
    append priority=low debian-installer/language=en debian-installer/country=IN locale=en_US.UTF-8 vga=normal initrd=/install.amd64/initrd.gz

label expertserial
    menu label Expert install on serial ^(S)
    kernel /install.amd64/vmlinuz
    append priority=low debian-installer/language=en debian-installer/country=IN locale=en_US.UTF-8 console=ttyS0,115200n8 vga=normal initrd=/install.amd64/initrd.gz
ISOLINUX_CFG

# Extract isohdpfx.bin for hybrid ISO
ISOLINUX_DEB="$(ls -t "$PROJECT_DIR"/dl/isolinux_*_all.deb 2>/dev/null | head -1 || true)"
if [[ -z "$ISOLINUX_DEB" ]]; then
    # Download it
    mkdir -p "$WORK_DIR/dl"
    SYS_VER="6.04~git20190206.bf6db5b4+dfsg1-3.1"
    ISOLINUX_DEB="$WORK_DIR/dl/isolinux_${SYS_VER}_all.deb"
    if [[ ! -s "$ISOLINUX_DEB" ]]; then
        log "downloading isolinux package for isohdpfx.bin..."
        curl -sfL -o "$ISOLINUX_DEB" \
            "http://deb.debian.org/debian/pool/main/s/syslinux/isolinux_${SYS_VER}_all.deb" \
            || die "failed to download isolinux deb"
    fi
fi
ISOHDPFX="$WORK_DIR/dl/isohdpfx.bin"
if [[ ! -s "$ISOHDPFX" ]]; then
    dpkg-deb --fsys-tarfile "$ISOLINUX_DEB" \
        | tar -xO ./usr/lib/ISOLINUX/isohdpfx.bin > "$ISOHDPFX" \
        || die "could not extract isohdpfx.bin"
fi

OUT="$PROJECT_DIR/$ISO_NAME"
log "building ISO: $OUT ..."
xorriso -as mkisofs -o "$OUT" \
    -isohybrid-mbr "$ISOHDPFX" \
    -c isolinux/boot.cat -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -iso-level 3 -J -joliet-long \
    -V "$VOLUME" -A "Debian trixie offline installer" \
    -p "Custom build" \
    "$ISO" 2>&1 | tail -3 \
    || die "xorriso failed"

sha256sum "$OUT" | tee "$OUT.sha256" >/dev/null

SIZE=$(du -h "$OUT" | cut -f1)
ok "installer ISO ready: $OUT ($SIZE)"
log "ISO boots into Debian Installer directly (no live system)"
log "All questions preseeded - fully offline install from CD/USB"
