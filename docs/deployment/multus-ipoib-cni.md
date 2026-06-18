# Multus + IPoIB Dual-Interface CNI for Kubernetes

## Overview

This document describes how to deploy Multus CNI with native IPoIB for dual-interface pod networking in Kubernetes. This approach provides maximum performance by eliminating VXLAN encapsulation overhead and enabling native InfiniBand communication for data plane traffic.

**When to use this approach:**
- You need maximum network performance (≥95 Gbps, <10 µs latency)
- You want to eliminate VXLAN encapsulation overhead (~10-15%)
- You require separate control plane and data plane networks
- You have InfiniBand hardware with IPoIB configured
- You want automatic dual-interface attachment for all pods

**When NOT to use this approach:**
- You need RDMA verbs support (requires SR-IOV or device plugin)
- You prefer operational simplicity over performance (use Flannel VXLAN instead)
- Your nodes are not on the same L2 network (host-gw requires L2 connectivity)

---

## Architecture

### Dual-Interface Design

This architecture provides **two network interfaces per pod**:

**1. Primary Interface (eth0) - Control Plane**
- **CNI**: Flannel with host-gw backend (direct routing, no VXLAN)
- **Purpose**: Kubernetes control plane, DNS, services
- **Traffic**: API server, kubelet, CoreDNS, service discovery
- **Subnet**: Configurable (default: 10.244.0.0/16)
- **Performance**: Standard Ethernet performance

**2. Secondary Interface (ipoib0) - Data Plane**
- **CNI**: IPoIB CNI (native IPoIB)
- **Purpose**: High-performance application data traffic
- **Traffic**: Pod-to-pod application communication
- **Subnet**: Configurable (default: 192.168.100.0/24)
- **Performance**: Native InfiniBand (≥95 Gbps, <10 µs latency)

### Network Separation

```
┌─────────────────────────────────────────────────────────────────┐
│ Pod                                                             │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Application Container                                     │  │
│  │                                                           │  │
│  │  eth0: 10.244.0.5/24  ← Control plane (Flannel)         │  │
│  │    • DNS queries                                         │  │
│  │    • Service discovery                                   │  │
│  │    • K8s API access                                      │  │
│  │                                                           │  │
│  │  ipoib0: 192.168.100.10/24  ← Data plane (IPoIB)        │  │
│  │    • Application data                                    │  │
│  │    • High-performance traffic                            │  │
│  │    • Native InfiniBand                                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                                    │
         │ eth0                               │ ipoib0
         ↓                                    ↓
┌─────────────────────┐          ┌─────────────────────┐
│ Flannel (host-gw)   │          │ IPoIB CNI           │
│ Direct routing      │          │ Native IPoIB        │
│ No encapsulation    │          │ No encapsulation    │
└─────────┬───────────┘          └─────────┬───────────┘
          │                                 │
          ↓                                 ↓
┌─────────────────────┐          ┌─────────────────────┐
│ eth0 (Ethernet)     │          │ <ipoib_iface> (IPoIB)      │
│ 10.0.0.x            │          │ No IP needed        │
└─────────────────────┘          └─────────────────────┘
          │                                 │
          ↓                                 ↓
┌─────────────────────┐          ┌─────────────────────┐
│ Management Network  │          │ InfiniBand Fabric   │
│ (Ethernet)          │          │ (hfi1_0)            │
└─────────────────────┘          └─────────────────────┘
```

### Traffic Flow

**Control Plane Traffic (via eth0):**
```
Pod A (eth0: 10.244.0.5)
  ↓
Flannel host-gw (direct routing)
  ↓
Node eth0 (10.0.0.104)
  ↓
Management Network
  ↓
Node eth0 (10.0.0.105)
  ↓
Flannel host-gw (direct routing)
  ↓
Pod B (eth0: 10.244.1.5)
```

**Data Plane Traffic (via ipoib0):**
```
Pod A (ipoib0: 192.168.100.10)
  ↓
IPoIB CNI (native IPoIB)
  ↓
Node <ipoib_iface> (IPoIB interface)
  ↓
InfiniBand Fabric (native, no encapsulation)
  ↓
Node <ipoib_iface> (IPoIB interface)
  ↓
IPoIB CNI (native IPoIB)
  ↓
Pod B (ipoib0: 192.168.100.20)
```

---

## Components

### 1. Flannel (host-gw backend)

**Purpose**: Primary CNI for control plane traffic (eth0)

**Key Features:**
- Direct routing between nodes (no VXLAN encapsulation)
- Requires L2 connectivity between nodes (same subnet)
- Lower overhead than VXLAN
- Standard Kubernetes networking

**Configuration:**
- Subnet: Configurable (default: 10.244.0.0/16)
- Backend: host-gw (direct routing)
- Interface: eth0 (management network)

### 2. Multus CNI

**Purpose**: Meta-plugin for multi-interface orchestration

**Key Features:**
- Delegates eth0 creation to Flannel
- Delegates ipoib0 creation to IPoIB CNI
- Supports NetworkAttachmentDefinition CRD
- Enables automatic network attachment

**Configuration:**
- Primary CNI: Flannel (eth0)
- Secondary CNI: IPoIB (ipoib0)
- Auto-attach: Enabled globally

### 3. IPoIB CNI

**Purpose**: Secondary CNI for data plane traffic (ipoib0)

**Key Features:**
- Native IPoIB interface creation
- Supports datagram and connected modes
- Configurable MTU (2044 for datagram, 65520 for connected)
- Zero encapsulation overhead

