# RDMA CDI Device Plugin Deployment Guide

**Status:** 🚧 Experimental  
**Platforms:** CN5000  
**Workflow:** `deploy_cni=rdma-shared-device`

## Overview

The RDMA CDI Device Plugin workflow exposes Cornelis SuperNIC devices to Kubernetes pods via the Container Device Interface (CDI), enabling native RDMA access for high-performance computing workloads using OPX libfabric provider.

### Key Characteristics

- **No IPoIB required**: Pods access SuperNIC devices directly via `/dev/hfi1_*` character devices
- **Control plane**: Standard Flannel (ethernet) for Kubernetes control traffic
- **Data plane**: Native RDMA verbs and OPX libfabric provider
- **Resource model**: Pods request `cornelis.com/hfi: 1` to get SuperNIC device access
- **Environment injection**: `FI_PROVIDER=opx` automatically set via CDI
- **Shared device**: Up to 64 pods can share each SuperNIC unit (configurable via `rdmaHcaMax`)

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Pod (MPI/HPC Application)                                   │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ eth0 (Flannel)          (RDMA - no secondary net iface)│ │
│ │ 10.244.x.x              /dev/hfi1_0                     │ │
│ │                         /dev/infiniband/uverbs0         │ │
│ │                         FI_PROVIDER=opx                 │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                    │                           │
                    │ (K8s control)             │ (RDMA data)
                    ▼                           ▼
            ┌───────────────┐          ┌──────────────────┐
            │ Flannel       │          │ HFI1 Driver      │
            │ (ethernet)    │          │ (/dev/hfi1_0)    │
            └───────────────┘          └──────────────────┘
                    │                           │
                    ▼                           ▼
            ┌───────────────┐          ┌──────────────────┐
            │ eth0          │          │ InfiniBand       │
            │ (control)     │          │ Fabric           │
            └───────────────┘          └──────────────────┘
```

## Prerequisites

### Hardware

- Cornelis CN5000 SuperNIC adapter installed
- InfiniBand fabric connectivity
- Active IB port (verify with `ibstat`)

### Software

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| Kubernetes | 1.28.0 | For `DevicePluginCDIDevices` feature gate (alpha) |
| containerd | 1.7.0 | For CDI support |
| HFI driver | Latest | `hfi1` (CN5000) |
| RDMA modules | - | `ib_core`, `ib_uverbs`, `rdma_cm`, `rdma_ucm` |
| RDMA tools | - | `rdma-core`, `ibverbs-utils`, `infiniband-diags` (optional, for testing) |

### Node Configuration

1. **SuperNIC character devices must exist:**
   ```bash
   ls -l /dev/hfi1_*
   # CN5000: /dev/hfi1_0
   ```

2. **RDMA subsystem must be initialized:**
   ```bash
   ls -l /dev/infiniband/
   # Should show: rdma_cm, uverbs0, etc.
   ```

3. **RDMA tools installed (optional, for testing):**
   ```bash
   # These are automatically installed by setup-node.sh
   ibv_devinfo  # List RDMA devices
   ibstat       # Show IB port status
   ```

4. **containerd CDI must be enabled** (handled by automation):
   ```toml
   # /etc/containerd/config.toml
   [plugins."io.containerd.grpc.v1.cri"]
     enable_cdi = true
     cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
   ```

5. **kubelet feature gate must be enabled** (handled by automation):
   ```bash
   # /var/lib/kubelet/kubeadm-flags.env
   KUBELET_KUBEADM_ARGS="... --feature-gates=DevicePluginCDIDevices=true"
   ```

## Deployment Steps

### Step 1: Prepare Nodes

Run the node setup playbook to install prerequisites and configure containerd for CDI:

```bash
cd automation
ansible-playbook -i inventory/hosts.yaml playbooks/node-management.yaml \
  -e operation=setup \
  -e deploy_cni=rdma-shared-device
