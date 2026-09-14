#!/bin/bash
# Boot-test a built ISO in qemu using the serial console.
#
# Usage: ./sdk/boot-test.sh [--help] [iso-file]
# Defaults to $SDK_ISO_NAME in the project dir.
# Needs: qemu-system-x86_64, xorriso. KVM is used if available, else TCG.
# Pass mark: kernel boots, live system reaches multi-user.target and shows
# a login prompt on the serial console.

source "$(dirname "$0")/common.sh"
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

ISO="${1:-$PROJECT_DIR/$SDK_ISO_NAME}"
[[ -f "$ISO" ]] || die "ISO not found: $ISO"
have qemu-system-x86_64 || die "qemu-system-x86_64 missing (sudo apt-get install qemu-system-x86)"
have xorriso || die "xorriso missing"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

log "Extracting kernel + initrd from ISO..."
xorriso -osirrox on -indev "$ISO" \
    -extract /live/vmlinuz "$TMPD/vmlinuz" \
    -extract /live/initrd.img "$TMPD/initrd.img" >/dev/null 2>&1 \
    || die "could not extract /live/{vmlinuz,initrd.img} from $ISO"

ACCEL=""
[[ -e /dev/kvm ]] && ACCEL="-enable-kvm" || log "no /dev/kvm, using TCG emulation (slower)"

log "Booting (timeout ${SDK_BOOT_TIMEOUT}s, serial log: $TMPD/console.log)..."
# shellcheck disable=SC2086
timeout "$SDK_BOOT_TIMEOUT" qemu-system-x86_64 \
    -m "$SDK_QEMU_MEM" -smp 2 $ACCEL \
    -kernel "$TMPD/vmlinuz" -initrd "$TMPD/initrd.img" \
    -append "boot=live console=ttyS0,115200n8" \
    -cdrom "$ISO" -boot d \
    -display none -serial "file:$TMPD/console.log" -no-reboot \
    >/dev/null 2>&1 || true   # timeout(124) is expected: the VM idles at login

# The console carries ANSI color/motion sequences, so strip them (and CRs)
# before matching, otherwise "multi-user.target" etc. never match literally.
sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][0-9A-B]//g' -e 's/\r//g' \
    "$TMPD/console.log" > "$TMPD/clean.log" 2>/dev/null || true

pass=0
grep -q "Reached target multi-user.target" "$TMPD/clean.log" 2>/dev/null && pass=$((pass + 1))
grep -q " login: " "$TMPD/clean.log" 2>/dev/null && pass=$((pass + 1))

if [[ "$pass" -eq 2 ]]; then
    ok "boot test PASSED (multi-user.target reached, login prompt shown)"
    grep -a "Debian GNU/Linux.*ttyS0" "$TMPD/console.log" | tail -1
else
    warn "boot test FAILED - last console lines:"
    tail -n 20 "$TMPD/clean.log"
    die "boot test failed (see above)"
fi