**Configuration:**
- Interface: Configurable (default: <ipoib_iface>, actual: <ipoib_iface>)
- Mode: Configurable (default: datagram)
- MTU: Configurable (default: 2044)
- IPAM: Whereabouts (cluster-wide)

**Source / build model:**
- `cn-ipoib-cni` is built **in-tree on each node** during node preparation
  (the `setup` operation runs `automation/playbooks/setup-node.yaml`, which
  compiles the plugin with the on-node Go toolchain and installs the binary to
  `/opt/cni/bin/ipoib`). The node build intentionally excludes any pre-built
  `bin/` artifacts from the repo.
- The DaemonSet `manifests/cni/ipoib-cni-daemonset.yaml` runs `alpine:3.18` as a
  lightweight **keepalive** pod. It does **not** build or copy the binary; it
  simply verifies that `/opt/cni/bin/ipoib` exists on the node and stays
  running so the plugin presence is observable as a DaemonSet.
- Upstream reference only (not used for the build): the IPoIB CNI concept
  originates from the upstream `ipoib-cni` project. The Cornelis `cn-ipoib-cni`
  is maintained at <https://github.com/cornelisnetworks/cn-ipoib-cni>.

### 4. Whereabouts IPAM

**Purpose**: Cluster-wide IP address management for the IPoIB network

**Key Features:**
- Cluster-wide IP coordination (no overlapping allocations across nodes)
- Dynamic IP assignment from the configured subnet
- Backed by a Kubernetes-stored allocation datastore
- Deployed as a DaemonSet by the `multus-ipoib` workflow

**Configuration:**
- Subnet: Configurable (default: 192.168.100.0/24)
- Range: .10 to .254 (network and broadcast excluded)
- IPAM type `whereabouts` is declared in
  `manifests/cni/ipoib-network-attachment.yaml`

**Note:** Whereabouts coordinates IP allocation across the whole cluster, so
two pods on different nodes never receive the same IPoIB address. This is the
IPAM used by the active deployment.

---

## Prerequisites

### Hardware Requirements

1. **InfiniBand Hardware**
   - Cornelis Networks CN5000 or compatible
   - hfi1 driver loaded and operational
   - IPoIB interface exists and is UP on all nodes

2. **Network Connectivity**
   - L2 connectivity between nodes (same subnet for host-gw)
   - InfiniBand fabric operational
   - Management network (eth0) operational

### Software Requirements

1. **Kubernetes Cluster**
   - Kubernetes 1.24+ initialized
   - kubectl configured and accessible
   - Cluster-admin permissions

2. **Kernel Modules**
   - `ib_ipoib`: InfiniBand IPoIB support
   - `br_netfilter`: Bridge netfilter support

3. **System Configuration**
   - `net.ipv4.ip_forward=1`
   - `net.bridge.bridge-nf-call-iptables=1`

### Verification

```bash
# Check InfiniBand hardware
ibstat

# Check IPoIB interface
ip link show <ipoib_iface>

# Check kernel modules
lsmod | grep -E '(ib_ipoib|br_netfilter)'

# Check sysctl settings
sysctl net.ipv4.ip_forward
sysctl net.bridge.bridge-nf-call-iptables
```

---

## Configuration Parameters

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `flannel_subnet` | Flannel subnet CIDR | `10.244.0.0/16` | `10.100.0.0/16` |
| `ipoib_interface` | IPoIB interface name | `<ipoib_iface>` | `<ipoib_iface>` |
| `ipoib_subnet` | IPoIB subnet CIDR | `192.168.100.0/24` | `10.10.0.0/16` |

**Note:** IPoIB mode and MTU are automatically detected from the parent IPoIB interface. The CNI inherits these settings from the physical interface configuration, ensuring consistency and eliminating manual configuration errors.

---

## Deployment

There are two main deployment scenarios depending on whether you're starting fresh or have an existing cluster.

---

### Scenario A: Fresh Cluster Deployment (Recommended)

Use this when setting up a new cluster from scratch. This is the **complete automated workflow**.

#### Prerequisites

Before starting, ensure:
- **No active cluster running** - nodes must be clean or freshly provisioned
- **All packages setup** - Kubernetes packages will be installed by the setup step
- Nodes are accessible via SSH
- User has root or sudo access
- IPoIB interface is configured on all nodes
- Ansible is installed on control machine

**IMPORTANT:** This workflow assumes you're starting with clean nodes or nodes that have been cleaned using the `operation=clean` step. If you have an existing running cluster, use **Scenario B** instead.

#### Complete Workflow

**Step 1: Clean Nodes** (if previously configured)
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=clean
```

**What it does:**
- Removes all Kubernetes components (kubelet, kubeadm, kubectl, containerd)
- Cleans network configurations and CNI plugins
- Removes `/etc/kubernetes` and `/var/lib/kubelet`
- Creates backup in `/var/log/k8s-cleanup-<timestamp>`

**Step 2: Setup Nodes** (install prerequisites)
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=setup
```

**What it does:**
- Installs Kubernetes packages (kubelet, kubeadm, kubectl)
- Installs and configures containerd runtime
- Installs CNI binaries (ipoib, multus, flannel, host-local, loopback, bridge, portmap, bandwidth)
- Builds `cn-ipoib-cni` in-tree on each node (Go toolchain) and installs it to `/opt/cni/bin/ipoib`
- Disables swap permanently
- Loads kernel modules (br_netfilter, overlay, ib_ipoib)
- Configures sysctl parameters (bridge-nf-call-iptables, ip_forward)
- Configures firewall rules (ports 10250, 30000-32767)
- Enables and starts kubelet and containerd services

