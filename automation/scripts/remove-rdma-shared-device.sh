#!/bin/bash
# Remove RDMA Shared Device Plugin from Kubernetes cluster
# This script removes all RDMA shared device plugin components

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BACKUP_DIR="/tmp/rdma-removal-backup-$(date +%Y%m%dT%H%M%S)"
DRY_RUN=false
SKIP_CONFIRMATION=false
REMOVE_FLANNEL=false

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Remove RDMA Shared Device Plugin from Kubernetes cluster.

OPTIONS:
    --yes              Skip confirmation prompt
    --dry-run          Show what would be removed without actually removing
    --remove-flannel   Also tear down the Flannel control plane (kube-flannel
                       namespace, ServiceAccount, ClusterRole/Binding). By
                       default Flannel is left in place because other workloads
                       on the cluster typically depend on it. Aligned with
                       automation/playbooks/tasks/remove-cni-rdma-shared-device.yaml.
    --help             Show this help message

EXAMPLES:
    $0                            # Remove RDMA plugin only, leave Flannel intact
    $0 --yes                      # Same, no confirmation prompt
    $0 --remove-flannel --yes     # Full teardown including Flannel
    $0 --dry-run                  # Preview what would be removed

WHAT GETS REMOVED:
    - RDMA device plugin DaemonSet, ConfigMap, RBAC
    - Flannel CNI -- ONLY when --remove-flannel is supplied

BACKUP:
    Kubernetes resources are backed up to: $BACKUP_DIR

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|--yes=true)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --dry-run|--dry-run=true)
            DRY_RUN=true
            shift
            ;;
        --remove-flannel|--remove-flannel=true)
            REMOVE_FLANNEL=true
            shift
            ;;
        --remove-flannel=false)
            REMOVE_FLANNEL=false
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi
}

# Check cluster identity and require operator confirmation before destructive
# operations. Coarse cluster-info reachability is not enough; we surface the
# current context and API server so the operator can confirm.
check_cluster() {
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi

    local current_context api_server
    current_context=$(kubectl config current-context 2>/dev/null || echo "<unknown>")
    api_server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "<unknown>")

    echo ""
    log_info "Target cluster context : ${current_context}"
    log_info "Target API server      : ${api_server}"

    if [[ "$SKIP_CONFIRMATION" == "true" ]]; then
        log_warn "--yes supplied; skipping cluster identity confirmation"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    # Accept both `y` and `yes`/`YES` so the grammar matches confirm_removal() below.
    # Temporarily disable `set -e` around read so EOF on /dev/null returns a clean
    # "Aborted by user" message instead of silently exiting with code 1 (otherwise
    # set -e eats the user-visible log line).
    local confirm
    set +e
    read -rp "Confirm this is the correct cluster [y/N]: " confirm
    local rc=$?
    set -e
    if [[ ${rc} -ne 0 ]] || [[ ! "${confirm}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        log_error "Aborted by user"
        exit 1
    fi
}

# Create backup directory
create_backup_dir() {
    if [[ "$DRY_RUN" == "false" ]]; then
        mkdir -p "$BACKUP_DIR"
        log_info "Created backup directory: $BACKUP_DIR"
    fi
}

# Backup Kubernetes resource
backup_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-""}
    
    if [[ "$DRY_RUN" == "false" ]]; then
        local ns_args=()
        if [[ -n "$namespace" ]]; then
            ns_args=(-n "$namespace")
        fi

        if kubectl get "$resource_type" "$resource_name" "${ns_args[@]}" &> /dev/null; then
            backup_file="$BACKUP_DIR/${resource_type}-${resource_name}.yaml"
            if ! kubectl get "$resource_type" "$resource_name" "${ns_args[@]}" -o yaml > "$backup_file"; then
                log_error "Backup FAILED for ${resource_type}/${resource_name}; aborting before destructive delete."
                rm -f "$backup_file"
                exit 1
            fi
            log_success "Backup written to ${backup_file}"
        fi
    fi
}

# Delete Kubernetes resource
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-""}
    
    local ns_args=()
    if [[ -n "$namespace" ]]; then
        ns_args=(-n "$namespace")
    fi

    if kubectl get "$resource_type" "$resource_name" "${ns_args[@]}" &> /dev/null; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would delete $resource_type/$resource_name"
        else
            kubectl delete "$resource_type" "$resource_name" "${ns_args[@]}" --ignore-not-found=true
            log_info "Deleted $resource_type/$resource_name"
        fi
    else
        log_warn "$resource_type/$resource_name not found (already removed or never deployed)"
    fi
}

# Show confirmation prompt
confirm_removal() {
    if [[ "$SKIP_CONFIRMATION" == "true" ]]; then
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}WARNING: This will remove RDMA Shared Device Plugin from the cluster.${NC}"
    echo ""
    echo "The following will be removed:"
    echo "  - DaemonSet: rdma-shared-device-plugin (kube-system)"
    echo "  - ConfigMap: rdma-cdi-device-config (kube-system)"
    echo "  - ServiceAccount: rdma-shared-device-plugin (kube-system)"
    echo "  - ClusterRole: rdma-shared-device-plugin"
    echo "  - ClusterRoleBinding: rdma-shared-device-plugin"
    if [[ "$REMOVE_FLANNEL" == "true" ]]; then
        echo "  - Flannel CNI (kube-flannel namespace) -- --remove-flannel supplied"
    else
        echo "  - Flannel CNI: LEFT IN PLACE (pass --remove-flannel to tear it down)"
    fi
    echo ""
    echo "Backup will be created at: $BACKUP_DIR"
    echo ""
    read -p "Do you want to continue? (yes/no): " -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Removal cancelled by user"
        exit 0
    fi
}

