#!/bin/bash
# Preflight checks for the debian-live SDK: tools, keyring, disk space, sudo.
#
# Usage: ./sdk/check.sh [--help]
# Exits non-zero if a hard requirement is missing.

source "$(dirname "$0")/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

fail=0

log "Checking required tools..."
for cmd in lb debootstrap xorriso isoinfo file fdisk sha256sum cpio dpkg-deb timeout python3; do
    if have "$cmd"; then
        ok "$cmd found"
    else
        warn "$cmd MISSING"
        fail=1
    fi
done

if have qemu-system-x86_64; then
    ok "qemu-system-x86_64 found (boot test available)"
else
    warn "qemu-system-x86_64 missing (only needed for sdk/boot-test.sh; install: sudo apt-get install qemu-system-x86)"
fi

if [[ -f /usr/share/debootstrap/scripts/trixie ]]; then
    ok "debootstrap knows trixie"
else
    warn "debootstrap has no trixie script"
    fail=1
fi

if [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
    ok "Debian archive keyring present"
else
    log "Installing debian-archive-keyring (needed to verify trixie packages)..."
    sudo apt-get install -y debian-archive-keyring \
        || { warn "could not install debian-archive-keyring"; fail=1; }
fi

free_gb=$(df -BG "$PROJECT_DIR" | awk 'NR==2 {print $4}' | tr -dc '0-9')
if [[ "$free_gb" -ge 12 ]]; then
    ok "disk space: ${free_gb}G free"
else
    warn "only ${free_gb}G free (recommend 12G+)"
    fail=1
fi

if [[ "$(uname -m)" == "x86_64" ]]; then
    ok "host arch: x86_64"
else
    warn "host arch is $(uname -m), images target amd64 (native build preferred)"
fi

sudo -n true 2>/dev/null && ok "sudo cached" || log "sudo will prompt when needed"

if [[ "$fail" -ne 0 ]]; then
    die "preflight FAILED - fix the items above and re-run"
fi
ok "preflight passed"
