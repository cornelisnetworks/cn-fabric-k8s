# Flannel VXLAN over IPoIB for Kubernetes

## Overview

This document describes how to deploy Flannel CNI with VXLAN encapsulation over InfiniBand IP over IB (IPoIB) interfaces for Kubernetes pod networking. This approach provides a simple, effective way to leverage high-speed InfiniBand fabric for pod-to-pod communication while keeping Kubernetes control plane traffic on the management network.

**When to use this approach:**
- You have InfiniBand hardware with IPoIB configured
- You want simple, full L3 pod connectivity across nodes
- You don't require RDMA verbs from pods
- You prefer operational simplicity over maximum performance

**When NOT to use this approach:**
- You need RDMA support from pods (use Multus + IPoIB CNI instead)
- You need SR-IOV device passthrough
- You require multiple network interfaces per pod
- VXLAN overhead (~50 bytes) is unacceptable for your workload

---

## CNI-Specific Architecture

The Flannel VXLAN over IPoIB CNI creates a VXLAN overlay (`flannel.1`) bound to the IPoIB interface via `--iface`, so all pod-to-pod traffic is encapsulated and transported over the InfiniBand fabric. The cluster-wide pod CIDR (`10.244.0.0/16`) is divided into per-node `/24` subnets by Flannel's Kubernetes-native subnet manager, and individual pod IPs are assigned sequentially from each node's subnet.

## Prerequisites (Flannel IPoIB-Specific)

1. **InfiniBand fabric** is operational with Cornelis Networks hardware (CN5000) and the `hfi1` driver is loaded.
2. The **`ib_ipoib` kernel module** is loaded on all nodes.
3. **IPoIB interfaces UP** with **IP addresses pre-configured** on each node.
   - Kubernetes cannot assign these before bootstrap due to the chicken-and-egg dependency with Flannel
   - Must be configured manually or via external tooling (Ansible, nmcli, netplan, etc.)
4. **`sysctl` setting** is `rp_filter=2` for proper routing behavior.

---

## Architecture

### Network Separation

The architecture uses two separate networks with distinct purposes:

**1. Management Network (eth0)**
- **Purpose**: Kubernetes control plane communication
- **Traffic**: API server, etcd, kubelet heartbeats, node registration
- **IP Range**: Typically 10.0.0.x or similar management subnet
- **Interface**: Standard Ethernet (eth0, ens0, etc.)

**2. Data Network (IPoIB)**
- **Purpose**: Pod-to-pod traffic via Flannel VXLAN
- **Traffic**: Application data between pods across nodes
- **IP Range**: Typically 10.56.0.x or similar IPoIB subnet
- **Interface**: InfiniBand IPoIB (<ipoib_iface>, <ipoib_iface>, etc.)

### How It Works

#### Traffic Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ Node 1                                                          │
│                                                                 │
│  ┌──────────────┐                                              │
│  │ Pod A        │                                              │
│  │ 10.244.0.5   │  ← Inner packet (pod IP)                    │
│  └──────┬───────┘                                              │
│         │                                                       │
│  ┌──────▼───────────┐                                          │
│  │ flannel.1 (VTEP) │  ← VXLAN encapsulation                  │
│  └──────┬───────────┘                                          │
│         │                                                       │
│  ┌──────▼───────────┐                                          │
│  │ <ipoib_iface> (IPoIB)   │  ← Outer packet (IPoIB IP)              │
│  │ 10.56.0.1        │                                          │
│  └──────┬───────────┘                                          │
│         │                                                       │
└─────────┼─────────────────────────────────────────────────────┘
          │
          │ InfiniBand Fabric (VXLAN UDP 8472)
          │
┌─────────▼─────────────────────────────────────────────────────┐
│ Node 2                                                          │
│                                                                 │
│  ┌──────────────┐                                              │
│  │ <ipoib_iface> (IPoIB)│  ← Receives VXLAN packet                   │
│  │ 10.56.0.2     │                                             │
│  └──────┬────────┘                                             │
│         │                                                       │
│  ┌──────▼───────────┐                                          │
│  │ flannel.1 (VTEP) │  ← VXLAN decapsulation                  │
│  └──────┬───────────┘                                          │
│         │                                                       │
│  ┌──────▼───────┐                                              │
│  │ Pod B        │                                              │
│  │ 10.244.1.5   │  ← Delivers inner packet                    │
│  └──────────────┘                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### Packet Structure

When Pod A (10.244.0.5) sends data to Pod B (10.244.1.5):

1. **Inner Packet**: Original pod-to-pod packet
   - Source: 10.244.0.5 (Pod A)
   - Destination: 10.244.1.5 (Pod B)
   - Payload: Application data

2. **VXLAN Header**: Added by flannel.1 interface (~50 bytes)
   - VXLAN Network Identifier (VNI)
   - UDP header (port 8472)

