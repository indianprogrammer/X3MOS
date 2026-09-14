# Shared make bits for the debian-live SDK (OpenWrt-style).
#
#   V=s          verbose build (stream live-build output instead of build.log)
#   SDK_ISO_NAME override the output filename, e.g. make world SDK_ISO_NAME=foo.iso

TOPDIR ?= $(CURDIR)
SCRIPTSDIR := $(TOPDIR)/scripts
BINDIR := $(TOPDIR)/bin/targets/trixie/amd64

ifeq ($(V),s)
export SDK_VERBOSE=1
endif

# Parallel make is not supported by the underlying live-build stages.
.NOTPARALLEL:

# ISO filename from .config (fallback default), overridable from the CLI.
CONFIG_ISO_NAME := $(shell grep -E '^CONFIG_SDK_ISO_NAME=' $(TOPDIR)/.config 2>/dev/null | cut -d'"' -f2)
ifeq ($(CONFIG_ISO_NAME),)
CONFIG_ISO_NAME := debian-trixie-cli-amd64.hybrid.iso
endif
ifdef SDK_ISO_NAME
ISO_NAME := $(SDK_ISO_NAME)
else
ISO_NAME := $(CONFIG_ISO_NAME)
endif
export SDK_ISO_NAME=$(ISO_NAME)
