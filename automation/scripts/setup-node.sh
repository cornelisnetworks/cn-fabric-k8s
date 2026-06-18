#!/bin/bash
#
# Kubernetes Node Setup Script
# Installs and configures all prerequisites for a cluster-ready node
#
# Usage: ./setup-node.sh [--k8s-version VERSION] [--yes]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

source "${REPO_ROOT}/automation/scripts/lib/load-versions.sh"

if [ -f "${REPO_ROOT}/automation/scripts/lib/package-manager.sh" ]; then
    source "${REPO_ROOT}/automation/scripts/lib/package-manager.sh"
else
    echo "ERROR: package-manager.sh not found at ${REPO_ROOT}/automation/scripts/lib/package-manager.sh"
    exit 1
fi
SKIP_CONFIRM=false
CLEANUP_BUILD_DEPS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --k8s-version) K8S_VERSION="$2"; shift 2 ;;
        --yes|-y) SKIP_CONFIRM=true; shift ;;
        --cleanup-build-deps) CLEANUP_BUILD_DEPS=true; shift ;;
        --go-version) GO_VERSION="$2"; shift 2 ;;
        --multus-version) MULTUS_VERSION="$2"; shift 2 ;;
        --flannel-version) FLANNEL_VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

export CLEANUP_BUILD_DEPS

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

if [ "${SKIP_CONFIRM}" = "false" ]; then
    echo ""
    log_info "This will install and configure Kubernetes ${K8S_VERSION} on this node"
    read -p "Continue? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Setup cancelled"
        exit 0
    fi
fi

log_info "Starting Kubernetes node setup..."

detect_distro
PKG_MGR=$(get_package_manager "${DISTRO_ID}" "${DISTRO_ID_LIKE}")

log_info "Distribution: ${DISTRO_NAME}"
log_info "Package Manager: ${PKG_MGR}"

log_info "Installing Kubernetes packages..."
case "${PKG_MGR}" in
    apt)
        pkg_install "kubelet=${K8S_VERSION}-*" "kubeadm=${K8S_VERSION}-*" "kubectl=${K8S_VERSION}-*"
        ;;
    dnf|yum)
        pkg_install "kubelet-${K8S_VERSION}" "kubeadm-${K8S_VERSION}" "kubectl-${K8S_VERSION}"
        ;;
    zypper)
        pkg_install "kubelet=${K8S_VERSION}" "kubeadm=${K8S_VERSION}" "kubectl=${K8S_VERSION}"
        ;;
esac

log_info "Checking containerd installation..."
if systemctl list-unit-files | grep -q containerd.service; then
    log_success "containerd already installed"
    if ! systemctl is-active --quiet containerd; then
        log_info "Starting containerd service..."
        systemctl enable --now containerd
    fi
    # On SLES, containerd-ctr is a separate package not included with containerd.
    # Even when containerd is pre-installed, ctr may be missing — install it if absent.
    if [ "${PKG_MGR}" = "zypper" ] && ! command -v ctr >/dev/null 2>&1; then
        pkg_install containerd-ctr || log_warn "containerd-ctr not available; ctr image import may fail"
        if command -v containerd-ctr >/dev/null 2>&1 && ! command -v ctr >/dev/null 2>&1; then
            ln -sf "$(command -v containerd-ctr)" /usr/local/bin/ctr
            log_success "ctr symlink created → $(command -v containerd-ctr)"
        fi
    fi
else
    log_warn "containerd not found, attempting to install..."
    case "${PKG_MGR}" in
        apt)
            pkg_install containerd
            ;;
        dnf|yum)
            if dnf list installed containerd.io &>/dev/null 2>&1 || dnf list installed containerd &>/dev/null 2>&1; then
                log_success "containerd package already installed"
            else
                log_info "Attempting to install containerd.io from Docker CE repo..."
                if pkg_install containerd.io; then
                    log_success "containerd.io installed"
                else
                    log_warn "containerd.io package not available, skipping (assuming containerd is manually installed)"
                fi
            fi
            ;;
        zypper)
            pkg_install containerd containerd-ctr
            ;;
    esac
fi

