#!/bin/bash
# Verify a built hybrid ISO: structure, MBR, volume metadata.
#
# Usage: ./sdk/verify.sh [--help] [iso-file]
# Defaults to $SDK_ISO_NAME in the project dir.

source "$(dirname "$0")/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

ISO="${1:-$PROJECT_DIR/$SDK_ISO_NAME}"
[[ -f "$ISO" ]] || die "ISO not found: $ISO"

log "Verifying $ISO ..."

file_out="$(file -b "$ISO")"
echo "  file: $file_out"
[[ "$file_out" == *"ISO 9660"* ]] || die "not an ISO 9660 image"
[[ "$file_out" == *"DOS/MBR boot sector"* ]] || die "no hybrid MBR (not USB-bootable)"

if fdisk -l "$ISO" 2>/dev/null | grep -qE '\*.*(Hidden HPFS|W95 FAT|EFI)'; then
    ok "partition table has bootable entry"
else
    fdisk -l "$ISO" 2>/dev/null | head -8
    die "no bootable partition entry found"
fi

vol="$(isoinfo -d -i "$ISO" 2>/dev/null | awk -F': ' '/Volume id/{print $2}')"
[[ -n "$vol" ]] || die "could not read ISO volume id"
ok "volume id: $vol"

size="$(stat -c%s "$ISO")"
[[ "$size" -gt 100000000 ]] || die "ISO suspiciously small ($size bytes)"
ok "size: $((size / 1024 / 1024)) MB"

ok "verify passed: $ISO"