**Step 3: Start Cluster with Multus IPoIB**
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start \
  -e deploy_cni=multus-ipoib \
  -e ipoib_interface=<ipoib_iface>
```

**What it does:**
1. Initializes Kubernetes control plane with `kubeadm init`
2. Configures kubeconfig for root and sudo users
3. Removes control-plane taint (allows workloads on control plane)
4. Generates join command for workers
5. Joins worker nodes to cluster
6. **Validates IPoIB interface exists and is UP**
7. **Checks required kernel modules are loaded**
8. **Deploys Flannel (host-gw backend) for control plane (eth0)**
9. **Deploys Multus CNI for multi-interface orchestration**
10. **Deploys IPoIB CNI for data plane (ipoib0)**
11. **Deploys Whereabouts IPAM for IP address management**
12. **Creates NetworkAttachmentDefinition for IPoIB network**
13. **Configures Multus default network auto-attach**
14. **🔴 CRITICAL: Configures Multus cache directory (`cniCacheDir: /var/lib/cni/multus`) to enable proper CNI cleanup during pod deletion**
15. Waits for all DaemonSets to rollout
16. Verifies nodes become Ready

> **🔴 VERY IMPORTANT - Multus Cache Configuration:**
> 
> The Multus daemon **MUST** be configured with `cniCacheDir: /var/lib/cni/multus` in its configuration. Without this setting:
> - Multus cannot cache which delegated CNI plugins were used during pod creation
> - During pod deletion, Multus will NOT call the IPoIB CNI DEL operation
> - **Stale IPoIB child interfaces will accumulate on nodes** (e.g., `dev151@<ipoib_iface>`, `dev153@<ipoib_iface>`)
> - Eventually hits kernel resource limits (max_nonsrq_conn_qp=128 for IPoIB)
> - New pod creation fails with "Device or resource busy" errors
> 
> **This configuration is automatically applied by the deployment automation.** If deploying manually, ensure the Multus daemon ConfigMap includes:
> ```json
> {
>   "cniCacheDir": "/var/lib/cni/multus",
>   "chrootDir": "/hostroot",
>   "binDir": "/hostroot/opt/cni/bin",
>   "cniDir": "/hostroot/opt/cni/bin"
> }
> ```
> 
> **Verification:**
> ```bash
> # Check Multus daemon config includes cniCacheDir
> kubectl get configmap multus-daemon-config -n kube-system -o jsonpath='{.data.daemon-config\.json}' | jq .cniCacheDir
> # Should output: "/var/lib/cni/multus"
> 
> # After pod deletion, verify no stale interfaces remain
> ssh root@<node> "ip link show | grep '@<ipoib_iface>'"
> # Should return empty (no stale interfaces)
> ```

**Variables:**
- `deploy_cni=multus-ipoib`: Enables Multus + IPoIB deployment
- `ipoib_interface=<ipoib_iface>`: Specifies IPoIB interface name (required)
- `ipoib_subnet=192.168.100.0/24`: IPoIB subnet CIDR (default)
- `flannel_subnet=10.244.0.0/16`: Flannel subnet CIDR (default)
- `pod_network_cidr=10.244.0.0/16`: Pod network CIDR (default)
- `service_cidr=10.96.0.0/12`: Service CIDR (default)
- `skip_worker_taint=true`: Allow control plane to run workloads (default)

**Expected Output:**
```
PLAY RECAP *********************************************************************
<control-plane>            : ok=91   changed=19   unreachable=0    failed=0
<worker>                   : ok=45   changed=10   unreachable=0    failed=0
```

**Verification:**
```bash
# Check nodes are Ready
kubectl get nodes

# Check all CNI components
kubectl get pods -n kube-flannel
kubectl get pods -n kube-system -l name=multus
kubectl get pods -n kube-system -l name=ipoib-cni
kubectl get pods -n kube-system -l app=whereabouts

# Check NetworkAttachmentDefinition
kubectl get network-attachment-definitions.k8s.cni.cncf.io -A

# Run comprehensive verification
tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --full
```

---

### Scenario B: Existing Cluster Deployment

Use this when you already have a running Kubernetes cluster and want to add Multus + IPoIB CNI.

#### When to Use This

- Cluster is already initialized with `kubeadm init`
- Nodes are already joined
- You want to add or replace the CNI plugin
- Nodes show "NotReady" status (no CNI installed)

#### Quick Deployment

**Option 1: Using Ansible (Recommended)**

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cni-deploy.yaml \
  -e deploy_cni=multus-ipoib \
  -e ipoib_interface=<ipoib_iface> \
  -e ipoib_subnet=192.168.100.0/24
```

**Option 2: Using Standalone Script**

```bash
# Deploy with default settings
automation/scripts/deploy-multus-ipoib.sh --ipoib-interface <ipoib_iface>

# Deploy with custom subnet
automation/scripts/deploy-multus-ipoib.sh \
  --ipoib-interface <ipoib_iface> \
  --ipoib-subnet 10.10.0.0/16 \
  --flannel-subnet 10.100.0.0/16
```

#### Prerequisites Verification

Before deploying to an existing cluster, verify these prerequisites:

```bash
# On all nodes, verify IPoIB interface
ip link show <ipoib_iface>
ip addr show <ipoib_iface>

# Verify kernel modules
lsmod | grep -E '(ib_ipoib|br_netfilter)'

# Verify sysctl parameters
sysctl net.ipv4.ip_forward          # Should be 1
sysctl net.bridge.bridge-nf-call-iptables  # Should be 1
```

