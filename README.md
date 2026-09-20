# custom-debian-iso

A build system that produces a **fully offline, fully unattended Debian
"trixie" (13) amd64 installer ISO**. The ISO boots straight into the Debian
Installer (`d-i`) which installs a minimal, offline Debian system from the
disc alone — no network, no mirror, no interaction required.

Unlike a live ISO, this image ships the **installer plus an offline package
pool** (`d-i` netinst style). The installed system is a bare-bones Debian:
base system, Linux kernel, GRUB, offline apt sources, matching user accounts.
It is tested in VirtualBox (VGA and serial console).

---

## Features

- **Boots directly into the Debian Installer** (no live system / squashfs).
- **Fully unattended** when the preseed defaults match your disk layout
  (hostname `X3MOS`, single ENTIRE-disk partition on `/dev/sda`, root/`x3m`
  with password `x3m@root`, English/India/US keyboard, UTC).
  Boot label `auto` runs with `auto=true priority=critical` (zero prompts);
  `install` shows the same questions pre-filled (press Enter to confirm).
- **100% offline**: netcfg disabled, mirror = `cdrom`, apt-setup disabled,
  no tasksel, no pkgsel download from a mirror. Nothing touches the network
  during install or after boot.
- **Offline target**: after install the target's apt sources are replaced
  with an offline stub (no mirror, no cdrom entry), signed for the CD archive
  so `apt-cdrom`/`apt` in the target trust the medium.
- **Credentials on screen**: on the first boot the login credentials
  (host `X3MOS`, users `root` / `x3m`, password `x3m@root`) are printed on
  the console; the system waits for ENTER (VGA **and** serial) and then
  reboots into a clean login prompt. The banner runs once only.
- **`sudo` pre-installed**: user `x3m` is a member of the `sudo` group, so
  `sudo`, `sudo reboot`, `sudo halt`, `sudo poweroff` work for the non-root
  account (root login is also enabled).
