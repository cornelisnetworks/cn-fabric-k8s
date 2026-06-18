# Test: 03-verify-rdma-shared-device.sh

**Test Type:** Integration + Functional
**Purpose:** Validates the `rdma-shared-device` workflow end to end — the
RDMA shared device plugin deployment, SuperNIC (HFI) device access, and native
RDMA / UCX / OPX / MPI data transfer over the Cornelis fabric.
**Test Coverage:** Infrastructure, resource advertisement, pod scheduling,
device access, RDMA operations, scaled multi-pod reachability and bandwidth,
MPI-over-RDMA (UCX), libfabric OPX sanity, MPI-over-libfabric (OFI/OPX), and
MPI collectives over OPX shared memory.

This document describes the real shipped script
`tests/03-verify-rdma-shared-device.sh`. It deploys the upstream
`k8s-rdma-shared-dev-plugin` with a Cornelis configuration (the workflow is
named `rdma-shared-device`; `deploy_cni=rdma-shared-device`). The control plane
uses vanilla Flannel (no IPoIB networking); the fabric is accessed directly via
`/dev/hfi1_*` and `/dev/infiniband/*` exposed through the `cornelis.com/hfi`
resource.

## Invocation

This script reads the IPoIB interface name from the **`IFACE` environment
variable** — there is no positional argument and no hard-coded default, because
the kernel-assigned name varies per platform. The script **does not** support
`--quick` / `--full` flags; it always runs the full 12-section suite.

```bash
# Discover the live IPoIB interface on a worker node first:
ssh <node> ip link show

# Run the verification (IFACE is required):
IFACE=<ipoib_iface> ./tests/03-verify-rdma-shared-device.sh
```