#### Post-Deployment Verification

```bash
# Check all CNI components are running
kubectl get pods -n kube-flannel -o wide
kubectl get pods -n kube-system -l name=multus -o wide
kubectl get pods -n kube-system -l name=ipoib-cni -o wide
kubectl get pods -n kube-system -l app=whereabouts -o wide

# Check nodes are Ready
kubectl get nodes

# Check NetworkAttachmentDefinition
kubectl get network-attachment-definitions.k8s.cni.cncf.io -A

# Run comprehensive verification
tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick
```

---

### Deployment Comparison

| Aspect | Scenario A: Fresh Cluster | Scenario B: Existing Cluster |
|--------|---------------------------|------------------------------|
| **Use Case** | New cluster setup | Add CNI to a running cluster |
| **Prerequisites** | Clean nodes or first-time setup | Cluster already initialized |
| **Automation** | Full Ansible workflow (3 steps) | Ansible or script (1 step) |
| **Time** | ~10-15 minutes (includes setup) | ~3-5 minutes (CNI only) |
| **Validation** | Built-in verification | Manual verification needed |
| **Recommended For** | Production deployments | Quick testing or CNI replacement |

---

### Method 3: Manual Deployment (Advanced)

For users who prefer manual control over each deployment step.

**Step 1: Deploy Flannel (host-gw)**

```bash
sed 's/{{ flannel_subnet }}/10.244.0.0\/16/g' \
  manifests/cni/flannel-hostgw.yaml | kubectl apply -f -

kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=300s
```

**Step 2: Deploy Multus CNI**

```bash
# Apply the THICK Multus DaemonSet (the active manifest). Its image uses the
# snapshot-thick tag and it configures cniCacheDir/binDir/cniDir, which are
# required for proper CNI cleanup. The thin multus-daemonset.yaml is NOT used.
kubectl apply -f manifests/cni/multus-daemonset-thick.yaml

kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=300s
```

**Step 3: Deploy IPoIB CNI keepalive**

The `cn-ipoib-cni` binary is already built in-tree and installed to
`/opt/cni/bin/ipoib` on every node during node preparation. This DaemonSet does
**not** build or copy the binary — it runs `alpine:3.18` as a keepalive that
verifies `/opt/cni/bin/ipoib` exists and stays running so the plugin presence
is visible as a DaemonSet.

```bash
kubectl apply -f manifests/cni/ipoib-cni-daemonset.yaml

kubectl rollout status daemonset/ipoib-cni -n kube-system --timeout=300s
```

**Step 4: Deploy Whereabouts IPAM**

```bash
kubectl apply -f manifests/cni/whereabouts-daemonset.yaml

kubectl rollout status daemonset/whereabouts -n kube-system --timeout=300s
```

**Step 5: Create NetworkAttachmentDefinition**

```bash
# Set environment variables for template substitution
export IPOIB_INTERFACE=<ipoib_iface>
export IPOIB_SUBNET=192.168.100.0/24
export RANGE_START=192.168.100.10
export RANGE_END=192.168.100.254
export GATEWAY=192.168.100.1

# Apply manifest with variable substitution
envsubst < manifests/cni/ipoib-network-attachment.yaml | kubectl apply -f -
```

**Step 6: Configure automatic attachment**

```bash
kubectl apply -f manifests/cni/multus-default-config.yaml

kubectl delete pods -n kube-system -l name=multus
kubectl wait --for=condition=ready pod -n kube-system -l name=multus --timeout=120s
```

---

## Verification

### Quick Verification

**Run quick test suite (~5 minutes, 51 tests):**

```bash
tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick
```

**Expected Output:**
```
==========================================
Multus + IPoIB Dual-Interface CNI Verification
==========================================
Mode: quick
IPoIB Interface: <ipoib_iface>
==========================================

[1/4] Infrastructure Validation
==========================================
  ✓ PASS: Kubernetes cluster accessible
  ✓ PASS: Nodes Ready (2 nodes)
  ✓ PASS: Flannel namespace exists
  ✓ PASS: Flannel pods running (2 pods)
  ✓ PASS: Multus pods running (2 pods)
  ✓ PASS: IPoIB CNI pods running (2 pods)
  ✓ PASS: Whereabouts pods running (2 pods)
  ✓ PASS: Multus binary installed
  ✓ PASS: IPoIB CNI binary installed
  ✓ PASS: NetworkAttachmentDefinition exists
  ✓ PASS: IPoIB interface <ipoib_iface> is UP
  ✓ PASS: Kernel module ib_ipoib loaded
  ✓ PASS: CoreDNS pods running (2 pods)

[2/4] Pod Interface Validation
==========================================
  ✓ PASS: Pod test-multus-node1-pod1 ready
  ✓ PASS: Pod test-multus-node1-pod1 has eth0 interface
  ✓ PASS: Pod test-multus-node1-pod1 has ipoib0 interface
  ...

[3/4] Control Plane Connectivity (via eth0)
==========================================
  ✓ PASS: Ping from test-multus-node1-pod1 to test-multus-node2-pod1 via eth0
  ✓ PASS: DNS resolution from test-multus-node1-pod1
  ✓ PASS: Service access from test-multus-node1-pod1 via eth0
  ...

[4/4] Data Plane Connectivity (via ipoib0)
==========================================
  ✓ PASS: Ping from test-multus-node1-pod1 to test-multus-node2-pod1 via ipoib0
  ✓ PASS: Ping from test-multus-node2-pod1 to test-multus-node1-pod1 via ipoib0
  ...

==========================================
Test Summary
==========================================
Total Tests:   51
Passed:        51
Failed:        0
Skipped:       0
==========================================
✓ All tests passed!
```