3. **Outer Packet**: IPoIB transport
   - Source: 10.56.0.1 (Node 1 IPoIB)
   - Destination: 10.56.0.2 (Node 2 IPoIB)
   - Protocol: UDP
   - Payload: VXLAN header + inner packet

4. **InfiniBand Layer**: Physical transport
   - Transmitted over InfiniBand fabric
   - High bandwidth, low latency

### Key Configuration: The --iface Patch

The critical mechanism that makes Flannel use IPoIB is the `--iface` argument to the flanneld daemon:

```yaml
containers:
- name: kube-flannel
  args:
  - --ip-masq
  - --kube-subnet-mgr
  - --iface=<ipoib_iface>  # ← Forces VXLAN VTEP to bind to IPoIB interface
```

**Without this patch:**
- Flannel binds VXLAN to the default route interface (eth0)
- Pod traffic flows over the management network
- InfiniBand fabric is unused

**With this patch:**
- Flannel binds VXLAN to the specified IPoIB interface (<ipoib_iface>)
- Pod traffic flows over the InfiniBand fabric
- Management network handles only control plane traffic

**How it works:**
1. Flannel creates a `flannel.1` VXLAN interface on each node.
2. The `--iface` argument tells Flannel which physical interface to use as the VXLAN underlay.
3. VXLAN tunnel endpoints (VTEPs) are configured with IPoIB interface IPs.
4. All pod-to-pod traffic is encapsulated and sent over IPoIB.

**Verification:**
```bash
# Check that flannel.1 is bound to IPoIB interface
ip -d link show flannel.1
# Output should show: vxlan id 1 ... dev <ipoib_iface> ...
```

---

## Prerequisites

### Hardware Requirements

- InfiniBand HCA (Host Channel Adapter) installed
- InfiniBand fabric connectivity between nodes
- Cornelis Networks CN5000 or compatible hardware

### Software Requirements

**Kernel Modules:**
```bash
# Required modules
modprobe ib_ipoib    # IPoIB support
modprobe vxlan       # VXLAN encapsulation
modprobe overlay     # Container networking
modprobe br_netfilter # Bridge netfilter
```

**IPoIB Interface:**
```bash
# IPoIB interface must be configured and UP
ip link show <ipoib_iface>
# Should show: state UP

# IPoIB interface must have IP address
ip addr show <ipoib_iface>
# Should show: inet 10.56.0.x/24
```

**Sysctl Parameters:**
```bash
# Required for VXLAN over IPoIB
net.ipv4.conf.all.rp_filter=2           # Loose mode (critical!)
net.ipv4.ip_forward=1                    # IP forwarding
net.bridge.bridge-nf-call-iptables=1     # Bridge netfilter
```

**Firewall Rules:**
```bash
# Management network (eth0)
firewall-cmd --permanent --add-port=6443/tcp      # API server
firewall-cmd --permanent --add-port=2379-2380/tcp # etcd
firewall-cmd --permanent --add-port=10250/tcp     # kubelet

# Data network (IPoIB)
firewall-cmd --permanent --add-port=8472/udp      # VXLAN
firewall-cmd --reload
```

### Kubernetes Cluster

- Kubernetes 1.28+ cluster initialized
- Control plane running and accessible
- Nodes in NotReady state (no CNI installed yet)

---

## Deployment

There are two main deployment scenarios depending on whether you are starting fresh or have an existing cluster.

---

### Scenario A: Fresh Cluster Deployment (Recommended)

Use this scenario when setting up a new cluster from scratch. This is the **complete automated workflow**.

#### Prerequisites

Before starting, ensure:
- **No active cluster running** - nodes must be clean or freshly provisioned
- **All packages setup** - Kubernetes packages will be installed by the setup step
- Nodes are accessible via SSH
- User has root or sudo access
- IPoIB interface is configured on all nodes
- Ansible is installed on control machine

**IMPORTANT:** This workflow assumes you are starting with clean nodes or nodes that have been cleaned using the `operation=clean` step. If you have an existing running cluster, use **Scenario B** instead.

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
- Installs dependencies (curl, wget, socat, conntrack, ipset, iptables)
- Disables swap permanently
- Loads kernel modules (br_netfilter, overlay, ib_ipoib, vxlan)
- Configures sysctl parameters (bridge-nf-call-iptables, ip_forward, rp_filter)
- Configures firewall rules (ports 10250, 30000-32767)
- Enables and starts kubelet and containerd services

