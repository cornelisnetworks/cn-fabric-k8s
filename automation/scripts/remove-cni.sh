#!/bin/bash
#
# CNI Removal Script
# Removes Multus, IPoIB, Whereabouts, and Flannel from Kubernetes cluster and nodes
#
# Usage: ./remove-cni.sh [OPTIONS]
#
# Options:
#   --yes       Skip confirmation prompts
#   --dry-run   Show what would be removed without making changes
#   --help      Show this help message
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
DRY_RUN=false

show_help() {
    cat << EOF
CNI Removal Script

Removes all CNI components from Kubernetes cluster:
  - Multus CNI
  - IPoIB CNI (cn-ipoib-cni)
  - Whereabouts IPAM
  - Flannel CNI

Usage: $0 [OPTIONS]

Options:
  --yes       Skip confirmation prompts
  --dry-run   Show what would be removed without making changes
  --help      Show this help message

Examples:
  # Dry-run to preview changes
  $0 --dry-run

  # Remove all CNI components (with confirmation)
  $0

  # Remove all CNI components (skip confirmation)
  $0 --yes

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y) SKIP_CONFIRM=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) show_help ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl first."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

BACKUP_DIR="/tmp/cni-removal-backup-$(date +%Y%m%d-%H%M%S)"

if [ "${DRY_RUN}" = "true" ]; then
    log_info "=== DRY RUN MODE - No changes will be made ==="
fi

if [ "${SKIP_CONFIRM}" = "false" ] && [ "${DRY_RUN}" = "false" ]; then
    echo ""
    log_warn "This will remove ALL CNI components from the cluster:"
    echo "  - Multus CNI"
    echo "  - IPoIB CNI (cn-ipoib-cni)"
    echo "  - Whereabouts IPAM"
    echo "  - Flannel CNI"
    echo ""
    log_warn "After removal, nodes will become NotReady (no CNI available)"
    echo ""
    read -p "Continue? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Removal cancelled"
        exit 0
    fi
fi

log_info "Starting CNI removal..."
echo ""

if [ "${DRY_RUN}" = "false" ]; then
    log_info "Creating backup directory: ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"
    
    log_info "Backing up current CNI configurations..."
    kubectl get daemonsets -n kube-system -o yaml > "${BACKUP_DIR}/daemonsets-backup.yaml" 2>/dev/null || true
    kubectl get configmaps -n kube-system -o yaml > "${BACKUP_DIR}/configmaps-backup.yaml" 2>/dev/null || true
    kubectl get net-attach-def -A -o yaml > "${BACKUP_DIR}/network-attachment-definitions-backup.yaml" 2>/dev/null || true
    kubectl get crd network-attachment-definitions.k8s.cni.cncf.io -o yaml > "${BACKUP_DIR}/crd-backup.yaml" 2>/dev/null || true
    log_success "Backup created"
fi

echo ""
log_info "=== Phase 1: Removing Kubernetes Resources ==="
echo ""

delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-""}
    
    local ns_flag=""
    if [ -n "${namespace}" ]; then
        ns_flag="-n ${namespace}"
    fi
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY RUN] Would delete ${resource_type}: ${resource_name} ${ns_flag}"
        return 0
    fi
    
    if kubectl get ${resource_type} ${resource_name} ${ns_flag} &> /dev/null; then
        if kubectl delete ${resource_type} ${resource_name} ${ns_flag} --ignore-not-found=true &> /dev/null; then
            log_success "Deleted ${resource_type}: ${resource_name}"
        else
            log_warn "Failed to delete ${resource_type}: ${resource_name} (continuing...)"
        fi
    else
        log_info "Resource not found (already removed): ${resource_type}/${resource_name}"
    fi
}

log_info "Removing DaemonSets..."
delete_resource "daemonset" "kube-multus-ds" "kube-system"
delete_resource "daemonset" "ipoib-cni" "kube-system"
delete_resource "daemonset" "whereabouts" "kube-system"
delete_resource "daemonset" "kube-flannel-ds" "kube-flannel"
delete_resource "daemonset" "kube-flannel-ds" "kube-system"

echo ""
log_info "Removing NetworkAttachmentDefinitions..."
if [ "${DRY_RUN}" = "true" ]; then
    log_info "[DRY RUN] Would delete all NetworkAttachmentDefinitions"
else
    kubectl delete net-attach-def --all -A --ignore-not-found=true &> /dev/null || log_warn "Failed to delete NetworkAttachmentDefinitions (continuing...)"
    log_success "Deleted NetworkAttachmentDefinitions"
fi

echo ""
log_info "Removing ConfigMaps..."
delete_resource "configmap" "multus-daemon-config" "kube-system"
delete_resource "configmap" "multus-default-networks" "kube-system"
delete_resource "configmap" "kube-flannel-cfg" "kube-flannel"
delete_resource "configmap" "kube-flannel-cfg" "kube-system"

echo ""
log_info "Removing ServiceAccounts..."
delete_resource "serviceaccount" "multus" "kube-system"
delete_resource "serviceaccount" "whereabouts" "kube-system"
delete_resource "serviceaccount" "flannel" "kube-flannel"
delete_resource "serviceaccount" "flannel" "kube-system"

echo ""
log_info "Removing ClusterRoleBindings..."
delete_resource "clusterrolebinding" "multus"
delete_resource "clusterrolebinding" "whereabouts"
delete_resource "clusterrolebinding" "flannel"

