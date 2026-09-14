#!/bin/bash
# One-command end-to-end builder for the Debian trixie CLI live ISO.
#
# Usage: ./sdk/build.sh [--help] [--no-verify] [--no-test]
#
# Pipeline: check -> clean -> configure (lb config + feeds install +
#           package sync/check) -> lb build -> finalize -> verify -> boot-test.
# The finished ISO lands in the project dir as $SDK_ISO_NAME (default:
# debian-trixie-cli-amd64.hybrid.iso) and is hardlinked into bin/.
# Customize: make menuconfig (options + package selection with dependency
# checks), layers/local/ for extra files, config_trixie.sh for raw options.

source "$(dirname "$0")/common.sh"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; fi

DO_VERIFY=1
DO_TEST=1
for arg in "$@"; do
    case "$arg" in
        --no-verify) DO_VERIFY=0 ;;
        --no-test) DO_TEST=0 ;;
        *) die "unknown flag: $arg (see --help)" ;;
    esac
done

cd "$PROJECT_DIR"
sudo_warmup

# The build takes a long time; keep the sudo timestamp fresh for the whole
# run so later steps never block on a password prompt. Killed on exit.
( while true; do sleep 50; sudo -v; done ) &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true' EXIT

log "=== [1/6] preflight ==="
"$SDK_DIR/check.sh"

log "=== [2/6] clean ==="
"$SDK_DIR/clean.sh"

log "=== [3/6] configure ==="
"$SDK_DIR/configure.sh"

log "=== [4/6] build (log: build.log, this takes a while) ==="
set +e
if [[ "${SDK_VERBOSE:-0}" == "1" ]]; then
    sudo lb build 2>&1 | tee build.log
    rc=${PIPESTATUS[0]}
else
    sudo lb build > build.log 2>&1
    rc=$?
fi
set -e
if [[ "$rc" -eq 0 ]]; then
    ok "lb build finished"
else
    warn "lb build failed (exit $rc) - last lines of build.log:"
    tail -n 25 build.log
    die "build failed; inspect build.log, fix, and re-run (caches make retries fast)"
fi

log "=== [5/6] finalize ==="
[[ -f binary.hybrid.iso ]] || die "expected binary.hybrid.iso not produced (see build.log)"
mv -f binary.hybrid.iso "$SDK_ISO_NAME"
sudo chown "$INVOKING_USER" "$SDK_ISO_NAME"
sha256sum "$SDK_ISO_NAME" | tee "$SDK_ISO_NAME.sha256"
ok "released: $PROJECT_DIR/$SDK_ISO_NAME"

if [[ "$DO_VERIFY" -eq 1 ]]; then
    log "=== [6/6] verify ==="
    "$SDK_DIR/verify.sh" "$PROJECT_DIR/$SDK_ISO_NAME"
fi

if [[ "$DO_TEST" -eq 1 ]]; then
    log "=== [7/7] boot test ==="
    "$SDK_DIR/boot-test.sh" "$PROJECT_DIR/$SDK_ISO_NAME"
fi

ok "ALL DONE: $PROJECT_DIR/$SDK_ISO_NAME"