```

This will:
- Install Kubernetes packages (kubelet, kubeadm, kubectl)
- Install SuperNIC (HFI) drivers and RDMA modules
- Configure containerd with CDI support (`enable_cdi = true`)
- Set kubelet feature gate `DevicePluginCDIDevices=true`
- Verify `/dev/hfi1_*` devices exist

### Step 2: Deploy Kubernetes Cluster

Initialize the cluster (control plane on ethernet):

```bash
ansible-playbook -i inventory/hosts.yaml playbooks/cluster-control.yaml \
  -e operation=start
```

### Step 3: Deploy RDMA CDI Device Plugin

Deploy the device plugin and Flannel CNI:

```bash
ansible-playbook -i inventory/hosts.yaml playbooks/cni-deploy.yaml \
  -e deploy_cni=rdma-shared-device
```

This will:
1. Auto-detect platform (CN5000) via `lspci`
2. Deploy vanilla Flannel (ethernet) for control plane
3. Deploy platform-specific ConfigMap (`rdma-cdi-device-config-cn5000.yaml`)
4. Deploy RDMA CDI device plugin DaemonSet
5. Verify `cornelis.com/hfi` resource appears in node allocatable

### Step 4: Verify Deployment

Check that the device plugin is running:

```bash
kubectl get pods -n kube-system -l app=rdma-shared-device-plugin
```

Check that SuperNIC (HFI) resources are advertised:

```bash
kubectl describe node <node-name> | grep cornelis.com/hfi
# Should show:
#   cornelis.com/hfi: 64
```

Check CDI spec files on nodes:

```bash
ls -l /var/run/cdi/
# Should show: cornelis.com-hfi.yaml (or similar)
```

## Pod Configuration

### Basic Pod Spec

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rdma-test
spec:
  containers:
  - name: app
    image: your-mpi-image:latest
    resources:
      limits:
        cornelis.com/hfi: 1  # Request HFI device access
    securityContext:
      capabilities:
        add:
        - IPC_LOCK  # Required for memory pinning
    volumeMounts:
    - name: dev-shm
      mountPath: /dev/shm
  volumes:
  - name: dev-shm
    emptyDir:
      medium: Memory
      sizeLimit: "1Gi"  # Increase from default 64MB
  hostIPC: true  # Required for OPX libfabric provider shared memory
```

### Security Context Requirements

| Requirement | Purpose | Configuration |
|-------------|---------|---------------|
| `CAP_IPC_LOCK` | Memory pinning for DMA | `securityContext.capabilities.add: [IPC_LOCK]` |
| `/dev/shm` expansion | OPX libfabric provider shared memory | `emptyDir` volume with `sizeLimit: 1Gi` |
| `hostIPC: true` | Cross-pod shared memory | `spec.hostIPC: true` |

### Environment Variables

The CDI spec automatically injects:
- `FI_PROVIDER=opx` — Select OPX libfabric provider

> **Note:** The plugin intentionally does **not** inject `FI_OPX_HFI_SELECT`. Setting it node-globally would pin every pod to a single HFI unit, which selects the wrong (or inactive) HFI on multi-HFI nodes. With the variable absent, OPX performs NUMA-aware auto-selection of an ACTIVE HFI. The plugin also defensively strips `FI_OPX_HFI_SELECT` from the global CDI environment if it appears in the ConfigMap.

Additional variables you may want to set:
- `FI_OPX_HFI_SELECT` — SuperNIC (HFI) unit selection (default: auto; only set per-workload if you must override auto-selection)
- `FI_OPX_PORT` — Port selection (default: any)
- `FI_OPX_UUID` — Job UUID for all processes in same job
- `FI_OPX_PKEY` — Partition key
- `FI_OPX_SL` — Service level