echo ""
log_info "Removing ClusterRoles..."
delete_resource "clusterrole" "multus"
delete_resource "clusterrole" "whereabouts-cni"
delete_resource "clusterrole" "flannel"

echo ""
log_info "Removing Custom Resource Definitions..."
delete_resource "crd" "network-attachment-definitions.k8s.cni.cncf.io"

echo ""
log_info "Removing Namespaces..."
delete_resource "namespace" "kube-flannel"

echo ""
log_info "=== Phase 2: Cleaning Node-Level Files ==="
echo ""

log_info "Getting list of cluster nodes..."
if [ "${DRY_RUN}" = "true" ]; then
    NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    log_info "[DRY RUN] Would clean files on nodes: ${NODES}"
else
    NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${NODES}" ]; then
        log_warn "No nodes found in cluster. Skipping node-level cleanup."
    else
        log_info "Found nodes: ${NODES}"
    fi
fi

cleanup_node_files() {
    local node=$1
    
    log_info "Cleaning files on node: ${node}"
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY RUN] Would remove CNI binaries from /opt/cni/bin/ on ${node}"
        log_info "[DRY RUN] Would remove CNI binaries from /hostroot/opt/cni/bin/ on ${node}"
        log_info "[DRY RUN] Would remove CNI configs from /etc/cni/net.d/ on ${node}"
        log_info "[DRY RUN] Would remove CNI data from /var/lib/cni/ on ${node}"
        return 0
    fi
    
    ssh -o StrictHostKeyChecking=no root@${node} bash << 'EOF'
        echo "Removing CNI binaries from /opt/cni/bin/..."
        rm -f /opt/cni/bin/ipoib /opt/cni/bin/multus /opt/cni/bin/multus-shim /opt/cni/bin/whereabouts /opt/cni/bin/flannel 2>/dev/null || true
        
        echo "Removing CNI binaries from /hostroot/opt/cni/bin/..."
        rm -f /hostroot/opt/cni/bin/ipoib /hostroot/opt/cni/bin/multus /hostroot/opt/cni/bin/multus-shim /hostroot/opt/cni/bin/whereabouts /hostroot/opt/cni/bin/flannel 2>/dev/null || true
        
        echo "Removing CNI configs from /etc/cni/net.d/..."
        rm -f /etc/cni/net.d/00-multus.conf /etc/cni/net.d/10-flannel.conflist 2>/dev/null || true
        rm -rf /etc/cni/net.d/whereabouts.d 2>/dev/null || true
        
        echo "Removing CNI data from /var/lib/cni/..."
        rm -rf /var/lib/cni/multus /var/lib/cni/flannel /var/lib/cni/networks /var/lib/cni/results 2>/dev/null || true
        
        echo "Removing debug/log files..."
        rm -f /var/log/cni-ipoib-debug.log 2>/dev/null || true
        
        echo "Cleanup complete on $(hostname)"
EOF
    
    if [ $? -eq 0 ]; then
        log_success "Cleaned files on node: ${node}"
    else
        log_warn "Failed to clean some files on node: ${node} (continuing...)"
    fi
}

if [ -n "${NODES}" ]; then
    for node in ${NODES}; do
        cleanup_node_files "${node}"
    done
fi

echo ""
log_info "=== Phase 3: Verification ==="
echo ""

log_info "Checking for remaining CNI pods..."
REMAINING_PODS=$(kubectl get pods -A 2>/dev/null | grep -E 'multus|ipoib|whereabouts|flannel' || true)
if [ -z "${REMAINING_PODS}" ]; then
    log_success "No remaining CNI pods found"
else
    log_warn "Some CNI pods still exist:"
    echo "${REMAINING_PODS}"
fi

echo ""
log_info "Checking for stale IPoIB interfaces on nodes..."
if [ -n "${NODES}" ] && [ "${DRY_RUN}" = "false" ]; then
    for node in ${NODES}; do
        STALE_IFACES=$(ssh -o StrictHostKeyChecking=no root@${node} "ip link show 2>/dev/null | grep -E '@ib[a-z]*[0-9]+' || true")
        if [ -z "${STALE_IFACES}" ]; then
            log_success "No stale IPoIB interfaces on node: ${node}"
        else
            log_warn "Stale IPoIB interfaces found on node ${node}:"
            echo "${STALE_IFACES}"
        fi
    done
else
    log_info "Skipping stale interface check (dry-run or no nodes)"
fi

echo ""
log_info "Checking cluster node status..."
kubectl get nodes -o wide 2>/dev/null || log_warn "Failed to get node status"

echo ""
echo "=== CNI Removal Complete ==="
echo ""
if [ "${DRY_RUN}" = "false" ]; then
    log_success "Backup saved to: ${BACKUP_DIR}"
    echo ""
fi
log_info "Summary:"
echo "  ✓ Removed Multus CNI"
echo "  ✓ Removed IPoIB CNI (cn-ipoib-cni)"
echo "  ✓ Removed Whereabouts IPAM"
echo "  ✓ Removed Flannel CNI"
echo ""
log_warn "Nodes are now NotReady (no CNI available)"
echo ""
echo "Next steps:"
echo "  1. Deploy a new CNI if needed"
echo "  2. Or leave cluster without networking"
if [ "${DRY_RUN}" = "false" ]; then
    echo "  3. Review backup in: ${BACKUP_DIR}"
fi
echo ""