# Main removal process
main() {
    log_info "Starting RDMA Shared Device Plugin removal..."
    
    # Pre-flight checks
    check_kubectl
    check_cluster
    
    # Show what will be removed
    confirm_removal
    
    # Create backup directory
    create_backup_dir
    
    echo ""
    log_info "=== Phase 1: Backing up Kubernetes resources ==="
    backup_resource "daemonset" "rdma-shared-device-plugin" "kube-system"
    backup_resource "configmap" "rdma-cdi-device-config" "kube-system"
    backup_resource "serviceaccount" "rdma-shared-device-plugin" "kube-system"
    backup_resource "clusterrole" "rdma-shared-device-plugin"
    backup_resource "clusterrolebinding" "rdma-shared-device-plugin"
    if [[ "$REMOVE_FLANNEL" == "true" ]]; then
        # Back up every Flannel object that Phase 3 will delete; backup and
        # delete must stay symmetric so the operator always has a restore path.
        backup_resource "daemonset" "kube-flannel-ds" "kube-flannel"
        backup_resource "configmap" "kube-flannel-cfg" "kube-flannel"
        backup_resource "serviceaccount" "flannel" "kube-flannel"
        backup_resource "clusterrole" "flannel"
        backup_resource "clusterrolebinding" "flannel"
        backup_resource "namespace" "kube-flannel"
    fi
    
    echo ""
    log_info "=== Phase 2: Removing RDMA device plugin ==="
    delete_resource "daemonset" "rdma-shared-device-plugin" "kube-system"
    delete_resource "configmap" "rdma-cdi-device-config" "kube-system"
    delete_resource "serviceaccount" "rdma-shared-device-plugin" "kube-system"
    delete_resource "clusterrole" "rdma-shared-device-plugin"
    delete_resource "clusterrolebinding" "rdma-shared-device-plugin"
    
    # Flannel teardown is opt-in. The Ansible task
    # (automation/playbooks/tasks/remove-cni-rdma-shared-device.yaml) leaves Flannel
    # in place because other workloads commonly depend on it; this script matches
    # that behaviour. Pass --remove-flannel to opt into a full teardown.
    if [[ "$REMOVE_FLANNEL" == "true" ]]; then
        echo ""
        log_info "=== Phase 3: Removing Flannel CNI (--remove-flannel) ==="
        delete_resource "daemonset" "kube-flannel-ds" "kube-flannel"
        delete_resource "configmap" "kube-flannel-cfg" "kube-flannel"
        delete_resource "serviceaccount" "flannel" "kube-flannel"
        delete_resource "clusterrole" "flannel"
        delete_resource "clusterrolebinding" "flannel"
        delete_resource "namespace" "kube-flannel"
    else
        echo ""
        log_info "=== Phase 3: Leaving Flannel CNI in place ==="
        log_info "Pass --remove-flannel to also tear down kube-flannel namespace and RBAC."
    fi
    
    echo ""
    log_info "=== Phase 4: Verification ==="
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Wait a moment for resources to be deleted
        sleep 3
        
        # Check for remaining RDMA pods
        local rdma_pods=$(kubectl get pods -n kube-system -l app=rdma-shared-device-plugin --no-headers 2>/dev/null | wc -l)
        if [[ $rdma_pods -eq 0 ]]; then
            log_info "✓ No RDMA device plugin pods remaining"
        else
            log_warn "⚠ Found $rdma_pods RDMA device plugin pods still running (may be terminating)"
        fi
        
        # Only check Flannel pods when the operator opted into Flannel teardown.
        # Otherwise Flannel is expected to still be running and reporting a count
        # would be misleading.
        if [[ "$REMOVE_FLANNEL" == "true" ]]; then
            local flannel_pods=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | wc -l)
            if [[ $flannel_pods -eq 0 ]]; then
                log_info "✓ No Flannel pods remaining"
            else
                log_warn "⚠ Found $flannel_pods Flannel pods still running (may be terminating)"
            fi
        fi
        
        # Check cornelis.com/hfi resource
        local hfi_nodes=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[].status.allocatable | select(.["cornelis.com/hfi"] != null) | .["cornelis.com/hfi"]' | wc -l)
        if [[ $hfi_nodes -eq 0 ]]; then
            log_info "✓ cornelis.com/hfi resource no longer advertised"
        else
            log_warn "⚠ cornelis.com/hfi resource still advertised on $hfi_nodes nodes (kubelet may need restart)"
        fi
        
        echo ""
        log_info "=== Cluster Status ==="
        kubectl get nodes -o wide
        
        echo ""
        log_info "=== Removal Complete ==="
        log_info "Backup location: $BACKUP_DIR"
        echo ""
        log_warn "Note: Nodes will be NotReady until a new CNI is deployed"
        log_warn "To restore networking, deploy a CNI plugin (Flannel, Multus+IPoIB, etc.)"
    else
        log_info "[DRY-RUN] No changes were made"
    fi
}

# Run main function
main
