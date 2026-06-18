#!/bin/bash

validate_ipoib_interface() {
    local interface="$1"

    if [[ -z "$interface" ]]; then
        echo "ERROR: IPoIB interface name is empty"
        echo ""
        echo "Supply the IPoIB interface via --ipoib-interface <ipoib_iface>"
        echo "Discover the live interface name on a target node with: ip link show"
        echo "See docs/architecture/networking.md for the platform mapping."
        exit 1
    fi

    echo "Validating IPoIB interface: $interface"

    if ! ip link show "$interface" &>/dev/null; then
        echo "ERROR: IPoIB interface '$interface' does not exist"
        echo ""
        echo "Available interfaces:"
        ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | sed 's/:$//'
        echo ""
        echo "Supply the IPoIB interface via --ipoib-interface <ipoib_iface>"
        echo "Discover the live interface name on a target node with: ip link show"
        echo "See docs/architecture/networking.md for the platform mapping."
        exit 1
    fi
    
    if ! ip link show "$interface" | grep -q "state UP"; then
        echo "ERROR: IPoIB interface '$interface' is not UP"
        echo ""
        ip link show "$interface"
        echo ""
        echo "Bring up the interface with: ip link set $interface up"
        exit 1
    fi
    
    if ! ip link show "$interface" | grep -q "link/infiniband"; then
        echo "WARNING: Interface '$interface' does not appear to be an InfiniBand interface"
        echo ""
        ip link show "$interface"
        echo ""
        if [ "${FORCE:-false}" = "true" ] || [ ! -t 0 ]; then
            echo "Non-interactive mode: continuing despite warning"
        else
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
    
    echo "✓ IPoIB interface '$interface' exists and is UP"
}

validate_kernel_modules() {
    echo "Validating kernel modules..."
    
    local required_modules=("ib_ipoib" "br_netfilter")
    local missing_modules=()
    
    for module in "${required_modules[@]}"; do
        if ! lsmod | grep -q "^$module"; then
            missing_modules+=("$module")
        fi
    done
    
    if [[ ${#missing_modules[@]} -gt 0 ]]; then
        echo "WARNING: Required kernel modules not loaded: ${missing_modules[*]}"
        echo "Attempting to load modules..."
        for module in "${missing_modules[@]}"; do
            if modprobe "$module" 2>/dev/null; then
                echo "✓ Loaded module: $module"
            else
                echo "ERROR: Failed to load module: $module"
                echo "Load manually with: modprobe $module"
                exit 1
            fi
        done
    fi
    
    echo "✓ Required kernel modules loaded: ${required_modules[*]}"
}

validate_l2_connectivity() {
    echo "Validating L2 connectivity for host-gw backend..."
    
    local default_iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -z "$default_iface" ]]; then
        echo "WARNING: Could not determine default network interface"
        return
    fi
    
    local default_network=$(ip route | grep "$default_iface" | grep -v default | awk '{print $1}' | head -n1)
    if [[ -z "$default_network" ]]; then
        echo "WARNING: Could not determine default network"
        return
    fi
    
    echo "✓ Default interface: $default_iface, network: $default_network"
    echo "  NOTE: Flannel host-gw requires all nodes on same L2 network (same subnet)"
}

get_ipoib_mode_mtu() {
    local mode="$1"
    
    case "$mode" in
        datagram)
            echo "2044"
            ;;
        connected)
            echo "65520"
            ;;
        *)
            echo "ERROR: Invalid IPoIB mode: $mode (must be 'datagram' or 'connected')"
            exit 1
            ;;
    esac
}

validate_ipoib_mode() {
    local mode="$1"
    
    if [[ "$mode" != "datagram" && "$mode" != "connected" ]]; then
        echo "ERROR: Invalid IPoIB mode: $mode"
        echo "Valid modes: datagram, connected"
        exit 1
    fi
    
    echo "✓ IPoIB mode: $mode"
}

validate_subnet() {
    local subnet="$1"
    local name="$2"
    
    if ! echo "$subnet" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
        echo "ERROR: Invalid $name subnet: $subnet"
        echo "Expected format: X.X.X.X/Y (e.g., 192.168.100.0/24)"
        exit 1
    fi
    
    echo "✓ $name subnet: $subnet"
}