if [[ "${PKG_MGR}" == "zypper" ]] && ! command -v ctr &>/dev/null; then
    pkg_install containerd-ctr || true
    if ! command -v ctr &>/dev/null; then
        if [ "${SKIP_RDMA_PLUGIN_BUILD:-false}" != "true" ]; then
            log_error "ctr not found and containerd-ctr install failed; the cn-rdma-shared-dev-plugin image import below ('ctr -n k8s.io images import') will fail. Install containerd-ctr or re-run with SKIP_RDMA_PLUGIN_BUILD=true."
            exit 1
        fi
        log_warn "ctr not found (containerd-ctr install failed); proceeding because SKIP_RDMA_PLUGIN_BUILD=true skips the ctr image import."
    fi
fi

log_info "Installing dependencies..."
case "${PKG_MGR}" in
    apt)
        conntrack_pkg="conntrack"
        ;;
    *)
        conntrack_pkg="conntrack-tools"
        ;;
esac
pkg_install curl wget socat "${conntrack_pkg}" ipset iptables


log_info "Installing RDMA tools (optional, for testing)..."
case "${PKG_MGR}" in
    apt)
        pkg_install rdma-core ibverbs-utils infiniband-diags || log_warn "RDMA tools installation failed (optional)"
        ;;
    dnf|yum)
        pkg_install rdma-core libibverbs-utils infiniband-diags || log_warn "RDMA tools installation failed (optional)"
        ;;
    zypper)
        pkg_install rdma-core libibverbs-utils infiniband-diags || log_warn "RDMA tools installation failed (optional)"
        ;;
esac

log_info "Installing Python and pip..."
case "${PKG_MGR}" in
    apt)
        pkg_install python3 python3-pip
        ;;
    dnf|yum)
        pkg_install python3 python3-pip
        ;;
    zypper)
        pkg_install python3 python3-pip
        ;;
esac

log_info "Installing yq for node validation..."
if ! command -v yq >/dev/null 2>&1; then
    pip3 install --quiet 'yq==3.2.3' || { log_error "Failed to install yq==3.2.3"; exit 1; }
    log_success "yq installed"
else
    log_success "yq already installed"
fi

configure_containerd
configure_kubelet

disable_swap true

log_info "Loading kernel modules..."
load_kernel_module br_netfilter true
load_kernel_module overlay true

log_info "Configuring sysctl parameters..."
configure_sysctl net.bridge.bridge-nf-call-iptables 1 true
configure_sysctl net.bridge.bridge-nf-call-ip6tables 1 true
configure_sysctl net.ipv4.ip_forward 1 true

log_info "Configuring firewall..."
configure_firewall 10250 tcp
configure_firewall 30000-32767 tcp
configure_firewall 8472 udp

log_info "Installing CNI binaries..."
prepare_cni_bin_directory

if [ "${SKIP_IPOIB_BUILD:-false}" != "true" ]; then
    log_info "Installing Go toolchain..."
    if ! install_go "${GO_VERSION}"; then
        log_error "Go installation failed"
        exit 1
    fi

    log_info "Building and installing cn-ipoib-cni..."
    BUILD_DIR=$(prepare_cni_ipoib_source "${REPO_ROOT}")
    if ! build_cni_ipoib "${BUILD_DIR}"; then
        log_error "cn-ipoib-cni build failed"
        exit 1
    fi
    if ! install_cni_ipoib_binary "${BUILD_DIR}"; then
        log_error "cn-ipoib-cni installation failed"
        exit 1
    fi
else
    log_info "Skipping cn-ipoib-cni build (SKIP_IPOIB_BUILD=true)"
    log_info "Assuming cn-ipoib-cni binary already installed at /opt/cni/bin/ipoib"
fi

if [ "${SKIP_RDMA_PLUGIN_BUILD:-false}" != "true" ]; then
    log_info "Installing buildah toolchain if missing..."
    if ! install_buildah_if_missing; then
        log_error "buildah installation failed"
        exit 1
    fi

    log_info "Building cn-rdma-shared-dev-plugin container image..."
    if ! build_cn_rdma_shared_dp_image "${REPO_ROOT}"; then
        log_error "cn-rdma-shared-dev-plugin image build failed"
        exit 1
    fi
