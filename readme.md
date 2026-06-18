# cn-fabric-k8s

Integration hub for Cornelis Networks hardware (CN5000) with Kubernetes.

## Overview

This repository provides Kubernetes manifests, deployment automation, and testing infrastructure to integrate Cornelis Networks high-performance networking hardware with Kubernetes clusters. It supports CN5000 hardware generation and enables high-performance computing (HPC) and machine learning (ML) workloads with RDMA, IPoIB and InfiniBand/Ethernet fabric capabilities.

## Hardware Platform Support

| Platform | Fabric | Networking | Driver | Status |
|----------|--------|------------|--------|--------|
| **CN5000** | InfiniBand | IPoIB, RDMA | hfi1 | Current (Reference) |

## Supported CNI Workflows

| Workflow ID | Topology | Pod-to-Pod Plane | Latency (fi_pingpong) | Test Suite |
|-------------|----------|------------------|-----------------------|------------|
| `flannel-ipoib` | Single-interface, Flannel VXLAN over IPoIB | VXLAN/IPoIB | ~10 µs (UDP) | `tests/01-verify-flannel-ipoib.sh` |
| `multus-ipoib` | Dual-interface, Flannel host-gw (control) + native IPoIB (data) | Native IPoIB | ~10 µs (UDP) / sub-µs MPI barrier | `tests/02-verify-multus-ipoib.sh` |
| `rdma-shared-device` | Single-interface Flannel + `cornelis.com/hfi` device resource | Userspace verbs / OPX provider | ~6 µs (OFI verbs) | `tests/03-verify-rdma-shared-device.sh` |

For step-by-step commands and parameters per workflow, open
[`docs/README.md`](docs/README.md) — it is the canonical 6-step **operational
workflow** document (prepare nodes → deploy cluster → deploy CNI → verify →
status → stop). Per-workflow deployment guides live under
[`docs/deployment/`](docs/deployment/) and verification tests under
[`docs/testing/`](docs/testing/).

## Quick Start

This repository **does not** ship a separate Quick Start. The canonical
6-step operational workflow lives at [`docs/README.md`](docs/README.md);
start there. Per-workflow deployment guides live under
[`docs/deployment/`](docs/deployment/) and verification tests under
[`docs/testing/`](docs/testing/), and the
stand-alone dual-NIC architecture description lives at
[`docs/architecture/networking.md`](docs/architecture/networking.md).

## Architecture

The repository pins a **dual-NIC architecture** (eth0 control plane + fabric
data plane) for every supported CNI workflow. The stand-alone description with
ASCII diagram lives at
[`docs/architecture/networking.md`](docs/architecture/networking.md).

### Function-Grouped Manifests

Cluster-scoped manifests are organized by **function**, not by platform.
Platform variance is encoded by **filename suffix** (`-cn5000`) and selected
at deploy time by Ansible.

```
manifests/
├── cni/                # Pod networking (CNI plugins and IPAM)
│   ├── multus-daemonset.yaml
│   ├── multus-daemonset-thick.yaml                 # Memory limits removed (see docs/deployment/multus-ipoib-cni.md)
│   ├── multus-default-config.yaml
│   ├── kube-flannel.yaml                           # Flannel variants
│   ├── flannel-hostgw.yaml
│   ├── flannel-ipoib.yaml
│   ├── ipoib-cni-daemonset.yaml                    # Cornelis IPoIB CNI
│   ├── ipoib-network-attachment.yaml
│   └── whereabouts-daemonset.yaml                  # IPAM
└── device-plugins/     # Kubernetes device plugins (hardware resource exposure)
    ├── rdma-cdi-device-plugin.yaml                 # RDMA CDI device plugin DaemonSet + RBAC
    └── rdma-cdi-device-config-cn5000.yaml          # Platform config (CN5000)
```

New functional siblings (e.g. `manifests/monitoring/`, `manifests/storage/`) MAY
be added when manifests for those concerns are introduced. The repository
deliberately does **not** ship `manifests/platform-cn5000/` or
`manifests/platform-mixed/` directories.

### Key Design Decisions

#### 1. Function-Grouped Manifests with Filename-Suffix Platform Variance

**Decision:** Organize manifests by function under a single `manifests/cni/`
directory; encode platform variance via `-cn<NNNN>` filename suffixes;
let Ansible dispatch the correct per-platform file at deploy time.

**Rationale:**
- **Truth in layout:** Most CNI primitives (Multus, Flannel, Whereabouts, IPoIB CNI) are platform-agnostic; grouping by function exposes that fact instead of forcing four-way duplication.
- **No empty scaffolding:** An earlier platform-first layout left empty `platform-*/` directories in the tree, which misled new contributors. Filename-suffix variance keeps everything that exists discoverable.
- **No Kustomize tax:** Each per-platform file is a complete, standalone Kubernetes resource that `kubectl apply --dry-run=client` validates on its own.
- **Workflow-aware deployment:** Selection happens via Ansible (`deploy_cni=...`), which is the deployment path the repository actually ships.

#### 2. Ansible-Driven Deployment Contract

**Decision:** Deployment is driven by `automation/playbooks/cni-deploy.yaml`
(production) and `automation/scripts/deploy-multus-ipoib.sh` (development).
Each `automation/playbooks/tasks/deploy-cni-*.yaml` task file is the single
source of truth for the manifests its workflow applies.

