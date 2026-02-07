#!/bin/bash
# =============================================================================
# Lakehouse Platform - WSL2 Ubuntu Prerequisites Installer
# =============================================================================
# Script:  install_prereqs.sh
# Purpose: Install and configure all prerequisites for running the lakehouse
#          platform on WSL2 Ubuntu (22.04/24.04).
#
# Installs:
#   - Ansible (via pip)
#   - containerd (container runtime)
#   - nerdctl-full (Docker-compatible CLI with compose support)
#   - CNI plugins (container networking)
#
# Configures:
#   - containerd service (systemd or direct)
#   - seaweedfs_default bridge network
#
# Usage:   sudo bash install_prereqs.sh
#          (or: chmod +x install_prereqs.sh && sudo ./install_prereqs.sh)
#
# Idempotent: Safe to run multiple times.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
NERDCTL_VERSION=""  # empty = latest
CNI_PLUGINS_VERSION=""  # empty = latest
CONTAINERD_VERSION=""  # empty = latest from apt
SHARED_NETWORK="seaweedfs_default"

# ---------------------------------------------------------------------------
# Colors and output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo ""; echo -e "${BOLD}=== $* ===${NC}"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
section "Pre-flight Checks"

if [[ "$(id -u)" -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi
ok "Running as root."

# Detect the invoking (non-root) user for later ownership operations
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$(logname 2>/dev/null || echo root)"
fi
info "Detected invoking user: ${REAL_USER}"

# Check that we are on an Ubuntu/Debian system
if ! command -v apt-get &>/dev/null; then
    err "apt-get not found. This script requires Ubuntu/Debian."
    exit 1
fi
ok "apt-get available (Ubuntu/Debian detected)."

# Detect architecture
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  ARCH_ALT="amd64" ;;
    aarch64) ARCH_ALT="arm64" ;;
    *)
        err "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac
info "Architecture: ${ARCH} (${ARCH_ALT})"

# ---------------------------------------------------------------------------
# Helper: resolve latest GitHub release tag
# ---------------------------------------------------------------------------
github_latest_tag() {
    local repo="$1"
    # Use the GitHub API redirect to find the latest release tag
    local tag
    tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/${repo}/releases/latest" 2>/dev/null \
        | grep -oP '[^/]+$')
    echo "${tag}"
}

# =========================================================================
# 1. SYSTEM PACKAGES
# =========================================================================
section "System Packages"

info "Updating apt package index..."
apt-get update -qq

info "Installing base dependencies..."
apt-get install -y -qq \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    iptables \
    iproute2 \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    > /dev/null 2>&1

ok "Base system packages installed."

# =========================================================================
# 2. ANSIBLE
# =========================================================================
section "Ansible"

if command -v ansible &>/dev/null; then
    ANSIBLE_VER="$(ansible --version 2>/dev/null | head -1)"
    ok "Ansible already installed: ${ANSIBLE_VER}"
else
    info "Installing Ansible via pip..."

    # Use pipx-style isolated install if possible, otherwise pip with break-system-packages
    if command -v pipx &>/dev/null; then
        pipx install --include-deps ansible 2>/dev/null || true
    else
        # On Ubuntu 23.04+ pip refuses to install globally without this flag
        python3 -m pip install --break-system-packages ansible 2>/dev/null \
            || python3 -m pip install ansible 2>/dev/null \
            || apt-get install -y -qq ansible > /dev/null 2>&1
    fi

    if command -v ansible &>/dev/null; then
        ANSIBLE_VER="$(ansible --version 2>/dev/null | head -1)"
        ok "Ansible installed: ${ANSIBLE_VER}"
    else
        # Last resort: try apt
        apt-get install -y -qq ansible > /dev/null 2>&1
        if command -v ansible &>/dev/null; then
            ANSIBLE_VER="$(ansible --version 2>/dev/null | head -1)"
            ok "Ansible installed (via apt): ${ANSIBLE_VER}"
        else
            err "Failed to install Ansible."
            exit 1
        fi
    fi
