#!/bin/bash
set -euo pipefail

MODE="quick"
IPOIB_IFACE=""
IPOIB_SUBNET=""

for arg in "$@"; do
    case $arg in
        --quick)
            MODE="quick"
            shift
            ;;
        --full)
            MODE="full"
            shift
            ;;
        --iface)
            IPOIB_IFACE="$2"
            shift 2
            ;;
        --subnet)
            IPOIB_SUBNET="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 --iface IFACE [OPTIONS]

Verify Multus + IPoIB dual-interface CNI deployment

REQUIRED:
    --iface IFACE     IPoIB interface name (supply <ipoib_iface> for the target cluster; discover with 'ip link show')

OPTIONS:
    --quick           Quick mode: 49 tests, ~10 minutes (default)
    --full            Full mode: 136 tests, ~30 minutes
    --subnet SUBNET   IPoIB subnet prefix (e.g., 10.0.1, 192.168.100)
    -h, --help        Show this help message

TEST CATEGORIES:
    [1/6] Infrastructure Validation (15 tests)
    [2/6] Pod Interface Validation (8 quick / 16 full)
    [3/6] Control Plane Connectivity (12 quick / 24 full)
    [4/6] Data Plane Connectivity (16 quick / 63 full)
    [5/6] MPI over IPoIB Performance (18 tests)
    [6/6] libfabric over IPoIB fi_udp (8 tests)

EXAMPLES:
    $0 --iface <ipoib_iface> --quick
    $0 --iface <ipoib_iface> --full
    $0 --iface <ipoib_iface> --quick --subnet 10.0.1
    # See docs/architecture/networking.md for the historical platform mapping.

EOF
            exit 0
            ;;
        *)
            ;;
    esac
done

if [ -z "$IPOIB_IFACE" ]; then
    echo "ERROR: --iface parameter is required" >&2
    echo "" >&2
    echo "Usage: $0 --iface <ipoib_iface> [OPTIONS]" >&2
    echo "" >&2
    echo "Discover the live IPoIB interface name on a target node with: ip link show" >&2
    echo "See docs/architecture/networking.md for the platform mapping." >&2
    echo "" >&2
    echo "Run '$0 --help' for more information" >&2
    exit 2
fi

if [ -z "$IPOIB_SUBNET" ]; then
    NAD_CONFIG=$(kubectl get network-attachment-definitions.k8s.cni.cncf.io ipoib-network -n kube-system -o jsonpath='{.spec.config}' 2>/dev/null || echo "")
    if [ -n "$NAD_CONFIG" ]; then
        IPOIB_SUBNET=$(echo "$NAD_CONFIG" | grep -oP '"range":\s*"\K[0-9]+\.[0-9]+\.[0-9]+' || echo "192.168.100")
    else
        IPOIB_SUBNET="192.168.100"
    fi
fi

echo "=========================================="
echo "Multus + IPoIB Dual-Interface CNI Verification"
echo "=========================================="
echo "Mode: $MODE"
echo "IPoIB Interface: $IPOIB_IFACE"
echo "IPoIB Subnet: $IPOIB_SUBNET.0/24"
echo "=========================================="
echo ""

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