check_kubectl_access() {
    echo "Checking kubectl access..."
    
    if ! command -v kubectl &>/dev/null; then
        echo "ERROR: kubectl not found in PATH"
        exit 1
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot access Kubernetes cluster"
        echo ""
        echo "Ensure:"
        echo "  1. Kubernetes cluster is running"
        echo "  2. kubectl is configured (KUBECONFIG or ~/.kube/config)"
        echo "  3. You have cluster-admin permissions"
        exit 1
    fi
    
    echo "✓ kubectl access verified"
}

wait_for_daemonset() {
    local name="$1"
    local namespace="$2"
    local timeout="${3:-300}"
    
    echo "Waiting for DaemonSet $name in namespace $namespace..."
    
    if ! kubectl rollout status daemonset/"$name" -n "$namespace" --timeout="${timeout}s"; then
        echo "ERROR: DaemonSet $name failed to roll out"
        echo ""
        echo "DaemonSet status:"
        kubectl get daemonset "$name" -n "$namespace" -o wide
        echo ""
        echo "Pod status:"
        kubectl get pods -n "$namespace" -l "name=$name" -o wide
        echo ""
        echo "Recent events:"
        kubectl get events -n "$namespace" --sort-by='.lastTimestamp' | tail -20
        exit 1
    fi
    
    echo "✓ DaemonSet $name rolled out successfully"
}

verify_cni_binary() {
    local binary_name="$1"
    local binary_path="/opt/cni/bin/$binary_name"
    
    echo "Verifying CNI binary: $binary_name"
    
    if [[ ! -f "$binary_path" ]]; then
        echo "ERROR: CNI binary not found: $binary_path"
        echo ""
        echo "Available CNI binaries:"
        ls -lh /opt/cni/bin/ 2>/dev/null || echo "  /opt/cni/bin/ does not exist"
        exit 1
    fi
    
    if [[ ! -x "$binary_path" ]]; then
        echo "ERROR: CNI binary not executable: $binary_path"
        exit 1
    fi
    
    echo "✓ CNI binary verified: $binary_path"
}

display_pod_interfaces() {
    local pod_name="$1"
    local namespace="${2:-default}"
    
    echo "Pod interfaces for $pod_name:"
    kubectl exec -n "$namespace" "$pod_name" -- ip addr show 2>/dev/null || {
        echo "ERROR: Could not get pod interfaces"
        return 1
    }
}

check_dual_interfaces() {
    local pod_name="$1"
    local namespace="${2:-default}"
    
    local eth0_exists=$(kubectl exec -n "$namespace" "$pod_name" -- ip addr show eth0 2>/dev/null && echo "yes" || echo "no")
    local net1_exists=$(kubectl exec -n "$namespace" "$pod_name" -- ip addr show net1 2>/dev/null && echo "yes" || echo "no")
    
    if [[ "$eth0_exists" == "yes" && "$net1_exists" == "yes" ]]; then
        echo "✓ Pod $pod_name has dual interfaces (eth0 + net1)"
        return 0
    else
        echo "ERROR: Pod $pod_name missing interfaces (eth0: $eth0_exists, net1: $net1_exists)"
        return 1
    fi
}

get_ipoib_interface_type() {
    local interface="$1"
    
    ip -d link show "$interface" | grep -o "mode [a-z]*" | awk '{print $2}'
}

display_deployment_summary() {
    local flannel_subnet="$1"
    local ipoib_interface="$2"
    local ipoib_subnet="$3"
    local ipoib_mode="$4"
    local ipoib_mtu="$5"
    
    cat <<EOF

==========================================
Multus + IPoIB Dual-Interface CNI Deployment
==========================================

Components:
  ✓ Flannel (host-gw) - Primary CNI for control plane (eth0)
  ✓ Multus CNI - Meta-plugin for multi-interface orchestration
  ✓ IPoIB CNI - Secondary network for data plane (net1)
  ✓ Whereabouts IPAM - Cluster-wide IP management
  ✓ NetworkAttachmentDefinition - IPoIB network configuration
  ✓ Auto-attach configuration - Automatic net1 attachment

Configuration:
  - Flannel subnet:  $flannel_subnet
  - IPoIB interface: $ipoib_interface
  - IPoIB subnet:    $ipoib_subnet
  - IPoIB mode:      $ipoib_mode
  - IPoIB MTU:       $ipoib_mtu

All pods will automatically receive:
  - eth0: Flannel network ($flannel_subnet)
  - net1: IPoIB network ($ipoib_subnet)

Next steps:
  1. Run verification tests: tests/02-verify-multus-ipoib.sh --quick
  2. Deploy your workloads - dual interfaces will be automatic
  3. Use net1 for high-performance data plane traffic

==========================================

EOF
}