### Full Verification

**Run Full Test Suite (~25 minutes, 125 tests):**

```bash
tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --full
```

**Additional Tests in Full Mode:**
- More pods per node (4 instead of 2)
- IP subnet validation
- All-to-all connectivity matrix (63 connectivity tests)
- External connectivity tests
- DNS resolution tests

### Manual Verification

**Check Component Status:**

```bash
# Check all DaemonSets
kubectl get daemonsets -A

# Check Flannel
kubectl get pods -n kube-flannel -o wide

# Check Multus
kubectl get pods -n kube-system -l name=multus -o wide

# Check IPoIB CNI
kubectl get pods -n kube-system -l name=ipoib-cni -o wide

# Check Whereabouts IPAM
kubectl get pods -n kube-system -l app=whereabouts -o wide

# Check NetworkAttachmentDefinition
kubectl get network-attachment-definitions.k8s.cni.cncf.io -A
```

**Create Test Pod and Verify Interfaces:**

```bash
# Create test pod
kubectl run test-dual-interface --image=alpine:3.18 --command -- sleep 3600

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/test-dual-interface --timeout=60s

# Check interfaces
kubectl exec test-dual-interface -- ip addr show

# Expected output:
# 1: lo: ...
# 2: eth0@if123: ...  ← Flannel interface (10.244.x.x)
# 3: ipoib0@if456: ...  ← IPoIB interface (192.168.100.x)

# Verify eth0 (Flannel)
kubectl exec test-dual-interface -- ip addr show eth0

# Verify ipoib0 (IPoIB)
kubectl exec test-dual-interface -- ip addr show ipoib0

# Cleanup
kubectl delete pod test-dual-interface
```

---

## Application Usage

### Automatic Dual Interfaces

**All Pods Automatically Receive Dual Interfaces:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: my-app:latest
```

**Result:**
- `eth0`: Flannel network (10.244.x.x) - control plane
- `ipoib0`: IPoIB network (192.168.100.x) - data plane

### Using the Data Plane Network

**Applications Should Bind to ipoib0 for High-performance Traffic:**

```python
# Python example: Bind to ipoib0 interface
import socket

# Get ipoib0 IP address
ipoib0_ip = socket.gethostbyname(socket.gethostname())  # May need adjustment

# Bind server to ipoib0
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind((ipoib0_ip, 8080))
server.listen(5)
```

**Environment Variable Approach:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: my-app:latest
    env:
    - name: DATA_PLANE_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIPs[1].ip  # ipoib0 IP
```

### Service Discovery

**Services Use eth0 (Flannel) by Default:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

**For Data Plane Communication, Use Pod IPs Directly:**

```bash
# Get pod ipoib0 IP
kubectl get pod my-app -o jsonpath='{.status.podIPs[1].ip}'

# Connect directly to ipoib0 IP
curl http://192.168.100.10:8080
```

---

## Performance Tuning

### IPoIB Mode and MTU

**Mode and MTU are automatically inherited from the parent IPoIB interface.** The CNI detects these settings from the physical interface, ensuring consistency across the cluster.

To change mode or MTU, configure the parent IPoIB interface on all nodes:

```bash
# Example: Set connected mode with jumbo frames
ip link set <ipoib_iface> mode connected
ip link set <ipoib_iface> mtu 65520

# Example: Set datagram mode with standard MTU
ip link set <ipoib_iface> mode datagram
ip link set <ipoib_iface> mtu 2044
```

After changing the parent interface settings, redeploy the CNI to pick up the new configuration.

### Expected Performance

| Metric | Flannel VXLAN | Multus + IPoIB | Improvement |
|--------|---------------|----------------|-------------|
| **Throughput** | ~90 Gbps | ~95+ Gbps | +5-8% |
| **Latency** | ~120 µs | <10 µs | ~12x lower |
| **CPU Overhead** | ~15-20% | ~5% | ~3-4x lower |
| **Encapsulation** | VXLAN (50 bytes) | None | Zero overhead |

### Performance Testing

**Bandwidth Test Between Pods:**

```bash
# Install iperf3 in test pods
kubectl exec test-pod-1 -- apk add --no-cache iperf3
kubectl exec test-pod-2 -- apk add --no-cache iperf3

# Get ipoib0 IPs
POD1_NET1_IP=$(kubectl exec test-pod-1 -- ip -4 addr show ipoib0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
POD2_NET1_IP=$(kubectl exec test-pod-2 -- ip -4 addr show ipoib0 | grep inet | awk '{print $2}' | cut -d'/' -f1)

# Start iperf3 server on pod 2
kubectl exec test-pod-2 -- iperf3 -s -D

# Run bandwidth test from pod 1 to pod 2
kubectl exec test-pod-1 -- iperf3 -c $POD2_NET1_IP -t 10

# Expected: ≥95 Gbps for native IPoIB
```

**Latency Test:**

```bash
# Ping test via ipoib0
kubectl exec test-pod-1 -- ping -c 100 $POD2_NET1_IP

# Expected: <10 µs average latency
```

---

## Troubleshooting

### Issue: Pods Missing ipoib0 Interface

**Symptoms:**
- Pods only have eth0, no ipoib0 interface

**Diagnosis:**

```bash
# Check Multus pods
kubectl get pods -n kube-system -l name=multus

# Check Multus logs
kubectl logs -n kube-system -l name=multus

# Check NetworkAttachmentDefinition
kubectl get network-attachment-definitions.k8s.cni.cncf.io -A

# Check IPoIB CNI binary
ls -l /opt/cni/bin/ipoib
```

