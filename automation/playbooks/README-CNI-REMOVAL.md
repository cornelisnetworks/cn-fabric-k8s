# CNI Removal Guide

This guide explains how to remove all CNI components (Multus, IPoIB, Whereabouts, and Flannel) from your Kubernetes cluster.

## Overview

The CNI removal automation provides two methods:

1. **Standalone Bash Script** - For manual execution or scripting
2. **Ansible Playbook** - For automated, idempotent execution

Both methods perform the same operations:
- Remove Kubernetes resources (DaemonSets, ConfigMaps, RBAC, CRDs)
- Clean node-level files (CNI binaries, configs, data directories)
- Verify complete removal
- Create backup before removal

## ⚠️ Important Warnings

**After CNI removal:**
- All nodes will become **NotReady** (no CNI available)
- All pods will lose network connectivity
- New pods cannot be scheduled
- Cluster control plane remains functional
- You can deploy a new CNI to restore networking

**What gets removed:**
- ✓ Multus CNI (meta-plugin)
- ✓ IPoIB CNI (cn-ipoib-cni)
- ✓ Whereabouts IPAM
- ✓ Flannel CNI (primary network)
- ✓ All related Kubernetes resources
- ✓ All CNI binaries and configurations on nodes

## Method 1: Standalone Bash Script

### Location
```
automation/scripts/remove-cni.sh
```

### Prerequisites
- Root access on control plane node
- `kubectl` configured with cluster access
- SSH access to all cluster nodes (passwordless recommended)

### Usage

**Dry-run (preview changes without making them):**
```bash
sudo ./automation/scripts/remove-cni.sh --dry-run
```

**Remove all CNI components (with confirmation prompt):**
```bash
sudo ./automation/scripts/remove-cni.sh
```

**Remove all CNI components (skip confirmation):**
```bash
sudo ./automation/scripts/remove-cni.sh --yes
```

**Show help:**
```bash
./automation/scripts/remove-cni.sh --help
```

### Script Options

| Option | Description |
|--------|-------------|
| `--yes`, `-y` | Skip confirmation prompts |
| `--dry-run` | Show what would be removed without making changes |
| `--help`, `-h` | Show help message |

### Example Output

```
=== CNI Removal Plan ===
Remove Multus: yes
Remove IPoIB CNI: yes
Remove Whereabouts: yes
Remove Flannel: yes

WARNING: After removal, nodes will become NotReady (no CNI available)

Continue? (yes/no): yes

Creating backup directory: /tmp/cni-removal-backup-20260411-123456
Backing up current CNI configurations...
✓ Backup created

=== Phase 1: Removing Kubernetes Resources ===

Removing DaemonSets...
✓ Deleted DaemonSet: kube-multus-ds
✓ Deleted DaemonSet: ipoib-cni
✓ Deleted DaemonSet: whereabouts
✓ Deleted DaemonSet: kube-flannel-ds

Removing NetworkAttachmentDefinitions...
✓ Deleted NetworkAttachmentDefinitions

Removing ConfigMaps...
✓ Deleted ConfigMap: multus-daemon-config
✓ Deleted ConfigMap: multus-default-networks
✓ Deleted ConfigMap: kube-flannel-cfg

... (more output)

=== Phase 2: Cleaning Node-Level Files ===

Found nodes: control-plane worker
Cleaning files on node: control-plane
✓ Cleaned files on node: control-plane
Cleaning files on node: worker
✓ Cleaned files on node: worker

=== Phase 3: Verification ===

Checking for remaining CNI pods...
✓ No remaining CNI pods found

Checking for stale IPoIB interfaces on nodes...
✓ No stale IPoIB interfaces on node: control-plane
✓ No stale IPoIB interfaces on node: worker

=== CNI Removal Complete ===

✓ Backup saved to: /tmp/cni-removal-backup-20260411-123456

Summary:
  ✓ Removed Multus CNI
  ✓ Removed IPoIB CNI (cn-ipoib-cni)
  ✓ Removed Whereabouts IPAM
  ✓ Removed Flannel CNI

⚠ Nodes are now NotReady (no CNI available)

Next steps:
  1. Deploy a new CNI if needed
  2. Or leave cluster without networking
  3. Review backup in: /tmp/cni-removal-backup-20260411-123456
```

## Method 2: Ansible Playbook

### Location
```
automation/playbooks/cni-remove.yaml
automation/playbooks/tasks/remove-cni-multus-ipoib.yaml
```

### Prerequisites
- Ansible installed on control machine
- Inventory file configured (`automation/inventory/hosts.yaml`)
- SSH access to all nodes
- `kubectl` configured on control plane node

### Usage

**Dry-run (preview changes without making them):**
```bash
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml \
  -e "dry_run_mode=true"
```

**Remove all CNI components (with confirmation prompt):**
```bash
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml
```

**Remove all CNI components (skip confirmation):**
```bash
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml \
  -e "skip_confirmation=true"
```

**Dry-run with skip confirmation:**
```bash
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml \
  -e "dry_run_mode=true" \
  -e "skip_confirmation=true"
```

### Playbook Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `dry_run_mode` | `false` | Set to `true` for dry-run (no changes) |
| `skip_confirmation` | `false` | Set to `true` to skip confirmation prompts |

### Example Playbook Output

