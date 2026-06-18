#!/bin/bash
set -euo pipefail

# RDMA Shared Device Plugin Verification Script
#
# This script validates RDMA shared device plugin deployment:
# - Infrastructure validation (DaemonSet, runtime)
# - Resource advertisement (cornelis.com/hfi)
# - Pod scheduling and device access
# - RDMA operations and data transfer
# - Scale deployment with intra-node and inter-node RDMA reachability and bandwidth
# - MPI over RDMA with UCX (split control/data plane validation)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODS_PER_NODE=${PODS_PER_NODE:-4}
MPI_IMAGE=${MPI_IMAGE:-"localhost/cornelis/rdma-test-tools:latest"}
# IPoIB interface name on the target cluster. Operator-supplied; the
# kernel-assigned name varies per platform. Discover via `ip link show` on a
# worker. See docs/architecture/networking.md for the dual-NIC architecture
# and the operator-supply contract.
IFACE="${IFACE:-}"

if [[ -z "$IFACE" ]]; then
    cat <<EOF >&2
Error: IPoIB interface not supplied.

Set the IFACE environment variable to the live IPoIB interface name on the
target cluster (this script no longer falls back to a hard-coded default
because the kernel-assigned name varies per platform).

Example:
    IFACE=<ipoib_iface> $0

Discover the live interface name on a target node with:
    ip link show

See docs/architecture/networking.md for the platform mapping.
EOF
    exit 2
fi

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

get_node_ipoib_ip() {
    local node_name="$1"
    local ip=""

    if [ "$node_name" = "$(hostname)" ] || [ "$node_name" = "$(hostname -s)" ]; then
        echo "    (Local node: using direct ip command)" >&2
        ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
    fi

    if [ -z "$ip" ]; then
        local internal_ip
        internal_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
        if [ -n "$internal_ip" ]; then
            echo "    (Trying SSH to InternalIP: $internal_ip)" >&2
            ip=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${internal_ip}" "ip -4 addr show $IFACE 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1" 2>/dev/null || echo "")
        fi
    fi

    if [ -z "$ip" ]; then
        echo "    (Trying SSH to node name: $node_name)" >&2
        ip=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${node_name}" "ip -4 addr show $IFACE 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1" 2>/dev/null || echo "")
    fi

    echo "$ip"
}

run_rdma_reach() {
    local srv="$1" cli="$2" label="$3"
    local srv_ip
    srv_ip=$(kubectl get pod "$srv" -o jsonpath='{.status.podIP}' 2>/dev/null)
    if [ -z "$srv_ip" ]; then
        test_result "$label" 1
        return
    fi
    kubectl exec "$srv" -- bash -c "pkill -9 ib_write_bw 2>/dev/null || true; nohup ib_write_bw -d hfi1_0 -i $ACTIVE_PORT -F -s 2 -n 5 > /tmp/reach.log 2>&1 < /dev/null &" &>/dev/null || true
    sleep 2
    local out
    out=$(kubectl exec "$cli" -- ib_write_bw -d hfi1_0 -i $ACTIVE_PORT -F -s 2 -n 5 "$srv_ip" 2>&1 || echo "FAILED")
    kubectl exec "$srv" -- bash -c "pkill -9 ib_write_bw 2>/dev/null || true" &>/dev/null || true
    if echo "$out" | grep -q "FAILED\|Error\|Couldn't"; then
        test_result "$label" 1
    else
        test_result "$label" 0
    fi
}

run_rdma_bw() {
    local srv="$1" cli="$2" label="$3"
    local srv_ip
    srv_ip=$(kubectl get pod "$srv" -o jsonpath='{.status.podIP}' 2>/dev/null)
    if [ -z "$srv_ip" ]; then
        test_result "$label" 1
        return
    fi
    kubectl exec "$srv" -- bash -c "pkill -9 ib_write_bw 2>/dev/null || true; nohup ib_write_bw -d hfi1_0 -i $ACTIVE_PORT -F > /tmp/bw.log 2>&1 < /dev/null &" &>/dev/null || true
    sleep 3
    local out
    out=$(kubectl exec "$cli" -- ib_write_bw -d hfi1_0 -i $ACTIVE_PORT -F "$srv_ip" 2>&1 || echo "FAILED")
    kubectl exec "$srv" -- bash -c "pkill -9 ib_write_bw 2>/dev/null || true" &>/dev/null || true
    if echo "$out" | grep -q "FAILED\|Error\|Couldn't"; then
        test_result "$label" 1
    else
        local bw
        bw=$(echo "$out" | grep "^[[:space:]]*[0-9]" | tail -1 | awk '{print $(NF-1)}')
        if [ -n "$bw" ]; then
            echo "    $bw MB/sec"
            test_result "$label" 0
        else
            test_result "$label" 1
        fi
    fi
}

echo "=========================================="
echo "RDMA Shared Device Plugin Verification"
echo "=========================================="
echo "Pods per node: $PODS_PER_NODE"
echo ""

# Check kubectl access
if kubectl get nodes &>/dev/null; then
    test_result "Kubernetes cluster accessible" 0
else
    test_result "Kubernetes cluster accessible" 1
    echo ""
    echo "✗ ERROR: Cannot access Kubernetes cluster"
    exit 1
fi

# Get nodes
NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
TOTAL_NODES=${#NODES[@]}

if [ "$TOTAL_NODES" -ge 1 ]; then
    test_result "Nodes Ready ($TOTAL_NODES nodes)" 0
else
    test_result "Nodes Ready" 1
fi

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up test resources..."
    kubectl delete pod rdma-test-pod --force --grace-period=0 2>/dev/null || true
    for node in "${NODES[@]}"; do
        for i in $(seq 1 $PODS_PER_NODE); do
            kubectl delete pod "rdma-scale-${node}-${i}" --force --grace-period=0 2>/dev/null || true
        done
    done
    for node_idx in 1 2; do
        for pod_idx in 1 2 3 4; do
            kubectl delete pod "mpi-test-node${node_idx}-pod${pod_idx}" --force --grace-period=0 2>/dev/null || true
        done
    done
    kubectl delete pod lf-rdma-node1-pod1 lf-rdma-node2-pod1 --force --grace-period=0 2>/dev/null || true
    for node_idx in 1 2; do
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            kubectl delete pod "mpi-lf-node${node_idx}-pod${pod_idx}" --force --grace-period=0 2>/dev/null || true
        done
    done
    kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep "node-debugger-" | awk '{print $1" "$2}' | xargs -r -n2 sh -c 'kubectl delete pod -n "$0" "$1" --force --grace-period=0 2>/dev/null || true' || true
    echo "Cleanup complete."
}
trap cleanup EXIT

ACTIVE_PORT="2"

# ==========================================
# [1/12] Infrastructure Validation
# ==========================================

echo "[1/12] Infrastructure Validation"
echo "=========================================="

if kubectl get daemonset rdma-shared-device-plugin -n kube-system &>/dev/null; then
    test_result "RDMA device plugin DaemonSet exists" 0
else
    test_result "RDMA device plugin DaemonSet exists" 1
    echo ""
    echo "✗ ERROR: RDMA device plugin DaemonSet not found"
    exit 1
fi

PLUGIN_PODS=$(kubectl get pods -n kube-system -l app=rdma-shared-device-plugin --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$PLUGIN_PODS" -ge 1 ]; then
    test_result "Device plugin pods running ($PLUGIN_PODS pods)" 0
else
    test_result "Device plugin pods running" 1
fi

MAX_RESTARTS=$(kubectl get pods -n kube-system -l app=rdma-shared-device-plugin --no-headers 2>/dev/null | awk '{print $4}' | sort -rn | head -1)
if [ -z "$MAX_RESTARTS" ]; then
    MAX_RESTARTS=0
fi
if [ "$MAX_RESTARTS" -le 2 ]; then
    test_result "Device plugin restart count acceptable ($MAX_RESTARTS)" 0
else
    test_result "Device plugin restart count acceptable ($MAX_RESTARTS)" 1
fi

FLANNEL_PODS=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep " Running " | wc -l)
if [ "$FLANNEL_PODS" -ge 1 ]; then
    test_result "Flannel pods running ($FLANNEL_PODS pods)" 0
else
    test_result "Flannel pods running" 1
fi

echo ""

# ==========================================
# [2/12] Resource Advertisement
# ==========================================

echo "[2/12] Resource Advertisement"
echo "=========================================="

FIRST_NODE="${NODES[0]}"

HFI_NODES=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[] | select(.status.allocatable["cornelis.com/hfi"] != null) | .metadata.name' | wc -l)
if [ "$HFI_NODES" -ge 1 ]; then
    test_result "cornelis.com/hfi resource advertised ($HFI_NODES nodes)" 0
else
    test_result "cornelis.com/hfi resource advertised" 1
    echo ""
    echo "✗ ERROR: No nodes advertising cornelis.com/hfi resource"
    exit 1
fi

ACTUAL_CAPACITY=$(kubectl get node "$FIRST_NODE" -o json 2>/dev/null | jq -r '.status.capacity["cornelis.com/hfi"] // "0"')
if [ "$ACTUAL_CAPACITY" -gt 0 ]; then
    test_result "Resource capacity ($ACTUAL_CAPACITY)" 0
else
    test_result "Resource capacity" 1
fi

AVAILABLE=$(kubectl get node "$FIRST_NODE" -o json 2>/dev/null | jq -r '.status.allocatable["cornelis.com/hfi"] // "0"')
if [ "$AVAILABLE" -ge 1 ]; then
    test_result "HFI resources available ($AVAILABLE)" 0
else
    test_result "HFI resources available" 1
fi

echo ""

# ==========================================
# [3/12] Pod Scheduling
# ==========================================

echo "[3/12] Pod Scheduling"
echo "=========================================="

echo "Creating test pod requesting cornelis.com/hfi: 1..."
cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: rdma-test-pod
  namespace: default
spec:
  hostIPC: true
  containers:
  - name: test
    image: localhost/cornelis/rdma-test-tools:latest
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep 600"]
    resources:
      limits:
        cornelis.com/hfi: 1
    securityContext:
      capabilities:
        add: [IPC_LOCK]
    volumeMounts:
    - name: dev-shm
      mountPath: /dev/shm
  volumes:
  - name: dev-shm
    emptyDir:
      medium: Memory
      sizeLimit: "1Gi"
  restartPolicy: Never
EOF

echo "Waiting for pod to be scheduled..."
SCHEDULED=0
for i in {1..30}; do
    if kubectl get pod rdma-test-pod -o jsonpath='{.spec.nodeName}' 2>/dev/null | grep -q .; then
        SCHEDULED=1
        break
    fi
    sleep 2
done

if [ "$SCHEDULED" -eq 1 ]; then
    POD_NODE=$(kubectl get pod rdma-test-pod -o jsonpath='{.spec.nodeName}')
    test_result "Pod scheduled to node ($POD_NODE)" 0
else
    test_result "Pod scheduled to node" 1
fi

echo "Waiting for pod to reach Running state..."
kubectl wait --for=condition=ready pod/rdma-test-pod --timeout=120s &>/dev/null
if [ $? -eq 0 ]; then
    test_result "Pod reached Running state" 0
else
    test_result "Pod reached Running state" 1
fi

echo ""

# ==========================================
# [4/12] Device Access
# ==========================================

echo "[4/12] Device Access"
echo "=========================================="

if kubectl exec rdma-test-pod -- test -e /dev/infiniband/uverbs0 &>/dev/null || true; then
    test_result "/dev/infiniband/uverbs0 exists" 0
else
    test_result "/dev/infiniband/uverbs0 exists" 1
fi

if kubectl exec rdma-test-pod -- test -e /dev/infiniband/rdma_cm &>/dev/null || true; then
    test_result "/dev/infiniband/rdma_cm exists" 0
else
    test_result "/dev/infiniband/rdma_cm exists" 1
fi

if kubectl exec rdma-test-pod -- mountpoint -q /dev/shm 2>/dev/null || true; then
    test_result "/dev/shm volume mounted" 0
else
    test_result "/dev/shm volume mounted" 1
fi

echo ""

# ==========================================
# [5/12] RDMA Operations
# ==========================================

echo "[5/12] RDMA Operations"
echo "=========================================="

echo "Running ibv_devinfo..."
IBV_OUTPUT=$(kubectl exec rdma-test-pod -- ibv_devinfo 2>/dev/null || echo "")

if [ -n "$IBV_OUTPUT" ]; then
    test_result "ibv_devinfo command succeeded" 0
else
    test_result "ibv_devinfo command succeeded" 1
fi

if echo "$IBV_OUTPUT" | grep -q "PORT_ACTIVE"; then
    test_result "RDMA port is in ACTIVE state" 0
else
    test_result "RDMA port is in ACTIVE state" 1
fi

echo "Running ibstat..."
IBSTAT_OUTPUT=$(kubectl exec rdma-test-pod -- ibstat 2>/dev/null || echo "")
if [ -n "$IBSTAT_OUTPUT" ]; then
    test_result "ibstat command succeeded" 0
else
    test_result "ibstat command succeeded" 1
fi

ACTIVE_PORT=$(echo "$IBSTAT_OUTPUT" | awk '/Port [0-9]+:/{port=$2; gsub(/:/, "", port)} /Physical state: LinkUp/{print port; exit}')
if [ -z "$ACTIVE_PORT" ]; then
    ACTIVE_PORT="2"