**Solutions:**

1. **Verify NetworkAttachmentDefinition exists:**
   ```bash
   kubectl get network-attachment-definitions.k8s.cni.cncf.io ipoib-network -n kube-system
   ```

2. **Verify IPoIB CNI binary installed:**
   ```bash
   test -f /opt/cni/bin/ipoib && echo "IPoIB CNI installed" || echo "IPoIB CNI missing"
   ```

3. **Restart Multus pods:**
   ```bash
   kubectl delete pods -n kube-system -l name=multus
   kubectl wait --for=condition=ready pod -n kube-system -l name=multus --timeout=120s
   ```

4. **Recreate pod:**
   ```bash
   kubectl delete pod <pod-name>
   # Pod will be recreated with dual interfaces
   ```

### Issue: IPoIB CNI Binary Missing

**Symptoms:**
- IPoIB CNI DaemonSet pods in CrashLoopBackOff
- Missing /opt/cni/bin/ipoib binary
- Pods fail to create ipoib0 interface

**Diagnosis:**

```bash
# Check IPoIB CNI pod status
kubectl get pods -n kube-system -l name=ipoib-cni

# Check IPoIB CNI logs
kubectl logs -n kube-system -l name=ipoib-cni

# Check if binary exists on nodes
ls -l /opt/cni/bin/ipoib
```

**Background:** `cn-ipoib-cni` is compiled **in-tree on each node** during node
preparation (the `setup` operation), not shipped as a pre-built artifact. The
`ipoib-cni-daemonset.yaml` pod is only an `alpine:3.18` keepalive that checks
for `/opt/cni/bin/ipoib`; if the binary is missing the keepalive surfaces the
problem but does not build it.

**Solutions:**

1. **Verify the node build produced the binary:**
   ```bash
   # The setup step compiles and installs the binary on each node
   ls -l /opt/cni/bin/ipoib
   ```

2. **Re-run setup to rebuild and reinstall the binary on the nodes:**
   ```bash
   ansible-playbook -i automation/inventory/hosts.yaml \
     automation/playbooks/node-management.yaml \
     -e operation=setup
   ```
   The setup playbook (`setup-node.yaml`) uses the on-node Go toolchain to build
   `cn-ipoib-cni` and install it to `/opt/cni/bin/ipoib`. Do **not** copy a
   pre-built `bin/ipoib` from the repository — the node build deliberately
   excludes any `bin/` artifacts and is the supported path.

### Issue: Whereabouts IPAM IP Conflicts

**Symptoms:**
- Pods fail to start with IPAM errors
- IP allocation failures
- Duplicate IP addresses

**Diagnosis:**

```bash
# Check Whereabouts pods
kubectl get pods -n kube-system -l app=whereabouts

# Check Whereabouts logs
kubectl logs -n kube-system -l app=whereabouts

# Check IP pools
kubectl get ippools.whereabouts.cni.cncf.io -A

# Check pod events
kubectl describe pod <pod-name>
```

**Solutions:**

1. **Restart Whereabouts pods:**
   ```bash
   kubectl delete pods -n kube-system -l app=whereabouts
   kubectl wait --for=condition=ready pod -n kube-system -l app=whereabouts --timeout=120s
   ```

2. **Clear IP pool allocations:**
   ```bash
   # Delete all IP pools (will be recreated)
   kubectl delete ippools.whereabouts.cni.cncf.io --all -A
   ```

3. **Increase subnet size if exhausted:**
   ```bash
   # Redeploy with larger subnet
   ansible-playbook -i automation/inventory/hosts.yaml \
     automation/playbooks/cni-deploy.yaml \
     -e deploy_cni=multus-ipoib \
     -e ipoib_interface=<ipoib_iface> \
     -e ipoib_subnet=10.10.0.0/16  # 65534 IPs instead of 254
   ```

### Flannel host-gw Routing Issues

**Symptoms:**
- Pods cannot reach other nodes via eth0
- DNS resolution failures

**Diagnosis:**

```bash
# Check Flannel pods
kubectl get pods -n kube-flannel

# Check Flannel logs
kubectl logs -n kube-flannel -l app=flannel

# Check routes on nodes
ip route show

# Check L2 connectivity
ip route | grep "$(ip -4 addr show eth0 | grep inet | awk '{print $2}')"
```

**Solutions:**

1. **Verify L2 connectivity (host-gw requirement):**
   ```bash
   # All nodes must be on same subnet
   # Check node IPs
   kubectl get nodes -o wide
   
   # Verify same subnet
   ip route show | grep eth0
   ```

2. **Check bridge netfilter:**
   ```bash
   lsmod | grep br_netfilter
   sysctl net.bridge.bridge-nf-call-iptables
   ```

3. **Restart Flannel:**
   ```bash
   kubectl delete pods -n kube-flannel -l app=flannel
   ```

### Issue: IPoIB Interface Not Found

**Symptoms:**
- Deployment fails with "interface not found" error
- IPoIB CNI cannot create ipoib0 interfaces

**Diagnosis:**

```bash
# Check IPoIB interface exists
ip link show <ipoib_iface>

# Check interface state
ip link show <ipoib_iface> | grep state

# Check kernel module
lsmod | grep ib_ipoib
```

**Solutions:**

1. **Verify interface name:**
   ```bash
   # List all interfaces
   ip link show
   
   # Common name: <ipoib_iface> (CN5000)
   ```

