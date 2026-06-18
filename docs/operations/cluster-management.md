# Kubernetes Cluster Management Guide

This guide describes the Ansible-based workflow for managing Kubernetes clusters in the CN Fabric environment.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Cluster Management Workflow](#cluster-management-workflow)
4. [Ansible Playbooks](#ansible-playbooks)
5. [Inventory Configuration](#inventory-configuration)
6. [Common Operations](#common-operations)
7. [Troubleshooting](#troubleshooting)
8. [Script Reference](#script-reference)

---

## Overview

The cluster management automation provides a complete lifecycle management solution for Kubernetes clusters using Ansible playbooks. The workflow follows a structured approach:

```
Clean → Setup → Precheck → Start → [Operations] → Stop
```

### Key Components

- **Ansible Playbooks**: Orchestrate operations across multiple nodes
- **Shell Scripts**: Perform node-level operations
- **Inventory**: Define cluster topology and node roles
- **Task Files**: Modular task definitions for reusability

---

## Prerequisites

### Control Machine Requirements

- Ansible 2.9 or later
- SSH access to all cluster nodes
- Python 3.x

### Target Node Requirements

- RHEL/CentOS 8+ or Ubuntu 20.04+
- Root or sudo access
- Network connectivity between nodes
- Minimum 2 CPU cores, 2GB RAM per node

---

## Cluster Management Workflow

### 1. Clean Nodes

Remove all existing Kubernetes components and configurations.

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=clean
```

**What it does:**
- Stops kubelet and containerd services
- Runs `kubeadm reset --force`
- Removes Kubernetes packages (kubelet, kubeadm, kubectl, containerd)
- Cleans network configurations and CNI plugins
- Removes `/etc/kubernetes` and `/var/lib/kubelet`
- Creates backup in `/var/log/k8s-cleanup-<timestamp>`

**Options:**
- `preserve_images=true`: Keep container images (default: false)
- `dry_run=true`: Preview changes without executing (default: false)

### 2. Setup Nodes

Install and configure all prerequisites for Kubernetes.

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=setup
```

**What it does:**
- Installs Kubernetes packages (kubelet, kubeadm, kubectl)
- Installs and configures containerd runtime
- Installs dependencies (curl, wget, socat, conntrack, ipset, iptables)
- Disables swap
- Loads kernel modules (br_netfilter, overlay)
- Configures sysctl parameters (bridge-nf-call-iptables, ip_forward)
- Configures firewall rules (ports 10250, 30000-32767)
- Enables and starts kubelet and containerd services

**Options:**
- `k8s_version`: Kubernetes version to install (default: 1.28.5)
- `platform`: Hardware platform (cn5000|auto)

### 3. Precheck Nodes

Verify nodes are ready for cluster initialization.

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=check
```

**What it validates:**
- ✓ Kubernetes packages installed (kubectl, kubeadm, kubelet)
- ✓ Container runtime installed (containerd)
- ✓ Swap disabled
- ✓ Kernel modules loaded (overlay, br_netfilter)
- ✓ Sysctl parameters configured
- ✓ Required services enabled (kubelet, containerd)
- ✓ Containerd service running
- ✓ Network connectivity
- ✓ Firewall rules configured

### 4. Start Cluster

Initialize control plane and join worker nodes.

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start
```

**What it does:**
- **Control Plane**: Runs `kubeadm init` with specified network CIDRs
- **Control Plane**: Configures kubeconfig for root and sudo users
- **Control Plane**: Optionally removes control-plane taint (default: yes)
- **Control Plane**: Generates join command for workers
- **Workers**: Join cluster using join command from control plane
- **All Nodes**: Verify cluster status

**Options:**
- `pod_network_cidr`: Pod network CIDR (default: 10.244.0.0/16)
- `service_cidr`: Service CIDR (default: 10.96.0.0/12)
- `skip_worker_taint`: Allow control plane to run workloads (default: true)
- `join_command`: Pre-generated join command (optional)

**Post-Start:**
After starting the cluster, deploy one of this repository's CNI workflows to
make nodes Ready. Use the `cni-deploy.yaml` playbook with a supported
`deploy_cni` value (`flannel-ipoib`, `multus-ipoib`, or `rdma-shared-device`):
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cni-deploy.yaml \
  -e deploy_cni=flannel-ipoib \
  -e ipoib_interface=<ipoib_iface>
```
See the [deployment guides](../deployment/) for the full options of each
workflow.

### 5. Check Cluster Status

Verify cluster health and node status.

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=status
```

**What it shows:**
- Node type (Control Plane or Worker)
- Kubelet service status
- Cluster membership status
- Cluster info (from control plane)
- All nodes’ status (from control plane)

### 6. Stop Cluster

Gracefully stop cluster nodes.

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=stop
```

**What it does:**
- **Workers First**: Drain pods from worker nodes
- **Workers First**: Optionally delete workers from cluster
- **Workers First**: Stop kubelet and containerd
- **Control Plane Last**: Drain control plane node
- **Control Plane Last**: Stop control plane components (kube-apiserver, etcd, etc.)
- **Control Plane Last**: Stop kubelet and containerd

**Options:**
- `drain_before_stop`: Drain nodes before stopping (default: true)
- `delete_worker_on_stop`: Remove workers from cluster (default: false)
- `force_stop`: Force stop without confirmation (default: false)

### 7. Restart Cluster

Stop and start cluster in one operation.

```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=restart
```

---

## Ansible Playbooks

### node-management.yaml

Manages node lifecycle: clean, setup, and precheck operations.

**Location:** `automation/playbooks/node-management.yaml`

**Operations:**
- `clean`: Remove all Kubernetes components
- `setup`: Install and configure prerequisites
- `check`: Validate node readiness

**Task Files:**
- `tasks/clean-node.yaml`: Cleanup tasks
- `tasks/setup-node.yaml`: Setup tasks
- `tasks/check-prerequisites.yaml`: Validation tasks

### cluster-control.yaml

Manages cluster operations: start, stop, status, and restart.

**Location:** `automation/playbooks/cluster-control.yaml`

**Operations:**
- `start`: Initialize control plane and join workers
- `stop`: Gracefully stop all nodes
- `status`: Check cluster health
- `restart`: Stop and start cluster

**Task Files:**
- `tasks/cluster-start.yaml`: Start tasks
- `tasks/cluster-stop.yaml`: Stop tasks
- `tasks/cluster-status.yaml`: Status check tasks

---

## Inventory Configuration

### File Location

`automation/inventory/hosts.yaml`

### Structure

```yaml
all:
  children:
    control_plane:
      hosts:
        node1:
          ansible_host: node1
          ansible_user: root
          ansible_password: <password>
          ansible_python_interpreter: /usr/bin/python3

    workers:
      hosts:
        node2:
          ansible_host: node2
          ansible_user: root
          ansible_password: <password>
          ansible_python_interpreter: /usr/bin/python3
          platform: auto

    # k8s_nodes is a group-of-groups containing every node
    # (control_plane + workers). A group may have only one `children:` key,
    # whose value is a mapping of child group names (not a YAML list).
    k8s_nodes:
      children:
        control_plane:
        workers:

  vars:
    k8s_version: "1.28.5"
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
```

### Host Groups

- **control_plane**: Control plane nodes (typically 1 or 3 for HA)
- **workers**: Worker nodes (1 or more)
- **k8s_nodes**: All nodes (control_plane + workers)

### Variables

- `ansible_host`: Hostname or IP address
- `ansible_user`: SSH user (typically root)
- `ansible_password`: SSH password (use vault in production)
- `ansible_python_interpreter`: Python interpreter path
- `k8s_version`: Kubernetes version to install
- `platform`: Hardware platform (cn5000|auto)

---

## Common Operations

### Complete Cluster Setup (Fresh Install)

```bash
# 1. Clean nodes (if previously configured)
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=clean

# 2. Setup prerequisites
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=setup

# 3. Validate readiness
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=check

# 4. Start cluster
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start

# 5. Deploy CNI plugin (choose one workflow: flannel-ipoib | multus-ipoib | rdma-shared-device)
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cni-deploy.yaml \
  -e deploy_cni=flannel-ipoib \
  -e ipoib_interface=<ipoib_iface>

# 6. Verify cluster
kubectl get nodes
kubectl get pods --all-namespaces
```

### Add New Worker Node

```bash
# 1. Add node to inventory under 'workers' group

# 2. Setup the new node
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=setup \
  --limit node3

# 3. Get join command from control plane
ssh root@node1 "kubeadm token create --print-join-command"

# 4. Join the worker (manual or via Ansible)
ssh root@node3 "kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"

# 5. Verify
kubectl get nodes
```

### Remove Worker Node

```bash
# 1. Drain the node
kubectl drain node3 --ignore-daemonsets --delete-emptydir-data

# 2. Delete from cluster
kubectl delete node node3

# 3. Clean the node
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=clean \
  --limit node3

# 4. Remove from inventory
```

### Upgrade Kubernetes Version

```bash
# 1. Update k8s_version in inventory

# 2. Upgrade control plane
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=setup \
  -e k8s_version=1.29.0 \
  --limit control_plane

# 3. Upgrade workers one by one
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/node-management.yaml \
  -e operation=setup \
  -e k8s_version=1.29.0 \
  --limit node2
```

### Control Plane as Worker (Default)

By default, the control plane is configured to run workloads (taint removed). To change this:

```bash
# Dedicated control plane (no workloads)
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start \
  -e skip_worker_taint=false

# Allow workloads on existing control plane
kubectl taint nodes node1 node-role.kubernetes.io/control-plane-
```

---

## Troubleshooting

### Issue: Node Fails Precheck

**Symptom:** Precheck operation reports failures

**Solutions:**
1. Review failed checks in output
2. Re-run setup operation:
   ```bash
   ansible-playbook -i automation/inventory/hosts.yaml \
     automation/playbooks/node-management.yaml \
     -e operation=setup
   ```
3. Check logs on target node:
   ```bash
   journalctl -u kubelet -f
   journalctl -u containerd -f
   ```

### Issue: Control Plane Fails to Start

**Symptom:** `kubeadm init` fails or times out

**Solutions:**
1. Check if kubelet is already running:
   ```bash
   systemctl status kubelet
   ```
2. Verify network configuration:
   ```bash
   ip addr show
   ip route show
   ```
3. Check firewall rules:
   ```bash
   firewall-cmd --list-all
   ```
4. Review kubeadm logs:
   ```bash
   journalctl -u kubelet -f
   cat /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log
   ```
5. Clean and retry:
   ```bash
   ansible-playbook -i automation/inventory/hosts.yaml \
     automation/playbooks/node-management.yaml \
     -e operation=clean
   ```

### Issue: Worker Fails to Join

**Symptom:** Worker node cannot join cluster

**Solutions:**
1. Verify control plane is accessible:
   ```bash
   telnet <control-plane-ip> 6443
   ```
2. Check token validity (on control plane):
   ```bash
   kubeadm token list
   ```
3. Generate new join command:
   ```bash
   kubeadm token create --print-join-command
   ```
4. Verify CA cert hash:
   ```bash
   openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
   openssl rsa -pubin -outform der 2>/dev/null | \
   openssl dgst -sha256 -hex | sed 's/^.* //'
   ```

### Issue: Nodes Show NotReady

**Symptom:** `kubectl get nodes` shows NotReady status

**Solutions:**
1. Deploy a CNI workflow (if not already deployed) via `cni-deploy.yaml`,
   choosing `deploy_cni=flannel-ipoib`, `multus-ipoib`, or `rdma-shared-device`:
   ```bash
   ansible-playbook -i automation/inventory/hosts.yaml \
     automation/playbooks/cni-deploy.yaml \
     -e deploy_cni=flannel-ipoib \
     -e ipoib_interface=<ipoib_iface>
   ```
2. Check CNI pod status:
   ```bash
   kubectl get pods -n kube-system
   ```
3. Verify network connectivity between nodes:
   ```bash
   ping <other-node-ip>
   ```

### Issue: Ansible Connection Failures

**Symptom:** Ansible cannot connect to nodes

**Solutions:**
1. Test SSH connectivity:
   ```bash
   ssh root@node1
   ```
2. Verify inventory credentials:
   ```bash
   ansible -i automation/inventory/hosts.yaml all -m ping
   ```
3. Check SSH key or password authentication
4. Clear SSH known_hosts if needed:
   ```bash
   ssh-keygen -R node1
   ```

### Issue: Clean Operation Fails

**Symptom:** Clean operation reports errors

**Solutions:**
1. Run with force (manual):
   ```bash
   ssh root@node1 "kubeadm reset --force"
   ```
2. Manually stop services:
   ```bash
   systemctl stop kubelet containerd
   ```
3. Check for stuck processes:
   ```bash
   ps aux | grep kube
   pkill -9 kubelet
   ```

---

## Script Reference

The Ansible playbooks orchestrate shell scripts that perform the actual node operations. Understanding these scripts helps with troubleshooting and customization.

### Core Scripts

#### setup-node.sh

**Location:** `automation/scripts/setup-node.sh`

**Purpose:** Install and configure all Kubernetes prerequisites on a node.

**Key Functions:**
- Detects OS distribution (RHEL/CentOS/Ubuntu) via `lib/package-manager.sh`
- Installs Kubernetes packages (kubelet, kubeadm, kubectl)
- Installs and configures containerd with SystemdCgroup
- Installs dependencies (curl, wget, socat, conntrack, ipset, iptables)
- Disables swap permanently (removes swap entries from /etc/fstab)
- Loads kernel modules (br_netfilter, overlay) and makes persistent
- Configures sysctl parameters for Kubernetes networking
- Configures firewall rules for kubelet and NodePort services
- Enables and starts kubelet and containerd services

**Usage:**
```bash
./setup-node.sh [--k8s-version VERSION] [--yes]
```

**Called by:** `tasks/setup-node.yaml`

#### clean-node.sh

**Location:** `automation/scripts/clean-node.sh`

**Purpose:** Remove all Kubernetes components and configurations from a node.

**Key Functions:**
- Creates backup of current state in `/var/log/k8s-cleanup-<timestamp>`
- Stops kubelet and containerd services
- Kills all Kubernetes processes (kubelet, kube-apiserver, controller-manager, scheduler, proxy, etcd)
- Runs `kubeadm reset --force` to clean cluster state
- Removes network configurations (iptables rules, CNI configs)
- Removes Kubernetes packages (kubelet, kubeadm, kubectl, containerd)
- Cleans directories (/etc/kubernetes, /var/lib/kubelet, /var/lib/etcd, /etc/cni)
- Cleans kubepods cgroups
- Reloads systemd daemon

**Usage:**
```bash
./clean-node.sh [--yes] [--dry-run] [--preserve-images]
```

**Called by:** `tasks/clean-node.yaml`

#### start-control-plane.sh

**Location:** `automation/scripts/start-control-plane.sh`

**Purpose:** Initialize Kubernetes control plane and optionally configure as worker.

**Key Functions:**
- Checks if cluster is already initialized
- Runs `kubeadm init` with specified network CIDRs
- Configures kubeconfig for root user in `/root/.kube/config`
- Configures kubeconfig for sudo user if applicable
- Optionally removes control-plane taint to allow workload scheduling
- Saves join command to `/tmp/kubeadm-init.log`
- Displays cluster info and node status

**Usage:**
```bash
./start-control-plane.sh [OPTIONS]
  --pod-network-cidr CIDR
  --service-cidr CIDR
  --apiserver-advertise-address IP
  --control-plane-endpoint ENDPOINT
  --skip-worker-taint | --no-skip-worker-taint
```

**Called by:** `tasks/cluster-start.yaml`

#### start-worker.sh

**Location:** `automation/scripts/start-worker.sh`

**Purpose:** Join a worker node to an existing Kubernetes cluster.

**Key Functions:**
- Checks if node is already part of a cluster
- Accepts join command or individual parameters (endpoint, token, CA cert hash)
- Runs `kubeadm join` with provided credentials
- Verifies successful join

**Usage:**
```bash
./start-worker.sh [OPTIONS]
  --join-command "COMMAND"
  OR
  --control-plane-endpoint HOST:PORT --token TOKEN --ca-cert-hash HASH
```

**Called by:** `tasks/cluster-start.yaml`

#### stop-node.sh

**Location:** `automation/scripts/stop-node.sh`

**Purpose:** Gracefully stop a Kubernetes node (control plane or worker).

**Key Functions:**
- Detects node type (control plane or worker)
- Optionally drains node before stopping (graceful pod termination)
- Optionally deletes worker node from cluster
- Stops kubelet service
- Stops containerd service
- For control plane: stops all control plane components (kube-apiserver, kube-controller-manager, kube-scheduler, etcd)
- Cleans up running containers via crictl

**Usage:**
```bash
./stop-node.sh [OPTIONS]
  --drain | --no-drain
  --delete (for workers)
  --force
```

**Called by:** `tasks/cluster-stop.yaml`

### Supporting Libraries

#### lib/package-manager.sh

**Location:** `automation/scripts/lib/package-manager.sh`

**Purpose:** Provide OS-agnostic package management functions.

**Key Functions:**
- `detect_os()`: Detect OS distribution (RHEL/CentOS/Ubuntu/Debian)
- `install_package()`: Install package using appropriate package manager
- `remove_package()`: Remove package using appropriate package manager
- `update_package_cache()`: Update package manager cache
- `add_repository()`: Add package repository (Kubernetes, Docker)

**Used by:** All node management scripts

### Script Integration Flow

```
Ansible Playbook
    ↓
Task File (YAML)
    ↓
Copy Scripts to /tmp on Target Node
    ↓
Execute Script with Parameters
    ↓
Script Sources lib/package-manager.sh
    ↓
Script Performs Operations
    ↓
Return Output to Ansible
    ↓
Display Results to User
```

### Script Design Principles

1. **Idempotency**: Scripts can be run multiple times safely
2. **Error Handling**: Exit on error with meaningful messages
3. **Logging**: All operations logged to stdout/stderr
4. **Backup**: Critical operations create backups before changes
5. **Validation**: Check prerequisites before executing operations
6. **OS Agnostic**: Support multiple Linux distributions via abstraction layer
7. **Modularity**: Reusable functions in shared libraries

### Customization Points

To customize the automation for your environment:

1. **Kubernetes Version**: Modify `k8s_version` in inventory or pass as parameter
2. **Network CIDRs**: Adjust `pod_network_cidr` and `service_cidr` variables
3. **Control Plane Behavior**: Set `skip_worker_taint` to control workload scheduling
4. **Firewall Rules**: Edit firewall configuration in `setup-node.sh`
5. **Package Sources**: Modify repository URLs in `lib/package-manager.sh`
6. **Platform-Specific Settings**: Add platform detection and configuration in scripts

---

## Summary

This Ansible-based workflow provides a complete, automated solution for Kubernetes cluster lifecycle management. The hierarchical approach (Clean → Setup → Precheck → Start → Operations → Stop) ensures consistent, repeatable deployments across the CN Fabric environment.

**Key Benefits:**
- ✓ Automated multi-node operations
- ✓ Consistent configuration across nodes
- ✓ Built-in validation and error checking
- ✓ Graceful cluster start/stop procedures
- ✓ Support for multiple hardware platforms
- ✓ Idempotent operations (safe to re-run)
- ✓ Comprehensive logging and troubleshooting

For additional support, refer to the Kubernetes documentation at https://kubernetes.io/docs/ or the Cornelis Networks documentation.
