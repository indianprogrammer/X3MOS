# debian-live SDK - OpenWrt-style frontend.
#
#   make help         this list (default target)
#   make menuconfig   interactively edit .config (whiptail UI)
#   make defconfig    reset .config to defaults
#   make oldconfig    add new symbols to .config, keep values
#   make check        host preflight checks
#   make download     fetch bootloader blobs into dl/
#   make feeds-update / feeds-install / feeds-list / feeds-clean
#   make clean        lb clean + stale-mount detach (keeps config, caches, ISOs)
#   make dirclean     clean + drop caches/build dirs/bin (keeps .config, layers, dl)
#   make configure    generate config tree + install feeds (asserts options)
#   make world        full pipeline to a boot-tested ISO in bin/
#   make image        build the ISO only (no verify/boot-test)
#   make package-list / package-add P= / package-del P= / package-check
#                     select/deselect trixie packages with dependency checks
#   make package-db   (re)build the local trixie package index
#   make os-list / os-add P= / os-del P= / os-check
#                     keep/remove OS-internal packages (base/live/kernel/...)
#   make verify       structural checks of the finished ISO
#   make boot-test    boot the finished ISO in qemu, check for login prompt
#
#   make world V=s             verbose build output
#   make world SDK_ISO_NAME=x  override output filename
#
# Customize: edit layers/local/ (package-lists, hooks, includes.*) and/or
# run make menuconfig, then make world. Unlike OpenWrt, the default target
# is `help`, not `world` (a full build takes ~30 min).

include $(CURDIR)/include/sdk.mk

.PHONY: help menuconfig defconfig oldconfig check download \
	feeds-update feeds-install feeds-list feeds-clean \
	package-list package-add package-del package-check package-db \
	os-list os-add os-del os-check \
	clean dirclean configure world image verify boot-test

help:
	@echo "debian-live SDK targets:"
	@echo "  menuconfig    interactively edit .config"
	@echo "  defconfig     reset .config to defaults"
	@echo "  oldconfig     sync new symbols into .config"
	@echo "  check         host preflight checks"
	@echo "  download      fetch bootloader blobs into dl/"
	@echo "  feeds-update  refresh feed sources (git pulls)"
	@echo "  feeds-install merge feeds (layers) into the config tree"
	@echo "  feeds-list    show feeds and status"
	@echo "  feeds-clean   drop checked-out git feeds"
	@echo "  clean         lb clean + stale-mount detach (keeps config/caches/ISOs)"
	@echo "  dirclean      clean + drop caches, build dirs and bin/ output"
	@echo "  configure     generate config tree + install feeds"
	@echo "  world         full pipeline to a boot-tested ISO in bin/"
	@echo "  image         build the ISO only (expects configured tree)"
	@echo "  package-list  show selected packages"
	@echo "  package-add   select package(s): make package-add P=\"htop vim\""
	@echo "  package-del   deselect package(s): make package-del P=htop"
	@echo "  package-check verify selection (unknown/conflicts/unsatisfiable)"
	@echo "  package-db    (re)build the local trixie package index"
	@echo "  os-list       show OS-internal packages (base/live/kernel/...)"
	@echo "  os-add        keep OS package(s): make os-add P=\"firmware-iwlwifi\""
	@echo "  os-del        remove OS package(s): make os-del P=live-boot-doc"
	@echo "  os-check      verify OS removals (boot guards + broken deps)"
	@echo "  verify        structural checks of the finished ISO"
	@echo "  boot-test     boot the ISO in qemu, expect a login prompt"
	@echo ""
	@echo "Options: V=s (verbose), SDK_ISO_NAME=<name> (output filename)"
	@echo "Customize: layers/local/ + make menuconfig, then make world"

menuconfig:
	$(SCRIPTSDIR)/menuconfig

defconfig:
	$(SCRIPTSDIR)/kconfig defconfig

oldconfig:
	$(SCRIPTSDIR)/kconfig oldconfig

.config:
	$(SCRIPTSDIR)/kconfig defconfig

check:
	$(SCRIPTSDIR)/check.sh

download:
	$(SCRIPTSDIR)/assemble-bootloader.sh

feeds-update:
	$(SCRIPTSDIR)/feeds update -a

feeds-install:
	$(SCRIPTSDIR)/feeds install -a

feeds-list:
	$(SCRIPTSDIR)/feeds list

feeds-clean:
	$(SCRIPTSDIR)/feeds clean

clean:
	$(SCRIPTSDIR)/clean.sh

dirclean: clean
	sudo rm -rf cache chroot binary .build bin package feeds .feeds.manifest \
		build.log build.log.prev source tftpboot
	@echo "dirclean done (kept: .config, layers/, dl/, config/, scripts/, *.iso)"

configure:
	$(SCRIPTSDIR)/configure.sh

# Full pipeline (build.sh does check/clean/configure/build/finalize).
world: .config image verify boot-test
	@echo "WORLD DONE: $(BINDIR)/$(ISO_NAME)"

image:
	$(SCRIPTSDIR)/build.sh --no-verify --no-test
	mkdir -p $(BINDIR)
	ln -f $(TOPDIR)/$(ISO_NAME) $(BINDIR)/$(ISO_NAME) 2>/dev/null || \
		cp $(TOPDIR)/$(ISO_NAME) $(BINDIR)/$(ISO_NAME)
	ln -f $(TOPDIR)/$(ISO_NAME).sha256 $(BINDIR)/$(ISO_NAME).sha256 2>/dev/null || \
		cp $(TOPDIR)/$(ISO_NAME).sha256 $(BINDIR)/$(ISO_NAME).sha256 || true

verify:
	$(SCRIPTSDIR)/verify.sh $(TOPDIR)/$(ISO_NAME)

boot-test:
	$(SCRIPTSDIR)/boot-test.sh $(TOPDIR)/$(ISO_NAME)

package-list:
	$(SCRIPTSDIR)/package list

package-add:
	@[ -n "$(P)" ] || (echo "usage: make package-add P=<pkg> [more...]"; exit 1)
	$(SCRIPTSDIR)/package add $(P)

package-del:
	@[ -n "$(P)" ] || (echo "usage: make package-del P=<pkg> [more...]"; exit 1)
	$(SCRIPTSDIR)/package del $(P)

package-check:
	$(SCRIPTSDIR)/package check

package-db:
	$(SCRIPTSDIR)/package updatedb

os-list:
	$(SCRIPTSDIR)/package os-list

os-add:
	@[ -n "$(P)" ] || (echo "usage: make os-add P=<pkg> [more...]"; exit 1)
	$(SCRIPTSDIR)/package os-add $(P)

os-del:
	@[ -n "$(P)" ] || (echo "usage: make os-del P=<pkg> [more...]"; exit 1)
	$(SCRIPTSDIR)/package os-del $(P)

os-check:
	$(SCRIPTSDIR)/package os-check
