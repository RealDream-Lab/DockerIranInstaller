#!/bin/bash

# ============================================================
# Docker CE Installation for Ubuntu 24.04
# Optimized for Iranian VPS
#
# - System update & full-upgrade
# - Base CLI packages (mc, unzip, htop, ...)
# - DNS: Shecan
# - Docker CE: Official Docker APT Repository
# - Docker Compose Plugin
# - Docker Buildx
# - Docker Registry Mirror: ArvanCloud
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

ARVAN_DOCKER_MIRROR="https://docker.arvancloud.ir"

# Shecan DNS
DNS1="178.22.122.100"
DNS2="185.51.200.2"

# Base packages to install before Docker setup.
# Remove/add as you like.
BASE_PACKAGES=(
    mc              # Midnight Commander - file manager
    unzip           # extract .zip archives
    zip             # create .zip archives
    curl            # HTTP client / downloads
    wget            # downloads
    htop            # interactive process monitor
    git             # version control
    net-tools       # netstat, ifconfig, etc.
    tree            # directory tree viewer
    ncdu            # interactive disk usage analyzer
    tmux            # terminal multiplexer (keep sessions alive)
    rsync           # file sync / backup
    jq              # JSON processor for shell scripts
    ufw             # simple firewall (installed but NOT enabled)
    fail2ban        # brute-force protection for SSH
    ca-certificates
    gnupg
    lsb-release
    apt-transport-https
    software-properties-common
)

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

cleanup() {
    if [[ -f /tmp/docker-install.lock ]]; then
        rm -f /tmp/docker-install.lock
    fi
}

trap cleanup EXIT

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    error "این اسکریپت باید با root اجرا شود."
fi

touch /tmp/docker-install.lock

export DEBIAN_FRONTEND=noninteractive

log "Starting server setup & Docker installation..."

# ------------------------------------------------------------
# 1. Check Ubuntu
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    error "Cannot detect operating system."
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    error "این اسکریپت فقط برای Ubuntu طراحی شده است."
fi

if [[ "${VERSION_ID}" != "24.04" ]]; then
    warning "این اسکریپت برای Ubuntu 24.04 طراحی شده است."
    warning "Detected version: ${VERSION_ID}"
fi

ARCH=$(dpkg --print-architecture)

log "Ubuntu version: ${VERSION_ID}"
log "Architecture: ${ARCH}"

# ------------------------------------------------------------
# 2. Configure DNS
# ------------------------------------------------------------

log "Configuring DNS..."

