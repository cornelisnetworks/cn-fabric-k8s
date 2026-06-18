# Test: 01-verify-flannel-ipoib.sh

**Test Type:** Integration  
**Purpose:** Comprehensive verification script for Flannel VXLAN over IPoIB deployment.  
**Test Coverage:** Infrastructure validation + Advanced connectivity testing

The script runs in 4 sections. Test counts are dynamic — pod-to-pod
connectivity is reported as a small number of aggregated results rather than
one result per pod pair — so the overall total scales with cluster size and
mode rather than being a fixed number.

## What it tests

### [1/4] Infrastructure Validation (~9 tests)
- kubectl availability and cluster access
- Node status (all nodes Ready)
- Flannel namespace and pods (all Running)
- Flannel `--iface` argument configuration
- IPoIB interface status (exists, UP, has IP)
- flannel.1 VXLAN interface binding to IPoIB
- VXLAN port listening (UDP 8472)
- Pod network routes (local via cni0, remote via flannel.1)
- CoreDNS / system pods status

### [2/4] Connectivity Testing (3 aggregated tests)
- Randomly selects 2 nodes from the cluster.
- Creates test pods on each selected node.
- Validates **intra-node** pod-to-pod connectivity (same node).
- Validates **inter-node** pod-to-pod connectivity across nodes via
  VXLAN/IPoIB (bidirectional).
- Results are reported as aggregated pass/fail rather than one result per pod
  pair.
- Automatically cleans up test pods.

### [3/4] libfabric Connectivity (6 tests)
- Creates dedicated libfabric test pods on two nodes.
- Verifies the `fi_info` tool and the `udp` libfabric provider are available.
- Runs `fi_pingpong` over UDP (over VXLAN/IPoIB) in both directions and
  reports measured latency.
- **Requires 2+ nodes**; skipped on single-node clusters.

### [4/4] Test Summary
- Aggregates total / passed / failed / skipped counts and pass rate.

## Usage

The IPoIB interface name is a **required positional argument** — the script no
longer falls back to a hard-coded default because the kernel-assigned name
varies per cluster. An optional `--quick` (default) or `--full` flag selects
the test depth.

```bash
# Usage: ./tests/01-verify-flannel-ipoib.sh <ipoib_iface> [--quick|--full]

# Quick mode (default)
./tests/01-verify-flannel-ipoib.sh <ipoib_iface>

# Quick / full mode explicitly
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> --quick
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> --full
```

Discover the live interface name on a target node with `ip link show`. See
[architecture/networking.md](../architecture/networking.md) for the
placeholder convention.

## Requirements

- Must run with `kubectl` access to the cluster (typically on the control
  plane node)
- Cluster must have at least 2 nodes (for inter-node and libfabric sections)
- Creates temporary test pods (automatically cleaned up)
- **libfabric test image:** the `[3/4]` libfabric section runs `fi_pingpong`
  inside test pods built from the local image
  `localhost/cornelis/rdma-test-tools:latest`. Override with the `LF_IMAGE`
  environment variable, e.g.
  `LF_IMAGE=localhost/cornelis/rdma-test-tools:latest`. The image must be
  present in the node container runtime (`imagePullPolicy: Never`) before the
  libfabric section runs.

## Example Output

```
==========================================
Flannel VXLAN over IPoIB Verification
==========================================
Mode: quick
IPoIB Interface: <ipoib_iface>
==========================================

[1/4] Infrastructure Validation
==========================================
[Nodes:]
NAME         STATUS   ROLES           AGE   VERSION
control-plane   Ready    control-plane   25m   v1.28.15
worker   Ready    <none>          25m   v1.28.15

  ✓ PASS: kubectl available and cluster reachable
  ✓ PASS: All nodes Ready
  ✓ PASS: Flannel pods Running
  ✓ PASS: Flannel --iface=<ipoib_iface> configured
  ✓ PASS: IPoIB interface <ipoib_iface> UP with IP
  ✓ PASS: flannel.1 VXLAN bound to <ipoib_iface>
  ✓ PASS: VXLAN port 8472 listening
  ✓ PASS: Pod routes present (cni0 / flannel.1)
  ✓ PASS: CoreDNS / system pods Running

[2/4] Connectivity Testing
==========================================
  Selected nodes for testing: control-plane, worker
  Creating test pods on each node...
  ✓ PASS: Intra-node connectivity (same node)
  ✓ PASS: Inter-node connectivity control-plane → worker (VXLAN over IPoIB)
  ✓ PASS: Inter-node connectivity worker → control-plane (VXLAN over IPoIB)

[3/4] libfabric Connectivity (fi_pingpong UDP over VXLAN/IPoIB)
==========================================
  ✓ PASS: libfabric pod lf-flannel-node1-pod1 ready
  ✓ PASS: libfabric pod lf-flannel-node2-pod1 ready
  ✓ PASS: fi_info available on both libfabric pods
  ✓ PASS: udp provider available on both pods
    fi_pingpong UDP latency (node1->node2): 12.3 us
  ✓ PASS: fi_pingpong UDP inter-node (node1 -> node2)
    fi_pingpong UDP latency (node2->node1): 12.1 us
  ✓ PASS: fi_pingpong UDP inter-node (node2 -> node1)

[4/4] Test Summary
==========================================
Mode: quick
Interface: <ipoib_iface>
Total Tests: 18
libfabric Tool: fi_pingpong UDP
Passed: 18
Failed: 0
Skipped: 0
Pass Rate: 100%

Result: ✓ ALL TESTS PASSED

Flannel VXLAN over IPoIB deployment is healthy:
  - Infrastructure: Validated
  - Intra-node connectivity: Working
  - Inter-node connectivity: Working (VXLAN over IPoIB)
  - libfabric fi_pingpong UDP: Working (inter-node)
```

> The exact `Total Tests` value is dynamic: connectivity results in `[2/4]`
> are aggregated, and the `[3/4]` libfabric section is skipped on single-node
> clusters. The numbers above are illustrative of a healthy 2-node run.

## Exit Codes

- `0`: All tests passed
- `1`: One or more tests failed

## Troubleshooting

If tests fail, check:

1. **Flannel pods not running:**
   ```bash
   kubectl get pods -n kube-flannel -o wide
   kubectl logs -n kube-flannel <pod-name>
   ```

2. **IPoIB interface issues:**
   ```bash
   ip link show <ipoib_iface>
   ip addr show <ipoib_iface>
   ```

3. **VXLAN interface not bound to IPoIB:**
   ```bash
   ip -d link show flannel.1
   ```

4. **VXLAN port not listening:**
   ```bash
   ss -ulnp | grep 8472
   ```

5. **Pod connectivity issues:**
   ```bash
   kubectl get pods -o wide
   kubectl exec <pod-name> -- ip route
   kubectl exec <pod-name> -- ping <other-pod-ip>
   ```

## Related Documentation

- [Flannel IPoIB CNI Deployment Guide](../deployment/flannel-ipoib-cni.md)
- [Testing Overview](README.md)
