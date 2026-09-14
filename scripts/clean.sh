#!/bin/bash
# Safe clean of the live-build working tree.
#
# Usage: ./sdk/clean.sh [--help]
#
# Runs `lb clean` (keeps config/ and the .deb caches in cache/ so rebuilds
# are fast, and keeps any already-built *.iso), then detaches any stale
# bind mounts left under chroot/ (plain umount often reports "busy" because
# of leaked file descriptors, so lazy detach is used), and finally locks
# chroot/ and cache/ to root-only access so background file indexers can
# never open files under a mounted sysfs and pin future unmounts.

source "$(dirname "$0")/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

cd "$PROJECT_DIR"

log "Running lb clean (keeps config/, cache/*.deb and released ISOs)..."
sudo lb clean

log "Detaching stale mounts under chroot/ ..."
proj_pat="$(basename "$PROJECT_DIR" | sed 's/[^A-Za-z0-9_-]/./g')"
for mnt in $(mount | awk -v pat="$proj_pat/chroot" '$3 ~ pat {print $3}' | sort -r); do
    log "lazy-detaching $mnt"
    sudo umount -l "$mnt" || true
done
if mount | grep -q "$proj_pat/chroot"; then
    warn "some mounts under chroot/ remain (check: mount | grep chroot)"
else
    ok "no mounts under chroot/"
fi

log "Locking down chroot/ and cache/ (root-only, keeps indexers out)..."
sudo mkdir -p chroot cache
sudo chown -R root:root chroot cache
sudo chmod 700 chroot cache

# Rotate the previous build log instead of silently overwriting it.
if [[ -f build.log ]]; then
    mv -f build.log build.log.prev
    log "previous build.log -> build.log.prev"
fi

ok "clean done"
