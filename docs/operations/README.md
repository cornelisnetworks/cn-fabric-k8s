# Operations and Management

Documentation for day-to-day operations, maintenance, and troubleshooting of
CN Fabric Kubernetes clusters on the CN5000 platform.

This page is a thin index. The canonical end-to-end workflow (the 6-step
prepare → deploy → CNI → verify → status → stop sequence) and the full quick-start
command reference live in the top-level [docs/README.md](../README.md). The
guides below cover the operational detail behind those steps.

## Operations Guides

| Guide | Description |
|-------|-------------|
| [cluster-management.md](cluster-management.md) | Kubernetes cluster lifecycle management, node operations, upgrades, backup/restore |
| [ansible-guide.md](ansible-guide.md) | Ansible playbooks and scripts for automated cluster start/stop/management |
| [cni-binary-installation.md](cni-binary-installation.md) | CNI binary and device-plugin container image installation (Step 1, node preparation) |
| [troubleshooting.md](troubleshooting.md) | Node prerequisites troubleshooting, common issues, and diagnostic procedures |

## Supported CNI Workflows

This repository supports three CNI workflows on CN5000, selected via the Ansible
`deploy_cni=...` value when running
[`automation/playbooks/cni-deploy.yaml`](../../automation/playbooks/cni-deploy.yaml)
(or `cluster-control.yaml` with `operation=start`):

| `deploy_cni` value | Workflow | Deployment guide |
|--------------------|----------|------------------|
| `flannel-ipoib` | Flannel VXLAN over IPoIB | [deployment/flannel-ipoib-cni.md](../deployment/flannel-ipoib-cni.md) |
| `multus-ipoib` | Multus + IPoIB dual-interface | [deployment/multus-ipoib-cni.md](../deployment/multus-ipoib-cni.md) |
| `rdma-shared-device` | RDMA shared device plugin (`cornelis.com/hfi`) | [deployment/rdma-cdi-device-plugin.md](../deployment/rdma-cdi-device-plugin.md) |

## Common Operational Tasks

| Task | Where it is documented |
|------|------------------------|
| Adding / removing a worker node | [cluster-management.md](cluster-management.md) |
| Upgrading Kubernetes | [cluster-management.md](cluster-management.md) |
| Backup and restore | [cluster-management.md](cluster-management.md) |
| Diagnosing network / CNI issues | [troubleshooting.md](troubleshooting.md) |
| RDMA device-plugin issues | [troubleshooting.md](troubleshooting.md) |

## Related Documentation

- [Top-level documentation index](../README.md) — architecture overview and full quick-start workflow
- [Deployment Guides](../deployment/) — initial deployment for each CNI workflow
- [Testing Documentation](../testing/) — verification scripts and expected results