**Step 3: Precheck Nodes** (validate readiness)
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=check
```

**What it validates:**
- Kubernetes packages installed
- Container runtime installed and running
- Swap disabled
- Kernel modules loaded
- Sysctl parameters configured
- Required services enabled
- Network connectivity

**Step 4: Start Cluster with Flannel IPoIB**
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start \
  -e deploy_cni=flannel-ipoib \
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
8. **Deploys Flannel with `--iface=<ipoib_iface>` configuration**
9. Waits for Flannel DaemonSet rollout
10. Verifies nodes become Ready

**Variables:**
- `deploy_cni=flannel-ipoib`: Enables Flannel IPoIB deployment
- `ipoib_interface=<ipoib_iface>`: Specifies IPoIB interface name (default: <ipoib_iface>)
- `pod_network_cidr=10.244.0.0/16`: Pod network CIDR (default)
- `service_cidr=10.96.0.0/12`: Service CIDR (default)
- `skip_worker_taint=true`: Allow control plane to run workloads (default)

**Expected Output:**
```
PLAY RECAP *********************************************************************
control-plane                 : ok=15   changed=8    unreachable=0    failed=0
worker                 : ok=10   changed=5    unreachable=0    failed=0
```

**Verification:**
```bash
# Check nodes are Ready
kubectl get nodes

# Check Flannel pods
kubectl get pods -n kube-flannel

# Run comprehensive verification
scp tests/01-verify-flannel-ipoib.sh root@control-plane:/tmp/verify.sh
ssh root@control-plane "bash /tmp/verify.sh <ipoib_iface>"
```

---

### Scenario B: Existing Cluster Deployment

Use this when you already have a running Kubernetes cluster and want to add Flannel IPoIB CNI.

#### When to Use This

- Cluster is already initialized with `kubeadm init`
- Nodes are already joined
- You want to add or replace the CNI plugin
- Nodes show "NotReady" status (no CNI installed)

#### Quick Deployment

**Option 1: Using kubectl (Fastest)**

```bash
# From control plane node (replace <ipoib_iface> with your IPoIB interface name)
sed 's/{{ ipoib_interface }}/<ipoib_iface>/g' manifests/cni/flannel-ipoib.yaml | kubectl apply -f -

# Wait for Flannel DaemonSet rollout
kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=300s

# Verify nodes become Ready
kubectl get nodes
```

**Option 2: Using Ansible (Automated)**

If you want Ansible to handle the deployment with validation:

```bash
# Create a custom playbook or run tasks manually
ansible -i automation/inventory/hosts.yaml control_plane -m shell \
  -a "kubectl apply -f /path/to/manifests/cni/flannel-ipoib.yaml"

# Or copy manifest and apply
scp manifests/cni/flannel-ipoib.yaml root@control-plane:/tmp/
ssh root@control-plane "kubectl apply -f /tmp/flannel-ipoib.yaml"
```

#### Prerequisites Verification

Before deploying to an existing cluster, verify the prerequisites:

```bash
# On all nodes, verify IPoIB interface
ip link show <ipoib_iface>
ip addr show <ipoib_iface>

# Verify kernel modules
lsmod | grep -E '(ib_ipoib|vxlan|overlay|br_netfilter)'

# Verify sysctl parameters
sysctl net.ipv4.conf.all.rp_filter  # Should be 0 or 2 (loose mode)
sysctl net.ipv4.ip_forward          # Should be 1
```

#### Post-Deployment Verification

```bash
# Check Flannel pods are running
kubectl get pods -n kube-flannel -o wide

# Check nodes are Ready
kubectl get nodes

# Verify --iface argument
kubectl get ds kube-flannel-ds -n kube-flannel -o yaml | grep "iface="

# Check flannel.1 interface binding
ssh root@control-plane "ip -d link show flannel.1 | grep 'dev <ipoib_iface>'"
ssh root@worker "ip -d link show flannel.1 | grep 'dev <ipoib_iface>'"

# Run comprehensive verification
scp tests/01-verify-flannel-ipoib.sh root@control-plane:/tmp/verify.sh
ssh root@control-plane "bash /tmp/verify.sh <ipoib_iface>"
```

---

### Deployment Comparison

| Aspect | Scenario A: Fresh Cluster | Scenario B: Existing Cluster |
|--------|---------------------------|------------------------------|
| **Use Case** | New cluster setup | Add CNI to a running cluster |
| **Prerequisites** | Clean nodes or first-time setup | Cluster already initialized |
| **Automation** | Full Ansible workflow (4 steps) | Manual kubectl or simple Ansible |
| **Time** | ~10-15 minutes (includes setup) | ~2-3 minutes (CNI only) |
| **Validation** | Built-in precheck + verification | Manual verification needed |
| **Recommended For** | Production deployments | Quick testing or CNI replacement |

---

### Troubleshooting Deployment

#### Issue: "Cluster already initialized" Error

**Symptom:** Running `operation=start` on existing cluster does nothing.

**Solution:** Use Scenario B (Existing Cluster Deployment) instead.

#### Issue: Nodes Stay "NotReady"

**Symptom:** After deployment, nodes remain in NotReady state.

**Possible causes:**
1. Flannel pods not running: `kubectl get pods -n kube-flannel`
2. IPoIB interface down: `ip link show <ipoib_iface>`
3. Kernel modules not loaded: `lsmod | grep ib_ipoib`
4. Wrong interface name in manifest

**Solution:**
```bash
# Check Flannel pod logs
kubectl logs -n kube-flannel -l app=flannel