fi

# =========================================================================
# 3. CONTAINERD
# =========================================================================
section "containerd"

if command -v containerd &>/dev/null; then
    CONTAINERD_VER="$(containerd --version 2>/dev/null || echo 'unknown')"
    ok "containerd already installed: ${CONTAINERD_VER}"
else
    info "Installing containerd..."

    # Try the official Docker repository first for a recent version
    DOCKER_GPG="/etc/apt/keyrings/docker.gpg"
    DOCKER_LIST="/etc/apt/sources.list.d/docker.list"

    if [[ ! -f "${DOCKER_GPG}" ]]; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o "${DOCKER_GPG}" 2>/dev/null
        chmod a+r "${DOCKER_GPG}"
    fi

    UBUNTU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-jammy}}")"

    echo \
        "deb [arch=${ARCH_ALT} signed-by=${DOCKER_GPG}] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
        | tee "${DOCKER_LIST}" > /dev/null

    apt-get update -qq
    apt-get install -y -qq containerd.io > /dev/null 2>&1

    if command -v containerd &>/dev/null; then
        CONTAINERD_VER="$(containerd --version 2>/dev/null || echo 'unknown')"
        ok "containerd installed: ${CONTAINERD_VER}"
    else
        err "Failed to install containerd."
        exit 1
    fi
fi

# Generate default config if not present
CONTAINERD_CFG="/etc/containerd/config.toml"
if [[ ! -f "${CONTAINERD_CFG}" ]] || ! grep -q 'SystemdCgroup' "${CONTAINERD_CFG}" 2>/dev/null; then
    info "Generating containerd configuration..."
    mkdir -p /etc/containerd
    containerd config default > "${CONTAINERD_CFG}" 2>/dev/null || true
    # Enable SystemdCgroup for runc (best practice on systemd hosts)
    if grep -q 'SystemdCgroup' "${CONTAINERD_CFG}" 2>/dev/null; then
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${CONTAINERD_CFG}"
        ok "containerd configured with SystemdCgroup = true."
    else
        ok "containerd configuration generated (default)."
    fi
fi

# =========================================================================
# 4. START CONTAINERD
# =========================================================================
section "Starting containerd"

start_containerd_direct() {
    # Direct start for environments without systemd (some WSL2 setups)
    if pgrep -x containerd &>/dev/null; then
        ok "containerd is already running (direct process)."
        return 0
    fi
    info "Starting containerd directly (no systemd detected)..."
    containerd &>/var/log/containerd.log &
    disown
    # Wait for the socket to appear
    local retries=0
    while [[ ! -S /run/containerd/containerd.sock ]] && [[ ${retries} -lt 30 ]]; do
        sleep 1
        retries=$((retries + 1))
    done
    if [[ -S /run/containerd/containerd.sock ]]; then
        ok "containerd started (direct)."
        return 0
    else
        err "containerd socket did not appear after 30 seconds."
        return 1
    fi
}

# Prefer systemd if available; fall back to direct start
if pidof systemd &>/dev/null && command -v systemctl &>/dev/null; then
    info "systemd detected -- using systemctl."
    systemctl enable containerd 2>/dev/null || true
    if systemctl is-active --quiet containerd 2>/dev/null; then
        ok "containerd service is already running."
    else
        systemctl start containerd
        sleep 2
        if systemctl is-active --quiet containerd 2>/dev/null; then
            ok "containerd service started via systemd."
        else
            warn "systemctl start did not succeed; trying direct start..."
            start_containerd_direct
        fi
    fi
else
    warn "systemd not detected (common in WSL2). Using direct start."
    start_containerd_direct
fi

# Final socket check
if [[ ! -S /run/containerd/containerd.sock ]]; then
    err "containerd socket not found at /run/containerd/containerd.sock."
    err "Cannot continue without a running containerd."
    exit 1
