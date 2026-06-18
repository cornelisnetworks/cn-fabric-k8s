# Deployment Guides

Comprehensive guides for deploying and configuring CN Fabric Kubernetes integration on **Cornelis Networks CN5000** OmniPath fabric.

## Available Deployment Options

Three CNI workflows are supported. All three use the same node preparation and
cluster lifecycle automation; they differ only in how the fabric NIC carries
pod traffic. The CNI is selected at deploy time with `deploy_cni=<workflow-id>`.

### Flannel VXLAN over IPoIB (`flannel-ipoib`)

**Best for:** Standard Kubernetes networking with InfiniBand fabric

- ✅ Simpler deployment
- ✅ Standard Flannel CNI
- ✅ Works with existing Kubernetes tools
- ⚠️ VXLAN encapsulation overhead (~50 bytes/packet)
- ⚠️ Latency ~120 µs

**Guide:** [flannel-ipoib-cni.md](flannel-ipoib-cni.md)

### Multus + IPoIB Dual-Interface (`multus-ipoib`)

**Best for:** Maximum performance with separate control/data planes

- ✅ Native IPoIB data plane (no encapsulation)
- ✅ Dual interface per pod (`eth0` control, `ipoib0` data)
- ✅ Whereabouts cluster-wide IPAM
- ⚠️ More components to operate (Multus, IPoIB CNI, Whereabouts)
- ✅ Latency <10 µs, throughput ~95+ Gbps

**Guide:** [multus-ipoib-cni.md](multus-ipoib-cni.md)

### RDMA CDI Device Plugin (`rdma-shared-device`)

**Best for:** Native RDMA access (OPX/PSM2) for MPI/HPC workloads

- ✅ Direct HFI device access via CDI, no IPoIB networking layer
- ✅ Lowest latency (<1 µs)
- ✅ Vanilla Flannel (ethernet) control plane only
- 🚧 Experimental

**Guide:** [rdma-cdi-device-plugin.md](rdma-cdi-device-plugin.md)

## Deployment Guides

| Guide | Workflow ID | Description | Complexity |
|-------|-------------|-------------|------------|
| [flannel-ipoib-cni.md](flannel-ipoib-cni.md) | `flannel-ipoib` | Flannel VXLAN over IPoIB deployment | ⭐⭐ Medium |
| [multus-ipoib-cni.md](multus-ipoib-cni.md) | `multus-ipoib` | Multus + IPoIB dual-interface deployment | ⭐⭐⭐ Advanced |
| [rdma-cdi-device-plugin.md](rdma-cdi-device-plugin.md) | `rdma-shared-device` | RDMA CDI device plugin for native HFI access | ⭐⭐⭐⭐ Expert |

## Prerequisites

### Common Prerequisites (All Options)

- Kubernetes cluster (default: 1.28.5)
- InfiniBand fabric with Cornelis CN5000 adapters
- IPoIB interface (e.g., `<ipoib_iface>`) UP on all nodes
- Kernel modules: `ib_ipoib`, `rdma_cm`, `rdma_ucm`

> **Note:** Each CNI type has additional prerequisites. See the respective
> deployment guide for details.

## Quick Start

Two playbooks drive every workflow:

- `automation/playbooks/cluster-control.yaml` — cluster lifecycle
  (`operation=start|status|stop`). It can optionally deploy the CNI in the same
  run via `deploy_cni=<workflow-id>`.
- `automation/playbooks/cni-deploy.yaml` — CNI-only deploy onto an existing
  cluster. Supported values: `flannel-ipoib`, `multus-ipoib`,
  `rdma-shared-device`.

### Flannel VXLAN over IPoIB

```bash
cd automation/playbooks

# Option A: deploy CNI onto an existing cluster
ansible-playbook -i ../inventory/hosts.yaml cni-deploy.yaml \
  -e "deploy_cni=flannel-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  --ask-pass

# Option B: start cluster and deploy CNI in one run
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=start" \
  -e "deploy_cni=flannel-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  --ask-pass

# Manual deployment (replace <ipoib_iface> with your IPoIB interface name)
sed 's/{{ ipoib_interface }}/<ipoib_iface>/g' manifests/cni/flannel-ipoib.yaml | kubectl apply -f -

# Verify
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> --quick
```

### Multus + IPoIB (Dual-Interface)

```bash
cd automation/playbooks

ansible-playbook -i ../inventory/hosts.yaml cni-deploy.yaml \
  -e "deploy_cni=multus-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  -e "ipoib_subnet=192.168.100.0/24" \
  --ask-pass

# Verify
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick
```

### RDMA CDI Device Plugin

```bash
cd automation/playbooks

ansible-playbook -i ../inventory/hosts.yaml cni-deploy.yaml \
  -e "deploy_cni=rdma-shared-device" \
  --ask-pass

# Verify (IFACE is read from the environment; no positional default)
IFACE=<ipoib_iface> ./tests/03-verify-rdma-shared-device.sh
```

### Cluster Lifecycle (status / stop)

```bash
cd automation/playbooks

# Status
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=status" --ask-pass

# Graceful stop
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=stop" -e "drain_before_stop=true" --ask-pass
```

## Troubleshooting

For deployment issues, see:

- [Flannel IPoIB Troubleshooting](flannel-ipoib-cni.md#troubleshooting)
- [Multus IPoIB Troubleshooting](multus-ipoib-cni.md#troubleshooting)
- [RDMA CDI Device Plugin Troubleshooting](rdma-cdi-device-plugin.md#troubleshooting)
- [Operations Troubleshooting Guide](../operations/troubleshooting.md)

## Related Documentation

- [Testing Documentation](../testing/) - Verify your deployment
- [Cluster Management](../operations/cluster-management.md) - Manage your cluster
- [Troubleshooting](../operations/troubleshooting.md) - Resolve common issues