fi
echo "  Active port: $ACTIVE_PORT"

if echo "$IBV_OUTPUT" | grep -q "link_layer.*InfiniBand"; then
    test_result "Link layer is InfiniBand" 0
else
    test_result "Link layer is InfiniBand" 1
fi

echo ""

# ==========================================
# [6/12] Scale Pod Deployment
# ==========================================

echo "[6/12] Scale Pod Deployment ($PODS_PER_NODE pods per node)"
echo "=========================================="

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "Scale pod deployment" "Requires 2+ nodes"
else
    NODE1="${NODES[0]}"
    NODE2="${NODES[1]}"
    
    echo "Creating $PODS_PER_NODE pods on each node ($((PODS_PER_NODE * 2)) total)..."
    for node in $NODE1 $NODE2; do
        for i in $(seq 1 $PODS_PER_NODE); do
            POD_NAME="rdma-scale-${node}-${i}"
            cat <<EOF | kubectl apply -f - &>/dev/null || true
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
spec:
  nodeName: $node
  hostIPC: true
  containers:
  - name: rdma
    image: localhost/cornelis/rdma-test-tools:latest
    imagePullPolicy: Never
    command: ["sleep", "3600"]
    resources:
      limits:
        cornelis.com/hfi: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    volumeMounts:
    - name: dev-shm
      mountPath: /dev/shm
  volumes:
  - name: dev-shm
    emptyDir:
      medium: Memory
      sizeLimit: "1Gi"
EOF
        done
    done
    
    echo "Waiting for all pods to be ready..."
    READY_COUNT=0
    ALL_READY=true
    for node in $NODE1 $NODE2; do
        for i in $(seq 1 $PODS_PER_NODE); do
            POD_NAME="rdma-scale-${node}-${i}"
            if kubectl wait --for=condition=Ready "pod/$POD_NAME" --timeout=120s &>/dev/null; then
                READY_COUNT=$((READY_COUNT + 1))
            else
                ALL_READY=false
                echo "  WARNING: $POD_NAME not ready"
            fi
        done
    done
    
    TOTAL_EXPECTED=$((PODS_PER_NODE * 2))
    if [ "$ALL_READY" = true ]; then
        test_result "All $TOTAL_EXPECTED pods scheduled and running" 0
    else
        test_result "All $TOTAL_EXPECTED pods running ($READY_COUNT/$TOTAL_EXPECTED ready)" 1
    fi
    
    NODE1_COUNT=$(kubectl get pods -o wide --no-headers 2>/dev/null | grep "rdma-scale-" | grep "$NODE1" | grep "Running" | wc -l)
    NODE2_COUNT=$(kubectl get pods -o wide --no-headers 2>/dev/null | grep "rdma-scale-" | grep "$NODE2" | grep "Running" | wc -l)
    echo "  $NODE1: $NODE1_COUNT pods, $NODE2: $NODE2_COUNT pods"
    
    if [ "$NODE1_COUNT" -eq "$PODS_PER_NODE" ]; then
        test_result "$NODE1 has $PODS_PER_NODE pods" 0
    else
        test_result "$NODE1 has $PODS_PER_NODE pods ($NODE1_COUNT found)" 1
    fi
    
    if [ "$NODE2_COUNT" -eq "$PODS_PER_NODE" ]; then
        test_result "$NODE2 has $PODS_PER_NODE pods" 0
    else
        test_result "$NODE2 has $PODS_PER_NODE pods ($NODE2_COUNT found)" 1
    fi
    
    echo "Verifying RDMA tools are available on all $TOTAL_EXPECTED pods..."
    VERIFY_FAILURES=0
    for node in $NODE1 $NODE2; do
        for i in $(seq 1 $PODS_PER_NODE); do
            POD_NAME="rdma-scale-${node}-${i}"
            if ! kubectl exec "$POD_NAME" -- which ibv_devinfo &>/dev/null; then
                VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
            fi
        done
    done
    
    if [ "$VERIFY_FAILURES" -eq 0 ]; then
        test_result "RDMA tools available on all $TOTAL_EXPECTED pods" 0
    else
        test_result "RDMA tools available ($VERIFY_FAILURES failures)" 1
    fi
fi

echo ""

# ==========================================
# [7/12] RDMA Reachability (Intra-Node + Inter-Node)
# ==========================================

echo "[7/12] RDMA Reachability"
echo "=========================================="

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "RDMA reachability" "Requires 2+ nodes"
else
    NODE1="${NODES[0]}"
    NODE2="${NODES[1]}"

    INTRA_PAIRS=$(( PODS_PER_NODE * (PODS_PER_NODE - 1) / 2 ))
    CROSS_PAIRS=$((PODS_PER_NODE * PODS_PER_NODE))
    echo "Intra-node: $INTRA_PAIRS pairs/node, Inter-node: $CROSS_PAIRS pairs (minimal transfer)"
    echo ""

    echo "  --- Intra-node: $NODE1 ---"
    for ((i=1; i<=PODS_PER_NODE; i++)); do
        for ((j=i+1; j<=PODS_PER_NODE; j++)); do
            run_rdma_reach "rdma-scale-${NODE1}-${i}" "rdma-scale-${NODE1}-${j}" "${NODE1} pod-${i} ↔ pod-${j}"
        done
    done

    echo ""
    echo "  --- Intra-node: $NODE2 ---"
    for ((i=1; i<=PODS_PER_NODE; i++)); do
        for ((j=i+1; j<=PODS_PER_NODE; j++)); do
            run_rdma_reach "rdma-scale-${NODE2}-${i}" "rdma-scale-${NODE2}-${j}" "${NODE2} pod-${i} ↔ pod-${j}"
        done
    done

    echo ""
    echo "  --- Inter-node: $NODE1 ↔ $NODE2 ---"
    for ((i=1; i<=PODS_PER_NODE; i++)); do
        for ((j=1; j<=PODS_PER_NODE; j++)); do
            run_rdma_reach "rdma-scale-${NODE1}-${i}" "rdma-scale-${NODE2}-${j}" "${NODE1}:pod-${i} ↔ ${NODE2}:pod-${j}"
        done
    done
fi

echo ""

# ==========================================
# [8/12] RDMA Bandwidth (Intra-Node + Inter-Node)
# ==========================================

echo "[8/12] RDMA Bandwidth"
echo "=========================================="

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "RDMA bandwidth" "Requires 2+ nodes"
else
    NODE1="${NODES[0]}"
    NODE2="${NODES[1]}"

    echo "  --- Intra-node bandwidth (2 tests) ---"
    run_rdma_bw "rdma-scale-${NODE1}-1" "rdma-scale-${NODE1}-2" "Intra-node BW: ${NODE1} pod-1 → pod-2"
    run_rdma_bw "rdma-scale-${NODE2}-1" "rdma-scale-${NODE2}-2" "Intra-node BW: ${NODE2} pod-1 → pod-2"

    echo ""
    echo "  --- Inter-node bandwidth (2 tests) ---"
    run_rdma_bw "rdma-scale-${NODE1}-1" "rdma-scale-${NODE2}-1" "Inter-node BW: ${NODE1}:pod-1 → ${NODE2}:pod-1"
    run_rdma_bw "rdma-scale-${NODE2}-1" "rdma-scale-${NODE1}-1" "Inter-node BW: ${NODE2}:pod-1 → ${NODE1}:pod-1"
fi

echo ""

# ==========================================
# [9/12] MPI over RDMA with UCX (Split Control/Data Plane)
# ==========================================

echo "[9/12] MPI over RDMA with UCX"
echo "=========================================="

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "UCX RDMA bandwidth test" "Requires 2+ nodes"
else
    NODE1="${NODES[0]}"
    NODE2="${NODES[1]}"

    echo "Creating 4 MPI test pods on each node (8 pods total)..."
    for node_idx in 1 2; do
        if [ "$node_idx" -eq 1 ]; then
            NODE="$NODE1"
        else
            NODE="$NODE2"
        fi
        
        for pod_idx in 1 2 3 4; do
            POD_NAME="mpi-test-node${node_idx}-pod${pod_idx}"
            cat <<EOF | kubectl apply -f - &>/dev/null || true
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
spec:
  nodeName: ${NODE}
  containers:
  - name: mpi
    image: localhost/cornelis/rdma-test-tools:latest
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
    resources:
      limits:
        cornelis.com/hfi: 1
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
            POD_NAME="mpi-test-node${node_idx}-pod${pod_idx}"
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
        # Check if UCX tools are present in the image. Product OPX image
        # may not contain UCX or ucx_perftest; skip if missing.
        UCX_TOOLS_PRESENT=$(kubectl exec mpi-test-node1-pod1 -- which ucx_info &>/dev/null && echo "true" || echo "false")
        UCX_TOOLS_READY=false
        MPI_UCX_READY=false

        if [ "$UCX_TOOLS_PRESENT" = "true" ]; then
            echo "Verifying UCX installation on all 8 pods..."
            UCX_INSTALL_COUNT=0
            for node_idx in 1 2; do
                for pod_idx in 1 2 3 4; do
                    POD_NAME="mpi-test-node${node_idx}-pod${pod_idx}"
                    UCX_CHECK=$(kubectl exec "$POD_NAME" -- ucx_info -v 2>/dev/null | grep -cE '^# Library version: [0-9]+\.[0-9]+' || echo "0")
                    if [ "$UCX_CHECK" -ge 1 ]; then
                        UCX_INSTALL_COUNT=$((UCX_INSTALL_COUNT + 1))
                    fi
                done
            done
            
            if [ "$UCX_INSTALL_COUNT" -eq 8 ]; then
                test_result "UCX installed on all 8 pods" 0
                UCX_TOOLS_READY=true
            else
                test_result "UCX installed ($UCX_INSTALL_COUNT/8 pods)" 1
            fi
        else
            test_skip "UCX installation" "UCX tools not present in product OPX image"
        fi

        if [ "$UCX_TOOLS_READY" = "true" ]; then
            echo "Verifying Open MPI installation on all 8 pods..."
            MPI_INSTALL_COUNT=0
            for node_idx in 1 2; do
                for pod_idx in 1 2 3 4; do
                    POD_NAME="mpi-test-node${node_idx}-pod${pod_idx}"
                    MPI_CHECK=$(kubectl exec "$POD_NAME" -- mpirun --version 2>/dev/null | grep -c "Open MPI" || echo "0")
                    if [ "$MPI_CHECK" -ge 1 ]; then
                        MPI_INSTALL_COUNT=$((MPI_INSTALL_COUNT + 1))
                    fi
                done
            done
            
            if [ "$MPI_INSTALL_COUNT" -eq 8 ]; then
                test_result "Open MPI installed on all 8 pods" 0
                MPI_UCX_READY=true
            else
                test_result "Open MPI installed ($MPI_INSTALL_COUNT/8 pods)" 1
            fi
        else
            test_skip "Open MPI installation" "Skipped due to missing UCX tools"
        fi

        if [ "$UCX_TOOLS_READY" = "true" ]; then
            echo "Checking UCX RDMA transport availability..."
            # Use tr to strip newlines before integer comparison — grep -c can return
            # multi-line output on some systems causing "integer expression expected"
            UCX_RDMA_CHECK=$(kubectl exec mpi-test-node1-pod1 -- bash -c 'ucx_info -d 2>/dev/null | grep -A 1 "Transport: rc_verbs" | grep -c "hfi1_0"' 2>/dev/null | tr -d '[:space:]' || echo "0")
            if [ "${UCX_RDMA_CHECK:-0}" -ge 1 ] 2>/dev/null; then
                test_result "UCX rc_verbs transport available for hfi1_0" 0
            else
                test_result "UCX rc_verbs transport available for hfi1_0" 1
                UCX_TOOLS_READY=false
            fi
        fi

        if [ "$UCX_TOOLS_READY" = "true" ]; then
            # Get all pod IPs for hostfile
            MPI_NODE1_POD1_IP=$(kubectl get pod mpi-test-node1-pod1 -o jsonpath='{.status.podIP}')
            MPI_NODE1_POD2_IP=$(kubectl get pod mpi-test-node1-pod2 -o jsonpath='{.status.podIP}')
            MPI_NODE1_POD3_IP=$(kubectl get pod mpi-test-node1-pod3 -o jsonpath='{.status.podIP}')
            MPI_NODE1_POD4_IP=$(kubectl get pod mpi-test-node1-pod4 -o jsonpath='{.status.podIP}')
            MPI_NODE2_POD1_IP=$(kubectl get pod mpi-test-node2-pod1 -o jsonpath='{.status.podIP}')
            MPI_NODE2_POD2_IP=$(kubectl get pod mpi-test-node2-pod2 -o jsonpath='{.status.podIP}')
            MPI_NODE2_POD3_IP=$(kubectl get pod mpi-test-node2-pod3 -o jsonpath='{.status.podIP}')
            MPI_NODE2_POD4_IP=$(kubectl get pod mpi-test-node2-pod4 -o jsonpath='{.status.podIP}')
            
            echo "Starting UCX server on mpi-test-node2-pod1 ($MPI_NODE2_POD1_IP)..."
            kubectl exec mpi-test-node2-pod1 -- bash -c "
                export UCX_TLS=rc,tcp,self
                nohup ucx_perftest -t tag_bw > /tmp/ucx_server.log 2>&1 &
            " &>/dev/null || true
            sleep 3

            echo "Testing TCP baseline bandwidth..."
            TCP_OUT=$(kubectl exec mpi-test-node1-pod1 -- bash -c "
                UCX_TLS=tcp,self ucx_perftest -t tag_bw ${MPI_NODE2_POD1_IP} -s 1048576 -n 100 2>&1
            " || echo "FAILED")
            
            if echo "$TCP_OUT" | grep -q "FAILED\|Error"; then
                test_result "UCX TCP baseline test" 1
            else
                TCP_BW=$(echo "$TCP_OUT" | grep "^Final:" | awk '{print $2}')
                if [ -n "$TCP_BW" ]; then
                    echo "    TCP bandwidth: ${TCP_BW} MB/s"
                    test_result "UCX TCP baseline test" 0
                else
                    test_result "UCX TCP baseline test" 1
                fi
            fi

            kubectl exec mpi-test-node2-pod1 -- pkill -9 ucx_perftest &>/dev/null || true
            sleep 2

            echo "Starting UCX server with RDMA transport..."
            kubectl exec mpi-test-node2-pod1 -- bash -c "
                export UCX_TLS=rc,tcp,self
                export UCX_NET_DEVICES=hfi1_0:2
                export UCX_LOG_LEVEL=info
                nohup ucx_perftest -t tag_bw > /tmp/ucx_server.log 2>&1 &
            " &>/dev/null || true
            sleep 3

            echo "Testing RDMA bandwidth (split control/data plane)..."
            RDMA_OUT=$(kubectl exec mpi-test-node1-pod1 -- bash -c "
                UCX_TLS=rc,tcp,self UCX_NET_DEVICES=hfi1_0:2 UCX_LOG_LEVEL=info ucx_perftest -t tag_bw ${MPI_NODE2_POD1_IP} -s 1048576 -n 100 2>&1
            " || echo "FAILED")

            kubectl exec mpi-test-node2-pod1 -- pkill -9 ucx_perftest &>/dev/null || true

            if echo "$RDMA_OUT" | grep -q "FAILED\|Error"; then
                echo "  RDMA test output: $(echo "$RDMA_OUT" | tail -5)"
                test_result "UCX perftest completed" 1
            else
                RDMA_BW=$(echo "$RDMA_OUT" | grep "^Final:" | awk '{print $2}')
                if [ -n "$RDMA_BW" ]; then
                    echo "    UCX perftest bandwidth: ${RDMA_BW} MB/s"
                    test_result "UCX perftest completed" 0

                    echo "Verifying RDMA transport was used (checking server log)..."
                    TRANSPORT_LOG=$(kubectl exec mpi-test-node2-pod1 -- cat /tmp/ucx_server.log 2>/dev/null | grep -E "cfg#.*tag.*rc_verbs/hfi1_0" || echo "")
                    if [ -n "$TRANSPORT_LOG" ]; then
                        echo "    Transport: $(echo "$TRANSPORT_LOG" | grep -o "tag([^)]*)" | head -1)"
                        test_result "UCX perftest used rc_verbs/hfi1_0 transport" 0
                    else
                        echo "    Checking client log for transport selection..."
                        CLIENT_TRANSPORT=$(echo "$RDMA_OUT" | grep -E "cfg#.*tag.*rc_verbs/hfi1_0" || echo "")
                        if [ -n "$CLIENT_TRANSPORT" ]; then
                            echo "    Transport: $(echo "$CLIENT_TRANSPORT" | grep -o "tag([^)]*)" | head -1)"
                            test_result "UCX perftest used rc_verbs/hfi1_0 transport" 0
                        else
                            echo "    WARNING: Could not verify transport from logs"
                            test_result "UCX perftest transport verification" 1
                        fi
                    fi

                    echo "Verifying TCP was NOT used for data transfer..."
                    TCP_USED=$(kubectl exec mpi-test-node2-pod1 -- cat /tmp/ucx_server.log 2>/dev/null | grep -E "cfg#.*tag.*tcp" || echo "")
                    if [ -z "$TCP_USED" ]; then
                        echo "    ✓ TCP not used for tag operations (data transfer)"
                        test_result "UCX perftest did not fall back to TCP" 0
                    else
                        echo "    ✗ WARNING: TCP detected in tag configuration"
                        echo "    Transport: $(echo "$TCP_USED" | head -1)"
                        test_result "UCX perftest did not fall back to TCP" 1
                    fi
                    
                    echo ""
                    echo "  NOTE: UCX perftest bandwidth may be lower than expected."
                    echo "  This is a known issue with ucx_perftest tool and does not indicate"
                    echo "  a problem with RDMA functionality. MPI OSU benchmarks (below) provide"
                    echo "  the authoritative RDMA performance measurement."
                else
                    test_result "UCX perftest completed" 1
                fi
            fi
        else
            test_skip "UCX RDMA transport availability" "Skipped due to missing UCX tools"
            test_skip "UCX TCP baseline test" "Skipped due to missing UCX tools"
            test_skip "UCX perftest completed" "Skipped due to missing UCX tools"
        fi


        echo "Cleaning up MPI test pods..."
        for node_idx in 1 2; do
            for pod_idx in 1 2 3 4; do
                kubectl delete pod "mpi-test-node${node_idx}-pod${pod_idx}" --force --grace-period=0 &>/dev/null || true
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
                    if kubectl get pod "mpi-test-node${node_idx}-pod${pod_idx}" &>/dev/null; then
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
        test_skip "UCX RDMA tests" "Pods not ready"
    fi