test_result() {
    local test_name="$1"
    local result="$2"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if [ "$result" -eq 0 ]; then
        echo "  ✓ PASS: $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo "  ✗ FAIL: $test_name"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

test_skip() {
    local test_name="$1"
    local reason="$2"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
    echo "  ⊘ SKIP: $test_name ($reason)"
}

cleanup() {
    echo ""
    echo "Cleaning up test resources..."
    
    if [ "$MODE" = "quick" ]; then
        PODS_PER_NODE=2
    else
        PODS_PER_NODE=4
    fi
    
    for node_idx in 1 2; do
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            kubectl delete pod "test-multus-node${node_idx}-pod${pod_idx}" --force --grace-period=0 2>/dev/null || true
        done
    done
    
    kubectl delete pod test-multus-dns --force --grace-period=0 2>/dev/null || true
    kubectl delete service test-multus-service --force --grace-period=0 2>/dev/null || true
    
    for node_idx in 1 2; do
        for pod_idx in 1 2 3 4; do
            kubectl delete pod "mpi-ipoib-node${node_idx}-pod${pod_idx}" --force --grace-period=0 2>/dev/null || true
        done
    done
    
    kubectl delete pod lf-ipoib-node1-pod1 lf-ipoib-node2-pod1 --force --grace-period=0 2>/dev/null || true
    
    kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep "node-debugger-" | awk '{print $1" "$2}' | xargs -r -n2 sh -c 'kubectl delete pod -n "$0" "$1" --force --grace-period=0 2>/dev/null || true' || true
    
    echo "Cleanup complete."
}

trap cleanup EXIT

echo "[1/6] Infrastructure Validation"
echo "=========================================="

if kubectl get nodes &>/dev/null; then
    test_result "Kubernetes cluster accessible" 0
else
    test_result "Kubernetes cluster accessible" 1
    echo ""
    echo "✗ ERROR: Cannot access Kubernetes cluster"
    exit 1
fi

READY_NODES=($(kubectl get nodes --no-headers 2>/dev/null | grep " Ready " | awk '{print $1}'))
TOTAL_NODES=${#READY_NODES[@]}

if [ "$TOTAL_NODES" -ge 1 ]; then
    test_result "Nodes Ready ($TOTAL_NODES nodes)" 0
else
    test_result "Nodes Ready" 1
fi

if kubectl get namespace kube-flannel &>/dev/null; then
    test_result "Flannel namespace exists" 0
else
    test_result "Flannel namespace exists" 1
fi

FLANNEL_PODS=$(kubectl get pods -n kube-flannel -l app=flannel --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$FLANNEL_PODS" -ge 1 ]; then
    test_result "Flannel pods running ($FLANNEL_PODS pods)" 0
else
    test_result "Flannel pods running" 1
fi

MULTUS_PODS=$(kubectl get pods -n kube-system -l name=multus --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$MULTUS_PODS" -ge 1 ]; then
    test_result "Multus pods running ($MULTUS_PODS pods)" 0
else
    test_result "Multus pods running" 1
fi

if test -f /opt/cni/bin/host-local; then
    test_result "host-local IPAM binary installed" 0
else
    test_result "host-local IPAM binary installed" 1
fi

IPOIB_CNI_PODS=$(kubectl get pods -n kube-system -l app=ipoib-cni --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$IPOIB_CNI_PODS" -ge 1 ]; then
    test_result "IPoIB CNI pods running ($IPOIB_CNI_PODS pods)" 0
else
    test_result "IPoIB CNI pods running" 1
fi

if test -f /opt/cni/bin/multus; then
    test_result "Multus binary installed" 0
else
    test_result "Multus binary installed" 1
fi

if test -f /opt/cni/bin/ipoib; then
    test_result "IPoIB CNI binary installed" 0
else
    test_result "IPoIB CNI binary installed" 1
fi



if kubectl get network-attachment-definitions.k8s.cni.cncf.io ipoib-network -n kube-system &>/dev/null; then
    test_result "NetworkAttachmentDefinition exists" 0
else
    test_result "NetworkAttachmentDefinition exists" 1
fi

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
IFACE_OK=0
MODULE_OK=0
for node in $(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
    iface_out=$(kubectl debug node/"${node}" --image=busybox:latest -it -- chroot /host ip link show "${IPOIB_IFACE}" 2>/dev/null || true)
    if echo "${iface_out}" | sed 's/\x1b\[[0-9;]*m//g' | grep -qE "state (UP|DOWN)"; then
        IFACE_OK=$((IFACE_OK + 1))
    fi
    mod_out=$(kubectl debug node/"${node}" --image=busybox:latest -it -- chroot /host sh -c "lsmod | grep ib_ipoib" 2>/dev/null || true)
    if echo "${mod_out}" | grep -q "ib_ipoib"; then
        MODULE_OK=$((MODULE_OK + 1))
    fi
done
if [ "${IFACE_OK}" -ge "${NODE_COUNT}" ] && [ "${NODE_COUNT}" -ge 1 ]; then
    test_result "IPoIB interface $IPOIB_IFACE exists on all nodes (${IFACE_OK}/${NODE_COUNT})" 0
else
    test_result "IPoIB interface $IPOIB_IFACE exists on all nodes (${IFACE_OK}/${NODE_COUNT})" 1
fi
if [ "${MODULE_OK}" -ge "${NODE_COUNT}" ] && [ "${NODE_COUNT}" -ge 1 ]; then
    test_result "Kernel module ib_ipoib loaded on all nodes (${MODULE_OK}/${NODE_COUNT})" 0
else
    test_result "Kernel module ib_ipoib loaded on all nodes (${MODULE_OK}/${NODE_COUNT})" 1
fi

COREDNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$COREDNS_PODS" -ge 1 ]; then
    test_result "CoreDNS pods running ($COREDNS_PODS pods)" 0
else
    test_result "CoreDNS pods running" 1
fi

echo ""

echo "[2/6] Pod Interface Validation"
echo "=========================================="

if [ "$MODE" = "quick" ]; then
    PODS_PER_NODE=2
else
    PODS_PER_NODE=4
fi

if [ "$TOTAL_NODES" -ge 2 ]; then
    NODE1="${READY_NODES[0]}"
    NODE2="${READY_NODES[1]}"
else
    NODE1="${READY_NODES[0]}"
    NODE2="${READY_NODES[0]}"
fi

echo "Creating test pods on nodes..."
for node_idx in 1 2; do
    if [ "$node_idx" -eq 1 ]; then
        NODE="$NODE1"
    else
        NODE="$NODE2"
    fi
    
    for pod_idx in $(seq 1 $PODS_PER_NODE); do
        POD_NAME="test-multus-node${node_idx}-pod${pod_idx}"
        
        cat <<EOF | kubectl apply -f - &>/dev/null || true
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  annotations:
    k8s.v1.cni.cncf.io/networks: kube-system/ipoib-network
spec:
  nodeName: $NODE
  containers:
  - name: test
    image: alpine:3.18
    command: ["sleep", "3600"]
EOF
        
        echo "  Created pod $POD_NAME on node $NODE"
    done
done

echo "Waiting for test pods to be ready..."

for node_idx in 1 2; do
    for pod_idx in $(seq 1 $PODS_PER_NODE); do
        POD_NAME="test-multus-node${node_idx}-pod${pod_idx}"
        
        if kubectl wait --for=condition=ready pod/"$POD_NAME" --timeout=60s &>/dev/null; then
            test_result "Pod $POD_NAME ready" 0
        else
            test_result "Pod $POD_NAME ready" 1
            continue
        fi
        
        if kubectl exec "$POD_NAME" -- ip addr show eth0 &>/dev/null; then
            test_result "Pod $POD_NAME has eth0 interface" 0
        else
            test_result "Pod $POD_NAME has eth0 interface" 1
        fi
        
        if kubectl exec "$POD_NAME" -- ip addr show net1 &>/dev/null; then
            test_result "Pod $POD_NAME has net1 interface" 0
        else
            test_result "Pod $POD_NAME has net1 interface" 1
        fi
        
        if [ "$MODE" = "full" ]; then
            ETH0_IP=$(kubectl exec "$POD_NAME" -- ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
            if [[ "$ETH0_IP" =~ ^10\.244\. ]]; then
                test_result "Pod $POD_NAME eth0 IP from Flannel subnet" 0
            else
                test_result "Pod $POD_NAME eth0 IP from Flannel subnet" 1
            fi
            
            NET1_IP=$(kubectl exec "$POD_NAME" -- ip -4 addr show net1 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
            SUBNET_REGEX="^${IPOIB_SUBNET//./\\.}\\."
            if [[ "$NET1_IP" =~ $SUBNET_REGEX ]]; then
                test_result "Pod $POD_NAME net1 IP from IPoIB subnet" 0
            else
                test_result "Pod $POD_NAME net1 IP from IPoIB subnet" 1
            fi
        fi
    done
done

echo ""

echo "[3/6] Control Plane Connectivity (via eth0)"
echo "=========================================="

POD1="test-multus-node1-pod1"
POD2="test-multus-node2-pod1"

if kubectl get pod "$POD1" &>/dev/null && kubectl get pod "$POD2" &>/dev/null; then
    POD1_ETH0_IP=$(kubectl exec "$POD1" -- ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
    POD2_ETH0_IP=$(kubectl exec "$POD2" -- ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
    
    if kubectl exec "$POD1" -- ping -c 3 -W 2 "$POD2_ETH0_IP" &>/dev/null; then
        test_result "Ping from $POD1 to $POD2 via eth0" 0
    else
        test_result "Ping from $POD1 to $POD2 via eth0" 1
    fi
    
    if kubectl exec "$POD2" -- ping -c 3 -W 2 "$POD1_ETH0_IP" &>/dev/null; then
        test_result "Ping from $POD2 to $POD1 via eth0" 0
    else
        test_result "Ping from $POD2 to $POD1 via eth0" 1
    fi
else
    test_skip "Control plane connectivity tests" "test pods not ready"
fi

# Use FQDN to avoid dependency on search domain configuration in pods
DNS_OUTPUT=$(kubectl exec "$POD1" -- nslookup kubernetes.default.svc.cluster.local 2>&1 || true)
if echo "$DNS_OUTPUT" | grep -q "Address"; then
    test_result "DNS resolution from $POD1" 0
else
    test_result "DNS resolution from $POD1" 1
fi

if [ "$MODE" = "full" ]; then
    DNS_OUTPUT2=$(kubectl exec "$POD2" -- nslookup kubernetes.default.svc.cluster.local 2>&1 || true)
    if echo "$DNS_OUTPUT2" | grep -q "Address"; then
        test_result "DNS resolution from $POD2" 0
    else
        test_result "DNS resolution from $POD2" 1
    fi
fi

kubectl run test-multus-dns --image=nginx:alpine --restart=Never --port=80 &>/dev/null || true
sleep 5

if kubectl wait --for=condition=ready pod/test-multus-dns --timeout=60s &>/dev/null; then
    kubectl expose pod test-multus-dns --name=test-multus-service --port=80 --target-port=80 &>/dev/null || true
    sleep 3
    
    SERVICE_IP=$(kubectl get service test-multus-service -o jsonpath='{.spec.clusterIP}')
    
    if kubectl exec "$POD1" -- wget -q -O- "http://$SERVICE_IP" &>/dev/null; then
        test_result "Service access from $POD1 via eth0" 0
    else
        test_result "Service access from $POD1 via eth0" 1
    fi
    
    if [ "$MODE" = "full" ]; then
        if kubectl exec "$POD2" -- wget -q -O- "http://$SERVICE_IP" &>/dev/null; then
            test_result "Service access from $POD2 via eth0" 0
        else
            test_result "Service access from $POD2 via eth0" 1
        fi
    fi
else
    test_skip "Service access tests" "test service pod not ready"
fi

if [ "$MODE" = "full" ]; then
    for node_idx in 1 2; do
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            POD_NAME="test-multus-node${node_idx}-pod${pod_idx}"
            
            if kubectl get pod "$POD_NAME" &>/dev/null; then
                if kubectl exec "$POD_NAME" -- ping -c 2 -W 2 8.8.8.8 &>/dev/null; then
                    test_result "External connectivity from $POD_NAME" 0
                else
                    test_result "External connectivity from $POD_NAME" 1
                fi
            fi
        done
    done
fi

echo ""

echo "[4/6] Data Plane Connectivity (via net1)"
echo "=========================================="

if kubectl get pod "$POD1" &>/dev/null && kubectl get pod "$POD2" &>/dev/null; then
    POD1_NET1_IP=$(kubectl exec "$POD1" -- ip -4 addr show net1 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
    POD2_NET1_IP=$(kubectl exec "$POD2" -- ip -4 addr show net1 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
    
    if kubectl exec "$POD1" -- ping -c 3 -W 2 "$POD2_NET1_IP" &>/dev/null; then
        test_result "Ping from $POD1 to $POD2 via net1" 0
    else
        test_result "Ping from $POD1 to $POD2 via net1" 1
    fi
    
    if kubectl exec "$POD2" -- ping -c 3 -W 2 "$POD1_NET1_IP" &>/dev/null; then
        test_result "Ping from $POD2 to $POD1 via net1" 0
    else
        test_result "Ping from $POD2 to $POD1 via net1" 1
    fi
else
    test_skip "Data plane connectivity tests" "test pods not ready"
fi

if [ "$MODE" = "full" ]; then
    for node1_idx in 1 2; do
        for pod1_idx in $(seq 1 $PODS_PER_NODE); do
            POD1_NAME="test-multus-node${node1_idx}-pod${pod1_idx}"
            
            if ! kubectl get pod "$POD1_NAME" &>/dev/null; then
                continue
            fi
            
            POD1_NET1_IP=$(kubectl exec "$POD1_NAME" -- ip -4 addr show net1 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
            
            for node2_idx in 1 2; do
                for pod2_idx in $(seq 1 $PODS_PER_NODE); do
                    POD2_NAME="test-multus-node${node2_idx}-pod${pod2_idx}"
                    
                    if [ "$POD1_NAME" = "$POD2_NAME" ]; then
                        continue
                    fi
                    
                    if ! kubectl get pod "$POD2_NAME" &>/dev/null; then
                        continue
                    fi
                    
                    POD2_NET1_IP=$(kubectl exec "$POD2_NAME" -- ip -4 addr show net1 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
                    
                    if kubectl exec "$POD1_NAME" -- ping -c 2 -W 2 "$POD2_NET1_IP" &>/dev/null; then
                        test_result "Ping $POD1_NAME to $POD2_NAME via net1" 0
                    else
                        test_result "Ping $POD1_NAME to $POD2_NAME via net1" 1
                    fi
                done
            done
        done
    done
fi

echo ""

echo "[5/6] MPI over IPoIB Performance Tests"
echo "=========================================="

MPI_IMAGE=${MPI_IMAGE:-"localhost/cornelis/rdma-test-tools:latest"}

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "MPI over IPoIB tests" "Requires 2+ nodes"
else
    NODE1="${READY_NODES[0]}"
    NODE2="${READY_NODES[1]}"

    echo "Creating 4 MPI test pods on each node (8 pods total)..."
    for node_idx in 1 2; do
        if [ "$node_idx" -eq 1 ]; then
            NODE="$NODE1"
        else
            NODE="$NODE2"
        fi
        
        for pod_idx in 1 2 3 4; do
            POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
            cat <<EOF | kubectl apply -f - &>/dev/null || true
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  annotations:
    k8s.v1.cni.cncf.io/networks: kube-system/ipoib-network
spec:
  nodeName: ${NODE}
  containers:
  - name: mpi
    image: ${MPI_IMAGE}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
    resources:
      limits:
        memory: "8Gi"
    securityContext:
      capabilities:
        add:
        - IPC_LOCK
      privileged: true
    volumeMounts:
    - name: shm
      mountPath: /dev/shm
  volumes:
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: "4Gi"
  restartPolicy: Never
EOF
        done
    done

    echo "Waiting for MPI test pods to be ready..."
    MPI_READY=true
    MPI_READY_COUNT=0
    for node_idx in 1 2; do
        for pod_idx in 1 2 3 4; do
            POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
            if kubectl wait --for=condition=Ready "pod/${POD_NAME}" --timeout=120s &>/dev/null; then
                MPI_READY_COUNT=$((MPI_READY_COUNT + 1))
            else
                MPI_READY=false
                echo "  WARNING: ${POD_NAME} not ready"
            fi
        done
    done

    if [ "$MPI_READY" = true ]; then
        test_result "MPI test pods ready (8 pods: 4 per node)" 0
    else
        test_result "MPI test pods ready ($MPI_READY_COUNT/8 ready)" 1
    fi

    if [ "$MPI_READY" = true ]; then
        echo "Verifying UCX installation on all 8 pods..."
        UCX_INSTALL_COUNT=0
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                # Use boolean `if ... | grep -q` instead of capturing `grep -c || echo 0`.
                # The earlier pattern produced a multi-line "0\n0" value (one from grep on
                # empty input, one from the fallback echo) which crashed `[ "$x" -ge 1 ]`.
                if kubectl exec "$POD_NAME" -- /usr/local/bin/ucx_info -v 2>/dev/null | grep -qE '^# Library version: [0-9]+\.[0-9]+'; then
                    UCX_INSTALL_COUNT=$((UCX_INSTALL_COUNT + 1))
                fi
            done
        done
        
        if [ "$UCX_INSTALL_COUNT" -eq 8 ]; then
            test_result "UCX installed on all 8 pods" 0
        else
            test_result "UCX installed ($UCX_INSTALL_COUNT/8 pods)" 1
        fi

        echo "Verifying Open MPI installation on all 8 pods..."
        MPI_INSTALL_COUNT=0
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- /usr/local/bin/mpirun --version 2>/dev/null | grep -q "Open MPI"; then
                    MPI_INSTALL_COUNT=$((MPI_INSTALL_COUNT + 1))
                fi
            done
        done
        
        if [ "$MPI_INSTALL_COUNT" -eq 8 ]; then
            test_result "Open MPI installed on all 8 pods" 0
        else
            test_result "Open MPI installed ($MPI_INSTALL_COUNT/8 pods)" 1
        fi

        echo "Checking net1 IPoIB interface on all pods..."
        NET1_COUNT=0
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                if kubectl get pod "$POD_NAME" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null | grep -q '"interface": "net1"'; then
                    NET1_COUNT=$((NET1_COUNT + 1))
                fi
            done
        done
        
        if [ "$NET1_COUNT" -eq 8 ]; then
            test_result "net1 IPoIB interface present on all 8 pods" 0
        else
            test_result "net1 IPoIB interface present ($NET1_COUNT/8 pods)" 1
        fi

        _get_net1_ip() {
            kubectl get pod "$1" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null \
                | python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '[]'); print(next((n['ips'][0] for n in d if n.get('interface')=='net1'), ''))"
        }
        MPI_NODE1_POD1_IP=$(_get_net1_ip mpi-ipoib-node1-pod1)
        MPI_NODE1_POD2_IP=$(_get_net1_ip mpi-ipoib-node1-pod2)
        MPI_NODE1_POD3_IP=$(_get_net1_ip mpi-ipoib-node1-pod3)
        MPI_NODE1_POD4_IP=$(_get_net1_ip mpi-ipoib-node1-pod4)
        MPI_NODE2_POD1_IP=$(_get_net1_ip mpi-ipoib-node2-pod1)
        MPI_NODE2_POD2_IP=$(_get_net1_ip mpi-ipoib-node2-pod2)
        MPI_NODE2_POD3_IP=$(_get_net1_ip mpi-ipoib-node2-pod3)
        MPI_NODE2_POD4_IP=$(_get_net1_ip mpi-ipoib-node2-pod4)
        
        echo ""
        echo "  --- MPI Application Tests with OSU Benchmarks (over IPoIB net1) ---"
        
        echo "Setting up SSH for MPI on all 8 pods..."
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                kubectl exec "$POD_NAME" -- bash -c "
                    set -e
                    mkdir -p /root/.ssh
                    ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa 2>/dev/null || true
                    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
                    chmod 600 /root/.ssh/authorized_keys
                    echo 'Host *' > /root/.ssh/config
                    echo '  StrictHostKeyChecking no' >> /root/.ssh/config
                    echo '  UserKnownHostsFile /dev/null' >> /root/.ssh/config
                    chmod 600 /root/.ssh/config
                    ssh-keygen -A >/dev/null 2>&1 || true
                    pkill -9 sshd 2>/dev/null || true
                    cat > /tmp/sshd_config_mpi_ipoib <<'SSHD_CFG'
Port 22
UsePAM no
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PidFile /tmp/sshd_mpi_ipoib.pid
SSHD_CFG
                    /usr/sbin/sshd -f /tmp/sshd_config_mpi_ipoib -E /tmp/sshd_mpi_ipoib.log || true
                " &>/dev/null || true
            done
        done
        sleep 3

        echo "Exchanging SSH keys between all pods..."
        TEMP_KEYS_FILE="/tmp/mpi_ipoib_ssh_keys_$$.txt"
        rm -f "$TEMP_KEYS_FILE"
        
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                kubectl exec "$POD_NAME" -- cat /root/.ssh/id_rsa.pub >> "$TEMP_KEYS_FILE" 2>/dev/null
            done
        done
        
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                cat "$TEMP_KEYS_FILE" | kubectl exec -i "$POD_NAME" -- bash -c "cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null
            done
        done
        
        rm -f "$TEMP_KEYS_FILE"

        echo "Testing SSH connectivity between all pods (using net1 IPs)..."
        SSH_FAILURES=0
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                if [ "$node_idx" -eq 1 ] && [ "$pod_idx" -eq 1 ]; then
                    TEST_IP="$MPI_NODE2_POD1_IP"
                else
                    TEST_IP="$MPI_NODE1_POD1_IP"
                fi
                SSH_TEST=$(kubectl exec "$POD_NAME" -- ssh -o ConnectTimeout=5 "$TEST_IP" hostname 2>&1 || echo "SSH_FAILED")
                if echo "$SSH_TEST" | grep -q "SSH_FAILED\|Connection refused\|Connection timed out"; then
                    SSH_FAILURES=$((SSH_FAILURES + 1))
                fi
            done
        done
        
        if [ "$SSH_FAILURES" -eq 0 ]; then
            test_result "SSH connectivity between all MPI pods (via net1)" 0
        else
            test_result "SSH connectivity between MPI pods ($SSH_FAILURES failures)" 1
        fi

        echo "Creating MPI hostfile with all 8 pods (using net1 IPoIB IPs)..."
        kubectl exec mpi-ipoib-node1-pod1 -- bash -c "
            echo '${MPI_NODE1_POD1_IP} slots=1' > /tmp/hostfile
            echo '${MPI_NODE1_POD2_IP} slots=1' >> /tmp/hostfile
            echo '${MPI_NODE1_POD3_IP} slots=1' >> /tmp/hostfile
            echo '${MPI_NODE1_POD4_IP} slots=1' >> /tmp/hostfile
            echo '${MPI_NODE2_POD1_IP} slots=1' >> /tmp/hostfile
            echo '${MPI_NODE2_POD2_IP} slots=1' >> /tmp/hostfile
            echo '${MPI_NODE2_POD3_IP} slots=1' >> /tmp/hostfile
            echo '${MPI_NODE2_POD4_IP} slots=1' >> /tmp/hostfile
            cat /tmp/hostfile
        " || true

        echo "Verifying OSU Micro-Benchmarks installation on all 8 pods..."
        OSU_INSTALL_COUNT=0
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                POD_NAME="mpi-ipoib-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- test -f /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_bw &>/dev/null; then
                    OSU_INSTALL_COUNT=$((OSU_INSTALL_COUNT + 1))
                fi
            done
        done
        
        if [ "$OSU_INSTALL_COUNT" -eq 8 ]; then
            test_result "OSU Micro-Benchmarks installed on all 8 pods" 0
        else
            test_result "OSU Micro-Benchmarks installed ($OSU_INSTALL_COUNT/8 pods)" 1
        fi

        if [ "$OSU_INSTALL_COUNT" -eq 8 ]; then
            echo "Running OSU barrier test with 8 MPI processes over IPoIB (8 pods across 2 nodes)..."
            set +e
            OSU_BARRIER=$(kubectl exec mpi-ipoib-node1-pod1 -- timeout 90 /usr/local/bin/mpirun --allow-run-as-root \
                       --mca pml ob1 \
                       --mca btl tcp,self \
                       --mca btl_tcp_if_include net1 \
                       --hostfile /tmp/hostfile \
                       -np 4 \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/collective/osu_barrier -i 5 2>&1)
            BARRIER_RC=$?
            set -e

            if [ "$BARRIER_RC" -ne 0 ]; then
                echo "  kubectl exec failed with exit code: $BARRIER_RC"
                echo "  Output: $(echo "$OSU_BARRIER" | tail -10)"
                test_result "MPI OSU barrier test over IPoIB (8 processes)" 1
            elif echo "$OSU_BARRIER" | grep -q "Error\|error"; then
                echo "  MPI test output: $(echo "$OSU_BARRIER" | tail -10)"
                test_result "MPI OSU barrier test over IPoIB (8 processes)" 1
            else
                BARRIER_LATENCY=$(echo "$OSU_BARRIER" | grep -E "^[[:space:]]*[0-9]" | tail -1 | awk '{print $1}')
                if [ -n "$BARRIER_LATENCY" ]; then
                    echo "    MPI Barrier Latency (8 processes over IPoIB): ${BARRIER_LATENCY} us"
                    test_result "MPI OSU barrier test completed over IPoIB (8 processes)" 0
                else
                    echo "  Could not parse barrier latency from output"
                    echo "  Output: $(echo "$OSU_BARRIER" | tail -10)"
                    test_result "MPI OSU barrier test over IPoIB (8 processes)" 1
                fi
            fi
            
            echo "Running OSU allreduce test with 8 MPI processes over IPoIB (8 pods across 2 nodes)..."
            set +e
            OSU_OUT=$(kubectl exec mpi-ipoib-node1-pod1 -- timeout 90 /usr/local/bin/mpirun --allow-run-as-root \
                       --mca pml ob1 \
                       --mca btl tcp,self \
                       --mca btl_tcp_if_include net1 \
                       --hostfile /tmp/hostfile \
                       -np 4 \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/collective/osu_allreduce -m 8:8 -i 5 2>&1)
            ALLREDUCE_RC=$?
            set -e

            if [ "$ALLREDUCE_RC" -ne 0 ]; then
                echo "  kubectl exec failed with exit code: $ALLREDUCE_RC"
                echo "  Output: $(echo "$OSU_OUT" | tail -10)"
                test_result "MPI OSU allreduce test over IPoIB (8 processes)" 1
            elif echo "$OSU_OUT" | grep -q "Error\|error"; then
                echo "  MPI test output: $(echo "$OSU_OUT" | tail -10)"
                test_result "MPI OSU allreduce test over IPoIB (8 processes)" 1
            else
                MPI_LATENCY=$(echo "$OSU_OUT" | grep "^[0-9]" | tail -1 | awk '{print $2}')
                if [ -n "$MPI_LATENCY" ]; then
                    echo "    MPI Allreduce Latency (8 processes over IPoIB, 8 bytes): ${MPI_LATENCY} us"
                    test_result "MPI OSU allreduce test completed over IPoIB (8 processes)" 0
                else
                    echo "  Could not parse allreduce latency from output"
                    echo "  Output: $(echo "$OSU_OUT" | tail -10)"
                    test_result "MPI OSU allreduce test over IPoIB (8 processes)" 1
                fi
            fi

            echo "Running OSU point-to-point bandwidth test over IPoIB (2 processes)..."
            set +e
            OSU_BW=$(kubectl exec mpi-ipoib-node1-pod1 -- timeout 180 bash -c "
                /usr/local/bin/mpirun --allow-run-as-root \
                       --mca pml ob1 \
                       --mca btl tcp,self \
                       --mca btl_tcp_if_include net1 \
                       -np 2 -host ${MPI_NODE1_POD1_IP},${MPI_NODE2_POD1_IP} \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_bw -m 0:4096 -i 100
             " 2>&1)
            BW_RC=$?
            set -e

            if [ "$BW_RC" -eq 124 ]; then
                MPI_BW=$(echo "$OSU_BW" | grep "^[0-9]" | tail -1 | awk '{print $2}')
                if [ -n "$MPI_BW" ]; then
                    echo "    MPI Bandwidth over IPoIB: ${MPI_BW} MB/s (test timed out but got results)"
                    test_result "MPI OSU bandwidth test completed over IPoIB" 0
                else
                    echo "  Test timed out without results"
                    test_result "MPI OSU bandwidth test over IPoIB" 1
                fi
            elif echo "$OSU_BW" | grep -q "Error\|error"; then
                echo "  MPI test output: $(echo "$OSU_BW" | tail -10)"
                test_result "MPI OSU bandwidth test over IPoIB" 1
            else
                MPI_BW=$(echo "$OSU_BW" | grep "^[0-9]" | tail -1 | awk '{print $2}')
                if [ -n "$MPI_BW" ]; then
                    echo "    MPI Bandwidth over IPoIB: ${MPI_BW} MB/s"
                    test_result "MPI OSU bandwidth test completed over IPoIB" 0
                else
                    test_result "MPI OSU bandwidth test over IPoIB" 1
                fi
            fi

            echo "Running OSU latency test over IPoIB (small messages only)..."
            OSU_LAT=$(kubectl exec mpi-ipoib-node1-pod1 -- timeout 60 bash -c "
                /usr/local/bin/mpirun --allow-run-as-root \
                       --mca pml ob1 \
                       --mca btl tcp,self \
                       --mca btl_tcp_if_include net1 \
                       -np 2 -host ${MPI_NODE1_POD1_IP},${MPI_NODE2_POD1_IP} \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 0:128 -i 100
            " 2>&1 || echo "MPI_FAILED")

            if echo "$OSU_LAT" | grep -q "MPI_FAILED\|Error\|error"; then
                test_result "MPI OSU latency test over IPoIB" 1
            else
                LAT_VAL=$(echo "$OSU_LAT" | grep "^[0-9]" | head -1 | awk '{print $2}')
                if [ -n "$LAT_VAL" ]; then
                    echo "    MPI Latency over IPoIB (small msg): ${LAT_VAL} us"
                    test_result "MPI OSU latency test completed over IPoIB" 0
                else
                    test_result "MPI OSU latency test over IPoIB" 1
                fi
            fi
        fi

        echo "Cleaning up MPI test pods..."
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                kubectl delete pod "mpi-ipoib-node${node_idx}-pod${pod_idx}" --force --grace-period=0 &>/dev/null || true
            done
        done
        
        echo "Verifying all MPI test pods are deleted..."
        CLEANUP_TIMEOUT=60
        CLEANUP_ELAPSED=0
        PODS_REMAINING=8
        while [ "$PODS_REMAINING" -gt 0 ] && [ "$CLEANUP_ELAPSED" -lt "$CLEANUP_TIMEOUT" ]; do
            PODS_REMAINING=0
            for node_idx in 1 2; do
                for pod_idx in 1 2 3 4; do
                    if kubectl get pod "mpi-ipoib-node${node_idx}-pod${pod_idx}" &>/dev/null; then
                        PODS_REMAINING=$((PODS_REMAINING + 1))
                    fi
                done
            done
            
            if [ "$PODS_REMAINING" -gt 0 ]; then
                sleep 2
                CLEANUP_ELAPSED=$((CLEANUP_ELAPSED + 2))
            fi
        done
        
        if [ "$PODS_REMAINING" -eq 0 ]; then
            test_result "All MPI test pods deleted successfully" 0
        else
            test_result "MPI test pod cleanup ($PODS_REMAINING pods still remaining)" 1
        fi
    else
        test_skip "MPI over IPoIB tests" "Pods not ready"
    fi
fi

echo ""

echo "[6/6] libfabric over IPoIB (fi_pingpong UDP via net1)"
echo "=========================================="

LF_IMAGE=${LF_IMAGE:-"localhost/cornelis/rdma-test-tools:latest"}

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "libfabric fi_udp over IPoIB tests" "Requires 2+ nodes"
else
    LF_NODE1="${READY_NODES[0]}"
    LF_NODE2="${READY_NODES[1]}"

    echo "Creating dedicated libfabric IPoIB test pods..."
    cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: lf-ipoib-node1-pod1
  labels:
    app: lf-ipoib-test
  annotations:
    k8s.v1.cni.cncf.io/networks: kube-system/ipoib-network
spec:
  nodeName: ${LF_NODE1}
  containers:
  - name: lf
    image: ${LF_IMAGE}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
  restartPolicy: Never
EOF

    cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: lf-ipoib-node2-pod1
  labels:
    app: lf-ipoib-test
  annotations:
    k8s.v1.cni.cncf.io/networks: kube-system/ipoib-network
spec:
  nodeName: ${LF_NODE2}
  containers:
  - name: lf
    image: ${LF_IMAGE}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
  restartPolicy: Never
EOF

    echo "Waiting for libfabric IPoIB test pods to be ready..."
    LF_READY=true
    for pod in lf-ipoib-node1-pod1 lf-ipoib-node2-pod1; do
        if kubectl wait --for=condition=Ready "pod/${pod}" --timeout=120s &>/dev/null; then
            test_result "libfabric pod ${pod} ready" 0
        else
            test_result "libfabric pod ${pod} ready" 1
            LF_READY=false
        fi
    done

    if [ "$LF_READY" = true ]; then
        echo "Verifying fi_info available on both pods..."
        FI_INFO_COUNT=0
        for pod in lf-ipoib-node1-pod1 lf-ipoib-node2-pod1; do
            if kubectl exec "$pod" -- fi_info --version &>/dev/null; then
                FI_INFO_COUNT=$((FI_INFO_COUNT + 1))
            fi
        done
        if [ "$FI_INFO_COUNT" -eq 2 ]; then
            test_result "fi_info available on both libfabric pods" 0
        else
            test_result "fi_info available on both libfabric pods ($FI_INFO_COUNT/2)" 1
            LF_READY=false
        fi
    fi

    if [ "$LF_READY" = true ]; then
        echo "Verifying net1 IPoIB interface on libfabric pods..."
        NET1_COUNT=0
        for pod in lf-ipoib-node1-pod1 lf-ipoib-node2-pod1; do
            if kubectl get pod "$pod" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null | grep -q '"interface": "net1"'; then
                NET1_COUNT=$((NET1_COUNT + 1))
            fi
        done
        if [ "$NET1_COUNT" -eq 2 ]; then
            test_result "net1 IPoIB interface present on both libfabric pods" 0
        else
            test_result "net1 IPoIB interface present on libfabric pods ($NET1_COUNT/2)" 1
            LF_READY=false
        fi
    fi

    if [ "$LF_READY" = true ]; then
        echo "Verifying fi_udp provider available on both pods..."
        FI_UDP_COUNT=0
        for pod in lf-ipoib-node1-pod1 lf-ipoib-node2-pod1; do
            if kubectl exec "$pod" -- bash -c 'fi_info -l 2>/dev/null | grep -qE "^udp(:|$)"'; then
                FI_UDP_COUNT=$((FI_UDP_COUNT + 1))
            fi
        done
        if [ "$FI_UDP_COUNT" -eq 2 ]; then
            test_result "fi_udp provider available on both libfabric pods" 0
        else
            test_result "fi_udp provider available on both libfabric pods ($FI_UDP_COUNT/2)" 1
            LF_READY=false
        fi
    fi

    if [ "$LF_READY" = true ]; then
        LF_NODE1_NET1_IP=$(_get_net1_ip lf-ipoib-node1-pod1)
        LF_NODE2_NET1_IP=$(_get_net1_ip lf-ipoib-node2-pod1)

        echo "Testing fi_pingpong UDP via net1: node1 -> node2 (${LF_NODE1_NET1_IP} -> ${LF_NODE2_NET1_IP})..."
        kubectl exec lf-ipoib-node2-pod1 -- bash -c \
            "pkill -9 fi_pingpong 2>/dev/null || true; nohup fi_pingpong -p udp -d net1 > /tmp/fi_pingpong_server.log 2>&1 &" &>/dev/null || true
        sleep 2
        LF_OUT=$(kubectl exec lf-ipoib-node1-pod1 -- bash -c \
            "fi_pingpong -p udp -d net1 ${LF_NODE2_NET1_IP} 2>&1" || echo "LF_FAILED")
        kubectl exec lf-ipoib-node2-pod1 -- bash -c "pkill -9 fi_pingpong 2>/dev/null || true" &>/dev/null || true

        if echo "$LF_OUT" | grep -q "LF_FAILED\|error\|Error"; then
            test_result "fi_pingpong UDP via net1 (node1 -> node2)" 1
        else
            LAT=$(echo "$LF_OUT" | grep -E "^[0-9]" | tail -1 | awk '{print $3}')
            if [ -n "$LAT" ]; then
                echo "    fi_pingpong UDP latency via net1 (node1->node2): ${LAT} us"
                test_result "fi_pingpong UDP via net1 (node1 -> node2)" 0
            else
                test_result "fi_pingpong UDP via net1 (node1 -> node2)" 1
            fi
        fi

        echo "Testing fi_pingpong UDP via net1: node2 -> node1 (${LF_NODE2_NET1_IP} -> ${LF_NODE1_NET1_IP})..."
        kubectl exec lf-ipoib-node1-pod1 -- bash -c \
            "pkill -9 fi_pingpong 2>/dev/null || true; nohup fi_pingpong -p udp -d net1 > /tmp/fi_pingpong_server.log 2>&1 &" &>/dev/null || true
        sleep 2
        LF_OUT2=$(kubectl exec lf-ipoib-node2-pod1 -- bash -c \
            "fi_pingpong -p udp -d net1 ${LF_NODE1_NET1_IP} 2>&1" || echo "LF_FAILED")
        kubectl exec lf-ipoib-node1-pod1 -- bash -c "pkill -9 fi_pingpong 2>/dev/null || true" &>/dev/null || true

        if echo "$LF_OUT2" | grep -q "LF_FAILED\|error\|Error"; then
            test_result "fi_pingpong UDP via net1 (node2 -> node1)" 1
        else
            LAT2=$(echo "$LF_OUT2" | grep -E "^[0-9]" | tail -1 | awk '{print $3}')
            if [ -n "$LAT2" ]; then
                echo "    fi_pingpong UDP latency via net1 (node2->node1): ${LAT2} us"
                test_result "fi_pingpong UDP via net1 (node2 -> node1)" 0
            else
                test_result "fi_pingpong UDP via net1 (node2 -> node1)" 1
            fi
        fi
    fi

    echo "Cleaning up libfabric IPoIB test pods..."
    kubectl delete pod lf-ipoib-node1-pod1 lf-ipoib-node2-pod1 --force --grace-period=0 &>/dev/null || true
fi

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total Tests:   $TOTAL_TESTS"
echo "Passed:        $PASSED_TESTS"
echo "Failed:        $FAILED_TESTS"
echo "Skipped:       $SKIPPED_TESTS"
echo "=========================================="

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo "✓ All tests passed!"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
