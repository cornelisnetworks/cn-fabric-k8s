# Cornelis RDMA Shared Device Plugin

Kubernetes device plugin for exposing Cornelis HFI devices to pods via Container Device Interface (CDI).

## Overview

This is a fork of [Mellanox k8s-rdma-shared-dev-plugin](https://github.com/Mellanox/k8s-rdma-shared-dev-plugin) v1.5.3, modified to support Cornelis Networks HFI adapters with CDI-based device and environment variable injection.

### Fork Rationale

The upstream plugin was designed for Mellanox RDMA devices and only exposes `/dev/infiniband/*` character devices. Cornelis HFI adapters require additional device files (`/dev/hfi1_*`) and environment variables (`FI_PROVIDER=opx`) for native OPX/PSM2 data path access. CDI provides a clean mechanism to inject both device nodes and environment variables without modifying the core Kubernetes device plugin API.

## Key Differences from Upstream

| Feature | Upstream (Mellanox) | Cornelis Fork |
|---------|---------------------|---------------|
| **CDI kind** | `nvidia.com/net-rdma` | `cornelis.com/hfi` |
| **Device nodes** | `/dev/infiniband/*` only | `/dev/infiniband/*` + `/dev/hfi1_*` |
| **Environment variables** | None | `FI_PROVIDER=opx` (node-global). `FI_OPX_HFI_SELECT` is intentionally **not** injected so the OPX provider can auto-select an active HFI per pod — see note below. |
| **PCI vendor** | `15b3` (Mellanox) | `434e` (Cornelis) |
| **Resource prefix** | `rdma` | `cornelis.com` |
| **Platform support** | Mellanox ConnectX | Cornelis CN5000 |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Node                                             │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Device Plugin DaemonSet                              │  │
│  │                                                       │  │
│  │  1. Discover HFI devices via PCI/sysfs               │  │
│  │  2. Generate CDI spec: cornelis.com/hfi              │  │
│  │     - deviceNodes: /dev/hfi1_*, /dev/infiniband/*    │  │
│  │     - env: FI_PROVIDER=opx                           │  │
│  │  3. Write spec to /var/run/cdi/                      │  │
│  │  4. Register resource: cornelis.com/hfi              │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                  │
│                          ▼                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ kubelet                                              │  │
│  │  - Allocate() → returns CDI device name             │  │
│  │  - Passes to containerd via CRI                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                  │
│                          ▼                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ containerd (CDI-enabled)                             │  │
│  │  - Reads /var/run/cdi/cornelis.com-hfi.yaml         │  │
│  │  - Applies containerEdits to OCI spec                │  │
│  │    - Mounts /dev/hfi1_*, /dev/infiniband/*           │  │
│  │    - Injects FI_PROVIDER=opx                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                  │
│                          ▼                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Pod Container                                        │  │
│  │  - /dev/hfi1_0 (native OPX/PSM2 data path)          │  │
│  │  - /dev/infiniband/uverbs0 (verbs path)             │  │
│  │  - FI_PROVIDER=opx (environment)                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Build

### Prerequisites

- Go 1.25+
- Docker or Podman

### Build Binary

```bash
make build
```

This produces `bin/k8s-rdma-shared-dp`.

### Build Container Image

The plugin DaemonSet (`manifests/device-plugins/rdma-cdi-device-plugin.yaml`)
consumes the image `localhost/cn-rdma-shared-dev-plugin:latest` with
`imagePullPolicy: Never`, so the image must be present in the containerd `k8s.io`
namespace on every node that runs the plugin.

Build the image with:

```bash
make image
```

This builds `localhost/cn-rdma-shared-dev-plugin:latest` from `Dockerfile.cornelis`
using your locally-installed Docker (or Podman via `IMAGE_BUILDER=podman make image`).

To distribute it to nodes without a registry, export it to an OCI archive and import
it into containerd on each node:

```bash
# On the build host:
docker save -o cn-rdma.tar localhost/cn-rdma-shared-dev-plugin:latest

# On each node (after copying cn-rdma.tar):
ctr -n k8s.io images import cn-rdma.tar
```

## Configuration

The plugin is configured via a Kubernetes ConfigMap mounted at `/k8s-rdma-shared-dev-plugin/config.json`.

### Example ConfigMap (CN5000)

```json
{
  "periodicUpdateInterval": 300,
  "configList": [
    {
      "resourceName": "hfi",
      "resourcePrefix": "cornelis.com",
      "rdmaHcaMax": 64,
      "selectors": {
        "vendors": ["434e"],
        "deviceIDs": ["0001"],
        "drivers": ["hfi1"]
      }
    }
  ]
}
```

### Selectors

| Field | Description | Example |
|-------|-------------|---------|
| `vendors` | PCI vendor IDs | `["434e"]` (Cornelis) |
| `deviceIDs` | PCI device IDs | `["0001"]` (CN5000) |
| `drivers` | Kernel driver names | `["hfi1"]` |
| `ifNames` | Network interface names | `["hfi1_0"]` |
| `linkTypes` | Link encapsulation types | `["infiniband"]` |

Selectors use OR logic within a field, AND logic between fields.

### Resource Naming

Pods request the resource as:

```yaml
resources:
  limits:
    cornelis.com/hfi: 1
```

## Deployment

### DaemonSet

The plugin runs as a DaemonSet in the `kube-system` namespace. See `manifests/device-plugins/rdma-cdi-device-plugin.yaml` for the full spec.

Key requirements:
- `privileged: true` — Access to `/dev` and PCI devices
- `hostNetwork: true` — Access to host network namespace
- Volume mounts:
  - `/var/lib/kubelet/device-plugins` — Device plugin socket directory
  - `/var/lib/kubelet/plugins_registry` — Plugin registration socket
  - `/var/run/cdi` — CDI spec directory (DirectoryOrCreate)
  - `/dev` — Host device files
  - ConfigMap at `/k8s-rdma-shared-dev-plugin`

### Runtime Requirements

- **containerd >= 1.7.0** with CDI enabled:
  ```toml
  [plugins."io.containerd.grpc.v1.cri"]
    enable_cdi = true
    cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
  ```

- **Kubernetes >= 1.28** with feature gate:
  ```bash
  --feature-gates=DevicePluginCDIDevices=true
  ```

## CDI Spec Generation

The plugin generates CDI specs at `/var/run/cdi/cornelis.com-hfi.yaml` with the following structure:

```yaml
cdiVersion: "0.6.0"
kind: "cornelis.com/hfi"
devices:
  - name: "hfi0"  # PCI address or unit number
    containerEdits:
      deviceNodes:
        - path: "/dev/hfi1_0"
          hostPath: "/dev/hfi1_0"
          permissions: "rw"
        - path: "/dev/infiniband/uverbs0"
          hostPath: "/dev/infiniband/uverbs0"
          permissions: "rw"
        - path: "/dev/infiniband/rdma_cm"
          hostPath: "/dev/infiniband/rdma_cm"
          permissions: "rw"
containerEdits:
  env:
    - "FI_PROVIDER=opx"
```

## Modifications from Upstream

### Code Changes

1. **CDI kind** (`pkg/cdi/cdi.go`, `pkg/resources/server.go`):
   - Changed from `nvidia.com/net-rdma` to `cornelis.com/hfi`

2. **Device node discovery** (`pkg/resources/rdma_device_spec.go`):
   - Added `/dev/hfi1_*` discovery using sysfs `/sys/class/infiniband/hfi1_*/`
   - Extended `PciNetDevice` to track HFI character devices

3. **Environment variable injection** (`pkg/cdi/cdi.go`):
   - Added node-global `containerEdits.env` with `FI_PROVIDER=opx`
   - **`FI_OPX_HFI_SELECT` is intentionally not injected.** Injecting it
     node-globally pinned every OPX pod to a single HFI unit (e.g. `hfi1_0`), which
     selects the wrong/inactive HFI on dual-HFI nodes. With the variable absent, the
     OPX provider performs NUMA-aware auto-selection of an ACTIVE HFI. `CreateCDISpec`
     defensively strips any `FI_OPX_HFI_SELECT` that arrives via config
     (`cdi.FilterGlobalEnv`).

4. **Config schema** (`pkg/types/types.go`):
   - Extended `UserConfig` with `HfiDevices` field for custom env vars

5. **Go module path**:
   - Changed from `github.com/Mellanox/k8s-rdma-shared-dev-plugin` to `github.com/cornelisnetworks/cn-fabric-k8s/plugins/device-plugins/cn-rdma-shared-dev-plugin`

### Compatibility Notes

| Component | Notes |
|-----------|-------|
| **PCI discovery** | `ghw.PCI()` with class `0x02` is used to enumerate Cornelis HFI devices |
| **rdmamap** | `rdmamap.GetRdmaCharDevices()` is used to enumerate RDMA character devices |
| **sysfs layout** | Standard `/sys/class/infiniband/hfi1_*/` structure |
| **CDI spec generation** | Device nodes + environment variables |
| **Multi-port handling** | The HFI unit (not port) is the resource boundary |

## Testing

### Unit Tests

```bash
make test
```

### Integration Test (requires HFI hardware)

1. Deploy the plugin:
   ```bash
   kubectl apply -f manifests/device-plugins/rdma-cdi-device-config-cn5000.yaml
   kubectl apply -f manifests/device-plugins/rdma-cdi-device-plugin.yaml
   ```

2. Verify resource advertisement:
   ```bash
   kubectl describe node <node-name> | grep cornelis.com/hfi
   ```

3. Deploy a test pod:
   ```bash
   kubectl apply -f docs/deployment/rdma-cdi-pod-example.yaml
   ```

4. Verify device access:
   ```bash
   kubectl exec rdma-test-pod -- ls -l /dev/hfi1_0 /dev/infiniband/uverbs0
   kubectl exec rdma-test-pod -- env | grep FI_PROVIDER
   ```

## Troubleshooting

### Plugin Fails to Start

**Check logs:**
```bash
kubectl logs -n kube-system -l app=rdma-shared-device-plugin
```

**Common issues:**
- containerd version < 1.7.0
- CDI not enabled in containerd config
- `/dev/hfi1_*` devices not present

### Resource Not Advertised

**Check device discovery:**
```bash
# On the node:
lspci -d 434e:0001
ls -l /dev/hfi1_*
lsmod | grep hfi
```

### CDI Spec Not Generated

**Check CDI directory:**
```bash
ls -l /var/run/cdi/
cat /var/run/cdi/cornelis.com-hfi.yaml
```

**Verify plugin has write access to `/var/run/cdi`.**

## License

Apache License 2.0 (inherited from upstream Mellanox plugin)

## References

- [Upstream Mellanox Plugin](https://github.com/Mellanox/k8s-rdma-shared-dev-plugin)
- [Container Device Interface Specification](https://github.com/cncf-tags/container-device-interface)
- [Kubernetes Device Plugin API](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- [Cornelis OPX Provider](https://github.com/cornelisnetworks/libfabric)
