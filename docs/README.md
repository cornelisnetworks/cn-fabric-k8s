# CN Fabric Kubernetes Integration - Documentation

Complete guide for deploying and managing Kubernetes with Cornelis Networks InfiniBand fabric integration.

## Architecture Overview

We deploy a Kubernetes cluster with a **dual-NIC design** — `eth0` for the Kubernetes control plane (API server, kubelet, DNS) and a high-performance fabric NIC (`<ipoib_iface>`, e.g. `ib0` on the CN5000 reference cluster) for the data plane. The stand-alone architecture reference lives at [`architecture/networking.md`](architecture/networking.md).

Deployment is automated via Ansible playbooks following the **canonical 6-step operational workflow** below: prepare nodes (including CNI binary installation) → deploy cluster → deploy CNI configuration → verify → status → stop. The CNI choice at Step 3 determines how the fabric NIC carries pod traffic.

## Supported CNI Configurations

| Platform | CNI Type | Fabric | Overlay | Throughput | Documentation | Status |
|----------|----------|--------|---------|------------|---------------|--------|
| CN5000 | Flannel VXLAN over IPoIB | InfiniBand | VXLAN | ~90 Gbps | [flannel-ipoib-cni.md](deployment/flannel-ipoib-cni.md) | ✅ Active |
| CN5000 | Multus + IPoIB (dual-interface) | InfiniBand | None | ~95+ Gbps | [multus-ipoib-cni.md](deployment/multus-ipoib-cni.md) | ✅ Active |
| CN5000 | RDMA CDI Device Plugin | InfiniBand | Flannel (ethernet) | N/A (native RDMA) | [rdma-cdi-device-plugin.md](deployment/rdma-cdi-device-plugin.md) | 🚧 Experimental |

## Common Prerequisites

1. SSH access to all nodes from the Ansible control host
2. Kubernetes packages installed (kubelet, kubeadm, kubectl)
3. Kernel modules: `vxlan`, `overlay`, `br_netfilter`
4. Sysctl: `ip_forward=1`, `bridge-nf-call-iptables=1`

