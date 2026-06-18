# cn-fabric-k8s Release Notes

## v1.0.0

**Release date:** 2026-06-16
**Supported hardware:** Cornelis Networks CN5000 (switched fabric)

`cn-fabric-k8s` is the integration hub for Cornelis Networks fabric hardware
with Kubernetes. This is the inaugural (v1.0.0) release: it delivers
production-ready Kubernetes manifests and deployment automation for running
RDMA, IPoIB, and OPX workloads on Cornelis CN5000 hardware.

---

### Supported Hardware

| Platform | Fabric | Networking | Driver | Status in v1.0.0 |
|----------|--------|------------|--------|------------------|
| **CN5000** | InfiniBand | IPoIB, RDMA | `hfi1` | **Supported** |

---

### Supported Operating Systems

v1.0.0 supports **SLES 15.7 and SLES 16.0 only**.

| Operating System | Status | Notes |
|------------------|--------|-------|
| **SLES 15.7** | **Supported** | OPXS kmod 338 |
| **SLES 16.0** | **Supported** | OPXS kmod 355; containerd 1.7.x requires `enable_cdi=true` |

The deployment automation is distribution-independent (it selects the package
manager from `/etc/os-release`, supporting `apt`, `dnf`/`yum`, and `zypper`), but
only SLES 15.7 and SLES 16.0 are supported in this release.

---

### Supported Orchestrators

| Orchestrator | Status | Notes |
|--------------|--------|-------|
| **kubeadm** | **Validated (reference)** | Full pass across all functional areas on both validated operating systems. K8s 1.28.5 → 1.29.15. |
| **RKE2** | **Sample / partial** | K8s v1.35.5+rke2r2. CNI and RDMA workflows operate; Multus IPoIB has known gaps on RKE2. Manifests are provided as samples for RKE2 and may require per-cluster adaptation. |

kubeadm is the validated reference deployment path. RKE2 is supported on a
best-effort, sample-manifest basis; customers adapt the provided manifests to
their cluster's pod CIDR and runtime layout.

---

### Features

This release delivers three Kubernetes CNI workflows plus an RDMA device plugin
for the CN5000 platform:

| Feature | Description |
|---------|-------------|
| **Flannel IPoIB CNI** (`flannel-ipoib`) | Single-interface Flannel VXLAN over IPoIB. ~10 µs UDP latency. |
| **Multus IPoIB CNI** (`multus-ipoib`) | Dual-interface: Flannel host-gw (control plane) + a native IPoIB data plane provided by the Cornelis `cn-ipoib-cni` plugin. ~10 µs UDP / sub-µs MPI barrier. |
| **RDMA CDI Device Plugin** (`rdma-shared-device`) | Single-interface Flannel plus the `cornelis.com/hfi` schedulable device resource for userspace RDMA verbs and the OPX libfabric provider. ~6 µs OFI verbs latency. |
| **OPX libfabric provider** | OPX provider available inside RDMA CDI pods; MPI over OPX, context sharing under pod density. |

---

### Limitations

- **Bulk Transfer Service (BTS) is not supported in v1.0.0.** Running workloads
  with the Bulk Transfer service enabled is not supported.
- **SR-IOV is not supported in v1.0.0.**

---

### Component Versions

| Component | Version |
|-----------|---------|
| Kubernetes | 1.28+ (validated 1.28.5 → 1.29.15 on kubeadm; v1.35.5+rke2r2 on RKE2) |
| Flannel | v0.28.1 |
| Flannel CNI plugin | v1.9.0-flannel1 |
| Multus CNI | v4.0.2 |
| Whereabouts IPAM | v0.8.0 |
| Cornelis IPoIB CNI | bundled (`cn-ipoib-cni`, forked from Mellanox `ipoib-cni` v1.2.2) |
| Cornelis RDMA shared device plugin | bundled (`cn-rdma-shared-dev-plugin`, forked from Mellanox `k8s-rdma-shared-dev-plugin` v1.5.3) |
| Base image | alpine:3.18 |
| Userspace | Cornelis libfabric (`opx` provider), UCX, Open MPI 4.1.x |
| Test tooling | OSU Micro-Benchmarks 7.x, `perftest`, `ibverbs-utils`, `infiniband-diags` |
| Automation | Ansible 2.15+, Bash |

---

Copyright 2026 Cornelis Networks, Inc. Licensed under the Apache License,
Version 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE) for details.
