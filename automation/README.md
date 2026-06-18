# Automation

Ansible playbooks and scripts for CN Fabric Kubernetes cluster automation.

## Documentation

For detailed documentation on cluster automation, see:

**[docs/operations/ansible-guide.md](../docs/operations/ansible-guide.md)**

## Quick Reference

### Prepare Nodes (Step 1)

Installs Kubernetes prerequisites and CNI binaries on all nodes:

```bash
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml -e "operation=setup" --ask-pass
```

**CNI Binaries Installed:**
- `cn-ipoib-cni` - Built from source on each node
- `multus` - Downloaded from GitHub (v4.0.2)
- `flannel` - Downloaded from GitHub (v1.2.0)
- `host-local` - IPAM plugin from Flannel release

**Optional Parameters:**
- `--cleanup-build-deps` - Remove Go toolchain after build (saves ~500MB disk space)
- `go_version` - Go version to install (default: 1.21.5)
- `multus_version` - Multus version to install (default: v4.0.2)
- `flannel_version` - Flannel version to install (default: v1.2.0)

### Start Cluster

```bash
cd automation/playbooks
ansible-playbook cluster-start.yaml
```

### Stop Cluster

```bash
cd automation/playbooks
ansible-playbook cluster-stop.yaml
```

### Available CNI Options

- `deploy_cni=flannel-ipoib` - Flannel VXLAN over IPoIB
- `deploy_cni=multus-ipoib` - Multus + IPoIB dual-interface

**Note:** CNI binaries are installed during node setup (Step 1). CNI deployment (Step 3) only configures the CNI, it does not install binaries.

See [docs/operations/ansible-guide.md](../docs/operations/ansible-guide.md) for complete documentation.