- **`xinstall` install menu**: running `xinstall` on the installed system
  opens an interactive menu with **NetworkManager / nmcli** (installed/enabled
  on fresh installs; shows device status + usage hint), **Docker Engine**
  (Docker's apt repository method, per `docs.docker.com`), an **Ookla Speedtest
  Server** (official `ooklaserver.sh` into `/opt/ooklaserver` with a systemd
  auto-start unit, per Srijit Banerjee's guide), or an **ISP CGNAT** (nftables
  NAT44 + ulogd2/rsyslog NAT logging per `cgnat.md`, asking for the public IP
  pool, private IP pool and NATLOG server at install time), or a **BGP
  Router** (FRRouting `frr` with the zebra/bgpd daemons enabled, dropping into
  `vtysh`). Runs as the normal user; elevates via sudo automatically. The menu
  **auto-starts at interactive console login** for `root`/`x3m` (skipped over
  SSH): disable per session with `XINSTALL_SKIP=1` or permanently with
  `touch /etc/xinstall-no-autorun`.
- **Passwordless sudo for xinstall**: the overlay ships a sudoers drop-in
  (`/etc/sudoers.d/xinstall`, mode 0440) granting the `sudo` group NOPASSWD
  for exactly `/usr/local/bin/xinstall` and `/usr/local/lib/xinstall/*` — the
  menu never prompts for a password, but nothing else gains passwordless
  sudo. Because `cp -a` copies the overlay preserving the build host's uid,
  the preseed explicitly `chown root:root`'s `/etc/sudoers.d` on the target —
  otherwise sudo refuses to read a drop-in dir owned by a non-root user.
- **Dual console**: kernel and GRUB are configured for `tty0` (VGA) **and**
  `ttyS0` (serial, 115200 8N1); `serial-getty@ttyS0` is enabled so a headless
  install is observable and usable over a serial cable.
- **NetworkManager owns networking**: `network-manager` is preinstalled
  (preseed + offline pool) and its `NetworkManager` service brings every
  interface up with DHCP at boot and handles `wifi`/ethernet connections;
  `nmcli` is the front-end. `/etc/resolv.conf` is managed by NetworkManager
  (no `systemd-resolved`, so nothing steals DNS). The old
  `dhclient-all.service` was dropped from the `chroot/` overlay so no second
  DHCP client races NetworkManager.
- **Login banner**: the console login prompt shows an `X3M-OS` ASCII-art
  banner from `/etc/issue` (via getty).
- **Target overlay (`chroot/`)**: any file placed under `chroot/` is copied
  verbatim onto the installed system at install time, e.g.
  `chroot/etc/apt/sources.list` → `/etc/apt/sources.list`. This is the
  installer-pipeline equivalent of live-build's `includes.chroot`.
- **VirtualBox-safe apt-cdrom setup**: the installer's `apt-cdrom-setup`
  `40cdrom` generator is patched so it never block-probes the VM's CD
  controller (that freeze was the classic "Scanning the mirror" hang).
- **Disc auto-eject**: at the end of the install the optical disc is ejected
  before the reboot (`/proc/sys/dev/cdrom/autoeject`).

---

## Default credentials

Installed and used by the installer:

| Field          | Value            |
|----------------|------------------|
| Hostname       | `X3MOS`          |
| Domain         | *(empty)*        |
| Root password  | `x3m@root`       |
| User (login)   | `x3m`            |
| User password  | `x3m@root`       |
| User groups    | `sudo` (plus defaults) |
| Keymap         | US English       |
| Timezone       | UTC              |

**In tests/real machines change nothing unless you want these defaults.**

---

## Requirements (build host)

Debian unstable/trixie (or newer) with:

```
debootstrap  xorriso  curl  cpio  apt-ftparchive  dpkg-dev  gpg  python3  sudo  rpm2cpio
```

Install them with:

```sh
sudo apt-get install debootstrap xorriso curl cpio apt-utils dpkg-dev gnupg python3 sudo
```

The ISO actually assembles via the same OpenWrt-style SDK tree (`.config*`,
`feeds*/`, `package/`, `sdk/`, `scripts/`), but the installer ISO itself is
produced by one script.

---

## Building the ISO

```sh
# from the repository root
sudo ./scripts/build-installer.sh
```

Output: `debian-trixie-netinst-amd64.iso` (approx. 370 MB) plus
`.installer-build/` (cached stage, deb pool, udeb pool, ISO staging) for fast
incremental rebuilds.

| Option       | Effect                                              |
|--------------|-----------------------------------------------------|
| `--help`     | Show usage.                                         |
| `--force`    | Discard the cached debootstrap stage and pool and re-resolve/download everything (recommended after changing the installed package list). |

The build:

1. Debootstraps a `trixie` `minbase` stage.
2. Resolves the offline **deb pool** against `deb.debian.org` — the base
   (required/important) set, the kernel/GRUB/networking closure
   (`linux-image-amd64 grub-pc ifupdown iproute2 kmod busybox zstd
   console-setup keyboard-configuration sudo`), plus the full
   dependency closure — and downloads every `.deb`.
3. Resolves **installer udebs** and mirrors them into `pool/main/...`
   preserving the official layout (so `anna`/`cdrom-retriever` can fetch them).
4. Patches `apt-cdrom-setup` for VirtualBox, signs the CD `Release` and
   embeds the keyring + post-base-installer hook.
5. Stamps the fresh `preseed.cfg` into the initrd (`/preseed.cfg`,
   `/etc/preseed.cfg`, `/cdrom/preseed.cfg`) and at the ISO root
   (`/preseed.cfg`), then assembles the ISO with `xorriso` in the official d-i
   CD layout.

### Verify an existing build

```sh
sudo ./scripts/verify.sh          # ISO + pool + archive checks
sudo ./scripts/check.sh           # configuration sanity
```

### Trying it in VirtualBox

- **VGA**: new VM, IDE/SATA disc, mount the ISO, boot label `auto` is default.
- **Serial**: add a serial port, boot `installserial` (or `auto` which already
  uses `console=ttyS0`) and open the serial console at 115200 8N1.
- Expect: install runs to completion, disc ejects, machine reboots, the
  credentials banner appears, ENTER reboots once more into the login prompt.
- Login as `x3m` / `x3m@root` (or `root` / `x3m@root`) and use `sudo`.

---

## How the offline, unattended parts are wired

| Concern                | Place in `preseed.cfg`                                |
|------------------------|-------------------------------------------------------|
| Locale / keymap        | `debian-installer/country`, `keyboard-configuration/*` |
| Host/domain/network    | `netcfg/*` (network disabled: `netcfg/enable false`)    |
| Mirror                 | `mirror/protocol select cdrom`, `apt-setup/*` disabled  |
| Installed files        | `chroot/` overlay (copied onto `/target` by `late_command`) |
| Partitioning           | `partman-auto/*` (`atomic` recipe on first disk)        |
| Accounts               | `passwd/*` (root + `x3m`), forced again by `late_command` `chpasswd` |
| Extra packages (`curl`, `sudo`, DNS/net tools...) | `late_command` `apt-get install` from the mounted CD pool |
| Bootloader             | `grub-installer/*`                                      |
| Disc eject + target offline | `late_command`                                   |
| First-boot banner/ENTER| `late_command` installs `press-to-reboot.service`      |

**Install-time spec** (`debconf/priority critical` + `auto-install/enable`)
drives the unattended path. Every question is either preseeded or marked
`seen true`.

---

## Target system after install

- **Console**: kernel cmdline `console=ttyS0,115200n8 console=tty0`;
  GRUB terminal `console serial`; `serial-getty@ttyS0` enabled.
- **Login banner**: `/etc/issue` shows an `X3M-OS` ASCII-art banner at the
  login prompt (MOTD is disabled: `/etc/motd` is empty and
  `/etc/update-motd.d/10-uname` is a no-op).
- **Network**: `NetworkManager` (preinstalled) owns networking — it brings
  **all** interfaces up with DHCP at boot and manages wifi/ethernet
  connections with `nmcli`; `/etc/resolv.conf` is a plain file that
  NetworkManager fills with the connection's nameservers (`systemd-resolved`
  is not used). The old `dhclient-all.service` overlay was removed.