else
    log_info "Skipping cn-rdma-shared-dev-plugin build (SKIP_RDMA_PLUGIN_BUILD=true)"
    log_info "Assuming localhost/cn-rdma-shared-dev-plugin:latest already loaded into containerd"
fi

log_info "Installing Multus CNI..."
log_info "Downloading Multus CNI ${MULTUS_VERSION}..."
MULTUS_TARBALL=$(download_multus_cni "${MULTUS_VERSION}")
if [ -z "${MULTUS_TARBALL}" ] || [ ! -f "${MULTUS_TARBALL}" ]; then
    log_error "Failed to download Multus CNI"
    exit 1
fi
log_success "Downloaded Multus CNI to ${MULTUS_TARBALL}"
# Mandatory checksum verification: a missing checksum is a fatal error.
# To update Multus: regenerate MULTUS_SHA256 below and pin to the new version.
declare -A MULTUS_SHA256_BY_VERSION=(
    ["v4.2.4"]="6354d20402ad20670251bcc151b94e09e22c7339f2ae905ee98d46a576e99220"
)
expected_sha="${MULTUS_SHA256_BY_VERSION[${MULTUS_VERSION}]:-}"
if [ -z "${expected_sha}" ] || [[ "${expected_sha}" == UNRESOLVED_* ]]; then
    log_error "No checksum pinned for Multus ${MULTUS_VERSION}. Refusing to install unverified binary."
    log_error "Add the SHA256 to MULTUS_SHA256_BY_VERSION map and retry."
    rm -f "${MULTUS_TARBALL}"
    exit 1
fi
actual_sha=$(sha256sum "${MULTUS_TARBALL}" | awk '{print $1}')
if [ "${actual_sha}" != "${expected_sha}" ]; then
    log_error "Multus checksum mismatch: expected ${expected_sha}, got ${actual_sha}"
    rm -f "${MULTUS_TARBALL}"
    exit 1
fi
log_success "Multus checksum verified"
if ! install_multus_binary "${MULTUS_TARBALL}"; then
    log_error "Multus installation failed"
    exit 1
fi

log_info "Installing Flannel CNI..."
log_info "Downloading Flannel CNI ${FLANNEL_VERSION}..."
FLANNEL_TARBALL=$(download_flannel_cni "${FLANNEL_VERSION}")
if [ -z "${FLANNEL_TARBALL}" ] || [ ! -f "${FLANNEL_TARBALL}" ]; then
    log_error "Failed to download Flannel CNI"
    exit 1
fi
log_success "Downloaded Flannel CNI to ${FLANNEL_TARBALL}"
if ! verify_flannel_checksum "${FLANNEL_TARBALL}" "${FLANNEL_VERSION}"; then
    log_error "Flannel checksum verification FAILED for ${FLANNEL_TARBALL}. Refusing to install unverified binary."
    rm -f "${FLANNEL_TARBALL}"
    exit 1
fi
if ! install_flannel_binaries "${FLANNEL_TARBALL}"; then
    log_error "Flannel installation failed"
    exit 1
fi

log_info "Verifying CNI binary installation..."
if ! generate_cni_verification_report; then
    log_error "CNI binary verification failed"
    exit 1
fi

if [ "${CLEANUP_BUILD_DEPS}" = "true" ]; then
    cleanup_build_dependencies
fi

start_k8s_services
verify_k8s_installation

echo ""
echo "=== Setup Complete ==="
log_success "Node is cluster-ready with Kubernetes ${K8S_VERSION}"
# Machine-readable marker for callers (e.g. Ansible) to capture the resolved
# version without parsing human log text. Keep the key stable.
echo "RESOLVED_K8S_VERSION=${K8S_VERSION}"
echo ""
echo "Next steps:"
echo "  1. Initialize cluster (control plane):"
echo "     kubeadm init --pod-network-cidr=10.244.0.0/16"
echo ""
echo "  2. Join cluster (worker):"
echo "     kubeadm join <control-plane>:6443 --token <token> \\"
echo "       --discovery-token-ca-cert-hash sha256:<hash>"
