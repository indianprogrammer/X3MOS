#!/bin/bash
# Install Docker Engine on Debian from Docker's official apt repository.
#
# Reference: https://docs.docker.com/engine/install/debian/
# Follows the "Install using the apt repository" method: adds the GPG key,
# configures the docker.sources entry, installs docker-ce + the plugins,
# enables the service and grants the invoking user docker-group access.

set -euo pipefail

LIB=/usr/local/lib/xinstall
[ -r "$LIB/lib.sh" ] && . "$LIB/lib.sh" || exit 1
require_root

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

require curl 'apt-get install curl'
export DEBIAN_FRONTEND=noninteractive

say ""
say "==> Docker Engine installation (Docker apt repository method)"
say ""

online download.docker.com || die "no network to download.docker.com - check the connection"

# 1. Uninstall any unofficial/conflicting Docker packages (docker.io,
#    docker-compose, docker-doc, docker-buildx, podman-docker, containerd, runc).
say "==> Removing any unofficial/conflicting Docker packages ..."
CONFLICTS="$(dpkg --get-selections docker.io docker-compose docker-doc \
    docker-buildx podman-docker containerd runc 2>/dev/null | awk '{print $1}')"
if [ -n "$CONFLICTS" ]; then
    apt-get -y purge $CONFLICTS || die "could not remove conflicting packages"
else
    say "    none found."
fi

# 2. Prerequisites.
say "==> Installing prerequisites (ca-certificates curl) ..."
apt-get update || die "apt-get update failed (check apt sources)"
apt-get -y install ca-certificates curl || die "could not install prerequisites"

# 3. Docker GPG key.
say "==> Adding Docker's GPG key ..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    || die "failed to fetch Docker GPG key"
chmod a+r /etc/apt/keyrings/docker.asc

# 4. Docker apt repository.
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"
say "==> Adding Docker apt repository ($CODENAME/$ARCH) ..."
mkdir -p /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $CODENAME
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# 5. Install the Docker packages.
say "==> Installing docker-ce docker-ce-cli containerd.io buildx compose ..."
apt-get update || die "apt-get update failed against docker repo"
apt-get -y install docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    || die "could not install docker packages"

# 6. Start and enable the service.
say "==> Enabling and starting the docker service ..."
systemctl enable --now docker || die "could not start docker service"

# 7. Non-root access (Linux post-install step).
SUDO_USER="${SUDO_USER:-}"
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ] && id "$SUDO_USER" >/dev/null 2>&1; then
    usermod -aG docker "$SUDO_USER"
    say "==> User '$SUDO_USER' added to the 'docker' group (re-login to take effect)."
fi

# 8. Verify.
say ""
say "==> Verifying with the hello-world image ..."
if docker run --rm hello-world >/dev/null 2>&1; then
    say "    hello-world ran successfully."
else
    say "    hello-world did not run (image pull needs internet/registry access)."
    say "    Docker itself is installed; check 'systemctl status docker' and"
    say "    'docker info'."
fi

say ""
say "Docker Engine installed and enabled:"
say "   docker version            docker info"
say "   docker compose version    docker run hello-world"
say ""
say "If 'docker ps' reports a permission error, log out and back in so the"
say "docker group membership from this install takes effect."
exit 0