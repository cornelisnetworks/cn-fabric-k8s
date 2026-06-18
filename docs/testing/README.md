# Testing Documentation

This directory contains detailed documentation for the verification scripts in
the repository's `tests/` directory.

## Overview

The CN Fabric Kubernetes integration ships three verification scripts, one per
supported CNI / fabric workflow on the CN5000 reference platform:

- Infrastructure deployment
- Network connectivity (Flannel VXLAN over IPoIB, Multus + IPoIB)
- Native RDMA device access (RDMA shared device plugin)
- InfiniBand fabric integration

## Test Documentation

| Index | Test Script | Documentation | Invocation |
|-------|-------------|---------------|------------|
| 01 | `tests/01-verify-flannel-ipoib.sh` | [01-verify-flannel-ipoib.md](01-verify-flannel-ipoib.md) | Positional `<ipoib_iface>` arg, optional `[--quick\|--full]` |
| 02 | `tests/02-verify-multus-ipoib.sh` | [02-verify-multus-ipoib.md](02-verify-multus-ipoib.md) | Requires `--iface <name>`, optional `[--quick\|--full]` |
| 03 | `tests/03-verify-rdma-shared-device.sh` | [03-verify-rdma-shared-device.md](03-verify-rdma-shared-device.md) | Requires `IFACE` env var (no `--quick`/`--full`) |

## Quick Start

```bash
# From repository root. Discover the live IPoIB interface on a node first:
#   ip link show

# 01 — Flannel VXLAN over IPoIB. <ipoib_iface> is a required positional arg.
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> --quick
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> --full

# 02 — Multus + IPoIB dual-interface. --iface is required (no default).
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --full

# 03 — RDMA shared device plugin. IFACE env var is required; this script
#      does NOT support --quick/--full (it always runs all 12 sections).
IFACE=<ipoib_iface> ./tests/03-verify-rdma-shared-device.sh
```

See [architecture/networking.md](../architecture/networking.md) for the
`<ipoib_iface>` placeholder convention (the kernel-assigned name varies per
cluster, so all three scripts require the operator to supply it).

## Test Counts and Modes

| Script | Modes | Counts |
|--------|-------|--------|
| 01 | `--quick` (default) / `--full` | Dynamic (4 sections: ~9 infrastructure + 3 aggregated connectivity + 6 libfabric); aggregated and node-count dependent |
| 02 | `--quick` (default) / `--full` | 49 tests (quick) / 136 tests (full); 6 sections |
| 03 | none (always full) | 12 sections; scales with `PODS_PER_NODE` (default 4) and node count |

### Test Output

All scripts provide:
- ✓ PASS / ✗ FAIL / ⊘ SKIP indicators for each test
- Detailed output showing what was tested
- A summary with total / passed / failed / skipped counts
- Exit code `0` (success) or `1` (failure)

## Test Categories

### Integration / Functional Tests
- **01-verify-flannel-ipoib.sh** — Flannel VXLAN over IPoIB: infrastructure,
  intra/inter-node connectivity, and libfabric `fi_pingpong` (4 sections,
  dynamic count).
- **02-verify-multus-ipoib.sh** — Multus + IPoIB dual-interface: infrastructure,
  pod interfaces, control-plane and data-plane connectivity, MPI/OSU and
  libfabric performance (6 sections; 49 quick / 136 full). The validation pod
  uses **host-local** IPAM.
- **03-verify-rdma-shared-device.sh** — RDMA shared device plugin: DaemonSet,
  `cornelis.com/hfi` resource advertisement, device access, RDMA bandwidth,
  UCX, OPX, and MPI-over-libfabric (12 sections; `PODS_PER_NODE=4`). The device
  plugin pods carry the label `app=rdma-shared-device-plugin`.

## Test Development

### Creating New Test Cases

When creating new test cases, follow the categories and code patterns
established by the existing scripts in the `tests/` directory.

### Adding New Tests

When creating a new test script:

1. **Choose next index** — use the next available number (e.g. `04`).
2. **Create test script** — `tests/NN-verify-<feature>.sh`.
3. **Make executable** — `chmod +x tests/NN-verify-<feature>.sh`.
4. **Create documentation** — `docs/testing/NN-verify-<feature>.md`.
5. **Update tables** — add an entry to both `tests/README.md` and
   `docs/testing/README.md`.

### Test Script Best Practices

- **Idempotent** — safe to run multiple times.
- **Isolated** — don't interfere with other tests.
- **Clear output** — use ✓ / ✗ / ⊘ symbols for PASS / FAIL / SKIP.
- **Error handling** — handle errors gracefully.
- **Cleanup** — always clean up resources (use `trap` for cleanup).
- **Exit codes** — `0` for success, non-zero for failure.

## Troubleshooting

### General Test Failures

1. **Check cluster status:**
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```

2. **Check test prerequisites:**
   - Review the per-script documentation for requirements.
   - Verify all components for the workflow are deployed.

3. **Run with verbose output:**
   ```bash
   bash -x ./tests/NN-verify-<feature>.sh
   ```

4. **Check logs:**
   ```bash
   kubectl logs -n <namespace> <pod-name>
   ```

### Common Issues

**Issue: kubectl not found**
- Ensure kubectl is installed and in PATH.
- Run tests on the control plane node or with kubectl access.

**Issue: Interface not supplied**
- 01 requires a positional `<ipoib_iface>`; 02 requires `--iface <name>`; 03
  requires the `IFACE` environment variable. Discover the live name with
  `ip link show`.

**Issue: Test pods stuck in Pending**
- Check node resources: `kubectl describe node <node>`.
- Check pod events: `kubectl describe pod <pod-name>`.

## Related Documentation

- [Flannel IPoIB CNI Guide](../deployment/flannel-ipoib-cni.md)
- [Multus + IPoIB CNI Guide](../deployment/multus-ipoib-cni.md)
- [RDMA CDI Device Plugin Guide](../deployment/rdma-cdi-device-plugin.md)
- [Dual-NIC architecture](../architecture/networking.md)
- [Operations / Troubleshooting Guide](../operations/troubleshooting.md)