fi
ok "containerd socket verified: /run/containerd/containerd.sock"

# =========================================================================
# 5. CNI PLUGINS
# =========================================================================
section "CNI Plugins"

CNI_DIR="/opt/cni/bin"

if [[ -x "${CNI_DIR}/bridge" ]] && [[ -x "${CNI_DIR}/loopback" ]]; then
    ok "CNI plugins already installed in ${CNI_DIR}."
else
    info "Determining latest CNI plugins release..."
    if [[ -z "${CNI_PLUGINS_VERSION}" ]]; then
        CNI_PLUGINS_VERSION="$(github_latest_tag 'containernetworking/plugins')"
    fi
    if [[ -z "${CNI_PLUGINS_VERSION}" ]]; then
        err "Could not determine latest CNI plugins version."
        exit 1
    fi
    info "Installing CNI plugins ${CNI_PLUGINS_VERSION}..."

    CNI_TARBALL="cni-plugins-linux-${ARCH_ALT}-${CNI_PLUGINS_VERSION}.tgz"
    CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/${CNI_TARBALL}"

    mkdir -p "${CNI_DIR}"
    curl -fsSL "${CNI_URL}" | tar -xz -C "${CNI_DIR}"

    if [[ -x "${CNI_DIR}/bridge" ]]; then
        ok "CNI plugins installed to ${CNI_DIR}."
    else
        err "CNI plugins installation failed."
        exit 1
    fi
fi

# =========================================================================
# 6. NERDCTL (full -- includes compose, buildkit, etc.)
# =========================================================================
section "nerdctl (full package)"

install_nerdctl() {
    info "Determining latest nerdctl release..."
    if [[ -z "${NERDCTL_VERSION}" ]]; then
        NERDCTL_VERSION="$(github_latest_tag 'containerd/nerdctl')"
    fi
    if [[ -z "${NERDCTL_VERSION}" ]]; then
        err "Could not determine latest nerdctl version."
        exit 1
    fi

    # Strip leading 'v' for the filename convention
    local ver_num="${NERDCTL_VERSION#v}"

    info "Installing nerdctl-full ${NERDCTL_VERSION}..."

    local NERDCTL_TARBALL="nerdctl-full-${ver_num}-linux-${ARCH_ALT}.tar.gz"
    local NERDCTL_URL="https://github.com/containerd/nerdctl/releases/download/${NERDCTL_VERSION}/${NERDCTL_TARBALL}"

    local TMP_DIR
    TMP_DIR="$(mktemp -d)"
    trap "rm -rf ${TMP_DIR}" RETURN

    curl -fsSL "${NERDCTL_URL}" -o "${TMP_DIR}/${NERDCTL_TARBALL}"
    tar -xzf "${TMP_DIR}/${NERDCTL_TARBALL}" -C /usr/local

    rm -rf "${TMP_DIR}"
    trap - RETURN
}

if command -v nerdctl &>/dev/null; then
    CURRENT_NERDCTL="$(nerdctl --version 2>/dev/null || echo '')"
    # Check that nerdctl compose also works (full package indicator)
    if nerdctl compose version &>/dev/null; then
        ok "nerdctl (full) already installed: ${CURRENT_NERDCTL}"
    else
        warn "nerdctl found but compose support missing. Reinstalling full package..."
        install_nerdctl
    fi
else
    install_nerdctl
fi

# Verify nerdctl works
if command -v nerdctl &>/dev/null; then
    NERDCTL_VER_STR="$(nerdctl --version 2>/dev/null)"
    ok "nerdctl installed: ${NERDCTL_VER_STR}"
else
    err "nerdctl binary not found after installation."
    exit 1
fi

# Verify nerdctl compose
if nerdctl compose version &>/dev/null; then
    COMPOSE_VER="$(nerdctl compose version 2>/dev/null)"
    ok "nerdctl compose available: ${COMPOSE_VER}"
