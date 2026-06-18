# Cornelis Networks IPoIB CNI Plugin

This is a synchronized version of the Mellanox IPoIB CNI plugin with strict type validation to prevent race conditions.

## Changes from Upstream

**Upstream:** https://github.com/Mellanox/ipoib-cni v1.2.2

**Patches:**
1. Strict IPoIB netlink type validation (from upstream)
2. Explicit mode override support from CNI configuration

### Strict IPoIB Type Validation

The parent interface is validated as a proper IPoIB netlink device before any
child interface is created:

```go
// Validate parent is proper IPoIB interface
if m.Type() != "ipoib" {
    return nil, fmt.Errorf("master device is not of type ipoib")
}

ipoibParent, ok := m.(*netlink.IPoIB)
if !ok {
    return nil, fmt.Errorf("failed to convert to ipoib netlink interface")
}

// Extract pkey and mode from parent
parentPkey := ipoibParent.Pkey & 0x7fff
mode := ipoibParent.Mode
```

Child IPoIB interfaces in pod namespaces therefore:
- **pkey:** inherit the partition key from the parent interface
- **mode:** inherit the parent's mode (datagram or connected), with CNI config override support

The strict `*netlink.IPoIB` type assertion also serializes concurrent child-interface
creation: if the kernel is busy with another IPoIB operation the assertion fails early,
the plugin returns an error, and Kubernetes retries the pod, avoiding debugfs name
collisions between simultaneously created child interfaces.

## IPoIB Modes

**Datagram mode:**
- MTU: 2044 bytes
- Unreliable datagram service
- Lower resource usage
- Good for most workloads

**Connected mode:**
- MTU: 65520 bytes (jumbo frames)
- Reliable connected service
- Higher throughput
- More resource intensive

## Build

```bash
make build
```

Binary output: `build/ipoib`

## Deployment

The binary is installed to `/opt/cni/bin/ipoib` on every node, and the IPoIB CNI
DaemonSet in `manifests/cni/ipoib-cni-daemonset.yaml` verifies that the binary is
present. See the repository README for the install workflow.

## License

Apache License 2.0 (same as upstream)
