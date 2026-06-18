#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

source "$SCRIPT_DIR/lib/load-versions.sh"
source "$SCRIPT_DIR/lib/package-manager.sh"

JOIN_COMMAND="${JOIN_COMMAND:-}"
JOIN_TOKEN="${JOIN_TOKEN:-}"
JOIN_CA_CERT_HASH="${JOIN_CA_CERT_HASH:-}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Start Kubernetes worker node and join to control plane

OPTIONS:
    --join-command "COMMAND"      Full kubeadm join command (quoted)
    --control-plane-endpoint HOST:PORT  Control plane endpoint (e.g., 192.168.1.10:6443)
    --token TOKEN                 Bootstrap token
    --ca-cert-hash HASH           CA certificate hash (sha256:...)
    -h, --help                    Show this help message

EXAMPLES:
    $0 --join-command "kubeadm join 192.168.1.10:6443 --token abc123..."
    $0 --control-plane-endpoint 192.168.1.10:6443 --token abc123 --ca-cert-hash sha256:xyz...

NOTES:
    - Either provide --join-command OR all of (--control-plane-endpoint, --token, --ca-cert-hash)
    - Get join command from control plane: kubeadm token create --print-join-command
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --join-command)
            JOIN_COMMAND="$2"
            shift 2
            ;;
        --control-plane-endpoint)
            CONTROL_PLANE_ENDPOINT="$2"
            shift 2
            ;;
        --token)
            JOIN_TOKEN="$2"
            shift 2
            ;;
        --ca-cert-hash)
            JOIN_CA_CERT_HASH="$2"
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

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "=== Starting Kubernetes Worker Node ==="

if systemctl is-active --quiet kubelet; then
    echo "Kubelet is already running. Checking node status..."
    if kubectl get nodes 2>/dev/null | grep -q "$(hostname)"; then
        echo "This node is already part of a Kubernetes cluster"
        exit 0
    fi
fi

# SLES/openSUSE-only kubeadm preflight suppression; see kubeadm_preflight_ignores
# in lib/package-manager.sh for the full rationale.
KUBEADM_PREFLIGHT_IGNORES="$(kubeadm_preflight_ignores)"

if [[ -n "$JOIN_COMMAND" ]]; then
    echo "Using provided join command..."
    echo "Command: $JOIN_COMMAND"
    bash -c "$JOIN_COMMAND ${KUBEADM_PREFLIGHT_IGNORES}"
elif [[ -n "$CONTROL_PLANE_ENDPOINT" && -n "$JOIN_TOKEN" && -n "$JOIN_CA_CERT_HASH" ]]; then
    echo "Joining cluster at $CONTROL_PLANE_ENDPOINT..."
    kubeadm join "$CONTROL_PLANE_ENDPOINT" \
        --token "$JOIN_TOKEN" \
        --discovery-token-ca-cert-hash "$JOIN_CA_CERT_HASH" \
        ${KUBEADM_PREFLIGHT_IGNORES}
else
    echo "ERROR: Must provide either --join-command or all of (--control-plane-endpoint, --token, --ca-cert-hash)"
    echo ""
    usage
fi

echo ""
echo "=== Worker Node Joined Successfully ==="
echo ""
echo "To verify from control plane, run:"
echo "  kubectl get nodes"
