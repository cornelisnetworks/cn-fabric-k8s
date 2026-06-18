#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

source "$SCRIPT_DIR/lib/ipoib-helpers.sh"

FLANNEL_SUBNET="${FLANNEL_SUBNET:-10.244.0.0/16}"
IPOIB_INTERFACE="${IPOIB_INTERFACE:-}"
IPOIB_SUBNET="${IPOIB_SUBNET:-192.168.100.0/24}"
IPOIB_CNI_VERSION="${IPOIB_CNI_VERSION:-v1.1.0}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy Multus + CN-IPoIB dual-interface CNI for Kubernetes

This script deploys:
  - Flannel (host-gw) as primary CNI for control plane (eth0)
  - Multus CNI as meta-plugin for multi-interface orchestration
  - CN-IPoIB CNI for secondary network (net1) - native IPoIB data plane
  - Whereabouts IPAM for cluster-wide IP management
  - NetworkAttachmentDefinition for IPoIB network
  - Auto-attach configuration for automatic net1 attachment

OPTIONS:
    --flannel-subnet CIDR         Flannel subnet CIDR (default: 10.244.0.0/16)
    --ipoib-interface INTERFACE   IPoIB interface name (REQUIRED, supply <ipoib_iface> for the target cluster; discover with 'ip link show')
    --ipoib-subnet CIDR           IPoIB subnet CIDR (default: 192.168.100.0/24)
    --ipoib-cni-version VERSION   IPoIB CNI version (default: v1.1.0)
    -h, --help                    Show this help message

NOTE:
    IPoIB mode and MTU are automatically inherited from the parent interface.
    The CNI will detect and use the parent interface's configuration.

EXAMPLES:
    # Deploy with default settings (replace <ipoib_iface> with the live name from 'ip link show')
    $0 --ipoib-interface <ipoib_iface>

    # Deploy with custom subnet
    $0 --ipoib-interface <ipoib_iface> --ipoib-subnet 10.10.0.0/16

    # Deploy with custom Flannel subnet
    $0 --ipoib-interface <ipoib_iface> --flannel-subnet 10.100.0.0/16

    # See docs/architecture/networking.md for the historical platform mapping.

PREREQUISITES:
    - Kubernetes cluster initialized
    - IPoIB interface exists and is UP on all nodes
    - L2 connectivity between nodes (same subnet for host-gw)
    - Kernel modules loaded: ib_ipoib, br_netfilter
    - kubectl configured and accessible

VERIFICATION:
    After deployment, run:
      tests/02-verify-multus-ipoib.sh --quick

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --flannel-subnet)
            FLANNEL_SUBNET="$2"
            shift 2
            ;;
        --ipoib-interface)
            IPOIB_INTERFACE="$2"
            shift 2
            ;;
        --ipoib-subnet)
            IPOIB_SUBNET="$2"
            shift 2
            ;;
        --ipoib-cni-version)
            IPOIB_CNI_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ -z "$IPOIB_INTERFACE" ]]; then
    echo "ERROR: --ipoib-interface is required"
    echo ""
    usage
fi

echo "=== Deploying Multus + IPoIB Dual-Interface CNI ==="
echo ""
echo "Configuration:"
echo "  Flannel subnet:    $FLANNEL_SUBNET"
echo "  IPoIB interface:   $IPOIB_INTERFACE"
echo "  IPoIB subnet:      $IPOIB_SUBNET"
echo "  IPoIB CNI version: $IPOIB_CNI_VERSION"
echo "  IPoIB mode/MTU:    Auto-detected from parent interface"
echo ""

echo "[1/9] Validating prerequisites..."
validate_ipoib_interface "$IPOIB_INTERFACE"
validate_kernel_modules
validate_l2_connectivity
echo "✓ Prerequisites validated"
echo ""

echo "[2/9] Deploying Flannel (host-gw backend)..."
MANIFEST_DIR="/tmp/k8s-manifests-multus-ipoib"
mkdir -p "$MANIFEST_DIR"

sed "s|{{ flannel_subnet }}|$FLANNEL_SUBNET|g" \
    "$REPO_ROOT/manifests/cni/flannel-hostgw.yaml" > "$MANIFEST_DIR/flannel-hostgw.yaml"

kubectl apply -f "$MANIFEST_DIR/flannel-hostgw.yaml"
echo "Waiting for Flannel DaemonSet rollout..."
kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=300s
echo "✓ Flannel deployed"
echo ""

echo "[3/9] Deploying Multus CNI..."
kubectl apply -f "$REPO_ROOT/manifests/cni/multus-daemonset.yaml"
echo "Waiting for Multus DaemonSet rollout..."
kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=300s
echo "✓ Multus deployed"
echo ""

echo "[4/9] Building and deploying IPoIB CNI (this may take 2-3 minutes)..."
sed "s|{{ ipoib_cni_version }}|$IPOIB_CNI_VERSION|g" \
    "$REPO_ROOT/manifests/cni/ipoib-cni-daemonset.yaml" > "$MANIFEST_DIR/ipoib-cni-daemonset.yaml"

kubectl apply -f "$MANIFEST_DIR/ipoib-cni-daemonset.yaml"
echo "Waiting for IPoIB CNI build and rollout..."
kubectl rollout status daemonset/ipoib-cni -n kube-system --timeout=600s
echo "✓ IPoIB CNI built and deployed"
echo ""