> **Note:** Each CNI type has additional prerequisites. See the respective deployment guide for details.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Supported CNI Configurations](#supported-cni-configurations)
- [Common Prerequisites](#common-prerequisites)
- [Container Image Management](#container-image-management)
  - [Cleaning Container Images from All Nodes](#cleaning-container-images-from-all-nodes)
  - [Building and Distributing the RDMA Test Tools Image](#building-and-distributing-the-rdma-test-tools-image)
- [Quick Start Workflow](#quick-start-workflow)
  - [Step 1: Prepare Nodes](#step-1-prepare-nodes)
  - [Step 2: Deploy Kubernetes Cluster](#step-2-deploy-kubernetes-cluster)
  - [Step 3: Deploy CNI](#step-3-deploy-cni)
  - [Step 4: Verify Deployment](#step-4-verify-deployment)
- [Detailed Guides](#detailed-guides)
  - [Deployment Guides](#deployment-guides)
  - [Operations Guides](#operations-guides)
  - [Testing Documentation](#testing-documentation)
- [Additional Resources](#additional-resources)

---

## Container Image Management

### Cleaning Container Images from All Nodes

**Objective:** Remove test and CNI container images from all cluster nodes using the Ansible playbook.

**Playbook:** `automation/playbooks/clean-images.yaml`  
**Targets:** All nodes in the `k8s_nodes` group (control plane + workers)

```bash
cd automation/playbooks

# Remove test and CNI images (default: excludes system images such as pause)
ansible-playbook -i ../inventory/hosts.yaml clean-images.yaml --ask-pass

# Remove ALL known images including system images (pause, etc.)
ansible-playbook -i ../inventory/hosts.yaml clean-images.yaml -e "clean_all=true" --ask-pass
```

**What gets removed:**

| Category | Images | Removed by default |
|----------|--------|--------------------|
| CNI images | `multus`, `flannel`, `whereabouts` | ✅ Yes |
| Test images | `cornelis/rdma-test-tools:latest`, `alpine`, `ubuntu`, `busybox` | ✅ Yes |
| Device plugin | `cn-rdma-shared-dev-plugin:latest` | ✅ Yes |
| System images | `registry.k8s.io/pause:3.9` | ❌ Only with `-e clean_all=true` |

> **Note:** Images currently in use by running pods cannot be removed. The playbook reports these as "failed to remove" — this is expected and not an error. Logs are written to `/var/log/clean-images-<hostname>.log` on each node.

**Verify cleanup:**
```bash
ansible -i ../inventory/hosts.yaml k8s_nodes -m shell -a 'crictl images' --ask-pass
```

---

### Building and Distributing the RDMA Test Tools Image

**Objective:** Build the `cornelis/rdma-test-tools` container image from source on a cluster node and distribute it to all nodes.

**Script:** `tests/images/rdma-test-tools/build-on-node.sh`

The image is built directly on the designated build node (default: `control-plane`) using `buildah`, then exported as an OCI archive and imported into the `k8s.io` containerd namespace on every node. This avoids the need for a container registry.

> **Build time:** ~30–45 minutes (source-builds libfabric OPX v2.0.0 and Open MPI v4.1.6 from GitHub, then compiles OSU Micro-Benchmarks). Requires outbound internet access from the build node to GitHub and the OSU mirror.

**Run from the repository root:**
```bash
# Default: uses automation/inventory/hosts.yaml, builds on 'control-plane' node
cd tests/images/rdma-test-tools
bash build-on-node.sh --ask-pass

# With password supplied non-interactively
ANSIBLE_PASS=<password> bash build-on-node.sh

# Override inventory or build node
INVENTORY=/path/to/hosts.yaml BUILD_NODE=control-plane ANSIBLE_PASS=<password> bash build-on-node.sh
```

**Build arguments (override defaults via environment or `--build-arg`):**

| Argument | Default | Description |
|----------|---------|-------------|
| `LIBFABRIC_VERSION` | `2.0.0` | libfabric git tag (prefix `v` added automatically) |
| `OPENMPI_VERSION` | `4.1.6` | Open MPI git tag (prefix `v` added automatically) |
| `OSU_VERSION` | `7.3` | OSU Micro-Benchmarks tarball version |

**What the script does:**
1. Tars the build context (`Dockerfile`, `build.sh`, `README.md`) and copies it to the build node
2. Runs `buildah bud` on the build node to produce `localhost/cornelis/rdma-test-tools:latest`
3. Exports the image as an OCI archive (`/tmp/rdma-test-tools-image.tar`)
4. Fetches the archive to the Ansible control host
5. Copies and imports the archive into `ctr -n k8s.io` on every node in `k8s_nodes`

**Verify the image is present on all nodes:**
```bash
ansible -i ../inventory/hosts.yaml k8s_nodes \
  -m shell -a 'crictl images | grep rdma-test' --ask-pass
```

**Self-check:** The image runs a build-time self-check that validates:
- `fi_info -l` lists the `opx` provider
- `ompi_info` shows the OFI MTL (`MCA mtl: ofi`)
- `ucx_info` and `ucx_perftest` are available
- OSU Micro-Benchmarks binary (`osu_bw`) is installed

If the self-check fails, the image build fails and no broken image is distributed.

---

## Quick Start Workflow

> **Before you begin:** Update `automation/inventory/hosts.yaml` with your node hostnames or IP addresses, SSH username, and any other environment-specific settings before running any of the Ansible playbooks below. The inventory file ships with placeholder values (`control-plane`, `worker`) that must be replaced with your actual node details.

### Step 1: Prepare Nodes

**Objective:** Ensure all nodes meet prerequisites for Kubernetes and InfiniBand integration, and install all CNI binaries.

**Required Parameters:**
- Node hostnames/IPs
- SSH access credentials
- IPoIB interface name (default: `<ipoib_iface>`)
- Ansible inventory file (e.g., `automation/inventory/hosts.yaml`)
  - Configure `ansible_user` in inventory file for SSH username
  - Or use `-u <username>` flag to override

**Automated (Ansible):**
```bash
cd automation/playbooks

# Note: -i specifies inventory file, --ask-pass prompts for SSH password
# Adjust inventory path if needed (default: ../inventory/hosts.yaml)

# 1. Cleanup: Remove existing Kubernetes components (if needed)
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml -e "operation=clean" --ask-pass

# 2. Setup: Install prerequisites, configure nodes, and install CNI binaries
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml -e "operation=setup" --ask-pass

# 3. Precheck: Validate node prerequisites
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml -e "operation=check" --ask-pass
```

**Manual Verification:**
```bash
# Run precheck script on each node
./automation/scripts/node-precheck.sh --iface <ipoib_iface>

# Check IPoIB interface
ip link show <ipoib_iface>

# Check kernel modules
lsmod | grep ib_ipoib

# Check Kubernetes tools
kubectl version --client
kubeadm version

# Verify CNI binaries are installed
ls -lh /opt/cni/bin/{ipoib,multus,flannel,host-local}
```

**Tasks Performed:**
1. Verify InfiniBand adapters installed
2. Load kernel modules: `ib_ipoib`, `rdma_cm`, `rdma_ucm`
3. Verify IPoIB interface is UP
4. Install required tools: `kubectl`, `kubeadm`, `kubelet`
5. Configure Kubernetes repositories
6. **Install Go toolchain (for building cn-ipoib-cni)**
7. **Build and install cn-ipoib-cni binary to /opt/cni/bin/ipoib**
8. **Download and install Multus CNI binary to /opt/cni/bin/multus**
9. **Download and install Flannel CNI binaries to /opt/cni/bin/**
10. **Install buildah (container build toolchain)**
11. **Build cn-rdma-shared-dev-plugin container image from `Dockerfile.cornelis` and import it into containerd's `k8s.io` namespace as `localhost/cn-rdma-shared-dev-plugin:latest` (consumed by the `rdma-shared-device` workflow with `imagePullPolicy: Never`)**
12. **Verify all CNI binaries are installed and executable, and the container image is loaded**

**Detailed Guides:**
- [operations/ansible-guide.md](operations/ansible-guide.md) - Ansible automation
- [operations/troubleshooting.md](operations/troubleshooting.md#prerequisites) - Node prerequisites troubleshooting

---

### Step 2: Deploy Kubernetes Cluster

**Objective:** Deploy Kubernetes control plane and worker nodes WITHOUT CNI.

**Required Parameters:**
- `pod_network_cidr` (default: `10.244.0.0/16`)
- `service_cidr` (default: `10.96.0.0/12`)
- `skip_worker_taint` (default: `false`)

**Deployment:**

**Option A: Automated (Ansible)**
```bash
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=start" \
  -e "deploy_cni=none" \
  -e "pod_network_cidr=10.244.0.0/16" \
  -e "service_cidr=10.96.0.0/12" \
  --ask-pass
```

**Option B: Manual**
```bash
# On control plane node
./automation/scripts/start-control-plane.sh 10.244.0.0/16 10.96.0.0/12 false

# On worker nodes
./automation/scripts/start-worker.sh <join-command>
```

**Verification:**
```bash
kubectl get nodes
# Nodes should be NotReady (CNI not deployed yet)
```

**Detailed Guide:** [operations/ansible-guide.md](operations/ansible-guide.md)

---

### Step 3: Deploy CNI Configuration

**Objective:** Deploy Container Network Interface configuration for pod networking. CNI binaries are already installed on nodes from Step 1.

**Available CNI Options:**

| CNI Option | Description | Use Case | Latency | Throughput |
|------------|-------------|----------|---------|------------|
| `none` | No CNI deployed | Manual CNI deployment or testing | N/A | N/A |
| `flannel-ipoib` | Flannel VXLAN over IPoIB | Standard Kubernetes networking, quick setup | ~120 µs | ~90 Gbps |
| `multus-ipoib` | Multus + IPoIB dual-interface | Maximum performance, separate control/data planes | <10 µs | ~95+ Gbps |
| `rdma-shared-device` | RDMA CDI Device Plugin | Native RDMA access (OPX/PSM2), no IPoIB networking | <1 µs | ~200 Gbps |

> **Workflow ID naming:** Throughout this repository the workflow ID is
> `rdma-shared-device` (the Ansible `deploy_cni=...` value, the test script
> suffix `tests/03-verify-rdma-shared-device.sh`, and the demo guide name).
> The Kubernetes device-plugin component it deploys is the upstream
> `k8s-rdma-shared-dev-plugin` with a Cornelis CDI configuration — that is
> what "RDMA CDI Device Plugin" refers to. Treat the two names as
> interchangeable in this document.

**Note:** This step deploys CNI configuration only. All CNI binaries (ipoib, multus, flannel, host-local) were installed during Step 1 (node preparation). The `rdma-shared-device` option does not use IPoIB for networking; it provides direct HFI device access for RDMA applications.

**Choose ONE of the following CNI options:**

#### Option A: Flannel VXLAN over IPoIB

**Best for:** Quick setup, standard Kubernetes networking  
**Performance:** ~120 µs latency, ~90 Gbps throughput  
**Overhead:** VXLAN encapsulation (~50 bytes/packet)

**Required Parameters:**
- `ipoib_interface` (default: `<ipoib_iface>`) — the IPoIB network interface name on each node
- `pod_cidr` (default: `10.244.0.0/16`) — must match the `--pod-network-cidr` passed to `kubeadm init`

**Deployment:**
```bash
# Automated (Ansible) - Deploy CNI only
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml cni-deploy.yaml \
  -e "deploy_cni=flannel-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  --ask-pass

# Automated (Ansible) - Deploy with cluster start
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=start" \
  -e "deploy_cni=flannel-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  --ask-pass

# Manual (replace <ipoib_iface> with your IPoIB interface name)
sed 's/{{ ipoib_interface }}/<ipoib_iface>/g' manifests/cni/flannel-ipoib.yaml | kubectl apply -f -
```

**Architecture:**
```
┌─────────────────────────────────────┐
│            POD                      │
├─────────────────────────────────────┤
│  eth0 (Flannel VXLAN over IPoIB)   │
│    ↓                                │
│  flannel.1 (VXLAN interface)       │
│    ↓                                │
│  <ipoib_iface> (IPoIB master)             │
│    ↓                                │
│  InfiniBand Fabric                  │
└─────────────────────────────────────┘
```

**Detailed Guide:** [deployment/flannel-ipoib-cni.md](deployment/flannel-ipoib-cni.md)

#### Option B: Multus + IPoIB (Dual-Interface)

**Best for:** Maximum performance, separate control/data planes  
**Performance:** <10 µs latency, ~95+ Gbps throughput  
**Overhead:** None (native IPoIB, no encapsulation)

**Required Parameters:**
- `ipoib_interface` (default: `<ipoib_iface>`) — the IPoIB network interface name on each node
- `flannel_subnet` (default: `10.244.0.0/16`) — Flannel control plane subnet
- `ipoib_subnet` (default: `192.168.100.0/24`) — IPoIB data plane subnet

**Note:** IPoIB mode and MTU are automatically detected from the parent IPoIB interface. The CNI inherits these settings from the physical interface configuration.

**Deployment:**
```bash
# Automated (Ansible) - Deploy CNI only
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml cni-deploy.yaml \
  -e "deploy_cni=multus-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  -e "ipoib_subnet=192.168.100.0/24" \
  --ask-pass

# Automated (Ansible) - Deploy with cluster start
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=start" \
  -e "deploy_cni=multus-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  -e "ipoib_subnet=192.168.100.0/24" \
  --ask-pass

# Manual (standalone script)
automation/scripts/deploy-multus-ipoib.sh --ipoib-interface <ipoib_iface>
```

**Architecture:**
```
┌─────────────────────────────────────┐
│            POD                      │
├─────────────────────────────────────┤
│  eth0 (Flannel host-gw)            │
│    ↓ Control plane traffic         │
│  Management Network                 │
│                                     │
│  net1 (Native IPoIB)               │
│    ↓ Data plane traffic            │
│  <ipoib_iface> (IPoIB interface)          │
│    ↓                                │
│  InfiniBand Fabric                  │
└─────────────────────────────────────┘
```

**Detailed Guide:** [deployment/multus-ipoib-cni.md](deployment/multus-ipoib-cni.md)

#### Option C: RDMA CDI Device Plugin

**Best for:** Native RDMA access (OPX/PSM2), MPI/HPC workloads  
**Performance:** <1 µs latency, ~200 Gbps throughput (CN5000 dual-port)  
**Overhead:** None (direct HFI device access, no networking layer)

**Required Parameters:**
- Platform auto-detected (CN5000)
- containerd ≥1.7.0 with CDI enabled
- Kubernetes ≥1.28 with `DevicePluginCDIDevices` feature gate

**Deployment:**
```bash
# Automated (Ansible)
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml cni-deploy.yaml \
  -e "deploy_cni=rdma-shared-device" \
  --ask-pass
```

**Architecture:**
```
┌─────────────────────────────────────┐
│            POD                      │
├─────────────────────────────────────┤
│  eth0 (Flannel ethernet)           │
│    ↓ Control plane traffic         │
│  Management Network                 │
│                                     │
│  /dev/hfi1_0 (HFI device)          │
│  /dev/infiniband/* (RDMA devices)  │
│    ↓ Direct RDMA operations        │
│  InfiniBand Fabric                  │
└─────────────────────────────────────┘
```

**Pod Resource Request:**
```yaml
resources:
  limits:
    cornelis.com/hfi: 1
```

**Detailed Guide:** [deployment/rdma-cdi-device-plugin.md](deployment/rdma-cdi-device-plugin.md)

---

### Step 4: Verify Deployment

**Objective:** Validate cluster and CNI deployment with comprehensive tests.

#### For Flannel VXLAN over IPoIB

**Test Script:** `tests/01-verify-flannel-ipoib.sh`  
**Test Count:** 44 tests  
**CNI Configuration:** Flannel VXLAN over IPoIB (<ipoib_iface>)

**Required Parameters:**
- `ipoib_interface` (default: `<ipoib_iface>`)
- `max_wait_time` (default: `300` seconds) - Pod readiness timeout

**Run Tests:**
```bash
# Automated (Ansible)
cd tests/ansible/playbooks
ansible-playbook -i ../inventory/test-nodes.yaml run-tests.yaml \
  -e "test_type=flannel-ipoib" \
  -e "ipoib_interface=<ipoib_iface>" \
  -e "max_wait_time=120" \
  --ask-pass

# Manual (on control plane node)
# Usage: ./tests/01-verify-flannel-ipoib.sh [ipoib_interface] [max_wait_time]
./tests/01-verify-flannel-ipoib.sh <ipoib_iface> 120
```

#### For Multus + IPoIB (Dual-Interface)

**Test Script:** `tests/02-verify-multus-ipoib.sh`  
**Test Count:** 51 tests (quick mode), 125 tests (full mode)  
**CNI Configuration:** Multus + IPoIB dual-interface

**Required Parameters:**
- `--iface <interface>` — IPoIB interface name (required, no default)

**Run Tests:**
```bash
# Quick mode (~5 minutes, 51 tests)
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick

# Full mode (~25 minutes, 125 tests)
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --full

# With custom subnet
./tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --subnet 192.168.100 --quick
```

#### For RDMA Shared Device (cornelis.com/hfi)

**Test Script:** `tests/03-verify-rdma-shared-device.sh` (the canonical, shipped verification script for the `rdma-shared-device` workflow).

**CNI Configuration:** k8s-rdma-shared-dev-plugin with vanilla Flannel control plane (no IPoIB).

**Run Tests:**
```bash
# Discover the IPoIB iface on a worker node first:
#   ssh <node> ip link show
IFACE=<ipoib_iface> ./tests/03-verify-rdma-shared-device.sh
```

The script reads `IFACE` from the environment (no positional default). See
[architecture/networking.md](architecture/networking.md) for the placeholder
convention.

**What's Tested (tests/03-verify-rdma-shared-device.sh):**
- Infrastructure: DaemonSet rollout, kubelet device-plugin registration, Flannel control plane
- Resource advertisement: `cornelis.com/hfi` capacity and per-node availability
- Pod scheduling: pod requesting `cornelis.com/hfi: 1` lands and starts
- Device access: `/dev/hfi1_*`, `/dev/infiniband/*`, mounts, permissions, env vars, capabilities
- RDMA operations: `ibv_devinfo`, port state, link layer, intra/inter-node verbs bandwidth
- OPX/PSM2 (when enabled): provider availability and basic data transfer

**What's Tested (Flannel/Multus):**
- Infrastructure (10 tests): Flannel pods, VXLAN interface, IPoIB binding
- Intra-node connectivity (12 tests): 4 pods per node, all combinations
- Inter-node connectivity (32 tests): Cross-node, all combinations

**Expected Result:**
```
Total Tests: 44
Passed: 44
Failed: 0
✓ ALL TESTS PASSED
```

**Detailed Test Documentation:** 
- [testing/01-verify-flannel-ipoib.md](testing/01-verify-flannel-ipoib.md)
- [deployment/rdma-cdi-device-plugin.md](deployment/rdma-cdi-device-plugin.md#troubleshooting)

---

### Step 5: Check Cluster Status

**Objective:** Monitor cluster health and component status.

**Automated (Ansible):**
```bash
cd automation/playbooks

# Check cluster status
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=status" \
  --ask-pass
```

**Manual:**
```bash
# Check node status
kubectl get nodes -o wide

# Check all pods across namespaces
kubectl get pods -A

# Check system component health
kubectl get componentstatuses

# Check kubelet service status on nodes
systemctl status kubelet
```

**What's Checked:**
- Kubelet service status on all nodes
- Node readiness and conditions
- System pods (kube-system namespace)
- CNI pods status
- Cluster component health

**Detailed Guide:** [operations/cluster-management.md](operations/cluster-management.md)

---

### Step 6: Stop Cluster (Optional)

**Objective:** Gracefully stop the Kubernetes cluster.

**Required Parameters:**
- `drain_before_stop` (default: `true`) - Drain nodes before stopping
- `delete_worker_on_stop` (default: `false`) - Remove workers from cluster
- `force_stop` (default: `false`) - Force stop without draining

**Automated (Ansible):**
```bash
cd automation/playbooks

# Graceful stop (drain nodes first)
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=stop" \
  -e "drain_before_stop=true" \
  --ask-pass

# Force stop (no draining)
ansible-playbook -i ../inventory/hosts.yaml cluster-control.yaml \
  -e "operation=stop" \
  -e "force_stop=true" \
  --ask-pass
```

**Manual:**
```bash
# On each worker node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
sudo systemctl stop kubelet

# On control plane node
sudo systemctl stop kubelet
```

**Detailed Guide:** [operations/cluster-management.md](operations/cluster-management.md)

---

## Detailed Guides

### Deployment Guides

| Guide | Description | Complexity |
|-------|-------------|------------|
| [flannel-ipoib-cni.md](deployment/flannel-ipoib-cni.md) | Flannel VXLAN over IPoIB deployment | ⭐⭐ Medium |
| [multus-ipoib-cni.md](deployment/multus-ipoib-cni.md) | Multus + IPoIB dual-interface deployment | ⭐⭐⭐ Advanced |
| [rdma-cdi-device-plugin.md](deployment/rdma-cdi-device-plugin.md) | RDMA CDI device plugin for native HFI access | ⭐⭐⭐⭐ Expert |

### Operations Guides

| Guide | Description |
|-------|-------------|
| [cluster-management.md](operations/cluster-management.md) | Kubernetes cluster lifecycle management |
| [ansible-guide.md](operations/ansible-guide.md) | Ansible automation for cluster operations |
| [troubleshooting.md](operations/troubleshooting.md) | Node prerequisites and common issues |

### Testing Documentation

| Test | Description | Documentation |
|------|-------------|---------------|
| 01 | Flannel IPoIB verification | [01-verify-flannel-ipoib.md](testing/01-verify-flannel-ipoib.md) |
| 02 | Multus IPoIB verification (49 quick / 136 full) | [02-verify-multus-ipoib.md](testing/02-verify-multus-ipoib.md) |
| 03 | RDMA shared device plugin verification (12 sections) | [03-verify-rdma-shared-device.md](testing/03-verify-rdma-shared-device.md) |

See [testing/README.md](testing/README.md) for complete testing documentation.

---

## Additional Resources

| Topic | Location |
|-------|----------|
| Dual-NIC architecture (stand-alone reference) | [`architecture/networking.md`](architecture/networking.md) |
| Per-workflow deployment guides | [`deployment/`](deployment/) |
| Per-workflow verification tests | [`testing/`](testing/) |
| One-time test image preparation | [`../tests/images/rdma-test-tools/README.md`](../tests/images/rdma-test-tools/README.md) |
| Flannel-over-IPoIB deep-dive | [`deployment/flannel-ipoib-cni.md`](deployment/flannel-ipoib-cni.md) |
| Multus + IPoIB deep-dive | [`deployment/multus-ipoib-cni.md`](deployment/multus-ipoib-cni.md) |
| RDMA CDI device plugin deep-dive | [`deployment/rdma-cdi-device-plugin.md`](deployment/rdma-cdi-device-plugin.md) |
| Workflow-specific failure modes | [`troubleshooting/`](troubleshooting/) |
| Day-to-day operations & troubleshooting | [`operations/troubleshooting.md`](operations/troubleshooting.md) |
| Test documentation index | [`testing/README.md`](testing/README.md) |

---

## Support

**Troubleshooting:**
1. Check [Troubleshooting Guide](operations/troubleshooting.md)
2. Review relevant deployment guide
3. Run verification tests
4. Check component logs

**Contributing:**
Please follow the existing documentation structure and conventions when contributing.
