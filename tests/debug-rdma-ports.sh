#!/bin/bash
# Quick diagnostic to check RDMA port configuration

set -euo pipefail

echo "=========================================="
echo "RDMA Port Diagnostic"
echo "=========================================="

# Create test pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rdma-port-test
spec:
  hostIPC: true
  containers:
  - name: test
    image: ubuntu:22.04
    command: ["sleep", "300"]
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

echo "Waiting for pod..."
kubectl wait --for=condition=Ready pod/rdma-port-test --timeout=60s

echo ""
echo "Installing tools..."
kubectl exec rdma-port-test -- bash -c "apt-get update -qq && apt-get install -y -qq rdma-core ibverbs-utils infiniband-diags" &>/dev/null

echo ""
echo "=========================================="
echo "ibstat output:"
echo "=========================================="
kubectl exec rdma-port-test -- ibstat

echo ""
echo "=========================================="
echo "ibv_devinfo output:"
echo "=========================================="
kubectl exec rdma-port-test -- ibv_devinfo

echo ""
echo "=========================================="
echo "Device files:"
echo "=========================================="
kubectl exec rdma-port-test -- ls -la /dev/hfi1_* /dev/infiniband/

echo ""
echo "Cleanup..."
kubectl delete pod rdma-port-test