# Verify interface binding
kubectl exec -n kube-flannel <pod-name> -- ip -d link show flannel.1
```

#### Issue: Flannel Pods CrashLoopBackOff

**Symptom:** Flannel pods repeatedly crash.

**Possible causes:**
1. IPoIB interface doesn't exist
2. Insufficient permissions
3. Kernel modules missing

**Solution:**
```bash
# Check pod logs
kubectl logs -n kube-flannel <pod-name>

# Verify IPoIB on the node where pod is crashing
kubectl get pod <pod-name> -n kube-flannel -o jsonpath='{.spec.nodeName}'
ssh root@<node> "ip link show <ipoib_iface>"
```

**Variables:**
- `deploy_cni=flannel-ipoib`: Enables Flannel IPoIB deployment
- `ipoib_interface=<ipoib_iface>`: Specifies IPoIB interface name (default: <ipoib_iface>)
- `pod_network_cidr=10.244.0.0/16`: Pod network CIDR (default)

**What it does:**
1. Validates IPoIB interface exists and is UP
2. Checks required kernel modules are loaded
3. Initializes Kubernetes control plane
4. Joins worker nodes
5. Deploys Flannel with IPoIB configuration
6. Waits for Flannel DaemonSet rollout
7. Verifies nodes become Ready

### Option 2: Manual Deployment

If you prefer manual deployment or need to deploy CNI after cluster initialization:

**Step 1: Verify Prerequisites**
```bash
# On all nodes, verify IPoIB interface
ip link show <ipoib_iface>
ip addr show <ipoib_iface>

# Verify kernel modules
lsmod | grep -E '(ib_ipoib|vxlan|overlay|br_netfilter)'

# Verify sysctl parameters
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.ip_forward
```

**Step 2: Apply Flannel Manifest**
```bash
# From control plane node (replace <ipoib_iface> with your IPoIB interface name)
sed 's/{{ ipoib_interface }}/<ipoib_iface>/g' manifests/cni/flannel-ipoib.yaml | kubectl apply -f -
```

**Step 3: Wait for Rollout**
```bash
# Wait for Flannel DaemonSet to be ready
kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=300s
```

**Step 4: Verify Deployment**
```bash
# Check Flannel pods are running
kubectl get pods -n kube-flannel

# Check nodes are Ready
kubectl get nodes

# Verify --iface argument
kubectl get ds kube-flannel-ds -n kube-flannel -o yaml | grep "iface="
```

### Option 3: Deploy to Existing Cluster

If you already have a cluster without CNI:

```bash
# Deploy only the CNI (from control plane, replace <ipoib_iface> with your IPoIB interface name)
sed 's/{{ ipoib_interface }}/<ipoib_iface>/g' manifests/cni/flannel-ipoib.yaml | kubectl apply -f -

# Wait for nodes to become Ready
kubectl get nodes -w
```

---

## Verification

### Automated Verification Script (Recommended)

The repository includes a comprehensive verification script that automates all validation checks:

**Location:** `tests/01-verify-flannel-ipoib.sh`

**Usage:**
```bash
# Copy script to control plane node
scp tests/01-verify-flannel-ipoib.sh root@control-plane:/tmp/verify.sh

# Run verification
ssh root@control-plane "bash /tmp/verify.sh <ipoib_iface>"
```

**What the script tests:**

1. **Infrastructure Checks**
   - Nodes status (all Ready)
   - Flannel pods status (all Running)
   - Flannel `--iface` argument configuration
   - IPoIB interface status (UP and configured)
   - flannel.1 VXLAN interface binding to IPoIB
   - VXLAN port listening (UDP 8472)
   - Pod network routes

2. **Advanced Connectivity Testing**
   - Randomly selects 2 nodes from the cluster
   - Creates 4 test pods on each selected node (8 pods total)
   - Tests **intra-node connectivity** (pods on same node)
     - All combinations: pod1↔pod2, pod1↔pod3, pod1↔pod4, pod2↔pod3, etc.
   - Tests **inter-node connectivity** (pods across nodes via VXLAN/IPoIB)
     - All combinations: node1-pod1 → node2-pod1, node1-pod1 → node2-pod2, etc.
     - Validates bidirectional communication
   - Automatically cleans up test pods

**Example Output:**
```
==========================================
Flannel VXLAN over IPoIB Verification
==========================================
IPoIB Interface: <ipoib_iface>
Pods per node: 4
==========================================

[10/10] Advanced Pod Connectivity Testing:
==========================================

  Selected nodes for testing:
    Node 1: control-plane
    Node 2: worker

  Creating 4 pods on control-plane...
  Creating 4 pods on worker...

  Pod IPs on control-plane:
    test-node1-pod1: 10.244.0.12
    test-node1-pod2: 10.244.0.13
    test-node1-pod3: 10.244.0.14
    test-node1-pod4: 10.244.0.15

  Pod IPs on worker:
    test-node2-pod1: 10.244.1.36
    test-node2-pod2: 10.244.1.37
    test-node2-pod3: 10.244.1.38
    test-node2-pod4: 10.244.1.39

