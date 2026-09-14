#!/bin/sh
# Live-build configuration for the Debian trixie CLI live ISO.
# Values come from .config (CONFIG_SDK_* symbols, see Config.in and
# `make menuconfig`); every default below reproduces the validated build.
set -e

_HERE="$(dirname "$0")"
if [ -f "${_HERE}/.config" ]; then
	# shellcheck disable=SC1091
	. "${_HERE}/.config"
fi

_DISTRIBUTION="${CONFIG_SDK_DISTRO:-trixie}"
_MIRROR="${CONFIG_SDK_MIRROR:-http://deb.debian.org/debian/}"
_MIRROR_SECURITY="${CONFIG_SDK_MIRROR_SECURITY:-http://deb.debian.org/debian-security/}"

# Kconfig booleans (y / not-set) -> live-build booleans (true / false).
_SECURITY="false"
_VOLATILE="false"
[ "${CONFIG_SDK_SECURITY:-}" = "y" ] && _SECURITY="true"
[ "${CONFIG_SDK_VOLATILE:-}" = "y" ] && _VOLATILE="true"

# OS-internal removals (.config.os-packages) -> debootstrap --exclude.
# `lb config` has no --bootstrap-exclude flag; it records $LB_BOOTSTRAP_EXCLUDE
# from the environment into config/bootstrap, so compute and export it here
# (in-process, so it also survives the `sudo ./config_trixie.sh` in configure.sh,
# which would strip a caller-side export). Chroot-side removals are handled by
# config/hooks/0910-os-purge.chroot (written by `scripts/package sync`).
_OS_EXCLUDE=""
if [ -f "${_HERE}/.config.os-packages" ]; then
	_OS_EXCLUDE="$(grep -E '^# CONFIG_OS_.+ is not set' "${_HERE}/.config.os-packages" 2>/dev/null \
		| sed 's/^# CONFIG_OS_//; s/ is not set$//' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
fi
# Combine with a pre-existing environment value (if any), then normalize.
LB_BOOTSTRAP_EXCLUDE="${LB_BOOTSTRAP_EXCLUDE:-} ${_OS_EXCLUDE}"
LB_BOOTSTRAP_EXCLUDE="$(printf '%s' "$LB_BOOTSTRAP_EXCLUDE" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')"
export LB_BOOTSTRAP_EXCLUDE

lb config noauto \
  --mode debian \
  --distribution "${_DISTRIBUTION}" \
  --archive-areas "main contrib non-free non-free-firmware" \
  --mirror-bootstrap "${_MIRROR}" \
  --mirror-chroot "${_MIRROR}" \
  --mirror-binary "${_MIRROR}" \
  --mirror-chroot-security "${_MIRROR_SECURITY}" \
  --mirror-binary-security "${_MIRROR_SECURITY}" \
  --parent-distribution "${_DISTRIBUTION}" \
  --parent-archive-areas "main contrib non-free non-free-firmware" \
  --parent-mirror-bootstrap "${_MIRROR}" \
  --parent-mirror-chroot "${_MIRROR}" \
  --parent-mirror-chroot-security "${_MIRROR_SECURITY}" \
  --parent-mirror-binary "${_MIRROR}" \
  --parent-mirror-binary-security "${_MIRROR_SECURITY}" \
  --binary-images iso-hybrid \
  --cache-stages "none" \
  --security "${_SECURITY}" \
  --volatile "${_VOLATILE}" \
  --linux-packages "linux-image" \
  --linux-flavours "${CONFIG_SDK_FLAVOUR:-amd64}" \
  --initsystem "${CONFIG_SDK_INITSYSTEM:-systemd}" \
  --bootloader "${CONFIG_SDK_BOOTLOADER:-syslinux}" \
  --syslinux-theme live-build \
  --memtest "${CONFIG_SDK_MEMTEST:-none}" \
  --iso-volume "${CONFIG_SDK_ISO_VOLUME:-Debian-Live-Trixie-CLI}" \
  --iso-application "${CONFIG_SDK_ISO_APPLICATION:-Debian Trixie Live (CLI, no GUI)}" \
  --iso-publisher "Custom Debian Live build" \
  --iso-preparer "live-build" \
  "$@"