else
    err "nerdctl compose is not working. The full package may not have installed correctly."
    exit 1
fi

# =========================================================================
# 7. SEAWEEDFS_DEFAULT NETWORK
# =========================================================================
section "Shared Container Network"

if nerdctl network inspect "${SHARED_NETWORK}" &>/dev/null; then
    ok "Network '${SHARED_NETWORK}' already exists."
else
    info "Creating bridge network '${SHARED_NETWORK}'..."
    nerdctl network create "${SHARED_NETWORK}" 2>/dev/null \
        || nerdctl network create --driver bridge "${SHARED_NETWORK}" 2>/dev/null

    if nerdctl network inspect "${SHARED_NETWORK}" &>/dev/null; then
        ok "Network '${SHARED_NETWORK}' created."
    else
        err "Failed to create network '${SHARED_NETWORK}'."
        exit 1
    fi
fi

# =========================================================================
# 8. /opt/lakehouse directory
# =========================================================================
section "Lakehouse Base Directory"

LAKEHOUSE_DIR="/opt/lakehouse"
if [[ -d "${LAKEHOUSE_DIR}" ]]; then
    ok "${LAKEHOUSE_DIR} already exists."
else
    info "Creating ${LAKEHOUSE_DIR}..."
    mkdir -p "${LAKEHOUSE_DIR}"
    chown "${REAL_USER}:${REAL_USER}" "${LAKEHOUSE_DIR}" 2>/dev/null || true
    ok "${LAKEHOUSE_DIR} created (owner: ${REAL_USER})."
fi

# =========================================================================
# 9. VERIFICATION SUMMARY
# =========================================================================
section "Verification Summary"

echo ""
PASS=0
FAIL=0

verify() {
    local label="$1"
    local cmd="$2"
    if eval "${cmd}" &>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}  ${label}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}  ${label}"
        FAIL=$((FAIL + 1))
    fi
}

verify "ansible is installed"          "command -v ansible"
verify "containerd is installed"       "command -v containerd"
verify "containerd socket exists"      "test -S /run/containerd/containerd.sock"
verify "nerdctl is installed"          "command -v nerdctl"
verify "nerdctl compose works"         "nerdctl compose version"
verify "CNI bridge plugin exists"      "test -x /opt/cni/bin/bridge"
verify "CNI loopback plugin exists"    "test -x /opt/cni/bin/loopback"
verify "seaweedfs_default network"     "nerdctl network inspect ${SHARED_NETWORK}"
verify "/opt/lakehouse directory"      "test -d /opt/lakehouse"

echo ""
echo "--------------------------------------"
echo -e "  Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}"
echo "--------------------------------------"

if [[ ${FAIL} -gt 0 ]]; then
    echo ""
    err "Some checks failed. Review the output above."
    exit 1
fi

echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD} PREREQUISITES INSTALLED SUCCESSFULLY${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""
echo "  Installed components:"
echo "    - Ansible:    $(ansible --version 2>/dev/null | head -1)"
echo "    - containerd: $(containerd --version 2>/dev/null || echo 'installed')"
echo "    - nerdctl:    $(nerdctl --version 2>/dev/null)"
echo "    - CNI:        /opt/cni/bin/"
echo "    - Network:    ${SHARED_NETWORK} (bridge)"
echo ""
echo "  Next steps:"
echo "    1. Deploy SeaweedFS storage layer:"
echo "       cd ansible"
echo "       ansible-playbook 260206_seaweedfs-storage_rb_v1_0.yaml"
echo ""
echo "    2. Deploy the lakehouse platform:"
echo "       ansible-playbook 260206_deploy_all_lakehouse_rb_v1_0.yaml"
echo ""
echo "    3. Check platform health:"
echo "       bash health_check.sh"
echo ""
echo -e "${BOLD}============================================${NC}"