==========================================
Testing Intra-Node Connectivity (Same Node)
==========================================

  Testing connectivity between pods on control-plane:
    test-node1-pod1 → test-node1-pod2 ... ✓ PASS
    test-node1-pod1 → test-node1-pod3 ... ✓ PASS
    test-node1-pod1 → test-node1-pod4 ... ✓ PASS
    test-node1-pod2 → test-node1-pod3 ... ✓ PASS
    test-node1-pod2 → test-node1-pod4 ... ✓ PASS
    test-node1-pod3 → test-node1-pod4 ... ✓ PASS

  Testing connectivity between pods on worker:
    test-node2-pod1 → test-node2-pod2 ... ✓ PASS
    test-node2-pod1 → test-node2-pod3 ... ✓ PASS
    test-node2-pod1 → test-node2-pod4 ... ✓ PASS
    test-node2-pod2 → test-node2-pod3 ... ✓ PASS
    test-node2-pod2 → test-node2-pod4 ... ✓ PASS
    test-node2-pod3 → test-node2-pod4 ... ✓ PASS

==========================================
Testing Inter-Node Connectivity (Cross-Node)
==========================================

  Testing connectivity from control-plane pods to worker pods:
    test-node1-pod1 → test-node2-pod1 ... ✓ PASS
    test-node1-pod1 → test-node2-pod2 ... ✓ PASS
    [... 14 more tests ...]
    test-node1-pod4 → test-node2-pod4 ... ✓ PASS

  Testing connectivity from worker pods to control-plane pods:
    test-node2-pod1 → test-node1-pod1 ... ✓ PASS
    test-node2-pod1 → test-node1-pod2 ... ✓ PASS
    [... 14 more tests ...]
    test-node2-pod4 → test-node1-pod4 ... ✓ PASS

==========================================
Overall Results
==========================================
Total Tests: 44
Total PASS:  44
Total FAIL:  0

✓ ALL TESTS PASSED

Flannel IPoIB deployment is HEALTHY:
  - Intra-node connectivity: Working
  - Inter-node connectivity: Working
  - VXLAN over IPoIB: Functional
```

**Script Features:**
- ✅ Comprehensive validation (44 connectivity tests)
- ✅ Random node selection (works with any cluster size)
- ✅ Automatic pod placement and cleanup
- ✅ Clear pass/fail indicators
- ✅ Detailed test results
- ✅ Safe to run multiple times

---

### Manual Verification Steps

If you prefer manual verification or need to troubleshoot specific issues:

#### 1. Check Flannel Pods

```bash
kubectl get pods -n kube-flannel -o wide
```

**Expected Output:**
```
NAME                    READY   STATUS    RESTARTS   AGE   NODE
kube-flannel-ds-xxxxx   1/1     Running   0          2m    control-plane
kube-flannel-ds-yyyyy   1/1     Running   0          2m    worker
```

#### 2. Verify --iface Configuration

```bash
kubectl get ds kube-flannel-ds -n kube-flannel -o yaml | grep -A 5 "args:"
```

**Expected Output:**
```yaml
args:
- --ip-masq
- --kube-subnet-mgr
- --iface=<ipoib_iface>
```

#### 3. Check flannel.1 Interface Binding

```bash
# On each node
ip -d link show flannel.1
```

**Expected Output:**
```
4: flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff promiscuity 0
    vxlan id 1 local 10.56.0.1 dev <ipoib_iface> srcport 0 0 dstport 8472 ...
                                ^^^^^^^^
                                This should be your IPoIB interface
```

#### 4. Verify Nodes are Ready

```bash
kubectl get nodes
```

**Expected Output:**
```
NAME         STATUS   ROLES           AGE   VERSION
control-plane   Ready    control-plane   5m    v1.28.15
worker   Ready    <none>          4m    v1.28.15
```

#### 5. Test Pod-to-Pod Connectivity (Manual)

```bash
# Create test pods on different nodes
kubectl run test-pod-1 --image=busybox --command -- sleep 3600
kubectl run test-pod-2 --image=busybox --command -- sleep 3600

# Wait for pods to be running
kubectl wait --for=condition=Ready pod/test-pod-1 --timeout=60s
kubectl wait --for=condition=Ready pod/test-pod-2 --timeout=60s

# Get pod IPs
POD1_IP=$(kubectl get pod test-pod-1 -o jsonpath='{.status.podIP}')
POD2_IP=$(kubectl get pod test-pod-2 -o jsonpath='{.status.podIP}')

# Test connectivity from pod-1 to pod-2
kubectl exec test-pod-1 -- ping -c 3 $POD2_IP