2. **Load kernel module:**
   ```bash
   modprobe ib_ipoib
   ```

3. **Bring interface up:**
   ```bash
   ip link set <ipoib_iface> up
   ```

4. **Redeploy with correct interface name:**
   ```bash
   automation/scripts/deploy-multus-ipoib.sh --ipoib-interface <ipoib_iface>
   ```

---

## Comparison with Flannel VXLAN

| Aspect | Flannel VXLAN | Multus + IPoIB | Notes |
|--------|---------------|----------------|-------|
| **Interfaces per pod** | 1 (eth0) | 2 (eth0 + ipoib0) | Dual-interface design |
| **Control plane** | VXLAN over IPoIB | Flannel host-gw | Direct routing |
| **Data plane** | VXLAN over IPoIB | Native IPoIB | Zero encapsulation |
| **Encapsulation** | VXLAN (50 bytes) | None | 10-15% overhead eliminated |
| **Throughput** | ~90 Gbps | ~95+ Gbps | +5-8% improvement |
| **Latency** | ~120 µs | <10 µs | ~12x lower |
| **CPU overhead** | ~15-20% | ~5% | ~3-4x lower |
| **Complexity** | Low | Medium | More components |
| **L2 requirement** | No | Yes (host-gw) | Same subnet required |
| **Automatic setup** | Yes | Yes | Auto-attach enabled |

**When to Use Flannel VXLAN:**
- Operational simplicity preferred
- Nodes on different subnets
- Performance overhead acceptable

**When to Use Multus + IPoIB:**
- Maximum performance required
- Nodes on same L2 network
- Willing to manage additional complexity

---

## Migration from Flannel VXLAN

### Migration Steps

1. **Backup current configuration:**
   ```bash
   kubectl get all -A -o yaml > backup-before-migration.yaml
   ```

2. **Drain and cordon nodes (rolling migration):**
   ```bash
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```

3. **Remove Flannel VXLAN:**
   ```bash
   kubectl delete -f manifests/cni/flannel-ipoib.yaml
   ```

4. **Deploy Multus + IPoIB:**
   ```bash
   ansible-playbook -i automation/inventory/hosts.yaml \
     automation/playbooks/cni-deploy.yaml \
     -e deploy_cni=multus-ipoib \
     -e ipoib_interface=<ipoib_iface>
   ```

5. **Uncordon nodes:**
   ```bash
   kubectl uncordon <node-name>
   ```

6. **Verify deployment:**
   ```bash
   tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick
   ```

7. **Recreate workload pods:**
   ```bash
   kubectl rollout restart deployment/<deployment-name>
   ```

### Rollback Procedure

**If migration fails, rollback to Flannel VXLAN:**

1. **Remove Multus + IPoIB:**
   ```bash
   kubectl delete -f manifests/cni/multus-default-config.yaml
   kubectl delete network-attachment-definitions.k8s.cni.cncf.io ipoib-network -n kube-system
   kubectl delete -f manifests/cni/whereabouts-daemonset.yaml
   kubectl delete -f manifests/cni/ipoib-cni-daemonset.yaml
   kubectl delete -f manifests/cni/multus-daemonset-thick.yaml
   kubectl delete -f manifests/cni/flannel-hostgw.yaml
   ```

2. **Redeploy Flannel VXLAN:**
   ```bash
   ansible-playbook -i automation/inventory/hosts.yaml \
     automation/playbooks/cni-deploy.yaml \
     -e deploy_cni=flannel-ipoib \
     -e ipoib_interface=<ipoib_iface>
   ```

3. **Verify rollback:**
   ```bash
   tests/01-verify-flannel-ipoib.sh --iface <ipoib_iface> --quick
   ```

---

## CNI Removal

### Overview

If you need to remove all CNI components (Multus, IPoIB, Whereabouts, and Flannel) from your cluster, use the automated removal tools provided in this repository.

**What gets removed:**
- ✓ All Kubernetes resources (DaemonSets, ConfigMaps, RBAC, CRDs, Namespaces)
- ✓ All node-level files (CNI binaries, configs, data directories)
- ✓ All NetworkAttachmentDefinitions
- ✓ Automatic backup creation before removal

**After removal:**
- Nodes will become **NotReady** (no CNI available)
- Cluster control plane remains functional
- You can deploy a new CNI or leave cluster without networking

### Quick Removal

**Using Ansible Playbook (Recommended):**

```bash
# Dry-run to preview changes
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml \
  -e "dry_run_mode=true"

# Remove all CNI components (with confirmation)
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml

# Remove all CNI components (skip confirmation)
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml \
  -e "skip_confirmation=true"
```

**Using Standalone Script:**

```bash
# Dry-run to preview changes
sudo automation/scripts/remove-cni.sh --dry-run

# Remove all CNI components (with confirmation)
sudo automation/scripts/remove-cni.sh

# Remove all CNI components (skip confirmation)
sudo automation/scripts/remove-cni.sh --yes
```

### Removal Process

The removal automation performs the following steps:

**Phase 1: Kubernetes Resources Removal**
- Deletes DaemonSets: `kube-multus-ds`, `ipoib-cni`, `whereabouts`, `kube-flannel-ds`
- Deletes NetworkAttachmentDefinitions (including `ipoib-network`)
- Deletes ConfigMaps: `multus-daemon-config`, `multus-default-networks`, `kube-flannel-cfg`
- Deletes RBAC resources: ServiceAccounts, ClusterRoles, ClusterRoleBindings
- Deletes CRD: `network-attachment-definitions.k8s.cni.cncf.io`
- Deletes Namespace: `kube-flannel`