- **SSH**: `openssh-server` installed and enabled (`ssh.service`); the root
  login drop-in (`chroot/etc/ssh/sshd_config.d/10-rootlogin.conf`) allows
  `PermitRootLogin yes` to match the root-only login design.
- **Kernel is trimmed of GPU/DRM + sound modules**: `build-installer.sh` unpacks
  the pool `linux-image-*` deb, deletes the `drivers/gpu` and `kernel/sound`
  module trees, regenerates the module index (`depmod`) and rebuilds the deb
  (~9 MB saved from the 103 MB kernel). Intended for headless serial-console
  boxes; the boot-time framebuffer console (efifb) is unaffected. Re-run a
  build to trim, or delete `pool/.kernel-trimmed-*` + build to re-trim after a
  kernel update.
- **apt**: offline stub sources by default (`# OFFLINE …` in
  `/etc/apt/sources.list`); override with `chroot/etc/apt/sources.list`
  (the overlay is applied last and therefore wins).
- **First boot**: `press-to-reboot.service` (ordered just before
  `getty.target`) shows the credentials banner on the active console, waits
  for ENTER on VGA and serial, then reboots once into a clean login.

---

## Install menu (`xinstall`)

`chroot/usr/local/bin/xinstall` ships on the installed system and gives a
simple menu to install optional services:

```
$ xinstall
========================================================
              X3M-OS install menu
========================================================

  [1] Install NetworkManager (nmcli,nmtui)  (status: installed)
      Ensures NetworkManager is installed and enabled (preinstalled on
      fresh X3M-OS installs), then shows device status and the main
      nmcli/nmtui commands for managing wifi/ethernet connections.

  [2] Install Docker Engine          (status: not installed)
      Adds Docker's official apt repository, installs docker-ce,
      containerd.io and the compose/buildx plugins, enables the
      service and adds your user to the 'docker' group.
      Guide: https://docs.docker.com/engine/install/debian/

  [3] Install Ookla Speedtest Server (status: not installed)
      Downloads and runs the official ooklaserver.sh, installs the
      daemon under /opt/ooklaserver and registers a systemd unit
      so it auto-starts at boot (listens on TCP 8080).
      Guide: https://srijit.com/ookla-speedtest-server-installation-guide/

  [4] Install ISP CGNAT              (status: not installed)
      Asks for the public IP pool, private IP pool and NATLOG server,
      then installs nftables NAT44 + ulogd2/rsyslog logging with
      conntrack tuning and fq_codel QoS (see cgnat.md).

  [5] Install BGP Router (FRR)     (status: not installed)
      Installs frr, enables the zebra and bgpd daemons, starts
      frr.service and opens vtysh so BGP neighbors and advertised
      networks can be configured interactively.

  [6] Quit
```

- Runs as the normal user (`x3m`) and re-executes itself under sudo for the
  install steps (every option is a system-wide installation).
- **NetworkManager / nmcli** is preinstalled on fresh installs (added to the
  preseed late-command package list and to the offline pool closure in
  `scripts/build-installer.sh`). The menu option (re)installs it if missing,
  enables the `NetworkManager` service and prints `nmcli device status` plus a
  usage hint (wifi scan/connect, connection bring-up, `nmcli`/`nmtui`).
- **Docker** follows the "Install using the apt repository" method: removes
  conflicting packages, adds the GPG key + `docker.sources`, installs
  `docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  docker-compose-plugin`, enables the service and adds `x3m` to the `docker`
  group.
- **Speedtest** follows Srijit Banerjee's guide: `wget` the official script,
  `./ooklaserver.sh install` into `/opt/ooklaserver`, applies the recommended
  `OoklaServer.properties` settings, and registers a `systemd` unit
  (`ooklaserver.service`, the native replacement for the guide's rc.local
  method) so the daemon starts at boot and listens on TCP 8080.
- **BGP** installs FRRouting (`frr` from the live Debian sources — it is
  intentionally NOT part of the preseed/ISO pool, and `frr-pythontools` is
  deliberately excluded because it drags in the whole python3 runtime for vtysh
  tab-completion), enables the `zebra` and `bgpd` daemons in
  `/etc/frr/daemons`, starts `frr.service` and opens `vtysh` for interactive
  BGP configuration (`router bgp <asn>`, `neighbor <ip> remote-as <asn>`,
  advertised networks).
