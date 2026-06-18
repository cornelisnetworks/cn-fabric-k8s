#!/bin/bash
#
# Kubernetes Node Cleanup Script
# Removes all Kubernetes components and configuration from a node
#
# Usage: ./clean-node.sh [--yes] [--remove-images]
#
# Options:
#   --yes             Skip confirmation prompt
#   --remove-images   Remove all container images (default: preserve images)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

source "${REPO_ROOT}/automation/scripts/lib/load-versions.sh"
if [ -f "${REPO_ROOT}/automation/scripts/lib/package-manager.sh" ]; then
    source "${REPO_ROOT}/automation/scripts/lib/package-manager.sh"
else
    echo "ERROR: package-manager.sh not found"
    exit 1
fi

SKIP_CONFIRM=false
PRESERVE_IMAGES=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y) SKIP_CONFIRM=true; shift ;;
        --remove-images) PRESERVE_IMAGES=false; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

if [ "${SKIP_CONFIRM}" = "false" ]; then
    echo ""
    log_warn "This will remove all Kubernetes components from this node"
    read -p "Continue? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
fi

log_info "Starting Kubernetes node cleanup..."

BACKUP_DIR=$(backup_k8s_state)

detect_distro
PKG_MGR=$(get_package_manager "${DISTRO_ID}" "${DISTRO_ID_LIKE}")

log_info "Stopping Kubernetes services..."
systemctl stop kubelet 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true

sleep 2
log_info "Force killing all Kubernetes processes..."
pkill -9 -f kubelet 2>/dev/null || true
pkill -9 -f kube-apiserver 2>/dev/null || true
pkill -9 -f kube-controller-manager 2>/dev/null || true
pkill -9 -f kube-scheduler 2>/dev/null || true
pkill -9 -f kube-proxy 2>/dev/null || true
pkill -9 -f etcd 2>/dev/null || true
pkill -9 -f containerd 2>/dev/null || true
sleep 1

if [ "${PRESERVE_IMAGES}" = "true" ]; then
    log_info "Preserving container images (use --remove-images to delete them)..."
    log_info "Running kubeadm reset (skip-phases=cleanup-node)..."
    kubeadm reset --force --skip-phases=cleanup-node 2>/dev/null || true
else
    log_info "Running kubeadm reset (will remove all images)..."
    kubeadm reset --force 2>/dev/null || true
fi

log_info "Unmounting kubelet volumes..."
for mount in $(mount | grep '/var/lib/kubelet/pods' | awk '{print $3}' | sort -r); do
    umount -f "$mount" 2>/dev/null || true
done
sleep 1

cleanup_network
cleanup_cni
cleanup_k8s_configs

log_info "Removing Kubernetes packages..."
case "${PKG_MGR}" in
    apt)
        apt-get purge -y kubelet kubeadm kubectl containerd 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        ;;
    dnf|yum)
        ${PKG_MGR} remove -y kubelet kubeadm kubectl containerd.io 2>/dev/null || true
        ;;
    zypper)
        zypper remove -y kubelet kubeadm kubectl containerd 2>/dev/null || true
        ;;
esac
log_success "Kubernetes packages removed"

log_info "Cleaning kubepods cgroup slices..."
for slice in $(systemctl list-units --type=slice --all | grep kubepods | awk '{print $1}'); do
    systemctl stop "$slice" 2>/dev/null || true
done
find /sys/fs/cgroup -name "kubepods*" -type d -exec rmdir {} \; 2>/dev/null || true
log_success "Kubepods cgroups cleaned"

log_info "Reloading systemd..."
systemctl daemon-reload
systemctl reset-failed

verify_cleanup

echo ""
echo "=== Cleanup Complete ==="
log_success "Backup saved to: ${BACKUP_DIR}"
echo ""
echo "Next steps:"
echo "  1. Review logs in ${BACKUP_DIR}"
echo "  2. Reboot node (recommended): sudo reboot"
echo "  3. Run setup script to prepare for new cluster"