echo "[5/9] Deploying Whereabouts IPAM..."
kubectl apply -f "$REPO_ROOT/manifests/cni/whereabouts-daemonset.yaml"
echo "Waiting for Whereabouts DaemonSet rollout..."
kubectl rollout status daemonset/whereabouts -n kube-system --timeout=300s
echo "✓ Whereabouts deployed"
echo ""

echo "[6/9] Creating NetworkAttachmentDefinition for IPoIB network..."
# Extract network prefix from subnet (e.g., 192.168.100.0/24 -> 192.168.100)
SUBNET_PREFIX=$(echo "$IPOIB_SUBNET" | sed 's/\.0\/.*$//')
export RANGE_START="${SUBNET_PREFIX}.10"
export RANGE_END="${SUBNET_PREFIX}.254"
export GATEWAY="${SUBNET_PREFIX}.1"
export IPOIB_INTERFACE
export IPOIB_SUBNET

envsubst < "$REPO_ROOT/manifests/cni/ipoib-network-attachment.yaml" > "$MANIFEST_DIR/ipoib-network-attachment.yaml"

kubectl apply -f "$MANIFEST_DIR/ipoib-network-attachment.yaml"
echo "✓ NetworkAttachmentDefinition created"
echo ""

echo "[7/9] Configuring automatic IPoIB network attachment..."
kubectl apply -f "$REPO_ROOT/manifests/cni/multus-default-config.yaml"
echo "Restarting Multus pods to apply configuration..."
kubectl delete pods -n kube-system -l name=multus
kubectl wait --for=condition=ready pod -n kube-system -l name=multus --timeout=120s
echo "✓ Automatic attachment configured"
echo ""

echo "[8/9] Verifying deployment..."
echo "Waiting for all nodes to become Ready..."
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=0
RETRIES=0
MAX_RETRIES=30

while [[ $READY_NODES -lt $TOTAL_NODES && $RETRIES -lt $MAX_RETRIES ]]; do
    READY_NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -o True | wc -l || echo 0)
    if [[ $READY_NODES -lt $TOTAL_NODES ]]; then
        echo "  $READY_NODES/$TOTAL_NODES nodes ready, waiting..."
        sleep 10
        ((RETRIES++))
    fi
done

if [[ $READY_NODES -lt $TOTAL_NODES ]]; then
    echo "WARNING: Not all nodes are ready ($READY_NODES/$TOTAL_NODES)"
else
    echo "✓ All nodes ready ($READY_NODES/$TOTAL_NODES)"
fi

echo ""
echo "Creating test pod to verify dual interfaces..."
kubectl run test-multus-ipoib --image=alpine:3.18 --restart=Never --command -- sleep 3600 2>/dev/null || true
sleep 5

if kubectl wait --for=condition=ready pod/test-multus-ipoib --timeout=60s 2>/dev/null; then
    echo "Test pod interfaces:"
    kubectl exec test-multus-ipoib -- ip addr show | grep -E "^[0-9]+:|inet " || true
    
    ETH0_EXISTS=$(kubectl exec test-multus-ipoib -- ip addr show eth0 2>/dev/null && echo "yes" || echo "no")
    NET1_EXISTS=$(kubectl exec test-multus-ipoib -- ip addr show net1 2>/dev/null && echo "yes" || echo "no")
    
    if [[ "$ETH0_EXISTS" == "yes" && "$NET1_EXISTS" == "yes" ]]; then
        echo "✓ Test pod has dual interfaces (eth0 + net1)"
    else
        echo "WARNING: Test pod missing interfaces (eth0: $ETH0_EXISTS, net1: $NET1_EXISTS)"
    fi
    
    kubectl delete pod test-multus-ipoib --ignore-not-found=true
else
    echo "WARNING: Test pod failed to start, skipping interface verification"
    kubectl delete pod test-multus-ipoib --ignore-not-found=true 2>/dev/null || true
fi
echo ""

echo "[9/9] Deployment summary"
echo "=========================================="
echo "Multus + IPoIB Dual-Interface CNI Deployment Complete"
echo "=========================================="
echo ""
echo "Components deployed:"
echo "  ✓ Flannel (host-gw) - Primary CNI for control plane (eth0)"
echo "  ✓ Multus CNI - Meta-plugin for multi-interface orchestration"
echo "  ✓ IPoIB CNI - Secondary network for data plane (net1)"
echo "  ✓ Whereabouts IPAM - Cluster-wide IP management"
echo "  ✓ NetworkAttachmentDefinition - IPoIB network configuration"
echo "  ✓ Auto-attach configuration - Automatic net1 attachment"
echo ""
echo "Configuration:"
echo "  - Flannel subnet: $FLANNEL_SUBNET"
echo "  - IPoIB interface: $IPOIB_INTERFACE"
echo "  - IPoIB subnet: $IPOIB_SUBNET"
echo "  - IPoIB mode/MTU: Auto-detected from parent interface"
echo ""
echo "All pods will automatically receive:"
echo "  - eth0: Flannel network ($FLANNEL_SUBNET)"
echo "  - net1: IPoIB network ($IPOIB_SUBNET)"
echo ""
echo "Next steps:"
echo "  1. Run verification tests: tests/02-verify-multus-ipoib.sh --quick"
echo "  2. Deploy your workloads - dual interfaces will be automatic"
echo "  3. Use net1 for high-performance data plane traffic"
echo "=========================================="
echo ""
echo "Deployment complete!"