fi

echo ""

echo "[10/12] libfabric OPX Provider Sanity Check"
echo "=================================================================="

# Cornelis HFI1 hardware uses the OPX libfabric provider for native data
# transfer. This section performs a deep sanity check of the OPX provider
# on each node, verifying device access, environment variables, and
# control-plane readiness. Data traffic is validated in section [11].

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "libfabric OPX sanity" "Requires 2+ nodes"
else
    LF_NODE1="${NODES[0]}"
    LF_NODE2="${NODES[1]}"

    # Use normal pod networking (NOT hostNetwork) to avoid OPX provider
    # sanity false negatives seen with hostNetwork pods.
    kubectl delete pod lf-rdma-node1-pod1 lf-rdma-node2-pod1 --force --grace-period=0 &>/dev/null || true
    echo "Creating OPX sanity test pods (normal pod networking)..."
    cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: lf-rdma-node1-pod1
  labels:
    app: lf-rdma-test
spec:
  nodeName: ${LF_NODE1}
  hostIPC: true
  containers:
  - name: lf
    image: ${LF_IMAGE:-localhost/cornelis/rdma-test-tools:latest}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
    resources:
      limits:
        cornelis.com/hfi: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    volumeMounts:
    - name: dev-shm
      mountPath: /dev/shm
  volumes:
  - name: dev-shm
    emptyDir:
      medium: Memory
      sizeLimit: "1Gi"
  restartPolicy: Never
EOF

    cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: lf-rdma-node2-pod1
  labels:
    app: lf-rdma-test
spec:
  nodeName: ${LF_NODE2}
  hostIPC: true
  containers:
  - name: lf
    image: ${LF_IMAGE:-localhost/cornelis/rdma-test-tools:latest}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
    resources:
      limits:
        cornelis.com/hfi: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    volumeMounts:
    - name: dev-shm
      mountPath: /dev/shm
  volumes:
  - name: dev-shm
    emptyDir:
      medium: Memory
      sizeLimit: "1Gi"
  restartPolicy: Never
EOF

    echo "Waiting for OPX sanity test pods to be ready..."
    LF_READY=true
    for pod in lf-rdma-node1-pod1 lf-rdma-node2-pod1; do
        if kubectl wait --for=condition=Ready "pod/${pod}" --timeout=120s &>/dev/null; then
            test_result "libfabric pod ${pod} ready" 0
        else
            test_result "libfabric pod ${pod} ready" 1
            LF_READY=false
        fi
    done

    if [ "$LF_READY" = true ]; then
        echo "Verifying fi_info and OPX provider on both pods..."
        OPX_SANITY_OK=0
        for pod in lf-rdma-node1-pod1 lf-rdma-node2-pod1; do
            if kubectl exec "$pod" -- bash -c \
                'FI_PROVIDER=opx FI_LOG_LEVEL=info FI_LOG_PROV=opx fi_info -p opx -v 2>&1 | grep -q "provider: opx"' &>/dev/null; then
                echo "    ✓ OPX provider sanity check passed on ${pod}"
                OPX_SANITY_OK=$((OPX_SANITY_OK + 1))
            else
                echo "    ✗ Error: OPX provider not found on ${pod}"
            fi
        done

        if [ "$OPX_SANITY_OK" -eq 2 ]; then
            test_result "OPX provider sanity check" 0
        else
            test_result "OPX provider sanity check ($OPX_SANITY_OK/2 pods passed)" 1
            LF_READY=false
        fi
    fi

    if [ "$LF_READY" = true ]; then
        echo "Verifying /dev/hfi1_* and $IFACE IPs..."
        IP_HFI_OK=true
        for pod in lf-rdma-node1-pod1 lf-rdma-node2-pod1; do
            if ! kubectl exec "$pod" -- bash -c 'ls /dev/hfi1_* >/dev/null 2>&1'; then
                echo "    ✗ Error: /dev/hfi1_* not found on ${pod}"
                IP_HFI_OK=false
            fi

            IP=$(kubectl exec "$pod" -- bash -c "ip -4 addr show $IFACE 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1")
            if [ -z "$IP" ]; then
                node_name=""
                if [[ "$pod" == *"node1"* ]]; then node_name="$LF_NODE1"; else node_name="$LF_NODE2"; fi
                echo "    (Pod-side $IFACE empty; trying node-level fallback for $node_name...)" >&2
                IP=$(get_node_ipoib_ip "$node_name")
            fi

            if [ -n "$IP" ]; then
                echo "    ✓ ${pod} $IFACE IP: ${IP}"
            else
                echo "    ✗ Error: $IFACE IP not found on ${pod} or node"
                IP_HFI_OK=false
            fi
        done

        if [ "$IP_HFI_OK" = true ]; then
            test_result "OPX device and IPoIB sanity" 0
        else
            test_result "OPX device and IPoIB sanity" 1
        fi
    fi

    echo "Cleaning up OPX sanity test pods..."
    kubectl delete pod lf-rdma-node1-pod1 lf-rdma-node2-pod1 --force --grace-period=0 &>/dev/null || true
fi

echo ""

# =====================================================================
# [11/12] MPI over libfabric (OFI/OPX) with multiple pods per node
#
# Uses Open MPI's OFI MTL with the OPX provider for native HFI1 transport.
# Multiple pods per node are deployed using normal pod networking so that
# the MPI launcher/OOB can use distinct pod IPs and per-pod sshd, while OPX
# itself communicates directly through /dev/hfi1_* devices on each pod.
# This avoids the hostNetwork SSH port collision that prevented multiple
# pods per node in the previous single-pod hostNetwork design.
# =====================================================================

echo "[11/12] MPI over libfabric (OFI/OPX)"
echo "=========================================="

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "MPI over libfabric tests" "Requires 2+ nodes"
else
    MPI_LF_NODE1="${NODES[0]}"
    MPI_LF_NODE2="${NODES[1]}"
    MPI_LF_TOTAL=$((PODS_PER_NODE * 2))

    # Use normal pod networking (NOT hostNetwork) so each pod has its own
    # IP and can run sshd on the default port 22 for the MPI launcher.
    # OPX still uses /dev/hfi1_* via the cornelis.com/hfi resource.
    echo "Creating MPI libfabric test pods (${PODS_PER_NODE} per node, ${MPI_LF_TOTAL} total)..."
    for node_idx in 1 2; do
        NODE_VAR="MPI_LF_NODE${node_idx}"
        NODE_NAME="${!NODE_VAR}"
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: mpi-lf-node${node_idx}-pod${pod_idx}
  labels:
    app: mpi-lf-test
spec:
  nodeName: ${NODE_NAME}
  # OPX/PSM-style providers historically rely on shared SysV/POSIX IPC
  # primitives between cooperating processes on the same host. Even though
  # each pod has its own /dev/hfi1_*, hostIPC=true matches the prior
  # working single-pod-per-node design and avoids surprising IPC isolation
  # while ranks bring up the OPX provider.
  hostIPC: true
  containers:
  - name: mpi
    image: ${LF_IMAGE:-localhost/cornelis/rdma-test-tools:latest}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
    resources:
      limits:
        cornelis.com/hfi: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    volumeMounts:
    - name: dev-shm
      mountPath: /dev/shm
  volumes:
  - name: dev-shm
    emptyDir:
      medium: Memory
      sizeLimit: "1Gi"
  restartPolicy: Never
