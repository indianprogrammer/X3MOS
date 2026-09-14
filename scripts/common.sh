#!/bin/bash
# Shared helpers for the debian-live SDK.
# Source this file, do not execute it:  source "$(dirname "$0")/common.sh"
#
# Env overrides (all optional):
#   SDK_ISO_NAME     final ISO filename (default: debian-trixie-cli-amd64.hybrid.iso)
#   SDK_BOOT_TIMEOUT seconds to wait for the boot test (default: 420)
#   SDK_QEMU_MEM     RAM (MB) for the boot test VM (default: 2048)

set -euo pipefail

SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SDK_DIR")"

# .config (OpenWrt-style CONFIG_ symbols, see make menuconfig) is the single
# source of truth; explicit SDK_* env vars override it.
if [[ -f "$PROJECT_DIR/.config" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.config"
    set +a
fi

SDK_ISO_NAME="${SDK_ISO_NAME:-${CONFIG_SDK_ISO_NAME:-debian-trixie-cli-amd64.hybrid.iso}}"
SDK_BOOT_TIMEOUT="${SDK_BOOT_TIMEOUT:-${CONFIG_SDK_BOOT_TIMEOUT:-420}}"
SDK_QEMU_MEM="${SDK_QEMU_MEM:-${CONFIG_SDK_QEMU_MEM:-2048}}"

# shellcheck disable=SC2034
BUILD_LOG="$PROJECT_DIR/build.log"
INVOKING_USER="${SUDO_USER:-$(id -un)}"

c_red='\033[0;31m'; c_green='\033[0;32m'; c_yellow='\033[0;33m'; c_blue='\033[0;34m'; c_reset='\033[0m'

log()  { printf "${c_blue}[sdk]${c_reset} %s\n" "$*"; }
ok()   { printf "${c_green}[sdk] OK:${c_reset} %s\n" "$*"; }
warn() { printf "${c_yellow}[sdk] WARN:${c_reset} %s\n" "$*" >&2; }
die()  { printf "${c_red}[sdk] ERROR:${c_reset} %s\n" "$*" >&2; exit 1; }

# Prompt for sudo upfront so a wrong password fails fast instead of mid-build.
sudo_warmup() {
    log "Requesting sudo (cached for this session)..."
    sudo -v || die "sudo authentication failed"
}

# Does the command exist?
have() { command -v "$1" >/dev/null 2>&1; }

# Print usage and exit (used by scripts with --help; each script wires this itself).
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0; }