# Test connectivity from pod-2 to pod-1
kubectl exec test-pod-2 -- ping -c 3 $POD1_IP

# Cleanup
kubectl delete pod test-pod-1 test-pod-2
```

**Expected Output:**
```
PING 10.244.1.5 (10.244.1.5): 56 data bytes
64 bytes from 10.244.1.5: seq=0 ttl=62 time=0.123 ms
64 bytes from 10.244.1.5: seq=1 ttl=62 time=0.098 ms
64 bytes from 10.244.1.5: seq=2 ttl=62 time=0.105 ms
```

#### 6. Verify VXLAN Traffic on IPoIB

```bash
# On any node, check VXLAN port is listening
ss -ulnp | grep 8472
```

**Expected Output:**
```
LISTEN  0  0  0.0.0.0:8472  0.0.0.0:*  users:(("flanneld",pid=12345,fd=10))
```

```bash
# Monitor VXLAN traffic on IPoIB interface
tcpdump -i <ipoib_iface> udp port 8472 -c 10
```

**Expected Output:**
```
10:56:0.1.8472 > 10.56.0.2.8472: VXLAN, flags [I] (0x08), vni 1
10:56:0.2.8472 > 10.56.0.1.8472: VXLAN, flags [I] (0x08), vni 1
```

### 7. Verify DNS Resolution

```bash
# Create test pod
kubectl run test-dns --image=busybox --command -- sleep 3600

# Test DNS resolution
kubectl exec test-dns -- nslookup kubernetes.default

# Cleanup
kubectl delete pod test-dns
```

**Expected Output:**
```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      kubernetes.default
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local
```

---

## Pros and Cons

### Advantages

✅ **Simple Deployment**
- Single CNI plugin (Flannel)
- No additional components (Multus, device plugins, etc.)
- Standard Kubernetes networking model
- 4 scripts vs 10+ for Multus-based solutions

✅ **Full L3 Pod Connectivity**
- All pods can reach all pods across all nodes
- Standard Kubernetes service discovery works
- No special application configuration needed
- Transparent to applications

✅ **Network Isolation**
- Control plane traffic separated from data plane
- Management network (eth0) handles API/etcd/kubelet
- Data network (IPoIB) handles pod traffic
- Reduces congestion on management network

✅ **Standard Flannel**
- Uses unmodified Flannel CNI plugin
- Just configured differently with --iface argument
- Well-tested, mature CNI plugin
- Large community support

✅ **Operational Simplicity**
- Easy to troubleshoot (standard Flannel tools)
- Familiar to Kubernetes operators
- No special pod annotations required
- Works with all Kubernetes workloads

✅ **High Bandwidth**
- Leverages InfiniBand fabric bandwidth
- Suitable for data-intensive workloads
- Better than standard Ethernet for pod traffic

### Limitations

❌ **No RDMA Support**
- VXLAN encapsulation prevents RDMA verbs
- Applications cannot use RDMA directly
- No zero-copy transfers
- No kernel bypass

❌ **VXLAN Overhead**
- ~50 bytes per packet for VXLAN headers
- Additional CPU cycles for encapsulation/decapsulation
- Slightly higher latency than native IPoIB
- Not suitable for ultra-low-latency workloads

❌ **No SR-IOV Support**
- Pods don't get direct hardware access
- No device passthrough
- Cannot use hardware offloads
- Limited to software-based networking

❌ **Single Data Network**
- All pod traffic uses same IPoIB interface
- No per-pod network isolation
- Cannot assign different QoS per pod
- No multi-tenancy at network level

❌ **No Multiple Interfaces per Pod**
- Pods get single network interface (eth0)
- Cannot separate control and data traffic within pod
- No support for complex networking topologies

---

## Comparison: Flannel IPoIB vs Multus

### Flannel IPoIB (This Approach)

**Architecture:**
- Single CNI plugin (Flannel)
- VXLAN encapsulation over IPoIB
- All pods get one interface (eth0)
- Transparent to applications

**Advantages:**
- ✅ Simple deployment (4 scripts)
- ✅ Standard Flannel CNI plugin
- ✅ Full pod-to-pod L3 connectivity
- ✅ No application changes required
- ✅ Easy to troubleshoot
- ✅ Mature, well-tested solution

**Limitations:**
- ❌ No RDMA support
- ❌ VXLAN overhead (~50 bytes)
- ❌ No SR-IOV support
- ❌ Single network interface per pod

**Best for:**
- General-purpose Kubernetes workloads
- Applications that don't require RDMA
- Environments prioritizing simplicity
- Teams familiar with standard Kubernetes networking

**Example Use Cases:**
- Web applications
- Microservices
- Databases (non-RDMA)
- Data processing pipelines (non-RDMA)

---

### Multus + IPoIB CNI

**Architecture:**
- Multiple CNI plugins (Multus meta-plugin + IPoIB CNI + default CNI)
- Direct IPoIB interfaces attached to pods
- Pods can have multiple network interfaces
- Requires application awareness

**Advantages:**
- ✅ Direct RDMA access from pods
- ✅ Multiple network interfaces per pod
- ✅ SR-IOV device passthrough support
- ✅ No encapsulation overhead
- ✅ Hardware offloads available
- ✅ Per-pod network isolation

**Limitations:**
- ❌ Complex deployment (10+ scripts)
- ❌ Requires Multus + IPoIB CNI + device plugins
- ❌ Applications must be aware of multiple interfaces
- ❌ More moving parts to troubleshoot
- ❌ Requires pod annotations for network attachment
- ❌ Not all pods may need IPoIB (resource waste)

**Best for:**
- HPC workloads requiring RDMA
- High-performance storage (NVMe-oF, etc.)
- Low-latency trading applications
- Scientific computing
- AI/ML training with RDMA

**Example Use Cases:**
- MPI applications
- Distributed training (Horovod, etc.)
- High-frequency trading
- Storage clusters (Ceph with RDMA)

---

### Decision Matrix

| Requirement | Flannel IPoIB | Multus + IPoIB CNI |
|-------------|---------------|-------------------|
| Simple deployment | ✅ Yes | ❌ No |
| Full L3 connectivity | ✅ Yes | ⚠️ Partial (depends on config) |
| RDMA support | ❌ No | ✅ Yes |
| SR-IOV support | ❌ No | ✅ Yes |
| Multiple interfaces per pod | ❌ No | ✅ Yes |
| Zero application changes | ✅ Yes | ❌ No (needs interface awareness) |
| Low operational complexity | ✅ Yes | ❌ No |
| Ultra-low latency | ❌ No (VXLAN overhead) | ✅ Yes |
| Standard K8s networking | ✅ Yes | ⚠️ Partial (needs annotations) |
| Suitable for all workloads | ✅ Yes | ❌ No (RDMA-specific) |

---

## Troubleshooting

### Issue: Nodes Stuck in NotReady

**Symptom:**
```bash
kubectl get nodes
NAME         STATUS     ROLES           AGE   VERSION
control-plane   NotReady   control-plane   5m    v1.28.15
```

**Diagnosis:**
```bash
# Check Flannel pods
kubectl get pods -n kube-flannel