**Rationale:**
- **Single command, three workflows:** `deploy_cni=flannel-ipoib|multus-ipoib|rdma-shared-device` covers all supported topologies without a separate per-platform entrypoint.
- **No ambiguous "apply directory" command:** Because `manifests/cni/` holds mutually exclusive workflows (e.g. `flannel-hostgw.yaml` vs. `flannel-ipoib.yaml`), `kubectl apply -f manifests/cni/` is never documented as a user-facing command.
- **Auditability:** A reader can determine which manifests participate in a given workflow by reading exactly one Ansible task file.

#### 3. Dual Automation Paths

**Decision:** Shell scripts for development, Ansible for production

**Rationale:**
- **Development velocity:** Quick iteration with shell scripts
- **Production reliability:** Idempotent, auditable Ansible playbooks
- **Flexibility:** Choose the right tool for the context
- **Learning curve:** Scripts are simple, Ansible is powerful

#### 4. 4-Tier Testing Pyramid

**Decision:** Functional → Performance → Integration → E2E

**Rationale:**
- **Fast feedback:** Functional tests run quickly
- **Confidence:** Each tier adds different validation
- **Scalability:** Run appropriate tier for the change
- **CI/CD ready:** Structured for automation

#### 5. Configuration as Code

**Decision:** All configuration in version control, no manual steps

**Rationale:**
- **Reproducibility:** Same manifests produce same results
- **Auditability:** Git history tracks all changes
- **Disaster recovery:** Rebuild from scratch using Git
- **GitOps ready:** Declarative, version-controlled

#### 6. Pinned Component Versions

**Decision:** Pin all container images, Helm charts, Ansible roles

**Rationale:**
- **Stability:** No surprise breakage from upstream changes
- **Testing:** Know exactly what version was tested
- **Rollback:** Easy to revert to known-good versions
- **Security:** Deliberate upgrade process with review

#### 7. Open Source First

**Decision:** Use open source components (Multus, Flannel, Whereabouts, Cornelis IPoIB CNI, `k8s-rdma-shared-dev-plugin`, libfabric, Open MPI, UCX).

**Rationale:**
- **Community support:** Large ecosystems, active development
- **Vendor neutrality:** No lock-in to proprietary solutions
- **Transparency:** Inspect and modify as needed
- **Cost:** No licensing fees

## Development Workflow

- Read this `readme.md` for project overview.
- For any **deploy / test / debug** task, open `docs/README.md` first — it is the canonical 6-step operational workflow document.
- See `docs/` for additional deep-dive guides.
- Follow standard Git workflow (branch, commit, PR).

## Technology Stack

- **Kubernetes:** 1.28+.
- **Container runtime:** containerd (with the `k8s.io` namespace for kubelet visibility).
- **CNI components:** Multus, Flannel (host-gw and VXLAN-over-IPoIB), Whereabouts IPAM, Cornelis IPoIB CNI.
- **Cornelis device plugin:** `k8s-rdma-shared-dev-plugin` exposing `cornelis.com/hfi` resources.
- **Userspace fabric stack:** Cornelis libfabric (with the `opx` provider) + UCX + Open MPI 4.1.x — packaged in [`tests/images/rdma-test-tools/`](tests/images/rdma-test-tools/).
- **Test tooling:** OSU Micro-Benchmarks 7.x, `perftest`, `ibverbs-utils`, `infiniband-diags`.
- **Automation:** Ansible 2.15+, Bash.

## Contributing

1. Fork the repository and create a feature branch.
2. Make your changes, following the existing code and documentation conventions.
3. Consult the guides under `docs/` for architecture and operational context.
4. Open a pull request with a clear description of the change and its rationale.

## Documentation

- **docs/README.md**: **Canonical 6-step operational workflow document** for deploying, testing, and stopping the cluster (prepare nodes → deploy cluster → deploy CNI → verify → status → stop). Start here for any deploy/test/debug task. This document takes precedence over inventory, playbooks, scripts, and skills for operational workflow procedures.
- **readme.md** (this file): Project overview.
- **docs/architecture/networking.md**: Stand-alone dual-NIC architecture description (eth0 control plane + fabric data plane).
- **tests/images/rdma-test-tools/README.md**: One-time pre-flight to build and distribute the `rdma-test-tools` container image used by every verification workflow.
- **docs/deployment/** and **docs/testing/**: Per-workflow deployment guides and verification-test documentation consumed after `docs/README.md`.

## License

This project integrates the following open source components:
- Flannel CNI (Apache 2.0)
- Multus CNI (Apache 2.0)
- Whereabouts IPAM (Apache 2.0)
- Cornelis IPoIB CNI (Apache 2.0)
- `k8s-rdma-shared-dev-plugin` (Apache 2.0)
- libfabric (BSD-2-Clause / GPL-2.0 dual-licensed; Cornelis fork)
- Open MPI (3-clause BSD)
- UCX (BSD-3-Clause)
- OSU Micro-Benchmarks (BSD-3-Clause)

See individual component licenses for details.

## Acknowledgments

Built on the excellent work of the Kubernetes networking community and the open source projects listed above.
