# Dual-NIC Networking Architecture

Every supported CNI workflow in this repository pins a **dual-NIC** design:

- **eth0** carries the Kubernetes control plane (API server, kubelet, DNS,
  services) over standard Ethernet.
- **`<ipoib_iface>`** (the Cornelis fabric SuperNIC, e.g. `ib0` on the reference
  CN5000 cluster) carries the data plane — either via VXLAN-over-IPoIB,
  native IPoIB, or as a `cornelis.com/hfi` device resource, depending on the
  workflow.

This document is the stand-alone reference that the operational workflow
document ([`../README.md`](../README.md)) and the per-workflow deployment
guides under [`../deployment/`](../deployment/) link into.

## Why Two NICs

Cornelis fabric NICs are tuned for low-latency RDMA traffic. At the same time
the Kubernetes control plane carries small, latency-insensitive control
messages that benefit from the maturity and observability of standard
Ethernet. Splitting them yields:

- **Predictable control-plane performance** unaffected by data-plane bursts.
- **Maximum data-plane performance** because the fabric NIC isn't sharing
  bandwidth or queues with control traffic.
- **Operational clarity** — `kubectl debug node/...` can diagnose
  control-plane reachability over eth0 without touching the fabric.

## Interface roles

```
┌─────────────────────────────────────────────────────────────────┐
│ Pod                                                             │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Application Container                                    │   │
│  │                                                          │   │
│  │  eth0: 10.244.x.y/24      ← Control plane (Flannel)      │   │
│  │    • DNS queries                                         │   │
│  │    • Service discovery                                   │   │
│  │    • K8s API access                                      │   │
│  │                                                          │   │
│  │  net1: 192.168.100.z/24   ← Data plane (workflow-dep.)   │   │
│  │    • Application data                                    │   │
│  │    • High-performance traffic                            │   │
│  │    • Native InfiniBand / RDMA                            │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                                    │
         │ eth0                               │ net1
         ↓                                    ↓
┌─────────────────────┐          ┌─────────────────────┐
│ Flannel (host-gw)   │          │ Workflow-dependent  │
│ Direct routing      │          │ (IPoIB CNI / Multus │
│ No encapsulation    │          │ / RDMA dev plugin)  │
└─────────┬───────────┘          └─────────┬───────────┘
          │                                │
          ↓                                ↓
┌─────────────────────┐          ┌─────────────────────┐
│ eth0 (Ethernet)     │          │ <ipoib_iface>       │
│ Management network  │          │ Cornelis fabric NIC │
└─────────┬───────────┘          └─────────┬───────────┘
          │                                │
          ↓                                ↓
┌─────────────────────┐          ┌─────────────────────┐
│ Management Network  │          │ InfiniBand Fabric   │
│ (Ethernet)          │          │ (hfi1)              │
└─────────────────────┘          └─────────────────────┘
```

`<ipoib_iface>` is the IPoIB interface name on the target cluster — the
operator supplies the value at deploy time via `ipoib_interface=...` for the
Ansible playbook. The test scripts each accept the interface differently:
`tests/01-verify-flannel-ipoib.sh` takes it as a positional `<ipoib_iface>`
argument, `tests/02-verify-multus-ipoib.sh` takes it via the `--iface <name>`
flag, and `tests/03-verify-rdma-shared-device.sh` reads it from the `IFACE`
environment variable. There is no canonical default across the fleet because
the kernel-assigned name depends on udev rules and PCI-slot enumeration. Use
`ip link show` on a target node to discover the live value.

### Example interface names (Do not hard-code)

For orientation only — these are example values, **not** defaults to bake into
code, manifests, scripts, or guides:

| Cluster shape | Example `<ipoib_iface>` value |
|---------------|-------------------------------|
| CN5000 reference cluster | `ib0` |
| Some PCI-slot variants | `ibp196s0`, `ibp22s0` |

When you encounter `ib0` in kernel logs or third-party tutorials, treat it as
a data point about *those* hosts. For any new code, manifest, script, or guide
in this repository, the canonical placeholder is `<ipoib_iface>`; the live
value must come from `ip link show` on the operator's target node.

## Per-workflow Projection

The three supported CNI workflows project the dual-NIC architecture onto
slightly different runtime topologies:

| Workflow | eth0 Role | Fabric NIC Role | Pod-facing Detail |
|----------|-----------|-----------------|-------------------|
| **flannel-ipoib** | Reachable for kubelet / API server | Carries Flannel VXLAN-encapsulated pod traffic | Single pod NIC (`eth0`) backed by Flannel; VXLAN tunnel runs over the fabric NIC |
| **multus-ipoib** | Carries Flannel host-gw pod-to-pod control traffic | Carries native IPoIB pod-to-pod data traffic via Multus secondary network | Two pod NICs (`eth0` + `net1`); `net1` is native IPoIB |
| **rdma-shared-device** | Vanilla Flannel pod networking | Exposed as `cornelis.com/hfi` device resource (no IPoIB child interface, no Multus secondary) | Single pod NIC (`eth0`); RDMA access via the device-plugin resource request |

For the operational sequence to deploy each workflow (clean → setup →
cluster start → CNI deploy → verify → status → stop), follow the
[canonical operational workflow document](../README.md). For deep-dive
per-workflow material, see:

- [`../deployment/flannel-ipoib-cni.md`](../deployment/flannel-ipoib-cni.md)
- [`../deployment/multus-ipoib-cni.md`](../deployment/multus-ipoib-cni.md)
- [`../deployment/rdma-cdi-device-plugin.md`](../deployment/rdma-cdi-device-plugin.md)
