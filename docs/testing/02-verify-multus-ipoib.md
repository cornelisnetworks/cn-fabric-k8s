# Test Case 02: Multus + IPoIB Dual-Interface CNI Verification

## Overview

This test suite validates the Multus + IPoIB dual-interface CNI deployment for Kubernetes. It verifies that all components are properly deployed, pods receive dual interfaces (eth0 + net1), and both control plane and data plane connectivity work as expected.

**Test Script:** `tests/02-verify-multus-ipoib.sh`

**Test Modes:**
- **Quick mode**: 49 tests, ~10 minutes
- **Full mode**: 136 tests, ~30 minutes

---

## Test Categories

The script runs in 6 sections: `[1/6]` Infrastructure Validation, `[2/6]` Pod
Interface Validation, `[3/6]` Control Plane Connectivity (eth0), `[4/6]` Data
Plane Connectivity (net1), `[5/6]` MPI over IPoIB performance, and `[6/6]`
libfabric over IPoIB (`fi_pingpong`). The categories below summarize the
primary validation areas.

### [1/6] Infrastructure Validation (14 tests)

Validates that all CNI components are properly deployed and operational.

**Tests:**
1. Kubernetes cluster accessible
2. Nodes Ready (count validation)
3. Flannel namespace exists
4. Flannel pods running (count validation)
5. Multus pods running (count validation)
6. IPoIB CNI pods running (count validation)
7. Multus binary installed at /opt/cni/bin/multus
8. IPoIB CNI binary installed at /opt/cni/bin/ipoib
9. host-local IPAM binary installed at /opt/cni/bin/host-local
10. NetworkAttachmentDefinition exists (ipoib-network)
11. IPoIB interface exists and is UP
12. Kernel module ib_ipoib loaded
13. CoreDNS pods running (count validation)
14. All nodes Ready

> **IPAM:** the validation pod's IPoIB attachment uses the **host-local** IPAM
> plugin (allocations tracked per-node on disk), not Whereabouts.

**Pass Criteria:**
- All components deployed and running
- All binaries installed
- IPoIB interface operational
- Kernel modules loaded

### [2/6] Pod Interface Validation

Validates that test pods receive dual interfaces with the correct configuration.

**Quick Mode (8 tests):**
- 2 pods per node (4 total)
- Verify pod ready status
- Verify eth0 interface exists
- Verify net1 interface exists

**Full Mode (16 tests):**
- 4 pods per node (8 total)
- All quick mode tests
- Verify eth0 IP from Flannel subnet (10.244.x.x)
- Verify net1 IP from IPoIB subnet (192.168.100.x)

**Pass Criteria:**
- All pods start successfully
- Each pod has eth0 (Flannel) interface
- Each pod has net1 (IPoIB) interface
- IPs assigned from correct subnets

### [3/6] Control Plane Connectivity (via eth0)

Validates connectivity through the Flannel control plane network.

**Quick Mode (12 tests):**
- Ping between pods via eth0
- DNS resolution from pods
- Service access via ClusterIP

**Full Mode (24 tests):**
- All quick mode tests
- DNS resolution from all pods
- Service access from all pods
- External connectivity (8.8.8.8)

**Pass Criteria:**
- Pods can ping each other via eth0
- DNS resolution works
- Services accessible via ClusterIP
- External connectivity functional

### [4/6] Data Plane Connectivity (via net1)

Validates connectivity through the native IPoIB data plane network.

**Quick Mode (16 tests):**
- Ping between pods via net1
- Basic connectivity validation

**Full Mode (64 tests):**
- All quick mode tests
- Bandwidth/latency testing with MPI/OSU micro-benchmarks and libfabric
  (`fi_pingpong`) over the native IPoIB data plane
- All-to-all connectivity matrix (all pod pairs)
- Latency validation

**Pass Criteria:**
- Pods can ping each other via net1
- Bandwidth ≥10 Gbps (full mode)
- All-to-all connectivity works
- Native IPoIB (no encapsulation)

---

## Usage

The `--iface <name>` argument is **required** — the script has no default
IPoIB interface name because the kernel-assigned name varies per cluster.
Discover the live name on a target node with `ip link show`.

### Quick Mode (Recommended for CI/CD)

```bash
tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick
```

**Duration:** ~10 minutes  
**Tests:** 49 tests  
**Use Case:** Quick validation after deployment, CI/CD pipelines

### Full Mode (Comprehensive Testing)

```bash
tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --full
```

**Duration:** ~30 minutes  
**Tests:** 136 tests  
**Use Case:** Thorough validation, performance testing, pre-production

### Custom Subnet

```bash
tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --subnet 192.168.100 --quick
```

**Use Case:** Non-default IPoIB data plane subnet

### Help

```bash
tests/02-verify-multus-ipoib.sh --help
```

---