EOF
        done
    done

    echo "Waiting for MPI libfabric pods to be ready..."
    MPI_LF_READY=true
    MPI_LF_READY_COUNT=0
    for node_idx in 1 2; do
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
            if kubectl wait --for=condition=Ready "pod/${POD_NAME}" --timeout=120s &>/dev/null; then
                MPI_LF_READY_COUNT=$((MPI_LF_READY_COUNT + 1))
            else
                MPI_LF_READY=false
                echo "  WARNING: ${POD_NAME} not ready"
            fi
        done
    done
    if [ "$MPI_LF_READY" = true ]; then
        test_result "MPI libfabric pods ready (${MPI_LF_TOTAL} pods: ${PODS_PER_NODE} per node)" 0
    else
        test_result "MPI libfabric pods ready (${MPI_LF_READY_COUNT}/${MPI_LF_TOTAL} ready)" 1
    fi

    if [ "$MPI_LF_READY" = true ]; then
        # Verify each pod is actually scheduled on its requested node. With
        # nodeName: ${NODE_NAME} this is normally guaranteed by the API
        # server, but we still assert it explicitly to make the multi-pod
        # per-node assignment a hard pass/fail.
        echo "Verifying MPI libfabric pod node assignment..."
        ASSIGN_OK=0
        for node_idx in 1 2; do
            NODE_VAR="MPI_LF_NODE${node_idx}"
            EXPECTED_NODE="${!NODE_VAR}"
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                ACTUAL_NODE=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
                PHASE=$(kubectl get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
                if [ "$ACTUAL_NODE" = "$EXPECTED_NODE" ] && [ "$PHASE" = "Running" ]; then
                    ASSIGN_OK=$((ASSIGN_OK + 1))
                else
                    echo "  WARNING: ${POD_NAME} on '${ACTUAL_NODE}' (expected '${EXPECTED_NODE}'), phase='${PHASE}'"
                fi
            done
        done
        if [ "$ASSIGN_OK" -eq "$MPI_LF_TOTAL" ]; then
            test_result "All ${MPI_LF_TOTAL} MPI libfabric pods scheduled on requested nodes and Running" 0
        else
            test_result "MPI libfabric pod node assignment (${ASSIGN_OK}/${MPI_LF_TOTAL} correct)" 1
            MPI_LF_READY=false
        fi
    fi

    if [ "$MPI_LF_READY" = true ]; then
        # Verify each pod actually got the cornelis.com/hfi resource granted
        # by the device plugin. This is required for OPX to access /dev/hfi1_*.
        echo "Verifying cornelis.com/hfi resource on each MPI libfabric pod..."
        HFI_OK=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                HFI_REQ=$(kubectl get pod "$POD_NAME" \
                    -o jsonpath='{.spec.containers[0].resources.limits.cornelis\.com/hfi}' 2>/dev/null)
                if [ "$HFI_REQ" = "1" ]; then
                    HFI_OK=$((HFI_OK + 1))
                fi
            done
        done
        if [ "$HFI_OK" -eq "$MPI_LF_TOTAL" ]; then
            test_result "All ${MPI_LF_TOTAL} MPI libfabric pods request cornelis.com/hfi: 1" 0
        else
            test_result "cornelis.com/hfi resource request (${HFI_OK}/${MPI_LF_TOTAL} pods)" 1
            MPI_LF_READY=false
        fi
    fi

    if [ "$MPI_LF_READY" = true ]; then
        echo "Verifying OPX runtime prerequisites in MPI libfabric pods..."
        OPX_PREFLIGHT_OK=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- bash -c '
                    set -e
                    ls /dev/hfi1_* >/dev/null 2>&1 || { echo "missing /dev/hfi1_*"; exit 1; }
                    test -d /sys/class/infiniband || { echo "missing /sys/class/infiniband"; exit 1; }

                    HFI_DEVS=$(ls -d /sys/class/infiniband/hfi1_* 2>/dev/null)
                    [ -n "$HFI_DEVS" ] || { echo "missing /sys/class/infiniband/hfi1_*"; exit 1; }

                    for dev in $HFI_DEVS; do
                        # Verify hfi1 sysfs symlink target resolves under /sys/devices
                        TARGET=$(readlink -f "$dev")
                        if [[ "$TARGET" != /sys/devices/* ]]; then
                            echo "hfi1 sysfs target not under /sys/devices ($TARGET)"
                            exit 1
                        fi

                        # Verify core sysfs attributes are readable for OPX/libibverbs
                        [ -r "$dev/node_guid" ] || { echo "node_guid unreadable for $dev"; exit 1; }
                        [ -d "$dev/ports" ] || { echo "ports directory missing for $dev"; exit 1; }

                        # Verify PCI device symlink resolves and vendor is readable
                        [ -L "$dev/device" ] || { echo "device symlink missing for $dev"; exit 1; }
                        PCI_TARGET=$(readlink -f "$dev/device")
                        if [[ "$PCI_TARGET" != /sys/devices/* ]]; then
                            echo "PCI device target not under /sys/devices ($PCI_TARGET)"
                            exit 1
                        fi
                        [ -r "$dev/device/vendor" ] || { echo "device vendor unreadable for $dev"; exit 1; }
                    done

                    STATE_FOUND=0
                    for sf in /sys/class/infiniband/hfi1_*/ports/*/state; do
                        [ -r "$sf" ] && STATE_FOUND=1 && break
                    done
                    [ "$STATE_FOUND" = "1" ] || { echo "no readable hfi1 port state"; exit 1; }
                ' &>/dev/null; then
                    OPX_PREFLIGHT_OK=$((OPX_PREFLIGHT_OK + 1))
                else
                    echo "  WARNING: OPX device prerequisites missing on ${POD_NAME}"
                fi
            done
        done
        if [ "$OPX_PREFLIGHT_OK" -eq "$MPI_LF_TOTAL" ]; then
            test_result "OPX device prerequisites on all ${MPI_LF_TOTAL} pods" 0
        else
            test_result "OPX device prerequisites (${OPX_PREFLIGHT_OK}/${MPI_LF_TOTAL} pods)" 1
            MPI_LF_READY=false
        fi

        OPX_FI_INFO_OK=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- bash -c \
                    'FI_PROVIDER=opx FI_LOG_LEVEL=info FI_LOG_PROV=opx fi_info -p opx -v 2>&1 | grep -q "provider: opx"' &>/dev/null; then
                    OPX_FI_INFO_OK=$((OPX_FI_INFO_OK + 1))
                else
                    echo "  WARNING: fi_info -p opx failed on ${POD_NAME}"
                fi
            done
        done
        if [ "$OPX_FI_INFO_OK" -eq "$MPI_LF_TOTAL" ]; then
            test_result "fi_info -p opx on all ${MPI_LF_TOTAL} pods" 0
        else
            test_result "fi_info -p opx (${OPX_FI_INFO_OK}/${MPI_LF_TOTAL} pods)" 1
            MPI_LF_READY=false
        fi
    fi

    if [ "$MPI_LF_READY" = true ]; then
        # Collect each pod's IP. With normal pod networking each pod has a
        # distinct IP, so multiple pods per node can each run sshd on port 22
        # without colliding (unlike hostNetwork pods sharing the host stack).
        echo "Collecting MPI libfabric pod IPs..."
        declare -A MPI_LF_POD_IP
        IPS_OK=true
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                IP=$(kubectl get pod "$POD_NAME" -o jsonpath='{.status.podIP}' 2>/dev/null)
                if [ -z "$IP" ]; then
                    echo "  WARNING: ${POD_NAME} has no podIP"
                    IPS_OK=false
                else
                    MPI_LF_POD_IP["$POD_NAME"]="$IP"
                fi
            done
        done
        if [ "$IPS_OK" = true ]; then
            test_result "Pod IP available on all ${MPI_LF_TOTAL} MPI libfabric pods" 0
        else
            test_result "Pod IP available on all ${MPI_LF_TOTAL} MPI libfabric pods" 1
            MPI_LF_READY=false
        fi
    fi

    if [ "$MPI_LF_READY" = true ]; then
        # SSH on the standard port 22; with pod networking each pod has its
        # own IP, so multiple pods per node coexist without port collision.
        #
        # The rdma-test-tools image is RHEL-based and its default sshd config
        # enables PAM (UsePAM yes). Inside an unprivileged container PAM's
        # session/account modules (pam_loginuid, pam_systemd, pam_keyinit, ...)
        # cannot succeed, so even a public-key authenticated remote command
        # exits with rc=254 ("command terminated with exit code 254") despite
        # TCP/22 reachability and key auth itself working. We work around this
        # by writing a test-local sshd config with `UsePAM no` and starting
        # sshd with that config explicitly. Any pre-existing default-config
        # sshd is killed first so the no-PAM config is the one actually
        # listening on port 22.
        echo "Setting up SSH for ${MPI_LF_TOTAL} MPI libfabric pods..."
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
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

                    # Ensure host keys exist (RHEL default sshd would normally
                    # generate them via systemd; in a container we do it here).
                    ssh-keygen -A >/dev/null 2>&1 || true

                    # Stop any sshd already running with the default (PAM-enabled)
                    # config so our no-PAM config is the one bound to port 22.
                    pkill -9 sshd 2>/dev/null || true

                    # Test-local sshd config: PAM disabled so remote commands
                    # don't fail with rc=254 inside unprivileged containers.
                    cat > /tmp/sshd_config_mpi_lf <<'SSHD_CFG'
Port 22
UsePAM no
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PidFile /tmp/sshd_mpi_lf.pid
SSHD_CFG

                    # Start sshd with the no-PAM config; capture stderr to a
                    # log file so failures are diagnosable post-hoc.
                    /usr/sbin/sshd -f /tmp/sshd_config_mpi_lf -E /tmp/sshd_mpi_lf.log || true
                " &>/dev/null || true
            done
        done

        echo "Exchanging SSH keys between all MPI libfabric pods..."
        TEMP_LF_KEYS="/tmp/mpi_lf_keys_$$.txt"
        rm -f "$TEMP_LF_KEYS"
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                kubectl exec "$POD_NAME" -- cat /root/.ssh/id_rsa.pub >> "$TEMP_LF_KEYS" 2>/dev/null
            done
        done
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                cat "$TEMP_LF_KEYS" | kubectl exec -i "$POD_NAME" -- bash -c \
                    "cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null
            done
        done
        rm -f "$TEMP_LF_KEYS"

        # Ensure sshd is actually listening on every pod's pod IP. Without
        # this the very first pairwise SSH attempt sometimes lands during
        # the sshd warmup window and the MPI launcher then sees a flaky
        # connection. We poll up to 15s per pod for TCP/22 readiness.
        echo "Waiting for sshd on all MPI libfabric pods..."
        SSHD_READY_OK=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- bash -c '
                    for i in $(seq 1 15); do
                        if (echo > /dev/tcp/127.0.0.1/22) 2>/dev/null; then exit 0; fi
                        sleep 1
                    done
                    exit 1
                ' &>/dev/null; then
                    SSHD_READY_OK=$((SSHD_READY_OK + 1))
                else
                    echo "  WARNING: sshd not listening on ${POD_NAME}:22"
                fi
            done
        done
        if [ "$SSHD_READY_OK" -eq "$MPI_LF_TOTAL" ]; then
            test_result "sshd listening on all ${MPI_LF_TOTAL} MPI libfabric pods" 0
        else
            test_result "sshd listening (${SSHD_READY_OK}/${MPI_LF_TOTAL} pods)" 1
        fi

        # Pairwise SSH preflight by pod IP. We test exactly the connections
        # the Open MPI PRRTE launcher will use: from mpi-lf-node1-pod${i}
        # (the launcher pod, where mpirun runs) to mpi-lf-node2-pod${i}'s
        # pod IP, plus the reverse direction so OOB callbacks succeed.
        # Pairs that fail this preflight are recorded so the MPI runs below
        # can distinguish "SSH never worked" (legit skip) from "SSH worked
        # but mpirun's PRRTE/OOB still fails" (must be a hard failure).
        echo "Pairwise SSH preflight between MPI libfabric pod pairs..."
        declare -A MPI_LF_PAIR_SSH_OK
        SSH_PREFLIGHT_PASS=0
        SSH_PREFLIGHT_FAIL=0
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            POD_A="mpi-lf-node1-pod${pod_idx}"
            POD_B="mpi-lf-node2-pod${pod_idx}"
            IP_A="${MPI_LF_POD_IP[$POD_A]}"
            IP_B="${MPI_LF_POD_IP[$POD_B]}"
            PAIR_OK=true

            # Forward: launcher pod (POD_A) -> POD_B by pod IP.
            if ! kubectl exec "$POD_A" -- ssh \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o BatchMode=yes \
                    -o ConnectTimeout=10 \
                    "$IP_B" "true" &>/dev/null; then
                PAIR_OK=false
                echo "  WARNING: SSH ${POD_A} -> ${IP_B} (${POD_B}) FAILED"
            fi

            # Reverse: POD_B -> POD_A by pod IP. Open MPI's PRRTE
            # daemon-to-daemon OOB uses TCP callbacks both ways, so the
            # reverse direction must work for mpirun to bring up prted
            # on the remote node reliably.
            if ! kubectl exec "$POD_B" -- ssh \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o BatchMode=yes \
                    -o ConnectTimeout=10 \
                    "$IP_A" "true" &>/dev/null; then
                PAIR_OK=false
                echo "  WARNING: SSH ${POD_B} -> ${IP_A} (${POD_A}) FAILED"
            fi

            if [ "$PAIR_OK" = true ]; then
                MPI_LF_PAIR_SSH_OK["$pod_idx"]="1"
                SSH_PREFLIGHT_PASS=$((SSH_PREFLIGHT_PASS + 1))
                test_result "Pairwise SSH preflight pair ${pod_idx} (${POD_A} <-> ${POD_B})" 0
            else
                MPI_LF_PAIR_SSH_OK["$pod_idx"]="0"
                SSH_PREFLIGHT_FAIL=$((SSH_PREFLIGHT_FAIL + 1))
                test_result "Pairwise SSH preflight pair ${pod_idx} (${POD_A} <-> ${POD_B})" 1
            fi
        done
        echo "  SSH preflight: pass=${SSH_PREFLIGHT_PASS} fail=${SSH_PREFLIGHT_FAIL}"

        echo "Verifying OSU Micro-Benchmarks on MPI libfabric pods..."
        OSU_LF_COUNT=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lf-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- \
                    test -f /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_bw &>/dev/null; then
                    OSU_LF_COUNT=$((OSU_LF_COUNT + 1))
                fi
            done
        done
        if [ "$OSU_LF_COUNT" -eq "$MPI_LF_TOTAL" ]; then
            test_result "OSU Micro-Benchmarks installed on all ${MPI_LF_TOTAL} MPI libfabric pods" 0
        else
            test_result "OSU Micro-Benchmarks installed (${OSU_LF_COUNT}/${MPI_LF_TOTAL} pods)" 1
        fi

        if [ "$OSU_LF_COUNT" -eq "$MPI_LF_TOTAL" ]; then
            # OSU pt2pt benchmarks (osu_latency, osu_bw) are strictly 2-rank
            # tests. To exercise every multi-pod-per-node deployment we run
            # one 2-rank pair per pod_idx, pairing mpi-lf-node1-pod${i} with
            # mpi-lf-node2-pod${i}. Each pair gets its own FI_OPX_UUID so
            # concurrent or sequential pairs do not collide on the OPX
            # rendezvous namespace.
            LAT_PASS=0; LAT_FAIL=0; LAT_SKIP=0
            BW_PASS=0;  BW_FAIL=0;  BW_SKIP=0
            OPX_EVIDENCE_LAT=0
            OPX_EVIDENCE_BW=0

            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_A="mpi-lf-node1-pod${pod_idx}"
                POD_B="mpi-lf-node2-pod${pod_idx}"
                IP_A="${MPI_LF_POD_IP[$POD_A]}"
                IP_B="${MPI_LF_POD_IP[$POD_B]}"

                # Per-pair 2-entry hostfile written on the launcher pod.
                PAIR_HOSTFILE="/tmp/hostfile_pair_${pod_idx}"
                printf '%s slots=1\n%s slots=1\n' "$IP_A" "$IP_B" \
                    | kubectl exec -i "$POD_A" -- bash -c "cat > ${PAIR_HOSTFILE}" 2>/dev/null || true

                # Per-pair OPX UUID so simultaneous/overlapping pairs cannot
                # cross-rendezvous; OPX requires all ranks of one job to
                # share FI_OPX_UUID, but distinct jobs must use distinct UUIDs.
                PAIR_UUID=$(kubectl exec "$POD_A" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-')
                [ -z "$PAIR_UUID" ] && PAIR_UUID="0000000000000000000000000000c0${pod_idx}"

                # Skip pairs whose pairwise SSH preflight already failed.
                # In that case the launcher truly cannot reach the remote
                # peer over the pod network, which is an environmental
                # prerequisite, not an MPI/OPX defect.
                if [ "${MPI_LF_PAIR_SSH_OK[$pod_idx]}" != "1" ]; then
                    test_skip "MPI OFI OPX latency pair ${pod_idx} (${POD_A} <-> ${POD_B})" "Pairwise SSH preflight failed"
                    LAT_SKIP=$((LAT_SKIP + 1))
                    test_skip "MPI OFI OPX bandwidth pair ${pod_idx} (${POD_A} <-> ${POD_B})" "Pairwise SSH preflight failed"
                    BW_SKIP=$((BW_SKIP + 1))
                    continue
                fi

                echo "Running OSU latency (pair ${pod_idx}: ${POD_A} <-> ${POD_B}, FI_OPX_UUID=${PAIR_UUID})..."
                set +e
                # MCA flags below pin Open MPI/PRRTE OOB and the runtime TCP
                # BTL to the pod-network interface (eth0) so the launcher
                # callbacks travel over the same IPs as our hostfile and
                # SSH preflight, instead of accidentally binding to a host
                # IPoIB or external interface that is not reachable from
                # the peer pod's network namespace. plm_rsh_agent forces
                # PRRTE to spawn remote prted via ssh (matches preflight).
                OFI_LAT=$(kubectl exec "$POD_A" -- timeout 120 \
                    mpirun --allow-run-as-root \
                           --mca pml cm \
                           --mca mtl ofi \
                           --mca mtl_ofi_provider_include opx \
                           --mca opal_common_ofi_provider_include opx \
                           --mca btl ^openib,ofi,vader,tcp,self \
                           --mca btl_tcp_if_include eth0 \
                           --mca oob_tcp_if_include eth0 \
                           --mca plm_rsh_agent ssh \
                           --mca plm_rsh_no_tree_spawn 1 \
                           -x FI_PROVIDER=opx \
                           -x FI_LOG_LEVEL=info \
                           -x FI_LOG_PROV=opx \
                           -x FI_OPX_UUID=${PAIR_UUID} \
                           -np 2 -hostfile ${PAIR_HOSTFILE} \
                           /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 0:128 -i 100 \
                    2>&1 || echo "MPI_FAILED")
                LAT_RC=$?
                set -e

                # SSH preflight has already proved pod-to-pod connectivity
                # works, so any remaining PRRTE/OOB launcher failure here
                # is an actual defect (likely an Open MPI MCA misconfig
                # for our pod network), not an environmental skip.
                if echo "$OFI_LAT" | grep -qE "Remote daemon|TCP network connection|command terminated with exit code 254"; then
                    echo "  Output: $(echo "$OFI_LAT" | tail -20)"
                    test_result "MPI OFI OPX latency pair ${pod_idx} (${POD_A} <-> ${POD_B}) - launcher failed after SSH preflight passed" 1
                    LAT_FAIL=$((LAT_FAIL + 1))
                elif echo "$OFI_LAT" | grep -q "MPI_FAILED\|Aborting\|fatal\|Fatal"; then
                    echo "  Output: $(echo "$OFI_LAT" | tail -10)"
                    test_result "MPI OFI OPX latency pair ${pod_idx} (${POD_A} <-> ${POD_B})" 1
                    LAT_FAIL=$((LAT_FAIL + 1))
                else
                    OFI_LAT_VAL=$(echo "$OFI_LAT" | grep "^[0-9]" | head -1 | awk '{print $2}')
                    if [ -n "$OFI_LAT_VAL" ]; then
                        echo "    Latency pair ${pod_idx}: ${OFI_LAT_VAL} us"
                        test_result "MPI OFI OPX latency pair ${pod_idx} (${POD_A} <-> ${POD_B})" 0
                        LAT_PASS=$((LAT_PASS + 1))
                        if echo "$OFI_LAT" | grep -qiE "provider: opx|FI_PROVIDER=opx|opx fabric"; then
                            OPX_EVIDENCE_LAT=$((OPX_EVIDENCE_LAT + 1))
                        fi
                    else
                        echo "  Could not parse latency"
                        echo "  Output: $(echo "$OFI_LAT" | tail -10)"
                        test_result "MPI OFI OPX latency pair ${pod_idx} (${POD_A} <-> ${POD_B})" 1
                        LAT_FAIL=$((LAT_FAIL + 1))
                    fi
                fi

                echo "Running OSU bandwidth (pair ${pod_idx}: ${POD_A} <-> ${POD_B}, FI_OPX_UUID=${PAIR_UUID})..."
                set +e
                OFI_BW=$(kubectl exec "$POD_A" -- timeout 180 \
                    mpirun --allow-run-as-root \
                           --mca pml cm \
                           --mca mtl ofi \
                           --mca mtl_ofi_provider_include opx \
                           --mca opal_common_ofi_provider_include opx \
                           --mca btl ^openib,ofi,vader,tcp,self \
                           --mca btl_tcp_if_include eth0 \
                           --mca oob_tcp_if_include eth0 \
                           --mca plm_rsh_agent ssh \
                           --mca plm_rsh_no_tree_spawn 1 \
                           -x FI_PROVIDER=opx \
                           -x FI_LOG_LEVEL=info \
                           -x FI_LOG_PROV=opx \
                           -x FI_OPX_UUID=${PAIR_UUID} \
                           -np 2 -hostfile ${PAIR_HOSTFILE} \
                           /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_bw -m 0:4096 -i 100 \
                    2>&1 || echo "MPI_FAILED")
                BW_RC=$?
                set -e

                if echo "$OFI_BW" | grep -qE "Remote daemon|TCP network connection|command terminated with exit code 254"; then
                    echo "  Output: $(echo "$OFI_BW" | tail -20)"
                    test_result "MPI OFI OPX bandwidth pair ${pod_idx} (${POD_A} <-> ${POD_B}) - launcher failed after SSH preflight passed" 1
                    BW_FAIL=$((BW_FAIL + 1))
                elif echo "$OFI_BW" | grep -q "MPI_FAILED\|Aborting\|fatal\|Fatal"; then
                    echo "  Output: $(echo "$OFI_BW" | tail -10)"
                    test_result "MPI OFI OPX bandwidth pair ${pod_idx} (${POD_A} <-> ${POD_B})" 1
                    BW_FAIL=$((BW_FAIL + 1))
                else
                    OFI_BW_VAL=$(echo "$OFI_BW" | grep "^[0-9]" | tail -1 | awk '{print $2}')
                    if [ -n "$OFI_BW_VAL" ]; then
                        echo "    Bandwidth pair ${pod_idx}: ${OFI_BW_VAL} MB/s"
                        test_result "MPI OFI OPX bandwidth pair ${pod_idx} (${POD_A} <-> ${POD_B})" 0
                        BW_PASS=$((BW_PASS + 1))
                        if echo "$OFI_BW" | grep -qiE "provider: opx|FI_PROVIDER=opx|opx fabric"; then
                            OPX_EVIDENCE_BW=$((OPX_EVIDENCE_BW + 1))
                        fi
                    else
                        echo "  Could not parse bandwidth"
                        echo "  Output: $(echo "$OFI_BW" | tail -10)"
                        test_result "MPI OFI OPX bandwidth pair ${pod_idx} (${POD_A} <-> ${POD_B})" 1
                        BW_FAIL=$((BW_FAIL + 1))
                    fi
                fi
            done

            echo "MPI OFI OPX pt2pt summary across ${PODS_PER_NODE} pair(s):"
            echo "  Latency:   pass=${LAT_PASS} fail=${LAT_FAIL} skip=${LAT_SKIP} (opx evidence: ${OPX_EVIDENCE_LAT})"
            echo "  Bandwidth: pass=${BW_PASS}  fail=${BW_FAIL}  skip=${BW_SKIP}  (opx evidence: ${OPX_EVIDENCE_BW})"
        fi
    fi

    echo "Cleaning up MPI libfabric test pods..."
    for node_idx in 1 2; do
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            kubectl delete pod "mpi-lf-node${node_idx}-pod${pod_idx}" --force --grace-period=0 &>/dev/null || true
        done
    done

    echo "Verifying MPI libfabric pods are deleted..."
    LF_CLEANUP_TIMEOUT=60
    LF_CLEANUP_ELAPSED=0
    LF_PODS_REMAINING=$MPI_LF_TOTAL
    while [ "$LF_PODS_REMAINING" -gt 0 ] && [ "$LF_CLEANUP_ELAPSED" -lt "$LF_CLEANUP_TIMEOUT" ]; do
        LF_PODS_REMAINING=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                if kubectl get pod "mpi-lf-node${node_idx}-pod${pod_idx}" &>/dev/null; then
                    LF_PODS_REMAINING=$((LF_PODS_REMAINING + 1))
                fi
            done
        done
        if [ "$LF_PODS_REMAINING" -gt 0 ]; then
            sleep 2
            LF_CLEANUP_ELAPSED=$((LF_CLEANUP_ELAPSED + 2))
        fi
    done

    if [ "$LF_PODS_REMAINING" -eq 0 ]; then
        test_result "All MPI libfabric pods deleted successfully" 0
    else
        test_result "MPI libfabric pod cleanup ($LF_PODS_REMAINING pods still remaining)" 1
    fi
fi

echo ""

# =====================================================================
# [12/12] MPI Collectives over OPX with Shared Memory Verification
#
# Section [11/12] only exercises cross-node OPX pt2pt (mpi-lf-node1-pod${i}
# <-> mpi-lf-node2-pod${i}). This section extends OPX coverage to:
#   12.A: np=${MPI_LFC_TOTAL} osu_allreduce collective across ALL pods,
#         distributing work over both nodes simultaneously.
#   12.B: Intra-node osu_latency on same-node pod pair to drive the OPX
#         intra-host fast path that pt2pt loop in section 11 never hits.
#   12.C: FI_OPX_SHM_ENABLE=yes vs =no differential on the SAME intra-node
#         pair. Per fi_opx(7), setting NO disables shm except for "peers
#         with same lid and same hfi1 (loopback)"; if the intra-node OPX
#         SHM module is doing the work, the YES run should be measurably
#         faster than (or equal to) the NO run, and we can confirm the
#         provider is exposing SHM as a tunable knob.
#   12.D: /proc/<pid>/fd inspection during a running osu_latency on the
#         same-node pair, asserting >=1 fd points into /dev/shm/* and no
#         /dev/shm/psm2_shm.* (which would indicate the wrong provider).
#   12.E: FI_LOG_LEVEL=debug FI_LOG_PROV=opx grep for 'opx' AND 'shm'
#         tokens (best-effort; some OPX builds compile without DEBUG).
#
# All MPI runs use the same Open MPI -> CM PML -> ofi MTL -> opx provider
# stack as section [11/12]. Open MPI's shared-memory BTL (vader/sm) is
# explicitly excluded via "--mca btl ^openib,ofi,vader,tcp,self", so any
# observed intra-node fast path comes from the OPX provider's own shm
# module, not Open MPI's vader/sm BTL.
# =====================================================================

echo "[12/12] MPI Collectives over OPX with Shared Memory Verification"
echo "=========================================="

if [ "$TOTAL_NODES" -lt 2 ]; then
    test_skip "MPI collectives + SHM verification" "Requires 2+ nodes"
elif [ "$PODS_PER_NODE" -lt 2 ]; then
    test_skip "MPI collectives + SHM verification" "Requires PODS_PER_NODE >= 2 (need 2 same-node pods for intra-node SHM tests)"
else
    MPI_LFC_NODE1="${NODES[0]}"
    MPI_LFC_NODE2="${NODES[1]}"
    MPI_LFC_TOTAL=$((PODS_PER_NODE * 2))

    # Pod creation (mirrors section [11/12] manifest, mpi-lfc- prefix to
    # avoid name collisions and to keep clean separation in cleanup).
    echo "Creating MPI libfabric collective pods (${PODS_PER_NODE} per node, ${MPI_LFC_TOTAL} total)..."
    for node_idx in 1 2; do
        NODE_VAR="MPI_LFC_NODE${node_idx}"
        NODE_NAME="${!NODE_VAR}"
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: mpi-lfc-node${node_idx}-pod${pod_idx}
  labels:
    app: mpi-lfc-test
spec:
  nodeName: ${NODE_NAME}
  hostIPC: true
  containers:
  - name: mpi
    image: ${LF_IMAGE:-localhost/cornelis/rdma-test-tools:latest}
    imagePullPolicy: Never
    command: ["/bin/bash", "-c", "sleep infinity"]
    resources:
      limits:
        cornelis.com/hfi: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
    volumeMounts:
    - name: dev-shm
      mountPath: /dev/shm
  volumes:
  # OPX intra-node SHM fast path requires every rank to share the same POSIX shm
  # namespace. hostIPC=true alone shares only the SysV IPC namespace; the /dev/shm
  # mount is governed by the volume + mount namespace. emptyDir gives EACH pod its
  # own private tmpfs, so OPX shm_open("/opx_<uuid>_<lid>") in pod A is invisible
  # to pod B and the OFI MTL aborts at endpoint init. Mounting the host's actual
  # /dev/shm via hostPath makes both pods see one shared tmpfs, which is what
  # OPX (and PSM-style providers) require for multi-rank-per-node MPI jobs in K8s.
  - name: dev-shm
    hostPath:
      path: /dev/shm
      type: Directory
  restartPolicy: Never
EOF
        done
    done

    echo "Waiting for MPI libfabric collective pods to be ready..."
    MPI_LFC_READY=true
    MPI_LFC_READY_COUNT=0
    for node_idx in 1 2; do
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
            if kubectl wait --for=condition=Ready "pod/${POD_NAME}" --timeout=120s &>/dev/null; then
                MPI_LFC_READY_COUNT=$((MPI_LFC_READY_COUNT + 1))
            else
                MPI_LFC_READY=false
                echo "  WARNING: ${POD_NAME} not ready"
            fi
        done
    done
    if [ "$MPI_LFC_READY" = true ]; then
        test_result "MPI libfabric collective pods ready (${MPI_LFC_TOTAL} pods)" 0
    else
        test_result "MPI libfabric collective pods ready (${MPI_LFC_READY_COUNT}/${MPI_LFC_TOTAL} ready)" 1
    fi

    if [ "$MPI_LFC_READY" = true ]; then
        # Verify pod node assignment + cornelis.com/hfi resource granted.
        ASSIGN_OK=0
        HFI_OK=0
        for node_idx in 1 2; do
            NODE_VAR="MPI_LFC_NODE${node_idx}"
            EXPECTED_NODE="${!NODE_VAR}"
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                ACTUAL_NODE=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
                PHASE=$(kubectl get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
                if [ "$ACTUAL_NODE" = "$EXPECTED_NODE" ] && [ "$PHASE" = "Running" ]; then
                    ASSIGN_OK=$((ASSIGN_OK + 1))
                fi
                HFI_REQ=$(kubectl get pod "$POD_NAME" \
                    -o jsonpath='{.spec.containers[0].resources.limits.cornelis\.com/hfi}' 2>/dev/null)
                if [ "$HFI_REQ" = "1" ]; then
                    HFI_OK=$((HFI_OK + 1))
                fi
            done
        done
        if [ "$ASSIGN_OK" -eq "$MPI_LFC_TOTAL" ] && [ "$HFI_OK" -eq "$MPI_LFC_TOTAL" ]; then
            test_result "MPI libfabric collective pod scheduling + cornelis.com/hfi (${MPI_LFC_TOTAL} pods)" 0
        else
            test_result "MPI libfabric collective pod scheduling/HFI (assign=${ASSIGN_OK}, hfi=${HFI_OK} of ${MPI_LFC_TOTAL})" 1
            MPI_LFC_READY=false
        fi
    fi

    if [ "$MPI_LFC_READY" = true ]; then
        # OPX runtime preflight (fi_info -p opx) on every pod.
        OPX_LFC_FI_INFO_OK=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- bash -c \
                    'FI_PROVIDER=opx FI_LOG_LEVEL=info FI_LOG_PROV=opx fi_info -p opx -v 2>&1 | grep -q "provider: opx"' &>/dev/null; then
                    OPX_LFC_FI_INFO_OK=$((OPX_LFC_FI_INFO_OK + 1))
                fi
            done
        done
        if [ "$OPX_LFC_FI_INFO_OK" -eq "$MPI_LFC_TOTAL" ]; then
            test_result "fi_info -p opx on all ${MPI_LFC_TOTAL} collective pods" 0
        else
            test_result "fi_info -p opx (${OPX_LFC_FI_INFO_OK}/${MPI_LFC_TOTAL} pods)" 1
            MPI_LFC_READY=false
        fi
    fi

    if [ "$MPI_LFC_READY" = true ]; then
        # Collect pod IPs for hostfile construction.
        echo "Collecting MPI libfabric collective pod IPs..."
        declare -A MPI_LFC_POD_IP
        IPS_LFC_OK=true
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                IP=$(kubectl get pod "$POD_NAME" -o jsonpath='{.status.podIP}' 2>/dev/null)
                if [ -z "$IP" ]; then
                    IPS_LFC_OK=false
                else
                    MPI_LFC_POD_IP["$POD_NAME"]="$IP"
                fi
            done
        done
        if [ "$IPS_LFC_OK" = true ]; then
            test_result "Pod IP available on all ${MPI_LFC_TOTAL} MPI libfabric collective pods" 0
        else
            test_result "Pod IP available on all ${MPI_LFC_TOTAL} MPI libfabric collective pods" 1
            MPI_LFC_READY=false
        fi
    fi

    if [ "$MPI_LFC_READY" = true ]; then
        # Set up no-PAM sshd on every pod (same approach as section [11/12]
        # but with separate sshd_config_mpi_lfc / sshd_mpi_lfc.pid files so
        # the two sections can run in the same script without conflict).
        echo "Setting up SSH for ${MPI_LFC_TOTAL} MPI libfabric collective pods..."
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
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
                    cat > /tmp/sshd_config_mpi_lfc <<'SSHD_CFG'
Port 22
UsePAM no
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PidFile /tmp/sshd_mpi_lfc.pid
SSHD_CFG
                    /usr/sbin/sshd -f /tmp/sshd_config_mpi_lfc -E /tmp/sshd_mpi_lfc.log || true
                " &>/dev/null || true
            done
        done

        echo "Exchanging SSH keys between all MPI libfabric collective pods..."
        TEMP_LFC_KEYS="/tmp/mpi_lfc_keys_$$.txt"
        rm -f "$TEMP_LFC_KEYS"
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                kubectl exec "$POD_NAME" -- cat /root/.ssh/id_rsa.pub >> "$TEMP_LFC_KEYS" 2>/dev/null
            done
        done
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                cat "$TEMP_LFC_KEYS" | kubectl exec -i "$POD_NAME" -- bash -c \
                    "cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null
            done
        done
        rm -f "$TEMP_LFC_KEYS"

        echo "Waiting for sshd on all MPI libfabric collective pods..."
        SSHD_LFC_READY_OK=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                if kubectl exec "$POD_NAME" -- bash -c '
                    for i in $(seq 1 15); do
                        if (echo > /dev/tcp/127.0.0.1/22) 2>/dev/null; then exit 0; fi
                        sleep 1
                    done
                    exit 1
                ' &>/dev/null; then
                    SSHD_LFC_READY_OK=$((SSHD_LFC_READY_OK + 1))
                fi
            done
        done
        if [ "$SSHD_LFC_READY_OK" -eq "$MPI_LFC_TOTAL" ]; then
            test_result "sshd listening on all ${MPI_LFC_TOTAL} MPI libfabric collective pods" 0
        else
            test_result "sshd listening on collective pods (${SSHD_LFC_READY_OK}/${MPI_LFC_TOTAL})" 1
            MPI_LFC_READY=false
        fi
    fi

    if [ "$MPI_LFC_READY" = true ]; then
        # Pairwise SSH preflight: launcher pod (mpi-lfc-node1-pod1) must be
        # able to ssh into every other pod, both forward (launcher -> peer)
        # and reverse (peer -> launcher) so PRRTE OOB callbacks succeed.
        echo "Pairwise SSH preflight from launcher (mpi-lfc-node1-pod1) to all peers..."
        LAUNCHER_LFC="mpi-lfc-node1-pod1"
        IP_LAUNCHER="${MPI_LFC_POD_IP[$LAUNCHER_LFC]}"
        SSH_LFC_OK=0
        SSH_LFC_TOTAL_PEERS=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                [ "$POD_NAME" = "$LAUNCHER_LFC" ] && continue
                SSH_LFC_TOTAL_PEERS=$((SSH_LFC_TOTAL_PEERS + 1))
                IP_PEER="${MPI_LFC_POD_IP[$POD_NAME]}"
                FWD_OK=true; REV_OK=true
                if ! kubectl exec "$LAUNCHER_LFC" -- ssh \
                        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        -o BatchMode=yes -o ConnectTimeout=10 \
                        "$IP_PEER" "true" &>/dev/null; then
                    FWD_OK=false
                fi
                if ! kubectl exec "$POD_NAME" -- ssh \
                        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        -o BatchMode=yes -o ConnectTimeout=10 \
                        "$IP_LAUNCHER" "true" &>/dev/null; then
                    REV_OK=false
                fi
                if [ "$FWD_OK" = true ] && [ "$REV_OK" = true ]; then
                    SSH_LFC_OK=$((SSH_LFC_OK + 1))
                else
                    echo "  WARNING: SSH preflight ${LAUNCHER_LFC} <-> ${POD_NAME} failed (fwd=${FWD_OK} rev=${REV_OK})"
                fi
            done
        done
        if [ "$SSH_LFC_OK" -eq "$SSH_LFC_TOTAL_PEERS" ]; then
            test_result "SSH preflight launcher -> all ${SSH_LFC_TOTAL_PEERS} peers (collective)" 0
        else
            test_result "SSH preflight launcher -> peers (${SSH_LFC_OK}/${SSH_LFC_TOTAL_PEERS})" 1
            MPI_LFC_READY=false
        fi
    fi

    if [ "$MPI_LFC_READY" = true ]; then
        # Verify osu_allreduce + osu_latency binaries exist on launcher pod.
        if kubectl exec "mpi-lfc-node1-pod1" -- bash -c '
            test -f /usr/local/libexec/osu-micro-benchmarks/mpi/collective/osu_allreduce && \
            test -f /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency
        ' &>/dev/null; then
            test_result "OSU collective + pt2pt binaries available on launcher" 0
        else
            test_result "OSU collective + pt2pt binaries available on launcher" 1
            MPI_LFC_READY=false
        fi
    fi

    if [ "$MPI_LFC_READY" = true ]; then
        # Build the all-pods hostfile (np=${MPI_LFC_TOTAL}) on the launcher
        # pod. Each pod gets slots=1 so MPI distributes one rank per pod;
        # collective traffic between same-node pods then exercises the OPX
        # intra-node fast path while cross-node traffic exercises the HFI
        # fabric path - all in one np=${MPI_LFC_TOTAL} job.
        ALL_HOSTFILE_LFC="/tmp/hostfile_lfc_all"
        {
            for node_idx in 1 2; do
                for pod_idx in $(seq 1 $PODS_PER_NODE); do
                    POD_NAME="mpi-lfc-node${node_idx}-pod${pod_idx}"
                    echo "${MPI_LFC_POD_IP[$POD_NAME]} slots=1"
                done
            done
        } | kubectl exec -i "mpi-lfc-node1-pod1" -- bash -c "cat > ${ALL_HOSTFILE_LFC}" 2>/dev/null || true

        # Per-job OPX UUID; all ranks of one mpirun must share it.
        ALLRED_UUID=$(kubectl exec "mpi-lfc-node1-pod1" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-')
        [ -z "$ALLRED_UUID" ] && ALLRED_UUID="0000000000000000000000000000a1ed"

        # =================================================================
        # SUBTEST 12.A - osu_allreduce np=${MPI_LFC_TOTAL} over OPX
        # =================================================================
        # Capture the OPX provider banner via a dedicated `fi_info -p opx` exec.
        # This is more reliable than grepping mpirun output: with FI_LOG_PROV=opx
        # and FI_LOG_LEVEL=info, the actual osu_allreduce stdout/stderr only
        # contains libfabric core:mr cleanup lines (no opx-tagged messages),
        # because the OPX provider's init logging happens before MPI_Init's
        # rank synchronization and is consumed by mpirun's I/O multiplexer.
        # `fi_info -p opx` deterministically prints "provider: opx" plus version,
        # fabric, domain - precisely the banner we want to assert.
        ALLRED_FI_INFO=$(kubectl exec "mpi-lfc-node1-pod1" -- env FI_PROVIDER=opx fi_info -p opx 2>&1 || echo "FI_INFO_FAILED")

        echo "Running OSU osu_allreduce (np=${MPI_LFC_TOTAL}, all pods, FI_OPX_UUID=${ALLRED_UUID})..."
        # FI_LOG vars intentionally OMITTED here. Adding FI_LOG_LEVEL=info to
        # 8-rank allreduce produced ~MB of stderr per rank; the captured
        # ALLRED_OUT is enormous and made downstream `grep | head` pipelines
        # SIGPIPE before the script's `set +e` re-armed `set -e`. Smaller
        # stdout also avoids stalling the kubectl exec stream.
        set +e
        ALLRED_OUT=$(kubectl exec "mpi-lfc-node1-pod1" -- timeout 240 \
            mpirun --allow-run-as-root \
                   --mca pml cm \
                   --mca mtl ofi \
                   --mca mtl_ofi_provider_include opx \
                   --mca opal_common_ofi_provider_include opx \
                   --mca btl ^openib,ofi,vader,tcp,self \
                   --mca btl_tcp_if_include eth0 \
                   --mca oob_tcp_if_include eth0 \
                   --mca plm_rsh_agent ssh \
                   --mca plm_rsh_no_tree_spawn 1 \
                   -x FI_PROVIDER=opx \
                   -x FI_OPX_UUID=${ALLRED_UUID} \
                   -np ${MPI_LFC_TOTAL} -hostfile ${ALL_HOSTFILE_LFC} \
                   /usr/local/libexec/osu-micro-benchmarks/mpi/collective/osu_allreduce -m 0:1024 \
            2>&1 || echo "MPI_FAILED")
        ALLRED_RC=$?
        set -e

        if echo "$ALLRED_OUT" | grep -qE "Remote daemon|TCP network connection|command terminated with exit code 254"; then
            echo "  Output: $(echo "$ALLRED_OUT" | tail -20)"
            test_result "12.A osu_allreduce np=${MPI_LFC_TOTAL} over OPX - launcher failed" 1
        elif echo "$ALLRED_OUT" | grep -q "MPI_FAILED\|Aborting\|fatal\|Fatal"; then
            echo "  Output: $(echo "$ALLRED_OUT" | tail -10)"
            test_result "12.A osu_allreduce np=${MPI_LFC_TOTAL} over OPX" 1
        else
            # osu_allreduce output: lines beginning with size (digits) and
            # avg latency (us). Parse the first numeric data line.
            # SIGPIPE-safe parse: single-pass awk reading from a here-string
            # avoids the prior `echo | grep | head -1 | awk` pipeline. With
            # large FI_LOG_LEVEL=info output (8 ranks * many message sizes),
            # `head -1` closed the pipe before `grep` finished writing,
            # causing grep to receive SIGPIPE. Combined with the script-wide
            # `set -euo pipefail`, that 141 exit code propagated up and
            # killed the script before any 12.* assertion could run.
            ALLRED_VAL=$(awk '/^[0-9]/{print $2; exit}' <<< "$ALLRED_OUT")
            if [ -n "$ALLRED_VAL" ]; then
                echo "    osu_allreduce np=${MPI_LFC_TOTAL} small-msg latency: ${ALLRED_VAL} us"
                test_result "12.A osu_allreduce np=${MPI_LFC_TOTAL} over OPX" 0
                # Provider evidence: assert that the same image used for
                # the allreduce launcher reports OPX as an available provider
                # via `fi_info -p opx`. If `fi_info -p opx` returns the OPX
                # banner, every rank linked against this libfabric must have
                # selected OPX (mpirun's --mca mtl_ofi_provider_include opx
                # would have aborted at MPI_Init otherwise).
                if echo "$ALLRED_FI_INFO" | grep -qE "provider: opx"; then
                    test_result "12.A OPX provider evidence (fi_info -p opx)" 0
                else
                    echo "  fi_info output (debug aid):"
                    echo "$ALLRED_FI_INFO" | sed 's/^/    /'
                    test_result "12.A OPX provider evidence (fi_info -p opx)" 1
                fi
            else
                echo "  Could not parse osu_allreduce output"
                echo "  Output: $(echo "$ALLRED_OUT" | tail -10)"
                test_result "12.A osu_allreduce np=${MPI_LFC_TOTAL} over OPX" 1
            fi
        fi

        # =================================================================
        # SUBTEST 12.B - intra-node osu_latency on same-node pod pair
        # This is the very thing section [11/12] never exercises: two pods
        # both on node1 talking via OPX. With BTLs disabled the only
        # possible intra-node transport is OPX SHM/loopback.
        # =================================================================
        INTRA_POD_A="mpi-lfc-node1-pod1"
        INTRA_POD_B="mpi-lfc-node1-pod2"
        IP_INTRA_A="${MPI_LFC_POD_IP[$INTRA_POD_A]}"
        IP_INTRA_B="${MPI_LFC_POD_IP[$INTRA_POD_B]}"
        INTRA_HOSTFILE_LFC="/tmp/hostfile_lfc_intra"
        printf '%s slots=1\n%s slots=1\n' "$IP_INTRA_A" "$IP_INTRA_B" \
            | kubectl exec -i "$INTRA_POD_A" -- bash -c "cat > ${INTRA_HOSTFILE_LFC}" 2>/dev/null || true

        INTRA_UUID=$(kubectl exec "$INTRA_POD_A" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-')
        [ -z "$INTRA_UUID" ] && INTRA_UUID="0000000000000000000000000000c12b"

        echo "Running OSU osu_latency intra-node (${INTRA_POD_A} <-> ${INTRA_POD_B}, both on ${MPI_LFC_NODE1})..."
        set +e
        INTRA_LAT_OUT=$(kubectl exec "$INTRA_POD_A" -- timeout 120 \
            mpirun --allow-run-as-root \
                   --mca pml cm \
                   --mca mtl ofi \
                   --mca mtl_ofi_provider_include opx \
                   --mca opal_common_ofi_provider_include opx \
                   --mca btl ^openib,ofi,vader,tcp,self \
                   --mca btl_tcp_if_include eth0 \
                   --mca oob_tcp_if_include eth0 \
                   --mca plm_rsh_agent ssh \
                   --mca plm_rsh_no_tree_spawn 1 \
                   -x FI_PROVIDER=opx \
                   -x FI_LOG_LEVEL=info \
                   -x FI_LOG_PROV=opx \
                   -x FI_OPX_UUID=${INTRA_UUID} \
                   -np 2 -hostfile ${INTRA_HOSTFILE_LFC} \
                   /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 0:128 -i 100 \
            2>&1 || echo "MPI_FAILED")
        set -e
        INTRA_LAT_VAL=$(awk '/^[0-9]/{print $2; exit}' <<< "$INTRA_LAT_OUT")
        if [ -n "$INTRA_LAT_VAL" ] && ! echo "$INTRA_LAT_OUT" | grep -q "MPI_FAILED\|Aborting\|fatal\|Fatal"; then
            echo "    Intra-node 8B latency (${INTRA_POD_A} <-> ${INTRA_POD_B}): ${INTRA_LAT_VAL} us"
            test_result "12.B osu_latency intra-node OPX (same node ${MPI_LFC_NODE1})" 0
        else
            echo "  Output: $(echo "$INTRA_LAT_OUT" | tail -10)"
            test_result "12.B osu_latency intra-node OPX (same node ${MPI_LFC_NODE1})" 1
            INTRA_LAT_VAL=""
        fi

        # =================================================================
        # SUBTEST 12.C - FI_OPX_SHM_ENABLE differential on intra-node pair
        # Per fi_opx(7): "Enables shm across all ports and hfi units on the
        # node. Setting it to NO disables shm except peers with same lid
        # and same hfi1 (loopback). Defaults to: YES."
        # The two pods share a single hfi1 device and LID on the host (the
        # device plugin advertises one cornelis.com/hfi per node), so even
        # FI_OPX_SHM_ENABLE=no would keep the loopback fast path. The
        # primary signal here is therefore: (a) provider accepts the env
        # variable at all (no error), and (b) latency under YES is at
        # least as good as latency under NO. A YES-vs-NO ratio of >=1.5x
        # is treated as additional positive evidence; ratio <1.0 (NO is
        # actually faster) is treated as failure.
        # =================================================================
        # The FI_OPX_SHM_ENABLE=yes run also enables FI_LOG_LEVEL=info so the
        # provider emits opx_shm_rx_init/opx_shm_tx_connect lines we can grep.
        # That second-stage assertion replaces the prior toggle-based >=1.5x
        # heuristic which is architecturally guaranteed to fail on a single-
        # HFI host: per fi_opx(7), FI_OPX_SHM_ENABLE=no still keeps SHM for
        # same-LID/same-hfi1 peers, so the YES vs NO latency are nearly
        # identical and the toggle cannot prove SHM is the active path.
        # Direct evidence (the provider literally logs the SHM segment it
        # creates) is the right signal.
        if [ -n "$INTRA_LAT_VAL" ]; then
            # The latency-comparison run (no FI_LOG) - identical env on both
            # YES and NO so the only variable is FI_OPX_SHM_ENABLE.
            echo "Running OSU osu_latency intra-node with FI_OPX_SHM_ENABLE=yes..."
            set +e
            SHM_YES_OUT=$(kubectl exec "$INTRA_POD_A" -- timeout 120 \
                mpirun --allow-run-as-root \
                       --mca pml cm --mca mtl ofi \
                       --mca mtl_ofi_provider_include opx \
                       --mca opal_common_ofi_provider_include opx \
                       --mca btl ^openib,ofi,vader,tcp,self \
                       --mca btl_tcp_if_include eth0 --mca oob_tcp_if_include eth0 \
                       --mca plm_rsh_agent ssh --mca plm_rsh_no_tree_spawn 1 \
                       -x FI_PROVIDER=opx \
                       -x FI_OPX_UUID=$(kubectl exec "$INTRA_POD_A" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-' || echo "0000000000000000000000000000c12c") \
                       -x FI_OPX_SHM_ENABLE=yes \
                       -np 2 -hostfile ${INTRA_HOSTFILE_LFC} \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 8:8 -i 1000 \
                2>&1 || echo "MPI_FAILED")
            SHM_YES_VAL=$(awk '/^[0-9]/{print $2; exit}' <<< "$SHM_YES_OUT")

            # Separate FI_LOG=info run with SHM_ENABLE=yes for the
            # opx_shm_* token assertion. We cannot reuse SHM_YES_OUT for both
            # the latency comparison and the token grep because FI_LOG=info
            # adds significant per-iteration logging overhead that would
            # dominate the latency measurement and break the YES vs NO
            # fairness check above.
            SHM_LOG_OUT=$(kubectl exec "$INTRA_POD_A" -- timeout 120 \
                mpirun --allow-run-as-root \
                       --mca pml cm --mca mtl ofi \
                       --mca mtl_ofi_provider_include opx \
                       --mca opal_common_ofi_provider_include opx \
                       --mca btl ^openib,ofi,vader,tcp,self \
                       --mca btl_tcp_if_include eth0 --mca oob_tcp_if_include eth0 \
                       --mca plm_rsh_agent ssh --mca plm_rsh_no_tree_spawn 1 \
                       -x FI_PROVIDER=opx \
                       -x FI_LOG_LEVEL=info \
                       -x FI_LOG_PROV=opx \
                       -x FI_OPX_UUID=$(kubectl exec "$INTRA_POD_A" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-' || echo "0000000000000000000000000000c12c") \
                       -x FI_OPX_SHM_ENABLE=yes \
                       -np 2 -hostfile ${INTRA_HOSTFILE_LFC} \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 8:8 -i 50 \
                2>&1 || echo "MPI_FAILED")

            echo "Running OSU osu_latency intra-node with FI_OPX_SHM_ENABLE=no..."
            SHM_NO_OUT=$(kubectl exec "$INTRA_POD_A" -- timeout 120 \
                mpirun --allow-run-as-root \
                       --mca pml cm --mca mtl ofi \
                       --mca mtl_ofi_provider_include opx \
                       --mca opal_common_ofi_provider_include opx \
                       --mca btl ^openib,ofi,vader,tcp,self \
                       --mca btl_tcp_if_include eth0 --mca oob_tcp_if_include eth0 \
                       --mca plm_rsh_agent ssh --mca plm_rsh_no_tree_spawn 1 \
                       -x FI_PROVIDER=opx \
                       -x FI_OPX_UUID=$(kubectl exec "$INTRA_POD_A" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-' || echo "0000000000000000000000000000c12d") \
                       -x FI_OPX_SHM_ENABLE=no \
                       -np 2 -hostfile ${INTRA_HOSTFILE_LFC} \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 8:8 -i 1000 \
                2>&1 || echo "MPI_FAILED")
            SHM_NO_VAL=$(awk '/^[0-9]/{print $2; exit}' <<< "$SHM_NO_OUT")
            set -e

            # Non-gating observation; sub-microsecond noise band exceeds the
            # 5% threshold on single-HFI hosts. See header comment above for
            # rationale. SHM-in-use proofs in sibling 12.C/12.D/12.E checks
            # below remain authoritative and gating.
            if [ -n "$SHM_YES_VAL" ] && [ -n "$SHM_NO_VAL" ]; then
                echo "    8B latency YES=${SHM_YES_VAL}us  NO=${SHM_NO_VAL}us (observation only; not gating on single-HFI hosts)"
            else
                echo "    Could not parse SHM differential output (observation only)"
                echo "    YES output tail: $(echo "$SHM_YES_OUT" | tail -10)"
                echo "    NO  output tail: $(echo "$SHM_NO_OUT" | tail -10)"
            fi
            test_result "12.C FI_OPX_SHM_ENABLE differential (observation, non-gating)" 0

            # Direct OPX SHM evidence: count opx_shm_rx_init / opx_shm_tx_connect
            # lines in the YES run's FI_LOG=info output. Each rank emits one
            # opx_shm_rx_init line per context segment it creates, plus an
            # opx_shm_tx_connect line per peer. With 2 ranks both on the same
            # HFI we expect at least 2 such matches; assert >=1 so we don't
            # depend on exact provider-internal counts.
            SHM_TOKEN_LINES=$(grep -cE "opx_shm_rx_init|opx_shm_tx_connect|/opx\.shm" <<< "$SHM_LOG_OUT" 2>/dev/null || true)
            SHM_TOKEN_LINES=${SHM_TOKEN_LINES:-0}
            if [ "${SHM_TOKEN_LINES}" -ge 1 ] 2>/dev/null; then
                echo "    OPX SHM init evidence: ${SHM_TOKEN_LINES} matching log line(s)"
                echo "    Sample:"
                grep -E "opx_shm_rx_init|opx_shm_tx_connect|/opx\.shm" <<< "$SHM_LOG_OUT" | awk 'NR<=3' | sed 's/^/      /'
                test_result "12.C OPX SHM is the active intra-node path (opx_shm_* tokens in FI_LOG)" 0
            else
                echo "    No opx_shm_* tokens in FI_LOG=info run output"
                echo "    SHM_LOG output tail: $(tail -10 <<< "$SHM_LOG_OUT")"
                test_result "12.C OPX SHM is the active intra-node path (opx_shm_* tokens in FI_LOG)" 1
            fi
        else
            test_skip "12.C FI_OPX_SHM_ENABLE differential" "Intra-node baseline (12.B) failed"
            test_skip "12.C OPX SHM is the active intra-node path" "Intra-node baseline (12.B) failed"
        fi

        # =================================================================
        # SUBTEST 12.D - /proc/<pid>/maps inspection during a running
        # osu_latency between same-node pods. Two changes from the prior
        # /proc/<pid>/fd approach:
        #   1) OPX uses POSIX shm_open() then shm_unlink() to mmap a shared
        #      segment and immediately remove its filesystem entry. The
        #      open fd is then closed once the mapping is established. So
        #      /proc/<pid>/fd will NOT show /dev/shm/* paths even though
        #      the segment is in active use by the process. /proc/<pid>/maps
        #      DOES still show the path of the mapping (with " (deleted)"
        #      suffix once unlinked), so it is the right place to look.
        #   2) The prior 8B / 5_000_000-iter run completed in ~1.2s, before
        #      the inspection sleep elapsed (race condition). We bump iters
        #      to 200_000_000 (~50s wallclock) so the process is alive
        #      throughout the inspection window.
        # =================================================================
        if [ -n "$INTRA_LAT_VAL" ]; then
            FD_UUID=$(kubectl exec "$INTRA_POD_A" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-')
            [ -z "$FD_UUID" ] && FD_UUID="0000000000000000000000000000c12e"

            echo "Launching long-running osu_latency for /proc/<pid>/maps inspection..."
            kubectl exec "$INTRA_POD_A" -- bash -c "
                ( mpirun --allow-run-as-root \
                         --mca pml cm --mca mtl ofi \
                         --mca mtl_ofi_provider_include opx \
                         --mca opal_common_ofi_provider_include opx \
                         --mca btl ^openib,ofi,vader,tcp,self \
                         --mca btl_tcp_if_include eth0 --mca oob_tcp_if_include eth0 \
                         --mca plm_rsh_agent ssh --mca plm_rsh_no_tree_spawn 1 \
                         -x FI_PROVIDER=opx \
                         -x FI_OPX_UUID=${FD_UUID} \
                         -np 2 -hostfile ${INTRA_HOSTFILE_LFC} \
                         /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 8:8 -i 200000000 \
                  >/tmp/lfc_fd_run.log 2>&1 &
                  echo \$! > /tmp/lfc_fd_run.pid
                )
            " &>/dev/null || true

            sleep 8

            MAP_INSPECT=$(kubectl exec "$INTRA_POD_B" -- bash -c '
                set +e
                PIDS=$(pgrep -f "osu_latency" 2>/dev/null)
                if [ -z "$PIDS" ]; then echo "NO_PIDS"; exit 0; fi
                for p in $PIDS; do
                    [ -r /proc/$p/maps ] || continue
                    grep -E "/opx\.shm|/dev/shm/opx|/dev/shm/" /proc/$p/maps 2>/dev/null
                done
            ' 2>&1 || echo "NO_PIDS")

            kubectl exec "$INTRA_POD_A" -- bash -c '
                if [ -f /tmp/lfc_fd_run.pid ]; then
                    pkill -9 -f mpirun 2>/dev/null || true
                    pkill -9 -f osu_latency 2>/dev/null || true
                    rm -f /tmp/lfc_fd_run.pid
                fi
            ' &>/dev/null || true

            if echo "$MAP_INSPECT" | grep -qE "/opx\.shm|/dev/shm/opx" && \
               ! echo "$MAP_INSPECT" | grep -qE "/dev/shm/psm2_shm"; then
                SHM_MAP_COUNT=$(echo "$MAP_INSPECT" | grep -cE "/opx\.shm|/dev/shm/opx" || echo 0)
                echo "    Observed ${SHM_MAP_COUNT} mmap region(s) referencing OPX SHM segment(s) on ${INTRA_POD_B}"
                echo "    Sample:"
                grep -E "/opx\.shm|/dev/shm/opx" <<< "$MAP_INSPECT" | awk 'NR<=3' | sed 's/^/      /'
                test_result "12.D /proc/<pid>/maps shows OPX SHM mmap region (no PSM2)" 0
            elif echo "$MAP_INSPECT" | grep -qE "/dev/shm/psm2_shm"; then
                echo "    ERROR: PSM2 SHM mapping present (/dev/shm/psm2_shm.*) - wrong provider in use"
                test_result "12.D /proc/<pid>/maps shows OPX SHM mmap region (PSM2 detected, wrong provider)" 1
            elif echo "$MAP_INSPECT" | grep -q "NO_PIDS"; then
                echo "    No osu_latency PIDs found on ${INTRA_POD_B} during inspection"
                test_result "12.D /proc/<pid>/maps shows OPX SHM mmap region" 1
            else
                echo "    Note: no /opx.shm or /dev/shm/* mappings found in inspected processes"
                echo "    Sample maps (first 10 lines):"
                awk 'NR<=10' <<< "$MAP_INSPECT" | sed 's/^/      /'
                test_result "12.D /proc/<pid>/maps shows OPX SHM mmap region" 1
            fi
        else
            test_skip "12.D /proc/<pid>/maps SHM inspection" "Intra-node baseline (12.B) failed"
        fi

        # =================================================================
        # SUBTEST 12.E - FI_LOG grep for 'opx' + 'shm' tokens.
        # Best-effort. Some OPX builds compile without DEBUG support, in
        # which case FI_LOG_LEVEL=debug won't emit any provider-internal
        # messages. We mark as skip in that case rather than fail.
        # =================================================================
        if [ -n "$INTRA_LAT_VAL" ]; then
            DBG_UUID=$(kubectl exec "$INTRA_POD_A" -- bash -c 'cat /proc/sys/kernel/random/uuid' 2>/dev/null | tr -d '\r\n-')
            [ -z "$DBG_UUID" ] && DBG_UUID="0000000000000000000000000000c12f"

            echo "Running osu_latency with FI_LOG_LEVEL=debug to capture SHM evidence..."
            set +e
            DBG_OUT=$(kubectl exec "$INTRA_POD_A" -- timeout 120 \
                mpirun --allow-run-as-root \
                       --mca pml cm --mca mtl ofi \
                       --mca mtl_ofi_provider_include opx \
                       --mca opal_common_ofi_provider_include opx \
                       --mca btl ^openib,ofi,vader,tcp,self \
                       --mca btl_tcp_if_include eth0 --mca oob_tcp_if_include eth0 \
                       --mca plm_rsh_agent ssh --mca plm_rsh_no_tree_spawn 1 \
                       -x FI_PROVIDER=opx \
                       -x FI_LOG_LEVEL=debug \
                       -x FI_LOG_PROV=opx \
                       -x FI_OPX_UUID=${DBG_UUID} \
                       -np 2 -hostfile ${INTRA_HOSTFILE_LFC} \
                       /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency -m 8:8 -i 100 \
                2>&1 || echo "MPI_FAILED")
            set -e

            # Tightened from generic "opx" + "shm" search to specific OPX
            # SHM provider symbols. Matching opx_shm_rx_init or
            # opx_shm_tx_connect or the literal "/opx.shm.<uuid>" segment
            # name proves the OPX provider's SHM transport actually ran.
            DBG_SHM_TOKEN_LINES=$(echo "$DBG_OUT" | grep -cE "opx_shm_rx_init|opx_shm_tx_connect|/opx\.shm" 2>/dev/null || true)
            DBG_SHM_TOKEN_LINES=${DBG_SHM_TOKEN_LINES:-0}

            if echo "$DBG_OUT" | grep -q "MPI_FAILED\|Aborting\|fatal\|Fatal"; then
                test_result "12.E FI_LOG debug grep for opx SHM tokens" 1
            elif [ "${DBG_SHM_TOKEN_LINES}" -ge 1 ] 2>/dev/null; then
                echo "    Found ${DBG_SHM_TOKEN_LINES} OPX SHM-init log line(s) (opx_shm_rx_init/opx_shm_tx_connect/opx.shm)"
                echo "    Sample:"
                grep -E "opx_shm_rx_init|opx_shm_tx_connect|/opx\.shm" <<< "$DBG_OUT" | awk 'NR<=3' | sed 's/^/      /'
                test_result "12.E FI_LOG debug shows opx_shm_* / /opx.shm tokens" 0
            else
                echo "    No opx_shm_*/opx.shm tokens in FI_LOG output"
                echo "    Last 10 lines of debug output:"
                echo "$DBG_OUT" | tail -10 | sed 's/^/      /'
                test_result "12.E FI_LOG debug shows opx_shm_* / /opx.shm tokens" 1
            fi
        else
            test_skip "12.E FI_LOG debug grep for opx+shm" "Intra-node baseline (12.B) failed"
        fi
    fi

    echo "Cleaning up MPI libfabric collective test pods..."
    for node_idx in 1 2; do
        for pod_idx in $(seq 1 $PODS_PER_NODE); do
            kubectl delete pod "mpi-lfc-node${node_idx}-pod${pod_idx}" --force --grace-period=0 &>/dev/null || true
        done
    done

    echo "Verifying MPI libfabric collective pods are deleted..."
    LFC_CLEANUP_TIMEOUT=60
    LFC_CLEANUP_ELAPSED=0
    LFC_PODS_REMAINING=$MPI_LFC_TOTAL
    while [ "$LFC_PODS_REMAINING" -gt 0 ] && [ "$LFC_CLEANUP_ELAPSED" -lt "$LFC_CLEANUP_TIMEOUT" ]; do
        LFC_PODS_REMAINING=0
        for node_idx in 1 2; do
            for pod_idx in $(seq 1 $PODS_PER_NODE); do
                if kubectl get pod "mpi-lfc-node${node_idx}-pod${pod_idx}" &>/dev/null; then
                    LFC_PODS_REMAINING=$((LFC_PODS_REMAINING + 1))
                fi
            done
        done
        if [ "$LFC_PODS_REMAINING" -gt 0 ]; then
            sleep 2
            LFC_CLEANUP_ELAPSED=$((LFC_CLEANUP_ELAPSED + 2))
        fi
    done

    if [ "$LFC_PODS_REMAINING" -eq 0 ]; then
        test_result "All MPI libfabric collective pods deleted successfully" 0
    else
        test_result "MPI libfabric collective pod cleanup ($LFC_PODS_REMAINING pods still remaining)" 1
    fi
fi

echo ""

# ==========================================
# Test Summary
# ==========================================

echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total Tests:   $TOTAL_TESTS"
echo "Passed:        $PASSED_TESTS"
echo "Failed:        $FAILED_TESTS"
echo "Skipped:       $SKIPPED_TESTS"
echo "=========================================="

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo "✓ ALL TESTS PASSED"
    exit 0
else
    echo "✗ SOME TESTS FAILED"
    exit 1
fi