- **CGNAT** follows `cgnat.md` (repo root): at install time it asks for the
  **public IP pool** (CIDR, IP range or single IP), the **private IP pool**
  (the subscribers' source subnet, e.g. `100.64.0.0/10`) and the **NATLOG
  server** (remote syslog receiver `ip[:port]`, UDP). It installs
  `nftables ulogd2 rsyslog iproute2 procps`, applies the conntrack/socket
  tuning from `/etc/sysctl.d/99-isp-cgnat.conf`, installs a `cgnat-qos`
  fq_codel service on every interface, binds the public subnet to the WAN
  interface, programs a full-cone `snat to <range> persistent,fully-random`
  ruleset with a hairpinning rule, and streams one line per new NAT allocation
  to the NATLOG server. A CIDR public pool is expanded to the FULL allocated
  subnet, network through broadcast, with no reserved addresses (e.g.
  `103.69.44.0/25` → `103.69.44.0-103.69.44.127`). Logging uses the reference's
  ulogd2 but wired as an **NFLOG** consumer (packet input) rather than the
  NFCT flow-input that `cgnat.md` specifies: the nftables `log group 1`
  statement hands each new mapping to ulogd2 asynchronously via nfnetlink
  (no per-packet kernel `printk` under load), ulogd2's NFLOG→SYSLOG stack
  (functioning `ulogd_inppkt_NFLOG`, `BASE`, `IFINDEX`, `IP2STR`, `PRINTPKT`,
  `SYSLOG` plugins) emits it on facility `local6`, and rsyslog `omfwd`s the
  `CGNAT_ALLOC: ` lines to the NATLOG server over UDP. The overlay's
  `chroot/etc/tmpfiles.d/ulogd.conf` creates a boot-time `/run/ulog`
  (`0755 ulog:ulog`) so ulogd2 can bind its NFLOG socket before its service
  starts. The NFCT→SYSLOG stack
  of the reference is not runnable on ulogd2 2.0.x (its SYSLOG/PRINTPKT
  output needs `oob.*` keys only the packet-NFLOG input provides); the
  hairpinning rule also lives in postrouting because nftables only allows
  `masquerade` there.
- The pieces live in `chroot/usr/local/bin/xinstall` (menu) and
  `chroot/usr/local/lib/xinstall/` (`lib.sh`, `install-nmcli.sh`,
  `install-docker.sh`, `install-speedtest.sh`, `install-cgnat.sh`,
  `install-bgp.sh`); they are applied via the `chroot/` overlay, so rebuild
  the ISO after changing them.

---

## Customizing the installed system (`chroot/` overlay)

Anything under the repository's `chroot/` directory is copied verbatim onto
the installed root filesystem during installation, after the base install and
after the offline apt defaults — so it also overrides them:

```
chroot/etc/apt/sources.list        ->  /etc/apt/sources.list
chroot/etc/motd                    ->  /etc/motd
chroot/etc/systemd/system/foo.service -> /etc/systemd/system/foo.service
```

- Paths are relative to the target root; ownership/permissions are preserved
  (`cp -a`).
- The tree is embedded into the installer initrd as `/overlay` at build time,
  then `late_command` runs `cp -a /overlay/. /target/`.
- Keep it small — it lives inside the initrd/ISO.
- Rebuild the ISO after changing it: `sudo ./scripts/build-installer.sh`.

---

## Repository layout

```
Makefile                     SDK entry points (world / clean / …)
Config.in / config_trixie.sh SDK configuration (kernel/packages)
.config*                     active configuration snapshots
scripts/
  build-installer.sh         builds the offline installer ISO   <-- main
  build.sh  check.sh  verify.sh  clean.sh  configure.sh ...
  assemble-bootloader.sh     isolinux/grub boot menu assembly
  boot-test.sh               helper to boot-test the ISO
  patch-virtualbox-cdrom.sh  the apt-cdrom 40cdrom fix
preseed.cfg                  the d-i auto-install preseed (all answers)
chroot/                      target overlay: files copied verbatim onto the
                             installed system (`chroot/<path>` -> `/<path>`)
patches/
  usr/share/press-to-reboot/ first-boot credentials banner + systemd unit
  usr/lib/apt-setup/generators/40cdrom  VirtualBox-safe apt-source writer
.installer-build/            build cache (gitignored): stage, pool, iso/
debian-trixie-netinst-amd64.iso  build output (gitignored ISO)
```

---

## Troubleshooting

- **Boot appears stuck at an early systemd line** — the first-boot banner
  unit is ordered so it runs only after the console/keyboard are fully up;
  if you still see no banner after ~5 minutes the unit timed out and the boot
  continued. Check `systemctl status press-to-reboot` after login.
- **`reboot`/`halt` not found for a non-root user** — those live in
  `/usr/sbin`, which only root has on PATH. Only `root` can log in on this
  system (password `x3m@root`), so they are already reachable.
- **`curl https://...` fails with "error setting certificate file"** — the
  CA bundle `ca-certificates` is now part of the extra-package set; if you
  still hit the error, rebuild the ISO (it embeds the updated package list).
- **Cannot log in as root** — root login is enabled (`passwd/root-login
  true`); `late_command` force-sets the `root` and `x3m` passwords with
  `chpasswd`. Password is `x3m@root`.
- **Build fails in the pool step** — make sure the build host has network
  access to `deb.debian.org`; rerun with `--force`.