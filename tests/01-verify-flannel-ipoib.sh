#!/bin/bash
set -euo pipefail

# Flannel VXLAN over IPoIB Verification Script
# 
# This script validates Flannel CNI deployment with VXLAN over IPoIB:
# - Infrastructure validation
# - Intra-node connectivity
# - Inter-node connectivity (VXLAN over IPoIB)

MODE="quick"
IFACE=""

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
        *)
            if [[ ! "$arg" =~ ^-- ]]; then
                IFACE="$arg"
            fi
            ;;
    esac
done

if [[ -z "$IFACE" ]]; then
    cat <<EOF >&2
Usage: $0 <ipoib_iface> [--quick|--full]

The IPoIB interface name is required; this script no longer falls back to a
hard-coded default because the kernel-assigned name varies per cluster.

Discover the live interface name on a target node with:
    ip link show
See docs/architecture/networking.md for the platform mapping.
EOF
    exit 2
fi

echo "=========================================="
echo "Flannel VXLAN over IPoIB Verification"
echo "=========================================="
echo "Mode: $MODE"
echo "IPoIB Interface: $IFACE"
echo "=========================================="
echo ""

# Test result tracking
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

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up test resources..."
    
    if [ "$MODE" = "quick" ]; then
        PODS_PER_NODE=4
    else
        PODS_PER_NODE=4
    fi
    
    for i in $(seq 1 $PODS_PER_NODE); do
        kubectl delete pod test-node1-pod$i test-node2-pod$i --force --grace-period=0 2>/dev/null || true
    done
    
    kubectl delete pod lf-flannel-node1-pod1 lf-flannel-node2-pod1 --force --grace-period=0 2>/dev/null || true
    
    kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep "node-debugger-" | awk '{print $1" "$2}' | xargs -r -n2 sh -c 'kubectl delete pod -n "$0" "$1" --force --grace-period=0 2>/dev/null || true' || true
    
    echo "Cleanup complete."
}

trap cleanup EXIT

# ==========================================
# [1/4] Infrastructure Validation
# ==========================================

echo "[1/4] Infrastructure Validation"
echo "=========================================="

# Check kubectl access
if kubectl get nodes &>/dev/null; then
    test_result "Kubernetes cluster accessible" 0
else
    test_result "Kubernetes cluster accessible" 1
    echo ""
    echo "✗ ERROR: Cannot access Kubernetes cluster"
    exit 1
fi

