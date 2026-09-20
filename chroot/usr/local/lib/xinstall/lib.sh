#!/bin/sh
# Shared helpers for the xinstall menu.

# Re-exec under sudo if not root. Every menu option performs a system-wide
# installation, so the whole menu runs elevated.
require_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    exec sudo "$0" "$@"
}

# require <command> [hint]
require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "xinstall: required command '$1' not found${2:+ ($2)}" >&2
        exit 1
    }
}

# online <host> -> true/false
online() {
    getent hosts "$1" >/dev/null 2>&1 \
        || ping -c1 -W2 "$1" >/dev/null 2>&1
}

# term_rows -> number of console rows currently available (fallback 24).
term_rows() {
    if [ -t 0 ] || [ -t 1 ]; then
        stty size 2>/dev/null | awk '{print $1; exit}' 2>/dev/null
    fi
}

# enable_at_boot <unit> [unit ...]
# Start the unit now and - more importantly - make sure it is enabled so it
# comes back up automatically after a reboot. Every service the xinstall menu
# creates must be handed to this helper so it auto-starts at boot.
enable_at_boot() {
    for unit in "$@"; do
        echo "    Enabling '$unit' for automatic start at boot ..."
        if systemctl enable --now "$unit" >/dev/null 2>&1; then
            echo "      -> enabled + started."
        elif systemctl enable "$unit" >/dev/null 2>&1; then
            echo "      -> enabled for boot (not started now, starts when ready)."
        else
            echo "      !! could not enable '$unit' (check 'journalctl -u $unit')."
        fi
    done
}
