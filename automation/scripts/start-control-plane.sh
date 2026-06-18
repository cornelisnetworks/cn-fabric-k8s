#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

source "$SCRIPT_DIR/lib/load-versions.sh"
source "$SCRIPT_DIR/lib/package-manager.sh"

POD_NETWORK_CIDR="${POD_NETWORK_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
API_SERVER_ADVERTISE_ADDRESS="${API_SERVER_ADVERTISE_ADDRESS:-}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
SKIP_WORKER_TAINT="${SKIP_WORKER_TAINT:-true}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Start Kubernetes control plane (with optional worker capability)

OPTIONS:
    --pod-network-cidr CIDR       Pod network CIDR (default: 10.244.0.0/16)
    --service-cidr CIDR           Service CIDR (default: 10.96.0.0/12)
    --apiserver-advertise-address IP  API server advertise address
    --control-plane-endpoint ENDPOINT Control plane endpoint for HA
    --skip-worker-taint           Allow control plane to run workloads (default: true)
    --no-skip-worker-taint        Prevent control plane from running workloads
    -h, --help                    Show this help message

EXAMPLES:
    $0
    $0 --apiserver-advertise-address 192.168.1.10
    $0 --no-skip-worker-taint
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --pod-network-cidr)
            POD_NETWORK_CIDR="$2"
            shift 2
            ;;
        --service-cidr)
            SERVICE_CIDR="$2"
            shift 2
            ;;
        --apiserver-advertise-address)
            API_SERVER_ADVERTISE_ADDRESS="$2"
            shift 2
            ;;
        --control-plane-endpoint)
            CONTROL_PLANE_ENDPOINT="$2"
            shift 2
            ;;
        --skip-worker-taint)
            SKIP_WORKER_TAINT=true
            shift
            ;;
        --no-skip-worker-taint)
            SKIP_WORKER_TAINT=false
            shift
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

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "=== Starting Kubernetes Control Plane ==="

if systemctl is-active --quiet kubelet; then
    echo "Kubelet is already running. Checking cluster status..."
    if kubectl get nodes &>/dev/null; then
        echo "Kubernetes cluster is already initialized and running"
        exit 0
    fi
fi

echo "Creating kubeadm configuration file with IPVS mode..."
cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: $POD_NETWORK_CIDR
  serviceSubnet: $SERVICE_CIDR
EOF

if [[ -n "$API_SERVER_ADVERTISE_ADDRESS" ]]; then
    cat >> /tmp/kubeadm-config.yaml <<EOF
localAPIEndpoint:
  advertiseAddress: $API_SERVER_ADVERTISE_ADDRESS
EOF
fi

if [[ -n "$CONTROL_PLANE_ENDPOINT" ]]; then
    cat >> /tmp/kubeadm-config.yaml <<EOF
controlPlaneEndpoint: $CONTROL_PLANE_ENDPOINT
EOF
fi

cat >> /tmp/kubeadm-config.yaml <<EOF
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  strictARP: true
EOF

echo "Initializing Kubernetes control plane with kubeadm..."
echo "Configuration file: /tmp/kubeadm-config.yaml"
cat /tmp/kubeadm-config.yaml

# SLES/openSUSE-only kubeadm preflight suppression; see kubeadm_preflight_ignores
# in lib/package-manager.sh for the full rationale.
KUBEADM_PREFLIGHT_IGNORES="$(kubeadm_preflight_ignores)"

kubeadm init --config /tmp/kubeadm-config.yaml ${KUBEADM_PREFLIGHT_IGNORES} | tee /tmp/kubeadm-init.log

echo ""
echo "Setting up kubeconfig for root user..."
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

if [[ -n "${SUDO_USER:-}" ]]; then
    echo "Setting up kubeconfig for user $SUDO_USER..."
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "$USER_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube"
fi

if [[ "$SKIP_WORKER_TAINT" == "true" ]]; then
    echo ""
    echo "Removing control-plane taint to allow workloads on this node..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
    kubectl taint nodes --all node-role.kubernetes.io/master- || true
fi

echo ""
echo "=== Control Plane Started Successfully ==="
echo ""
echo "Cluster info:"
kubectl cluster-info
echo ""
echo "Nodes:"
kubectl get nodes
echo ""
echo "Join command for worker nodes saved to: /tmp/kubeadm-init.log"
echo ""
echo "To get the join command later, run:"
echo "  kubeadm token create --print-join-command"