# Check nodes
READY_NODES=($(kubectl get nodes --no-headers 2>/dev/null | grep " Ready " | awk '{print $1}'))
TOTAL_NODES=${#READY_NODES[@]}

if [ "$TOTAL_NODES" -ge 1 ]; then
    test_result "Nodes Ready ($TOTAL_NODES nodes)" 0
else
    test_result "Nodes Ready" 1
fi

# Check Flannel namespace
if kubectl get namespace kube-flannel &>/dev/null; then
    test_result "Flannel namespace exists" 0
else
    test_result "Flannel namespace exists" 1
fi

# Check Flannel pods
FLANNEL_PODS=$(kubectl get pods -n kube-flannel -l app=flannel --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$FLANNEL_PODS" -ge 1 ]; then
    test_result "Flannel pods running ($FLANNEL_PODS pods)" 0
else
    test_result "Flannel pods running" 1
fi

# Check Flannel --iface argument
if kubectl get ds kube-flannel-ds -n kube-flannel -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -q "iface=$IFACE"; then
    test_result "Flannel --iface=$IFACE configured" 0
else
    test_result "Flannel --iface=$IFACE configured" 1
fi

# Check IPoIB interface on cluster nodes
IFACE_CHECK_PASS=0
IFACE_CHECK_TOTAL=0
for node in "${READY_NODES[@]}"; do
    IFACE_CHECK_TOTAL=$((IFACE_CHECK_TOTAL + 1))
    NODE_IFACE_CHECK=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [ -n "$NODE_IFACE_CHECK" ]; then
        if kubectl debug node/"$node" -it --image=busybox -- ip link show "$IFACE" &>/dev/null; then
            IFACE_CHECK_PASS=$((IFACE_CHECK_PASS + 1))
        fi
    fi
done

if [ "$IFACE_CHECK_PASS" -eq "$IFACE_CHECK_TOTAL" ] && [ "$IFACE_CHECK_TOTAL" -gt 0 ]; then
    test_result "IPoIB interface $IFACE exists on all nodes ($IFACE_CHECK_PASS/$IFACE_CHECK_TOTAL)" 0
else
    test_result "IPoIB interface $IFACE exists on nodes ($IFACE_CHECK_PASS/$IFACE_CHECK_TOTAL)" 1
fi

# Check flannel.1 VXLAN interface on cluster nodes
VXLAN_CHECK_PASS=0
VXLAN_CHECK_TOTAL=0
for node in "${READY_NODES[@]}"; do
    VXLAN_CHECK_TOTAL=$((VXLAN_CHECK_TOTAL + 1))
    if kubectl debug node/"$node" -it --image=busybox -- sh -c "ip -d link show flannel.1 | grep -q 'vxlan.*dev $IFACE'" &>/dev/null; then
        VXLAN_CHECK_PASS=$((VXLAN_CHECK_PASS + 1))
    fi
done

if [ "$VXLAN_CHECK_PASS" -eq "$VXLAN_CHECK_TOTAL" ] && [ "$VXLAN_CHECK_TOTAL" -gt 0 ]; then
    test_result "flannel.1 VXLAN bound to $IFACE on all nodes ($VXLAN_CHECK_PASS/$VXLAN_CHECK_TOTAL)" 0
else
    test_result "flannel.1 VXLAN bound to $IFACE on nodes ($VXLAN_CHECK_PASS/$VXLAN_CHECK_TOTAL)" 1
fi

# Check VXLAN port on cluster nodes via Flannel pods
FLANNEL_POD_NAMES=($(kubectl get pods -n kube-flannel -l app=flannel --no-headers 2>/dev/null | awk '{print $1}'))
VXLAN_PORT_PASS=0
VXLAN_PORT_TOTAL=${#FLANNEL_POD_NAMES[@]}

for pod in "${FLANNEL_POD_NAMES[@]}"; do
    if kubectl exec -n kube-flannel "$pod" -- ss -ulnp 2>/dev/null | grep -q ":8472" &>/dev/null; then
        VXLAN_PORT_PASS=$((VXLAN_PORT_PASS + 1))
    fi
done

if [ "$VXLAN_PORT_PASS" -eq "$VXLAN_PORT_TOTAL" ] && [ "$VXLAN_PORT_TOTAL" -gt 0 ]; then
    test_result "VXLAN port 8472 listening on all nodes ($VXLAN_PORT_PASS/$VXLAN_PORT_TOTAL)" 0
else
    test_result "VXLAN port 8472 listening on nodes ($VXLAN_PORT_PASS/$VXLAN_PORT_TOTAL)" 1
fi

# Check CoreDNS
COREDNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$COREDNS_PODS" -ge 1 ]; then
    test_result "CoreDNS pods running ($COREDNS_PODS pods)" 0
else
    test_result "CoreDNS pods running" 1
fi

echo ""

# ==========================================
# [2/4] Connectivity Testing
# ==========================================

echo "[2/4] Connectivity Testing"
echo "=========================================="

# Check if we have enough nodes for inter-node testing
if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "Inter-node connectivity" "Only $TOTAL_NODES node(s) available, need 2+"
    echo ""
    echo "⚠ WARNING: Skipping connectivity tests (need at least 2 nodes)"
    echo ""
else
    # Select 2 nodes for testing
    SELECTED_INDICES=($(shuf -i 0-$((TOTAL_NODES-1)) -n 2))
    NODE1="${READY_NODES[${SELECTED_INDICES[0]}]}"
    NODE2="${READY_NODES[${SELECTED_INDICES[1]}]}"
    
    echo "Selected nodes for testing:"
    echo "  Node 1: $NODE1"
    echo "  Node 2: $NODE2"
    echo ""
    
    # Set pods per node based on mode
    if [ "$MODE" = "quick" ]; then
        PODS_PER_NODE=4
    else
        PODS_PER_NODE=4
    fi
    
    # Create test pods on Node 1
    echo "Creating $PODS_PER_NODE test pods on $NODE1..."
    for i in $(seq 1 $PODS_PER_NODE); do
        cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-node1-pod$i
  labels:
    app: test-pod
    pod: test-node1-pod$i
spec:
  nodeName: $NODE1
  containers:
  - name: busybox
    image: busybox
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF
    done
    
    # Create test pods on Node 2
    echo "Creating $PODS_PER_NODE test pods on $NODE2..."
    for i in $(seq 1 $PODS_PER_NODE); do
        cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-node2-pod$i
  labels:
    app: test-pod
    pod: test-node2-pod$i
spec:
  nodeName: $NODE2
  containers:
  - name: busybox
    image: busybox
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF
    done
    
    # Wait for pods to be ready
    echo "Waiting for pods to be ready..."
    TOTAL_EXPECTED=$((PODS_PER_NODE * 2))
    
    if kubectl wait --for=condition=Ready pod -l app=test-pod --timeout=120s &>/dev/null; then
        READY_COUNT=$(kubectl get pods -l app=test-pod --no-headers 2>/dev/null | grep " Running " | wc -l)
        test_result "Test pods ready ($READY_COUNT/$TOTAL_EXPECTED)" 0
    else
        READY_COUNT=$(kubectl get pods -l app=test-pod --no-headers 2>/dev/null | grep " Running " | wc -l)
        test_result "Test pods ready ($READY_COUNT/$TOTAL_EXPECTED)" 1
    fi
    
    echo ""
    
    # Get pod IPs
    declare -A NODE1_POD_IPS
    declare -A NODE2_POD_IPS
    
    for i in $(seq 1 $PODS_PER_NODE); do
        NODE1_POD_IPS[$i]=$(kubectl get pod test-node1-pod$i -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
        NODE2_POD_IPS[$i]=$(kubectl get pod test-node2-pod$i -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
    done
    
    # Test intra-node connectivity on Node 1
    echo "Testing intra-node connectivity on $NODE1..."
    INTRA_NODE1_PASS=0
    INTRA_NODE1_TOTAL=0
    
    for i in $(seq 1 $PODS_PER_NODE); do
        for j in $(seq $((i+1)) $PODS_PER_NODE); do
            if [ -n "${NODE1_POD_IPS[$i]}" ] && [ -n "${NODE1_POD_IPS[$j]}" ]; then
                INTRA_NODE1_TOTAL=$((INTRA_NODE1_TOTAL + 1))
                if timeout 5 kubectl exec test-node1-pod$i -- ping -c 1 -W 2 ${NODE1_POD_IPS[$j]} &>/dev/null; then
                    INTRA_NODE1_PASS=$((INTRA_NODE1_PASS + 1))
                fi
            fi
        done
    done
    
    if [ "$INTRA_NODE1_TOTAL" -gt 0 ]; then
        if [ "$INTRA_NODE1_PASS" -eq "$INTRA_NODE1_TOTAL" ]; then
            test_result "Intra-node connectivity on $NODE1 ($INTRA_NODE1_PASS/$INTRA_NODE1_TOTAL)" 0
        else
            test_result "Intra-node connectivity on $NODE1 ($INTRA_NODE1_PASS/$INTRA_NODE1_TOTAL)" 1
        fi
    fi
    
    # Test intra-node connectivity on Node 2
    echo "Testing intra-node connectivity on $NODE2..."
    INTRA_NODE2_PASS=0
    INTRA_NODE2_TOTAL=0
    
    for i in $(seq 1 $PODS_PER_NODE); do
        for j in $(seq $((i+1)) $PODS_PER_NODE); do
            if [ -n "${NODE2_POD_IPS[$i]}" ] && [ -n "${NODE2_POD_IPS[$j]}" ]; then
                INTRA_NODE2_TOTAL=$((INTRA_NODE2_TOTAL + 1))
                if timeout 5 kubectl exec test-node2-pod$i -- ping -c 1 -W 2 ${NODE2_POD_IPS[$j]} &>/dev/null; then
                    INTRA_NODE2_PASS=$((INTRA_NODE2_PASS + 1))
                fi
            fi
        done
    done
    
    if [ "$INTRA_NODE2_TOTAL" -gt 0 ]; then
        if [ "$INTRA_NODE2_PASS" -eq "$INTRA_NODE2_TOTAL" ]; then
            test_result "Intra-node connectivity on $NODE2 ($INTRA_NODE2_PASS/$INTRA_NODE2_TOTAL)" 0
        else
            test_result "Intra-node connectivity on $NODE2 ($INTRA_NODE2_PASS/$INTRA_NODE2_TOTAL)" 1
        fi
    fi
    
    # Test inter-node connectivity (VXLAN over IPoIB)
    echo "Testing inter-node connectivity (VXLAN over IPoIB)..."
    INTER_NODE_PASS=0
    INTER_NODE_TOTAL=0
    
    # Node1 → Node2
    for i in $(seq 1 $PODS_PER_NODE); do
        for j in $(seq 1 $PODS_PER_NODE); do
            if [ -n "${NODE1_POD_IPS[$i]}" ] && [ -n "${NODE2_POD_IPS[$j]}" ]; then
                INTER_NODE_TOTAL=$((INTER_NODE_TOTAL + 1))
                if timeout 5 kubectl exec test-node1-pod$i -- ping -c 1 -W 2 ${NODE2_POD_IPS[$j]} &>/dev/null; then
                    INTER_NODE_PASS=$((INTER_NODE_PASS + 1))
                fi
            fi
        done
    done
    
    # Node2 → Node1
    for i in $(seq 1 $PODS_PER_NODE); do
        for j in $(seq 1 $PODS_PER_NODE); do
            if [ -n "${NODE2_POD_IPS[$i]}" ] && [ -n "${NODE1_POD_IPS[$j]}" ]; then
                INTER_NODE_TOTAL=$((INTER_NODE_TOTAL + 1))
                if timeout 5 kubectl exec test-node2-pod$i -- ping -c 1 -W 2 ${NODE1_POD_IPS[$j]} &>/dev/null; then
                    INTER_NODE_PASS=$((INTER_NODE_PASS + 1))
                fi
            fi
        done
    done
    
    if [ "$INTER_NODE_TOTAL" -gt 0 ]; then
        if [ "$INTER_NODE_PASS" -eq "$INTER_NODE_TOTAL" ]; then
            test_result "Inter-node connectivity via VXLAN/IPoIB ($INTER_NODE_PASS/$INTER_NODE_TOTAL)" 0
        else
            test_result "Inter-node connectivity via VXLAN/IPoIB ($INTER_NODE_PASS/$INTER_NODE_TOTAL)" 1
        fi
    fi
    
    echo ""
fi

echo ""

# ==========================================
# [3/4] libfabric Connectivity (fi_udp)
# ==========================================

echo "[3/4] libfabric Connectivity (fi_pingpong UDP over VXLAN/IPoIB)"
echo "=========================================="

LF_IMAGE=${LF_IMAGE:-"localhost/cornelis/rdma-test-tools:latest"}

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "libfabric fi_udp tests" "Only $TOTAL_NODES node(s) available, need 2+"
else
    LF_NODE1="${READY_NODES[0]}"
    LF_NODE2="${READY_NODES[1]}"

    echo "Creating dedicated libfabric test pods..."
    cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: lf-flannel-node1-pod1
  labels:
    app: lf-flannel-test
spec:
  nodeName: $LF_NODE1
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
  name: lf-flannel-node2-pod1
  labels:
    app: lf-flannel-test
spec:
  nodeName: $LF_NODE2
  containers:
  - name: lf
    image: ${LF_IMAGE}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
  restartPolicy: Never
EOF

    echo "Waiting for libfabric test pods to be ready..."
    LF_READY=true
    for pod in lf-flannel-node1-pod1 lf-flannel-node2-pod1; do
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
        for pod in lf-flannel-node1-pod1 lf-flannel-node2-pod1; do
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
        echo "Verifying fi_udp provider available on both pods..."
        FI_UDP_COUNT=0
        for pod in lf-flannel-node1-pod1 lf-flannel-node2-pod1; do
            if kubectl exec "$pod" -- bash -c 'fi_info -l 2>/dev/null | grep -qE "^udp(:|$)"'; then
                FI_UDP_COUNT=$((FI_UDP_COUNT + 1))
            fi
        done
        if [ "$FI_UDP_COUNT" -eq 2 ]; then
            test_result "fi_udp provider available on both pods" 0
        else
            test_result "fi_udp provider available on both pods ($FI_UDP_COUNT/2)" 1
            LF_READY=false
        fi
    fi

    if [ "$LF_READY" = true ]; then
        LF_NODE1_IP=$(kubectl get pod lf-flannel-node1-pod1 -o jsonpath='{.status.podIP}' 2>/dev/null)
        LF_NODE2_IP=$(kubectl get pod lf-flannel-node2-pod1 -o jsonpath='{.status.podIP}' 2>/dev/null)

        echo "Testing fi_pingpong UDP: node1 -> node2 (${LF_NODE1_IP} -> ${LF_NODE2_IP})..."
        kubectl exec lf-flannel-node2-pod1 -- bash -c \
            "pkill -9 fi_pingpong 2>/dev/null || true; nohup fi_pingpong -p udp > /tmp/fi_pingpong_server.log 2>&1 &" &>/dev/null || true
        sleep 2
        LF_OUT=$(kubectl exec lf-flannel-node1-pod1 -- bash -c \
            "fi_pingpong -p udp ${LF_NODE2_IP} 2>&1" || echo "LF_FAILED")
        kubectl exec lf-flannel-node2-pod1 -- bash -c "pkill -9 fi_pingpong 2>/dev/null || true" &>/dev/null || true

        if echo "$LF_OUT" | grep -q "LF_FAILED\|error\|Error"; then
            test_result "fi_pingpong UDP inter-node (node1 -> node2)" 1
        else
            LATENCY=$(echo "$LF_OUT" | grep -E "^[0-9]" | tail -1 | awk '{print $2}')
            if [ -n "$LATENCY" ]; then
                echo "    fi_pingpong UDP latency (node1->node2): ${LATENCY} us"
                test_result "fi_pingpong UDP inter-node (node1 -> node2)" 0
            else
                test_result "fi_pingpong UDP inter-node (node1 -> node2)" 1
            fi
        fi

        echo "Testing fi_pingpong UDP: node2 -> node1 (${LF_NODE2_IP} -> ${LF_NODE1_IP})..."
        kubectl exec lf-flannel-node1-pod1 -- bash -c \
            "pkill -9 fi_pingpong 2>/dev/null || true; nohup fi_pingpong -p udp > /tmp/fi_pingpong_server.log 2>&1 &" &>/dev/null || true
        sleep 2
        LF_OUT2=$(kubectl exec lf-flannel-node2-pod1 -- bash -c \
            "fi_pingpong -p udp ${LF_NODE1_IP} 2>&1" || echo "LF_FAILED")
        kubectl exec lf-flannel-node1-pod1 -- bash -c "pkill -9 fi_pingpong 2>/dev/null || true" &>/dev/null || true

        if echo "$LF_OUT2" | grep -q "LF_FAILED\|error\|Error"; then
            test_result "fi_pingpong UDP inter-node (node2 -> node1)" 1
        else
            LATENCY2=$(echo "$LF_OUT2" | grep -E "^[0-9]" | tail -1 | awk '{print $2}')
            if [ -n "$LATENCY2" ]; then
                echo "    fi_pingpong UDP latency (node2->node1): ${LATENCY2} us"
                test_result "fi_pingpong UDP inter-node (node2 -> node1)" 0
            else
                test_result "fi_pingpong UDP inter-node (node2 -> node1)" 1
            fi
        fi
    fi

    echo "Cleaning up libfabric test pods..."
    kubectl delete pod lf-flannel-node1-pod1 lf-flannel-node2-pod1 --force --grace-period=0 &>/dev/null || true
fi

echo ""

# ==========================================
# [4/4] Test Summary
# ==========================================

echo "[4/4] Test Summary"
echo "=========================================="
echo "Mode: $MODE"
echo "Interface: $IFACE"
echo "Total Tests: $TOTAL_TESTS"
echo "libfabric Tool: fi_pingpong UDP"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"
echo "Skipped: $SKIPPED_TESTS"

if [ $TOTAL_TESTS -eq 0 ]; then
    echo ""
    echo "⚠ NO TESTS RAN"
    exit 1
fi

if [ $FAILED_TESTS -eq 0 ]; then
    PASS_RATE=100
else
    PASS_RATE=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
fi

echo "Pass Rate: ${PASS_RATE}%"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo "Result: ✓ ALL TESTS PASSED"
    echo ""
    echo "Flannel VXLAN over IPoIB deployment is healthy:"
    echo "  - Infrastructure: Validated"
    echo "  - Intra-node connectivity: Working"
    echo "  - Inter-node connectivity: Working (VXLAN over IPoIB)"
    echo "  - libfabric fi_pingpong UDP: Working (inter-node)"
    exit 0
else
    echo "Result: ✗ SOME TESTS FAILED"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check Flannel pod logs: kubectl logs -n kube-flannel -l app=flannel"
    echo "  - Verify IPoIB interface: ip link show $IFACE"
    echo "  - Verify VXLAN binding: ip -d link show flannel.1"
    echo "  - Check VXLAN port: ss -ulnp | grep 8472"
    echo ""
    echo "See docs/deployment/flannel-ipoib-cni.md for more details."
    exit 1
fi