# Check kubelet logs
journalctl -u kubelet -f
```

**Common Causes:**
1. Flannel pods not running
2. IPoIB interface down
3. Kernel modules not loaded
4. Firewall blocking VXLAN (UDP 8472)

**Solutions:**
```bash
# Verify IPoIB interface is UP
ip link show <ipoib_iface>

# Verify kernel modules
lsmod | grep -E '(ib_ipoib|vxlan)'

# Check firewall
firewall-cmd --list-all

# Restart Flannel pods
kubectl delete pods -n kube-flannel --all
```

### Issue: Flannel Pods CrashLoopBackOff

**Symptom:**
```bash
kubectl get pods -n kube-flannel
NAME                    READY   STATUS             RESTARTS   AGE
kube-flannel-ds-xxxxx   0/1     CrashLoopBackOff   5          3m
```

**Diagnosis:**
```bash
# Check pod logs
kubectl logs -n kube-flannel kube-flannel-ds-xxxxx

# Check pod events
kubectl describe pod -n kube-flannel kube-flannel-ds-xxxxx
```

**Common Causes:**
1. IPoIB interface doesn't exist
2. Invalid --iface argument
3. Missing kernel modules
4. Insufficient permissions

**Solutions:**
```bash
# Verify interface name matches --iface argument
ip link show | grep ibs

# Check Flannel DaemonSet configuration
kubectl get ds kube-flannel-ds -n kube-flannel -o yaml | grep iface

# If interface name is wrong, update manifest and reapply (replace <correct_interface> with actual name)
sed 's/{{ ipoib_interface }}/<correct_interface>/g' manifests/cni/flannel-ipoib.yaml | kubectl apply -f -
```

### Issue: Pod-to-Pod Connectivity Fails

**Symptom:**
```bash
kubectl exec test-pod-1 -- ping 10.244.1.5
# Times out or "Network unreachable"
```

**Diagnosis:**
```bash
# Check flannel.1 interface exists
ip link show flannel.1

# Check flannel.1 is bound to IPoIB
ip -d link show flannel.1 | grep dev

# Check VXLAN port is listening
ss -ulnp | grep 8472

# Check routes
ip route show
```

**Common Causes:**
1. flannel.1 not bound to IPoIB interface
2. VXLAN port blocked by firewall
3. rp_filter too strict
4. IPoIB interface down

**Solutions:**
```bash
# Verify flannel.1 underlay device
ip -d link show flannel.1
# Should show: dev <ipoib_iface>

# Check rp_filter setting (must be 0 or 2)
sysctl net.ipv4.conf.all.rp_filter
# If 1, set to 2:
sysctl -w net.ipv4.conf.all.rp_filter=2

