# Kubernetes Cluster Control Automation

Automation scripts and Ansible playbooks for starting, stopping, and managing Kubernetes cluster nodes.

## Scripts

### start-control-plane.sh
Initializes and starts a Kubernetes control plane node. By default, the control plane is also configured as a worker node (taint removed).

**Usage:**
```bash
./automation/scripts/start-control-plane.sh [OPTIONS]

OPTIONS:
  --pod-network-cidr CIDR              Pod network CIDR (default: 10.244.0.0/16)
  --service-cidr CIDR                  Service CIDR (default: 10.96.0.0/12)
  --apiserver-advertise-address IP     API server advertise address
  --control-plane-endpoint ENDPOINT    Control plane endpoint for HA
  --skip-worker-taint                  Allow control plane to run workloads (default)
  --no-skip-worker-taint               Prevent control plane from running workloads
```

**Examples:**
```bash
./automation/scripts/start-control-plane.sh
./automation/scripts/start-control-plane.sh --apiserver-advertise-address 192.168.1.10
./automation/scripts/start-control-plane.sh --no-skip-worker-taint
```

### start-worker.sh
Joins a worker node to an existing Kubernetes cluster.

**Usage:**
```bash
./automation/scripts/start-worker.sh [OPTIONS]

OPTIONS:
  --join-command "COMMAND"             Full kubeadm join command (quoted)
  --control-plane-endpoint HOST:PORT   Control plane endpoint
  --token TOKEN                        Bootstrap token
  --ca-cert-hash HASH                  CA certificate hash (sha256:...)
```

**Examples:**
```bash
./automation/scripts/start-worker.sh --join-command "kubeadm join 192.168.1.10:6443 --token abc123..."
./automation/scripts/start-worker.sh --control-plane-endpoint 192.168.1.10:6443 --token abc123 --ca-cert-hash sha256:xyz...
```

**Get join command from control plane:**
```bash
kubeadm token create --print-join-command
```

### stop-node.sh
Stops a Kubernetes node (control plane or worker). Supports graceful drain and node deletion.

**Usage:**
```bash
./automation/scripts/stop-node.sh [OPTIONS]

OPTIONS:
  --drain                  Drain node before stopping (default)
  --no-drain               Skip draining node
  --delete                 Delete node from cluster (for workers)
  --force                  Force stop without confirmation
```

**Examples:**
```bash
./automation/scripts/stop-node.sh
./automation/scripts/stop-node.sh --no-drain
./automation/scripts/stop-node.sh --delete
```

## Ansible Playbook

### cluster-control.yaml
Main playbook for cluster-wide start/stop/status operations.

**Usage:**
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=<start|stop|status|restart>
```

**Variables:**
- `operation`: Operation to perform (start, stop, status, restart) - **REQUIRED**
- `pod_network_cidr`: Pod network CIDR (default: 10.244.0.0/16)
- `service_cidr`: Service CIDR (default: 10.96.0.0/12)
- `skip_worker_taint`: Allow control plane to run workloads (default: true)
- `drain_before_stop`: Drain nodes before stopping (default: true)
- `delete_worker_on_stop`: Delete workers from cluster on stop (default: false)
- `force_stop`: Force stop without confirmation (default: false)
- `join_command`: Pre-generated join command (optional)

**Examples:**

Start the cluster:
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start
```

Start with control plane dedicated (no workloads):
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=start \
  -e skip_worker_taint=false
```

Stop the cluster gracefully:
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=stop
```

Stop and remove workers from cluster:
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=stop \
  -e delete_worker_on_stop=true
```

Check cluster status:
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=status
```

Restart the cluster:
```bash
ansible-playbook -i automation/inventory/hosts.yaml \
  automation/playbooks/cluster-control.yaml \
  -e operation=restart
```

## Workflow

### Starting a Cluster

1. **Control plane starts first** - Initializes the cluster and generates join token
2. **Workers join** - Use the join command from control plane to join workers
3. **Verification** - Check cluster status with `kubectl get nodes`

### Stopping a Cluster

1. **Workers stop first** - Gracefully drain and stop worker nodes
2. **Control plane stops last** - Stop control plane components
3. **Optional cleanup** - Use `--delete` to remove workers from cluster

## Prerequisites

Before using these scripts, ensure nodes are set up with:
- kubelet, kubeadm, kubectl installed
- Container runtime (containerd) configured
- Required kernel modules and sysctl settings
- Network connectivity between nodes

Use the existing `setup-node.sh` script or `node-management.yaml` playbook with `operation=setup` to prepare nodes.

## Integration with Existing Automation

These scripts integrate with the existing automation framework:
- Use the same `lib/package-manager.sh` library
- Follow the same directory structure
- Compatible with existing inventory (`automation/inventory/hosts.yaml`)
- Can be combined with `node-management.yaml` for full lifecycle management

## Troubleshooting

**Control plane fails to start:**
- Check if kubelet is already running: `systemctl status kubelet`
- Verify network configuration and firewall rules
- Check logs: `journalctl -u kubelet -f`

**Worker fails to join:**
- Verify control plane is accessible from worker
- Check token validity: `kubeadm token list` (on control plane)
- Ensure CA cert hash is correct

**Node fails to stop gracefully:**
- Use `--no-drain` to skip draining
- Use `--force` to force stop
- Check for stuck pods: `kubectl get pods --all-namespaces`