### Example MPI Job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: mpi-benchmark
spec:
  parallelism: 4
  completions: 4
  template:
    spec:
      hostIPC: true
      containers:
      - name: mpi-worker
        image: cornelis/openmpi-opx:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          # Wait for all ranks to be ready
          sleep 10
          # Run MPI benchmark
          mpirun --allow-run-as-root -np 4 \
            --mca btl ^tcp,openib \
            --mca mtl ofi \
            --mca mtl_ofi_provider_include opx \
            /opt/osu-micro-benchmarks/mpi/pt2pt/osu_latency
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
```

## Troubleshooting

### Issue: Device Plugin Not Running

**Symptom:** DaemonSet pods in CrashLoopBackOff

**Check:**
```bash
kubectl logs -n kube-system -l app=rdma-shared-device-plugin
```

**Common causes:**
- containerd version < 1.7.0
- CDI not enabled in containerd config
- `/dev/hfi1_*` devices not present on node

### Issue: Resource Not Advertised

**Symptom:** `cornelis.com/hfi` not in node allocatable

**Check:**
```bash
# On the node:
ls -l /dev/hfi1_*
lspci -d 434e:0001
lsmod | grep hfi
```

**Fix:**
- Ensure HFI driver is loaded: `modprobe hfi1`
- Verify PCI device is present
- Check device plugin logs

### Issue: Pod Fails to Start

**Symptom:** Pod stuck in `ContainerCreating`

**Check:**
```bash
kubectl describe pod <pod-name>
# Look for events related to device allocation
```

**Common causes:**
- Feature gate `DevicePluginCDIDevices` not enabled
- containerd CDI not enabled
- CDI spec file missing in `/var/run/cdi/`

### Issue: RDMA Operations Fail

**Symptom:** `ibv_devinfo` or OPX libfabric provider operations fail inside pod

**Check:**
```bash
# Inside pod:
ls -l /dev/hfi1_0 /dev/infiniband/uverbs0
env | grep FI_
ulimit -l  # Should be unlimited or very high
```

**Common causes:**
- Missing `CAP_IPC_LOCK` capability
- `memlock` ulimit too low
- `/dev/shm` too small for OPX libfabric provider

### CDI Spec Inspection

View the generated CDI spec on a node:

```bash
cat /var/run/cdi/cornelis.com-hfi.yaml
```

Expected structure:
```yaml
cdiVersion: "0.6.0"
kind: "cornelis.com/hfi"
devices:
  - name: "hfi0"
    containerEdits:
      deviceNodes:
        - path: "/dev/hfi1_0"
          permissions: "rw"
        - path: "/dev/infiniband/uverbs0"
          permissions: "rw"
        - path: "/dev/infiniband/rdma_cm"
          permissions: "rw"
containerEdits:
  env:
    - "FI_PROVIDER=opx"
```

## Performance Considerations

- **Latency:** Native RDMA verbs provide lowest latency (<1 µs for small messages)
- **Throughput:** Limited by SuperNIC (HFI) hardware (400 Gbps for CN5000)
- **Scalability:** Up to 64 pods per SuperNIC (HFI) unit (configurable via `rdmaHcaMax`)
- **Context sharing:** OPX libfabric provider supports 2-8 endpoints per SuperNIC (HFI) context via `FI_OPX_CONTEXT_SHARING`

## Comparison with IPoIB Workflows

| Aspect | RDMA CDI Device Plugin | Multus + IPoIB |
|--------|------------------------|----------------|
| **Network interface** | None (direct device access) | `ipoib0` (IPoIB interface) |
| **Protocol** | Native RDMA verbs, OPX libfabric provider | IP over InfiniBand |
| **Latency** | Lowest (<1 µs) | Low (~10 µs) |
| **Use case** | HPC, MPI, native RDMA apps | IP-based apps, socket APIs |
| **IPoIB required** | No | Yes |
| **Pod networking** | Flannel (ethernet) only | Dual-interface (Flannel + IPoIB) |

## References

- [Container Device Interface (CDI) Specification](https://github.com/cncf-tags/container-device-interface)
- [Kubernetes Device Plugin API](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- [OPX Libfabric Provider Documentation](https://github.com/cornelisnetworks/libfabric)
- [PSM2 User Guide](https://github.com/cornelisnetworks/opa-psm2)

## Next Steps

- [Operations Guide](../operations/README.md) — Cluster management and troubleshooting
- [Testing Guide](../testing/README.md) — Functional and performance testing
- [Multus + IPoIB Guide](multus-ipoib-cni.md) — Alternative workflow with IP networking
