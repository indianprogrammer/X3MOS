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
- **Dual console**: kernel and GRUB are configured for `tty0` (VGA) **and**
  `ttyS0` (serial, 115200 8N1); `serial-getty@ttyS0` is enabled so a headless
  install is observable and usable over a serial cable.
- **All interfaces up with DHCP on boot**: a `dhclient-all.service` (oneshot,
  provided by the `chroot/` overlay) runs `dhclient` on every interface at
  boot, and `systemd-resolved` provides DNS (stub `resolv.conf`).
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

Output: `debian-trixie-netinst-amd64.iso` (approx. 365 MB) plus
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
5. Stamps the `preseed.cfg` into the initrd/filesystem and assembles the ISO
   with `xorriso` in the official d-i CD layout.

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
- **Network**: `dhclient-all.service` brings **all** interfaces up with DHCP
  at boot (runs `/usr/sbin/dhclient`; `/etc/resolv.conf` → systemd stub from
  `systemd-resolved`).
- **SSH**: `openssh-server` installed and enabled (`ssh.service`); the root
  login drop-in (`chroot/etc/ssh/sshd_config.d/10-rootlogin.conf`) allows
  `PermitRootLogin yes` to match the root-only login design.
- **apt**: offline stub sources by default (`# OFFLINE …` in
  `/etc/apt/sources.list`); override with `chroot/etc/apt/sources.list`
  (the overlay is applied last and therefore wins).
- **First boot**: `press-to-reboot.service` (ordered just before
  `getty.target`) shows the credentials banner on the active console, waits
  for ENTER on VGA and serial, then reboots once into a clean login.

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