**Phase 2: Node-Level Cleanup (on all nodes)**
- Removes CNI binaries from `/opt/cni/bin/` and `/hostroot/opt/cni/bin/`
  - `ipoib`, `multus`, `multus-shim`, `whereabouts`, `flannel`
- Removes CNI configs from `/etc/cni/net.d/`
  - `00-multus.conf`, `10-flannel.conflist`, `whereabouts.d/`
- Removes CNI data from `/var/lib/cni/`
  - `multus/`, `flannel/`, `networks/`, `results/`
- Removes debug logs: `/var/log/cni-ipoib-debug.log`

**Phase 3: Verification**
- Checks for remaining CNI pods (should be 0)
- Checks for stale IPoIB interfaces (should be 0)
- Verifies CNI binaries removed
- Displays final cluster status

### Backup Location

Both methods create a timestamped backup in `/tmp/`:

```
/tmp/cni-removal-backup-YYYYMMDD-HHMMSS/
├── daemonsets-backup.yaml
├── configmaps-backup.yaml
├── network-attachment-definitions-backup.yaml
└── crd-backup.yaml
```

The backup path is displayed at the end of the removal process.

### Verification After Removal

**Check for remaining CNI pods:**
```bash
kubectl get pods -A | grep -E 'multus|ipoib|whereabouts|flannel'
# Expected: No output (all CNI pods removed)
```

**Check node status:**
```bash
kubectl get nodes
# Expected: Nodes show NotReady status
```

**Check for stale IPoIB interfaces:**
```bash
# On each node
ip link show | grep '@<ipoib_iface>'
# Expected: No output (no stale interfaces)
```

**Check CNI binaries removed:**
```bash
# On each node
ls -la /opt/cni/bin/ | grep -E 'multus|ipoib|whereabouts|flannel'
# Expected: No output (binaries removed)
```

### Restoring Networking

After CNI removal, to restore networking:

**Option 1: Redeploy the same CNI stack**
```bash
ansible-playbook automation/playbooks/cni-deploy.yaml \
  -i automation/inventory/hosts.yaml \
  -e "deploy_cni=multus-ipoib" \
  -e "ipoib_interface=<ipoib_iface>"
```

**Option 2: Deploy a different CNI**
- Follow the deployment guide for your chosen CNI
- Examples: Calico, Cilium, Weave, Flannel VXLAN

**Option 3: Leave cluster without CNI**
- Cluster control plane remains functional
- Useful for maintenance or testing scenarios

### Safety Features

Both removal methods include:

- ✓ **Confirmation prompts** - Prevents accidental removal (can be skipped)
- ✓ **Dry-run mode** - Preview changes before making them
- ✓ **Automatic backup** - All configurations backed up before removal
- ✓ **Graceful error handling** - Continues with warnings on missing resources
- ✓ **Verification steps** - Confirms complete removal
- ✓ **Idempotent** - Safe to run multiple times

### Detailed Documentation

For complete documentation including troubleshooting, integration examples, and advanced usage, refer to:

```bash
cat automation/playbooks/README-CNI-REMOVAL.md
```

---

## Manifest Customizations

### `multus-daemonset-thick.yaml` — Memory Limits Removed

**Source:** Based on upstream Multus thick deployment
[`k8snetworkplumbingwg/multus-cni@v4.2.4`](https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.2.4/deployments/multus-daemonset-thick.yml)

> **Versions:** `v4.2.4` above is the **Multus binary version** the manifest is
> derived from. The container **image tag** used by this manifest is
> `snapshot-thick` (the thick variant), and the manifest sets
> `cniCacheDir`/`binDir`/`cniDir`. This is the active manifest
> (`manifests/cni/multus-daemonset-thick.yaml`); the thin
> `multus-daemonset.yaml` is not used.

**Customization:** Memory limits removed from the `kube-multus` container.

**Original upstream:**
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "50Mi"
  limits:
    cpu: "100m"
    memory: "50Mi"   # ← REMOVED
```

**Modified:**
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "50Mi"
  # limits removed — see reason below
```

**Why:** Multus runs the Whereabouts IPAM binary as a subprocess. Whereabouts inherits the
cgroup memory limit (50 Mi) from the Multus pod. When Whereabouts allocates memory for IPAM
operations it hits the 50 Mi ceiling, causing the kernel to enter a memory reclaim loop
(`shrink_node_memcgs` / `try_to_free_mem_cgroup_pages`). The process hangs indefinitely and
pods remain in `ContainerCreating` state, never receiving IP addresses.

Removing the memory limit allows Whereabouts to allocate freely. The memory *request* (50 Mi)
is retained so the scheduler still accounts for the pod during placement.

**When upgrading Multus:**
1. Download the new upstream manifest.
2. Re-apply this customization (remove the `limits.memory` line).
3. Update the version reference above.
4. Run `tests/02-verify-multus-ipoib.sh --iface <ipoib_iface> --quick` to confirm.

---

## References

- [Multus CNI Documentation](https://github.com/k8snetworkplumbingwg/multus-cni)
- [Cornelis IPoIB CNI](https://github.com/cornelisnetworks/cn-ipoib-cni) - Pre-built binary included in this repository
- [Whereabouts IPAM](https://github.com/k8snetworkplumbingwg/whereabouts)
- [Flannel Documentation](https://github.com/flannel-io/flannel)
- [Cornelis Networks Documentation](https://www.cornelisnetworks.com/support/)
- [CNI Removal Guide](../../automation/playbooks/README-CNI-REMOVAL.md) - Detailed removal documentation
