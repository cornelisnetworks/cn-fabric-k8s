# Cornelis Fork of k8s-rdma-shared-dev-plugin

This is a fork of [Mellanox k8s-rdma-shared-dev-plugin](https://github.com/Mellanox/k8s-rdma-shared-dev-plugin) v1.5.3 with Cornelis-specific enhancements for HFI support.

## Fork Rationale

The upstream plugin exposes RDMA devices via standard `/dev/infiniband/*` paths, which works for verbs-based applications. However, Cornelis HFI devices require additional device files and environment variables for native OPX/PSM2 performance:

- **HFI character devices**: `/dev/hfi1_0`, `/dev/hfi1_1`, etc. (not exposed by upstream)
- **OPX environment variable**: `FI_PROVIDER=opx` injected node-globally (not injected by
  upstream). Note: `FI_OPX_HFI_SELECT` is intentionally **not** injected — see note below.
- **CDI vendor**: Changed from `nvidia.com/net-rdma` to `cornelis.com/hfi`

## Key Modifications

### 1. Module Path
- **Upstream**: `github.com/Mellanox/k8s-rdma-shared-dev-plugin`
- **Fork**: `github.com/cornelisnetworks/cn-fabric-k8s/plugins/device-plugins/cn-rdma-shared-dev-plugin`

### 2. PCI Class Filter (Verified Compatible)
- **Location**: `pkg/resources/resources_manager.go:316`
- **Filter**: `devClass != netClass` where `netClass = 0x02` (Network controller)
- **Status**: ✅ Compatible with Cornelis HFI (PCI class 0x02)
- **Tested**: CN5000 (vendor `1fc1`, device `14e4`, driver `hfi1`)

### 3. RDMA Device Discovery
- **Location**: `pkg/resources/rdma_device_spec.go`
- **Upstream**: Uses `rdmamap.GetRdmaCharDevices()` to discover `/dev/infiniband/*`
- **Fallback**: Sysfs-based discovery for the Cornelis vendor

### 4. HFI Device File Discovery
- **Location**: `pkg/resources/rdma_device_spec.go`
- **Logic**: Discovers `/dev/hfi1_<unit>` using sysfs `/sys/class/infiniband/hfi1_<unit>/`
- **Naming**: `/dev/hfi1_0` for unit 0, `/dev/hfi1_1` for unit 1, etc.

### 5. CDI Spec Generation
- **Location**: `pkg/cdi/cdi.go`, `pkg/resources/server.go`
- **Changes**:
  - CDI kind: `nvidia.com/net-rdma` → `cornelis.com/hfi`
  - Device nodes: Add `/dev/hfi1_*` alongside `/dev/infiniband/*`
  - Environment variables: Add node-global `FI_PROVIDER=opx`

> **`FI_OPX_HFI_SELECT` is intentionally not injected.** Injecting it via the
> node-global CDI container edits would pin every OPX pod on the node to one HFI unit
> (e.g. `hfi1_0`), which selects the wrong/inactive HFI on multi-HFI nodes. The plugin
> injects only `FI_PROVIDER=opx` and defensively strips any `FI_OPX_HFI_SELECT` from the
> configured env (`cdi.FilterGlobalEnv`); the OPX provider then auto-selects an ACTIVE,
> NUMA-local HFI per pod.

### 6. Configuration Extensions
- **Target**: `pkg/types/types.go`
- **New fields**: `HfiDevices` with `DevicePattern` and `EnvVars` in `UserConfig`

## License

This fork preserves the original Apache 2.0 license from Mellanox/NVIDIA. See LICENSE file.

## Upstream Compatibility

This fork tracks upstream v1.5.3 (commit `948098b7540b739463dc03e9010c0ff36c2afd78`). Periodic rebases may be performed to incorporate upstream bug fixes and features.