# Backup current resolv.conf
if [[ -f /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf /etc/resolv.conf.docker-backup 2>/dev/null || true
fi

# Check whether resolv.conf is symlinked to systemd-resolved
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then

    log "systemd-resolved detected."

    mkdir -p /etc/systemd/resolved.conf.d

    cat > /etc/systemd/resolved.conf.d/docker-dns.conf <<EOF
[Resolve]
DNS=${DNS1} ${DNS2}
FallbackDNS=1.1.1.1 8.8.8.8
EOF

    systemctl restart systemd-resolved

else

    log "systemd-resolved is not active."

    # Only replace resolv.conf if it is a normal file.
    if [[ ! -L /etc/resolv.conf ]]; then
        cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
nameserver 1.1.1.1
EOF
    else
        warning "/etc/resolv.conf is managed by another service."
        warning "Skipping direct modification."
    fi

fi

# ------------------------------------------------------------
# 3. Update APT & full-upgrade
# ------------------------------------------------------------

log "Updating APT package lists..."
apt-get update -qq || error "apt update failed."

log "Running full-upgrade (this may take a while)..."
apt-get full-upgrade -y || error "apt full-upgrade failed."

# ------------------------------------------------------------
# 4. Install base packages & prerequisites
# ------------------------------------------------------------

log "Installing base packages: ${BASE_PACKAGES[*]}"
apt-get install -y "${BASE_PACKAGES[@]}" || error "Base package installation failed."

# ------------------------------------------------------------
# 5. Remove conflicting Docker packages
# ------------------------------------------------------------

log "Checking for conflicting Docker packages..."

CONFLICTING_PACKAGES="docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc"

INSTALLED_CONFLICTS=""

for package in ${CONFLICTING_PACKAGES}; do
    if dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q "install ok installed"; then
        INSTALLED_CONFLICTS="${INSTALLED_CONFLICTS} ${package}"
    fi
done

if [[ -n "${INSTALLED_CONFLICTS}" ]]; then
    warning "Removing conflicting packages:${INSTALLED_CONFLICTS}"

    apt-get remove -y ${INSTALLED_CONFLICTS}
else
    log "No conflicting Docker packages found."
fi

# ------------------------------------------------------------
# 6. Add Docker official GPG key
# ------------------------------------------------------------

log "Installing Docker official GPG key..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc \
    || error "Failed to download Docker GPG key."

chmod a+r /etc/apt/keyrings/docker.asc

# ------------------------------------------------------------
# 7. Add Docker official repository
# ------------------------------------------------------------

log "Configuring official Docker repository..."

DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${DOCKER_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# ------------------------------------------------------------
# 8. Update APT
# ------------------------------------------------------------

log "Updating APT with Docker repository..."

apt-get update -qq || error "apt update after adding Docker repository failed."

# ------------------------------------------------------------
# 9. Install Docker CE
# ------------------------------------------------------------

log "Installing Docker CE..."

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    || error "Docker installation failed."

# ------------------------------------------------------------
# 10. Enable Docker
# ------------------------------------------------------------

log "Enabling Docker service..."

systemctl enable docker
systemctl enable containerd

systemctl restart containerd
systemctl restart docker

sleep 3

if ! systemctl is-active --quiet docker; then
    error "Docker service is not running."
fi

success "Docker service is running."

# ------------------------------------------------------------
# 11. Configure Docker Registry Mirror
# ------------------------------------------------------------

log "Configuring Docker Registry Mirror..."

mkdir -p /etc/docker

# Backup existing daemon.json
if [[ -f /etc/docker/daemon.json ]]; then
    cp /etc/docker/daemon.json \
       "/etc/docker/daemon.json.backup.$(date +%Y%m%d-%H%M%S)"
fi

cat > /etc/docker/daemon.json <<EOF
{
    "registry-mirrors": [
        "${ARVAN_DOCKER_MIRROR}"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
EOF

# ------------------------------------------------------------
# 12. Validate daemon configuration
# ------------------------------------------------------------

log "Validating Docker daemon configuration..."

dockerd --validate 2>/dev/null || \
    warning "Docker daemon configuration validation command is unavailable."

# ------------------------------------------------------------
# 13. Restart Docker
# ------------------------------------------------------------

log "Restarting Docker..."

systemctl daemon-reload
systemctl restart docker

sleep 3

if ! systemctl is-active --quiet docker; then
    error "Docker failed to start after daemon configuration."
fi

# ------------------------------------------------------------
# 14. Verify Docker
# ------------------------------------------------------------

log "Checking Docker version..."

docker --version

echo ""

log "Checking Docker Compose..."

docker compose version

echo ""

log "Checking Docker Buildx..."

docker buildx version

# ------------------------------------------------------------
# 15. Check Docker Registry Mirror
# ------------------------------------------------------------

echo ""
log "Docker registry configuration:"

docker info 2>/dev/null | sed -n '/Registry Mirrors:/,/Live Restore Enabled/p' || true

# ------------------------------------------------------------
# 16. Test Docker
# ------------------------------------------------------------

echo ""
log "Testing Docker with hello-world..."

if docker run --rm hello-world >/tmp/docker-hello-world.log 2>&1; then

    success "Docker image pull and container execution successful."

else

    warning "hello-world test failed."

    echo ""
    echo "Docker output:"
    cat /tmp/docker-hello-world.log

    echo ""

    warning "ممکن است Mirror آروان در این لحظه در دسترس نباشد."
    warning "خود Docker نصب شده است ولی Pull تست ناموفق بوده."
fi

# ------------------------------------------------------------
# 17. Cleanup & reboot check
# ------------------------------------------------------------

log "Cleaning up unused packages..."
apt-get autoremove -y
apt-get autoclean -y

if [[ -f /var/run/reboot-required ]]; then
    echo ""
    warning "سیستم برای اعمال کامل آپدیت‌ها نیاز به ریبوت دارد."
    if [[ -f /var/run/reboot-required.pkgs ]]; then
        echo "پکیج‌های نیازمند ریبوت:"
        cat /var/run/reboot-required.pkgs
    fi
fi

# ------------------------------------------------------------
# 18. Final information
# ------------------------------------------------------------

echo ""
echo "============================================================"
success "Server setup & Docker installation completed."
echo "============================================================"
echo ""

echo "Docker:"
docker --version

echo ""

echo "Compose:"
docker compose version

echo ""

echo "Buildx:"
docker buildx version

echo ""

echo "Registry Mirror:"
echo "  ${ARVAN_DOCKER_MIRROR}"

echo ""

echo "Docker service:"
systemctl is-active docker

echo ""

echo "Installed base packages:"
echo "  ${BASE_PACKAGES[*]}"

echo ""

echo "Useful commands:"
echo "  docker ps"
echo "  docker images"
echo "  docker compose version"
echo "  systemctl status docker"
echo "  journalctl -u docker -f"
echo "  mc"
echo "  htop"

echo ""
success "Ready for Docker Compose / Portainer / Nginx Proxy Manager / AzuraCast."