```
PLAY [Remove CNI Components from Kubernetes Cluster] ***************************

TASK [Display removal plan] ****************************************************
ok: [control-plane] => {
    "msg": [
        "=== CNI Removal Plan ===",
        "Remove Multus: yes",
        "Remove IPoIB CNI: yes",
        "Remove Whereabouts: yes",
        "Remove Flannel: yes",
        "Dry Run Mode: false",
        "",
        "WARNING: After removal, nodes will become NotReady (no CNI available)"
    ]
}

TASK [Confirm removal (unless skip_confirmation=true)] *************************
[Confirm removal (unless skip_confirmation=true)]
This will remove ALL CNI components from the cluster. Continue? (yes/no):
yes

TASK [Check if cluster is accessible] ******************************************
ok: [control-plane]

TASK [Remove CNI components] ***************************************************
included: /root/cn-fabric-k8s/automation/playbooks/tasks/remove-cni-multus-ipoib.yaml

... (detailed task output)

PLAY RECAP *********************************************************************
control-plane              : ok=XX   changed=XX   unreachable=0    failed=0
worker                     : ok=XX   changed=XX   unreachable=0    failed=0
```

## Backup Location

Both methods create a timestamped backup directory in `/tmp/`:

```
/tmp/cni-removal-backup-YYYYMMDD-HHMMSS/
├── daemonsets-backup.yaml
├── configmaps-backup.yaml
├── network-attachment-definitions-backup.yaml
└── crd-backup.yaml
```

**Backup contents:**
- All DaemonSets from kube-system namespace
- All ConfigMaps from kube-system namespace
- All NetworkAttachmentDefinitions
- NetworkAttachmentDefinition CRD

**Backup retention:**
- Backups are stored in `/tmp/` and may be cleaned up on reboot
- Copy backups to a permanent location if needed for long-term retention

## Verification Steps

After removal, verify the cleanup:

**1. Check for remaining CNI pods:**
```bash
kubectl get pods -A | grep -E 'multus|ipoib|whereabouts|flannel'
```
Expected: No output (all CNI pods removed)

**2. Check node status:**
```bash
kubectl get nodes
```
Expected: All nodes show `NotReady` status

**3. Check for stale IPoIB interfaces on nodes:**
```bash
# On each node
ip link show | grep -E '@ib[a-z]*[0-9]+'
```
Expected: No output (no stale interfaces)

**4. Check CNI binaries removed:**
```bash
# On each node
ls -la /opt/cni/bin/ | grep -E 'multus|ipoib|whereabouts|flannel'
ls -la /hostroot/opt/cni/bin/ | grep -E 'multus|ipoib|whereabouts|flannel'
```
Expected: No output (binaries removed)

**5. Check CNI configs removed:**
```bash
# On each node
ls -la /etc/cni/net.d/
```
Expected: Directory empty or only contains non-CNI files

## Troubleshooting

### Issue: Script fails with "kubectl not found"
**Solution:** Install kubectl or run from a node with kubectl installed

### Issue: Script fails with "Cannot connect to Kubernetes cluster"
**Solution:** Ensure kubeconfig is properly configured:
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl cluster-info
```

### Issue: SSH connection fails to nodes
**Solution:** 
- Ensure SSH keys are set up for passwordless access
- Or manually run cleanup commands on each node

### Issue: Some resources show "not found" warnings
**Solution:** This is normal - resources may have been already removed or never existed. The script continues with warnings.

### Issue: Pods still exist after removal
**Solution:** 
- Wait a few minutes for Kubernetes to terminate pods
- Force delete stuck pods:
  ```bash
  kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0
  ```

### Issue: Stale IPoIB interfaces remain
**Solution:**
- Reload the ib_ipoib kernel module:
  ```bash
  # On each node
  rmmod ib_ipoib
  modprobe ib_ipoib
  ```

## Restoring Networking

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
- Examples: Calico, Cilium, Weave, etc.

**Option 3: Leave cluster without CNI**
- Cluster control plane remains functional
- Useful for maintenance or testing scenarios

## Integration with Existing Workflows

### Use in CI/CD pipelines
```bash
# Example: Clean up test cluster
ansible-playbook automation/playbooks/cni-remove.yaml \
  -i automation/inventory/hosts.yaml \
  -e "skip_confirmation=true"
```

### Use in cluster reset workflow
```bash
# 1. Remove CNI
./automation/scripts/remove-cni.sh --yes

# 2. Stop cluster
ansible-playbook automation/playbooks/cluster-control.yaml \
  -i automation/inventory/hosts.yaml \
  -e "operation=stop"

# 3. Clean cluster
ansible-playbook automation/playbooks/node-management.yaml \
  -i automation/inventory/hosts.yaml \
  -e "operation=clean"
```

## Safety Features

Both methods include safety features:

1. **Confirmation prompts** - Prevents accidental removal (can be skipped with `--yes` or `skip_confirmation=true`)
2. **Dry-run mode** - Preview changes before making them
3. **Backup creation** - Automatic backup of all configurations before removal
4. **Graceful error handling** - Continues on missing resources with warnings
5. **Verification steps** - Confirms complete removal
6. **Idempotent** - Safe to run multiple times

## Files Created/Modified

**New files:**
- `automation/scripts/remove-cni.sh` - Standalone removal script
- `automation/playbooks/cni-remove.yaml` - Main Ansible playbook
- `automation/playbooks/tasks/remove-cni-multus-ipoib.yaml` - Ansible task file
- `automation/playbooks/README-CNI-REMOVAL.md` - This documentation

**No existing files modified**

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review backup files in `/tmp/cni-removal-backup-*/`
3. Check Kubernetes logs: `kubectl logs -n kube-system <pod-name>`
4. Check node logs: `journalctl -u kubelet -f`

## See Also

- [CNI Deployment Guide](../../docs/deployment/multus-ipoib-cni.md)
- [Cluster Management Guide](../../docs/operations/cluster-management.md)
- [Node Management Playbook](./node-management.yaml)
- [Cluster Control Playbook](./cluster-control.yaml)