# Check firewall allows VXLAN
firewall-cmd --list-all | grep 8472
# If not present:
firewall-cmd --permanent --add-port=8472/udp
firewall-cmd --reload

# Restart Flannel pods
kubectl delete pods -n kube-flannel --all
```

### Issue: VXLAN Traffic Not Using IPoIB

**Symptom:**
```bash
# VXLAN traffic appears on eth0 instead of <ipoib_iface>
tcpdump -i eth0 udp port 8472
# Shows VXLAN packets (should be on <ipoib_iface>)
```

**Diagnosis:**
```bash
# Check Flannel --iface argument
kubectl get ds kube-flannel-ds -n kube-flannel -o yaml | grep iface

# Check flannel.1 underlay device
ip -d link show flannel.1
```

**Common Causes:**
1. --iface argument missing or wrong
2. Flannel manifest not properly patched
3. Old Flannel pods still running

**Solutions:**
```bash
# Verify --iface in DaemonSet
kubectl get ds kube-flannel-ds -n kube-flannel -o jsonpath='{.spec.template.spec.containers[0].args}'

# If missing, reapply manifest (replace <ipoib_iface> with your IPoIB interface name)
sed 's/{{ ipoib_interface }}/<ipoib_iface>/g' manifests/cni/flannel-ipoib.yaml | kubectl apply -f -

# Force pod restart
kubectl rollout restart daemonset/kube-flannel-ds -n kube-flannel

# Verify flannel.1 binding
ip -d link show flannel.1 | grep "dev ibs"
```

### Issue: IPoIB Interface Not Found

**Symptom:**
```bash
ip link show <ipoib_iface>
# Device "<ipoib_iface>" does not exist
```

**Diagnosis:**
```bash
# List all interfaces
ip link show

# Check InfiniBand devices
ls /sys/class/infiniband/

# Check IPoIB module
lsmod | grep ib_ipoib
```

**Common Causes:**
1. IPoIB module not loaded
2. InfiniBand hardware not detected
3. Wrong interface name
4. IPoIB not configured

**Solutions:**
```bash
# Load IPoIB module
modprobe ib_ipoib

# Check InfiniBand hardware
ibstat

# List IPoIB interfaces
ip link show | grep ib

# If interface has different name, update manifest
# Edit manifests/cni/flannel-ipoib.yaml
# Change --iface=<ipoib_iface> to --iface=<your-interface>
```

---

## Advanced Configuration

### Custom Pod Network CIDR

To use a different pod network CIDR:

```bash
# Deploy with custom CIDR
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start \
  -e deploy_cni=flannel-ipoib \
  -e pod_network_cidr=10.100.0.0/16
```

**Note:** The Flannel manifest must be updated to match the CIDR.

### Multiple IPoIB Interfaces

If you have multiple IPoIB interfaces and want to use a specific one:

```bash
# List IPoIB interfaces
ip link show | grep ib

# Deploy with specific interface
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start \
  -e deploy_cni=flannel-ipoib \
  -e ipoib_interface=<ipoib_iface>
```

### High Availability Control Plane

For HA control plane with multiple control plane nodes:

```bash
# Initialize with control plane endpoint
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start \
  -e deploy_cni=flannel-ipoib \
  -e control_plane_endpoint=10.0.0.100:6443
```

---

## Performance Considerations

### VXLAN Overhead

- **Header size**: ~50 bytes per packet
- **MTU reduction**: Effective MTU is 1450 (1500 - 50)
- **CPU overhead**: Encapsulation/decapsulation on each node
- **Latency impact**: Typically 10-50 microseconds additional latency

### Optimization Tips

1. **Increase MTU on IPoIB interface** (if supported):
   ```bash
   ip link set <ipoib_iface> mtu 9000
   ```

2. **Enable hardware offloads** (if supported):
   ```bash
   ethtool -K <ipoib_iface> tx on rx on
   ```

3. **Tune VXLAN parameters** (advanced):
   - Adjust VXLAN port (default 8472)
   - Configure VXLAN TTL
   - Enable VXLAN checksums

4. **Monitor performance**:
   ```bash
   # Check interface statistics
   ip -s link show <ipoib_iface>
   
   # Monitor VXLAN traffic
   iftop -i <ipoib_iface>
   ```

---

## Summary

Flannel VXLAN over IPoIB provides a **simple, effective solution** for leveraging InfiniBand fabric in Kubernetes environments where RDMA is not required. It offers:

- ✅ Easy deployment and operation
- ✅ Full pod-to-pod connectivity
- ✅ Network separation (control vs data plane)
- ✅ High bandwidth over InfiniBand

While it doesn't provide RDMA support or ultra-low latency, it's an excellent choice for most Kubernetes workloads that benefit from high-bandwidth networking without the complexity of Multus-based solutions.

For workloads requiring RDMA, consider the Multus + IPoIB CNI approach instead.