## Requirements

### Prerequisites

1. **Multus + IPoIB CNI deployed:**
   ```bash
   automation/scripts/deploy-multus-ipoib.sh --ipoib-interface <ipoib_iface>
   ```

2. **kubectl configured:**
   ```bash
   kubectl get nodes
   ```

3. **Cluster operational:**
   - All nodes Ready
   - All CNI components running

### Test Environment

- **Minimum nodes:** 1 (single-node testing)
- **Recommended nodes:** 2+ (inter-node testing)
- **Network:** InfiniBand fabric operational
- **IPoIB interface:** UP and configured

---

## Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| `0` | All tests passed |
| `1` | One or more tests failed |

**Usage in CI/CD:**

```bash
#!/bin/bash
if tests/02-verify-multus-ipoib.sh --quick; then
    echo "Deployment verified successfully"
    exit 0
else
    echo "Deployment verification failed"
    exit 1
fi
```

---

## Troubleshooting

### Test Failures

**Infrastructure validation failures:**

1. **Check component status:**
   ```bash
   kubectl get daemonsets -A
   kubectl get pods -A | grep -E '(flannel|multus|ipoib)'
   ```

2. **Check logs:**
   ```bash
   kubectl logs -n kube-system -l name=multus
   kubectl logs -n kube-system -l name=ipoib-cni
   ```

3. **Verify binaries:**
   ```bash
   ls -l /opt/cni/bin/{multus,ipoib,host-local}
   ```

**Pod interface validation failures:**

1. **Check pod status:**
   ```bash
   kubectl get pods -o wide
   kubectl describe pod <pod-name>
   ```

2. **Check Multus annotations:**
   ```bash
   kubectl get pod <pod-name> -o jsonpath='{.metadata.annotations}'
   ```

3. **Check NetworkAttachmentDefinition:**
   ```bash
   kubectl get network-attachment-definitions.k8s.cni.cncf.io -A
   kubectl describe network-attachment-definitions.k8s.cni.cncf.io ipoib-network -n kube-system
   ```

**Connectivity failures:**

1. **Check routes in pods:**
   ```bash
   kubectl exec <pod-name> -- ip route show
   ```

2. **Check IPoIB interface on host:**
   ```bash
   ip link show <ipoib_iface>
   ip addr show <ipoib_iface>
   ```

3. **Check Flannel routes:**
   ```bash
   ip route show | grep flannel
   ```

### Test Cleanup Issues

**If test cleanup fails:**

```bash
# Manual cleanup
kubectl delete pod test-multus-node1-pod1 test-multus-node1-pod2 \
                   test-multus-node2-pod1 test-multus-node2-pod2 \
                   test-multus-dns --force --grace-period=0

kubectl delete service test-multus-service
```

### Performance Issues

**If bandwidth tests fail in full mode:**

1. **Check IPoIB mode:**
   ```bash
   kubectl get network-attachment-definitions.k8s.cni.cncf.io ipoib-network -n kube-system -o yaml
   ```

2. **Verify native IPoIB (no encapsulation):**
   ```bash
   # In pod
   kubectl exec <pod-name> -- ip -d link show net1
   ```

3. **Check InfiniBand fabric:**
   ```bash
   ibstat
   ibstatus
   ```

---

## Integration with CI/CD

### GitLab CI Example

```yaml
test-multus-ipoib:
  stage: test
  script:
    - tests/02-verify-multus-ipoib.sh --quick
  only:
    - main
  tags:
    - kubernetes
```

### GitHub Actions Example

```yaml
name: Test Multus IPoIB

on:
  push:
    branches: [ main ]

jobs:
  test:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v3
      - name: Run verification tests
        run: tests/02-verify-multus-ipoib.sh --quick
```

### Jenkins Pipeline Example

```groovy
pipeline {
    agent any
    stages {
        stage('Test') {
            steps {
                sh 'tests/02-verify-multus-ipoib.sh --quick'
            }
        }
    }
}
```

---

## Test Coverage

### Quick Mode Coverage

| Category | Coverage |
|----------|----------|
| Infrastructure | 100% |
| Pod Interfaces | Basic |
| Control Plane | Basic |
| Data Plane (incl. MPI/OSU + libfabric) | Basic |
| **Total** | **49 tests** |

### Full Mode Coverage

| Category | Coverage |
|----------|----------|
| Infrastructure | 100% |
| Pod Interfaces | Comprehensive |
| Control Plane | Comprehensive |
| Data Plane (incl. MPI/OSU + libfabric) | Comprehensive |
| **Total** | **136 tests** |

---

## Related Documentation

- [Multus + IPoIB Deployment Guide](../deployment/multus-ipoib-cni.md)
- [Test Case 01: Flannel VXLAN over IPoIB](01-verify-flannel-ipoib.md)
- [Main README](../README.md)
