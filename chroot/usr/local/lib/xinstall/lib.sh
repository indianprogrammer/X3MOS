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