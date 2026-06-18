#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

source "$SCRIPT_DIR/lib/load-versions.sh"
source "$SCRIPT_DIR/lib/package-manager.sh"

DRAIN_NODE="${DRAIN_NODE:-true}"
DELETE_NODE="${DELETE_NODE:-false}"
FORCE="${FORCE:-false}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Stop Kubernetes node (control plane or worker)

OPTIONS:
    --drain                       Drain node before stopping (default: true)
    --no-drain                    Skip draining node
    --delete                      Delete node from cluster (for workers)
    --force                       Force stop without confirmation
    -h, --help                    Show this help message

EXAMPLES:
    $0                            Stop node with drain
    $0 --no-drain                 Stop node immediately
    $0 --delete                   Stop and remove worker from cluster

NOTES:
    - For control plane nodes, this stops the cluster
    - For worker nodes, use --delete to remove from cluster
    - Draining ensures graceful pod termination
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --drain)
            DRAIN_NODE=true
            shift
            ;;
        --no-drain)
            DRAIN_NODE=false
            shift
            ;;
        --delete)
            DELETE_NODE=true
            shift
            ;;
        --force)
            FORCE=true
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

echo "=== Stopping Kubernetes Node ==="

if ! systemctl is-active --quiet kubelet; then
    echo "Kubelet is not running. Node already stopped."
    exit 0
fi

NODE_NAME=$(hostname)
IS_CONTROL_PLANE=false

if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    IS_CONTROL_PLANE=true
    echo "Detected control plane node"
else
    echo "Detected worker node"
fi

if [[ "$DRAIN_NODE" == "true" ]]; then
    echo ""
    echo "Draining node $NODE_NAME..."
    if kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --force 2>/dev/null; then
        echo "Node drained successfully"
    else
        echo "Warning: Failed to drain node (cluster may be unreachable)"
    fi
fi

if [[ "$DELETE_NODE" == "true" && "$IS_CONTROL_PLANE" == "false" ]]; then
    echo ""
    echo "Deleting node $NODE_NAME from cluster..."
    if kubectl delete node "$NODE_NAME" 2>/dev/null; then
        echo "Node deleted from cluster"
    else
        echo "Warning: Failed to delete node (cluster may be unreachable)"
    fi
fi

echo ""
echo "Stopping kubelet service..."
systemctl stop kubelet

echo "Stopping container runtime..."
systemctl stop containerd || true

if [[ "$IS_CONTROL_PLANE" == "true" ]]; then
    echo ""
    echo "Stopping control plane components..."
    
    for component in kube-apiserver kube-controller-manager kube-scheduler etcd; do
        if pgrep -f "$component" > /dev/null; then
            echo "Stopping $component..."
            pkill -f "$component" || true
        fi
    done
    
    sleep 2
fi

echo ""
echo "Cleaning up running containers..."
if command -v crictl &> /dev/null; then
    crictl stop $(crictl ps -q) 2>/dev/null || true
    crictl rm $(crictl ps -aq) 2>/dev/null || true
fi

echo ""
echo "=== Node Stopped Successfully ==="
echo ""
if [[ "$IS_CONTROL_PLANE" == "true" ]]; then
    echo "Control plane stopped. To restart:"
    echo "  $SCRIPT_DIR/start-control-plane.sh"
else
    echo "Worker node stopped."
    if [[ "$DELETE_NODE" == "true" ]]; then
        echo "Node removed from cluster. To rejoin:"
        echo "  $SCRIPT_DIR/start-worker.sh --join-command \"...\""
    else
        echo "To restart:"
        echo "  systemctl start kubelet"
    fi
fi
