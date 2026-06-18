# Tests

Test scripts for CN Fabric Kubernetes integration.

## Test Cases

| Index | Test Script | Description | Documentation |
|-------|-------------|-------------|---------------|
| 01 | `01-verify-flannel-ipoib.sh` | Flannel VXLAN over IPoIB verification (infrastructure + intra-node + inter-node connectivity + libfabric) | [docs/testing/01-verify-flannel-ipoib.md](../docs/testing/01-verify-flannel-ipoib.md) |
| 02 | `02-verify-multus-ipoib.sh` | Multus + IPoIB dual-interface verification (49 quick / 136 full tests: infrastructure + interfaces + control plane + data plane) | [docs/testing/02-verify-multus-ipoib.md](../docs/testing/02-verify-multus-ipoib.md) |
| 03 | `03-verify-rdma-shared-device.sh` | RDMA shared device plugin verification (12 sections: DaemonSet + resources + device access + RDMA/UCX/OPX/MPI) | [docs/testing/03-verify-rdma-shared-device.md](../docs/testing/03-verify-rdma-shared-device.md) |

## Quick Start

```bash
# Run Flannel IPoIB tests (positional IPoIB interface; quick mode is default)
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> --quick

# Run Flannel IPoIB tests (full mode)
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> --full

# Run Multus + IPoIB tests (interface passed via --iface; quick mode)
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick

# Run Multus + IPoIB tests (full mode)
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --full

# Run RDMA shared device plugin tests (interface passed via the IFACE env var)
IFACE=<ipoib_iface> ./tests/03-verify-rdma-shared-device.sh
```

## Test Modes

Tests 01 and 02 support two modes:

### Quick Mode (Default)
- **Purpose**: Fast validation for development/CI
- **Coverage**: Essential tests only
- **Usage**: `./tests/0N-verify-*.sh ... --quick` (or omit the flag)

### Full Mode
- **Purpose**: Comprehensive validation for releases
- **Coverage**: All test categories
- **Usage**: `./tests/0N-verify-*.sh ... --full`

> Note: `03-verify-rdma-shared-device.sh` does not use `--quick`/`--full`; it runs a fixed set of 12 sections and takes its interface from the `IFACE` environment variable.

## Test Categories

Test scripts may include any combination of:
1. Infrastructure validation
2. Basic connectivity
3. Performance & Scalability
4. Reliability & Failover
5. Isolation & Security
6. Lifecycle Management
7. HPC-Specific

See [docs/testing/README.md](../docs/testing/README.md) for details on each category.

## Directory Structure

```
tests/
├── README.md                          # This file - test case index
├── 01-verify-flannel-ipoib.sh         # Flannel IPoIB CNI verification script
├── 02-verify-multus-ipoib.sh          # Multus + IPoIB dual-interface verification script
├── 03-verify-rdma-shared-device.sh    # RDMA shared device plugin verification script
├── images/                            # Test container image (rdma-test-tools)
│   └── ...
└── ansible/                           # Ansible playbook tests
    └── ...
```

## Documentation

For detailed test documentation including:
- What each test validates
- Usage examples
- Requirements
- Example output
- Troubleshooting

See **[docs/testing/](../docs/testing/)** directory.

## Test Development

When adding new test scripts:

1. Use indexed naming: `NN-verify-<feature>.sh`
2. Make executable: `chmod +x tests/NN-verify-<feature>.sh`
3. Create documentation: `docs/testing/NN-verify-<feature>.md`
4. Update this table with the new entry
5. Update `docs/testing/README.md` table

See [docs/testing/README.md](../docs/testing/README.md) for test development guidelines.