If `IFACE` is unset the script exits with an error and usage hint. See
[architecture/networking.md](../architecture/networking.md) for the
placeholder convention and the operator-supply contract.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IFACE` | _(required)_ | IPoIB interface name on the target cluster (e.g. `<ipoib_iface>`). No default. |
| `PODS_PER_NODE` | `4` | Number of test pods created per node for the scale, reachability, bandwidth and MPI sections. |
| `MPI_IMAGE` | `localhost/cornelis/rdma-test-tools:latest` | Image used for MPI/UCX test pods. |
| `LF_IMAGE` | `localhost/cornelis/rdma-test-tools:latest` | Image used for libfabric/OPX test pods. |

All test pods use `imagePullPolicy: Never`, so the test image must already be
present in the node container runtime.

## What It Tests

The script runs 12 sections (`[1/12]` … `[12/12]`). Sections that require
two or more nodes are automatically skipped on single-node clusters.

### [1/12] Infrastructure Validation
- Kubernetes cluster accessibility and node readiness
- `rdma-shared-device-plugin` DaemonSet exists in `kube-system`
- Device plugin pods Running (label `app=rdma-shared-device-plugin`)
- Device plugin restart count acceptable
- Flannel control plane pods Running

### [2/12] Resource Advertisement
- `cornelis.com/hfi` resource advertised on nodes
- Node resource capacity > 0
- HFI resources available for allocation

### [3/12] Pod Scheduling
- Pod requesting `cornelis.com/hfi: 1` is scheduled to a node
- Pod reaches Running / Ready state

### [4/12] Device Access
- `/dev/infiniband/uverbs0` present in the pod
- `/dev/infiniband/rdma_cm` present in the pod
- `/dev/shm` volume mounted

### [5/12] RDMA Operations
- `ibv_devinfo` succeeds in the pod
- RDMA port is in `PORT_ACTIVE` state
- `ibstat` succeeds; active port detected
- Link layer is InfiniBand

### [6/12] Scale Pod Deployment (`PODS_PER_NODE` pods per node)
- Creates `PODS_PER_NODE` pods on each of two nodes (default 4 → 8 total)
- All pods scheduled and Running
- Per-node pod count matches `PODS_PER_NODE`
- RDMA tools available on every pod
- _Requires 2+ nodes._

### [7/12] RDMA Reachability (Intra-Node + Inter-Node)
- Minimal `ib_write_bw` transfer between all intra-node pod pairs on each node
- Minimal transfer across all inter-node pod pairs
- _Requires 2+ nodes._

### [8/12] RDMA Bandwidth (Intra-Node + Inter-Node)
- `ib_write_bw` bandwidth between same-node pod pairs (2 tests)
- `ib_write_bw` bandwidth across nodes, both directions (2 tests)
- _Requires 2+ nodes._

### [9/12] MPI over RDMA with UCX (Split Control/Data Plane)
- Creates 4 MPI test pods per node (8 total)
- Verifies UCX and Open MPI present (skipped if absent from the image)
- Verifies UCX `rc_verbs` transport available for `hfi1_0`
- Runs `ucx_perftest` (TCP baseline + RDMA), asserting the RDMA data path uses
  `rc_verbs/hfi1_0` and does not fall back to TCP
- _Requires 2+ nodes._

### [10/12] libfabric OPX Provider Sanity Check
- Creates OPX sanity pods on two nodes (normal pod networking)
- `fi_info -p opx` reports `provider: opx` on both pods
- `/dev/hfi1_*` present and the `IFACE` IPoIB IP resolvable per pod (with a
  node-level fallback)
- _Requires 2+ nodes._

### [11/12] MPI over libfabric (OFI/OPX)
- Creates `PODS_PER_NODE` MPI pods per node using normal pod networking
- Verifies node assignment, `cornelis.com/hfi` grant, OPX device prerequisites,
  and `fi_info -p opx`
- Sets up per-pod sshd (no-PAM) and performs pairwise SSH preflight
- Runs OSU pt2pt micro-benchmarks (`osu_latency`, `osu_bw`) per pod pair via
  Open MPI → CM PML → OFI MTL → OPX provider, with a per-pair `FI_OPX_UUID`
- _Requires 2+ nodes._

### [12/12] MPI Collectives over OPX with Shared Memory Verification
- `osu_allreduce` collective across all pods spanning both nodes
- Intra-node `osu_latency` exercising the OPX intra-host fast path
- `FI_OPX_SHM_ENABLE=yes` vs `=no` differential on the same intra-node pair
- Inspects `/proc/<pid>/fd` during a running benchmark for `/dev/shm/*` usage
- Best-effort OPX/`shm` token check in `FI_LOG_LEVEL=debug` output
- _Requires 2+ nodes._

## Requirements

### Cluster Prerequisites
- Kubernetes cluster deployed and accessible via `kubectl`
- RDMA shared device plugin deployed (`deploy_cni=rdma-shared-device`)
- Flannel control plane CNI running
- At least 2 Ready nodes for the scale, reachability, bandwidth, UCX, OPX and
  MPI sections (single-node runs skip those sections)

### Node Prerequisites
- Cornelis SuperNIC (HFI) hardware (CN5000)
- HFI kernel driver loaded (`hfi1`)
- RDMA kernel modules loaded (`ib_core`, `ib_uverbs`, `rdma_cm`)
- Device files present (`/dev/hfi1_*`, `/dev/infiniband/*`)
- An active IPoIB interface (supplied via `IFACE`)

### Test Image Requirements
- `localhost/cornelis/rdma-test-tools:latest` loaded into the node runtime
  (`imagePullPolicy: Never`), containing `ibverbs`/`perftest`, UCX + Open MPI,
  libfabric with the OPX provider, and the OSU micro-benchmarks. Sections whose
  tools are missing from the image are skipped rather than failed.

## Example Output

```
==========================================
RDMA Shared Device Plugin Verification
==========================================
Pods per node: 4

  ✓ PASS: Kubernetes cluster accessible
  ✓ PASS: Nodes Ready (2 nodes)

[1/12] Infrastructure Validation
==========================================
  ✓ PASS: RDMA device plugin DaemonSet exists
  ✓ PASS: Device plugin pods running (2 pods)
  ✓ PASS: Device plugin restart count acceptable (0)
  ✓ PASS: Flannel pods running (2 pods)

[2/12] Resource Advertisement
==========================================
  ✓ PASS: cornelis.com/hfi resource advertised (2 nodes)
  ✓ PASS: Resource capacity (4)
  ✓ PASS: HFI resources available (4)

[3/12] Pod Scheduling
==========================================
  ✓ PASS: Pod scheduled to node (worker)
  ✓ PASS: Pod reached Running state

[4/12] Device Access
==========================================
  ✓ PASS: /dev/infiniband/uverbs0 exists
  ✓ PASS: /dev/infiniband/rdma_cm exists
  ✓ PASS: /dev/shm volume mounted

[5/12] RDMA Operations
==========================================
  ✓ PASS: ibv_devinfo command succeeded
  ✓ PASS: RDMA port is in ACTIVE state
  ✓ PASS: ibstat command succeeded
  ✓ PASS: Link layer is InfiniBand

[6/12] Scale Pod Deployment (4 pods per node)
... (sections [6/12]–[12/12] run when 2+ nodes are present) ...

==========================================
Test Summary
==========================================
✓ ALL TESTS PASSED
```

## Exit Codes

- `0`: All tests passed
- `1`: One or more tests failed
- `2`: `IFACE` environment variable not supplied

## Troubleshooting

### Issue: Device plugin pods not running

**Diagnosis:**
```bash
kubectl get pods -n kube-system -l app=rdma-shared-device-plugin
kubectl logs -n kube-system -l app=rdma-shared-device-plugin
```

**Common causes:**
- HFI device files missing (`/dev/hfi1_*`)
- Device plugin ConfigMap selectors do not match the hardware

### Issue: Resource not advertised

**Diagnosis:**
```bash
kubectl describe node <node> | grep cornelis.com/hfi
kubectl logs -n kube-system -l app=rdma-shared-device-plugin
lspci -d 434e:0001   # CN5000 HFI (vendor 434e, device 0001)
lsmod | grep hfi1
ls -la /dev/hfi1_*
```

**Common causes:**
- SuperNIC (HFI) hardware not detected (wrong PCI vendor/device ID — the
  runtime selector is vendor `434e`, device `0001`, driver `hfi1`)
- HFI driver not loaded
- Device plugin ConfigMap has wrong selectors

### Issue: Pod stuck in ContainerCreating / not Running

**Diagnosis:**
```bash
kubectl describe pod rdma-test-pod
kubectl get events --sort-by='.lastTimestamp'
```

### Issue: RDMA / UCX / OPX sections fail or skip

**Diagnosis:**
```bash
kubectl exec rdma-test-pod -- ibv_devinfo
kubectl exec rdma-test-pod -- ucx_info -d
kubectl exec rdma-test-pod -- bash -c 'FI_PROVIDER=opx fi_info -p opx -v'
```

**Common causes:**
- UCX / Open MPI / OSU benchmarks / OPX provider not present in the test image
  (the affected sections are skipped, not failed)
- Fabric not connected between nodes (inter-node bandwidth)
- IPoIB interface name supplied in `IFACE` does not match the live interface

## Related Documentation

- [RDMA CDI Device Plugin Deployment Guide](../deployment/rdma-cdi-device-plugin.md)
- [Dual-NIC architecture / placeholder convention](../architecture/networking.md)
- [Troubleshooting Guide](../operations/troubleshooting.md)
- [Testing Overview](README.md)
