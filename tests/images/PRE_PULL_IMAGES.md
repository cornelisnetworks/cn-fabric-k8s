# Container Images for Pre-Pull

This document lists all container images used in the cn-fabric-k8s project that should be pre-pulled to reduce test and deployment time.

## Summary

**Total Images: 12**
- CNI/Networking: 7 images
- System/Infrastructure: 1 image
- Testing: 4 images

**Estimated Time Savings:**
- Without pre-pull: ~5-15 minutes (network-dependent)
- With pre-pull: ~30 seconds
- **Net savings: ~4.5-14.5 minutes per deployment/test**

---

## CNI and Networking Images (7 images)

### Multus CNI
```bash
ghcr.io/k8snetworkplumbingwg/multus-cni:v4.0.2
ghcr.io/k8snetworkplumbingwg/multus-cni:v4.0.2-thick
```
- **Purpose:** Multi-network CNI plugin
- **Used by:** `manifests/cni/multus-daemonset.yaml`
- **Size:** ~50 MB each

### Flannel CNI (Latest)
```bash
ghcr.io/flannel-io/flannel:v0.28.1
ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1
```
- **Purpose:** Flannel CNI for pod networking
- **Used by:** `manifests/cni/kube-flannel.yaml`
- **Size:** ~70 MB + ~10 MB

### Flannel CNI (IPoIB Variant)
```bash
docker.io/flannel/flannel:v0.25.4
docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel1
```
- **Purpose:** Flannel CNI with IPoIB support
- **Used by:** `manifests/cni/flannel-ipoib.yaml`, `manifests/cni/flannel-hostgw.yaml`
- **Size:** ~70 MB + ~10 MB

### Whereabouts IPAM
```bash
ghcr.io/k8snetworkplumbingwg/whereabouts:v0.8.0
```
- **Purpose:** IP address management for secondary networks
- **Used by:** `manifests/cni/whereabouts-daemonset.yaml`
- **Size:** ~20 MB

---

## System and Infrastructure Images (1 image)

### Kubernetes Pause Container
```bash
registry.k8s.io/pause:3.9
```
- **Purpose:** Kubernetes sandbox/pause container
- **Used by:** containerd configuration (`automation/config/system-config.yaml`)
- **Size:** ~700 KB

---

## Testing Images (4 images)

### RDMA Test Tools (Custom)
```bash
cornelis/rdma-test-tools:latest
```
- **Purpose:** Pre-built RDMA testing tools (UCX, OpenMPI, OSU benchmarks)
- **Used by:** `tests/03-verify-rdma-shared-device.sh`
- **Size:** ~2.5 GB
- **Build:** `tests/images/rdma-test-tools/build.sh`
- **Contents:**
  - Ubuntu 22.04 base
  - RDMA tools: rdma-core, ibverbs-utils, infiniband-diags, perftest
  - UCX 1.15.0 (compiled)
  - OpenMPI 4.1.6 (compiled with UCX)
  - OSU Micro-Benchmarks 7.3 (compiled)
  - SSH server/client
- **Time savings:** Eliminates ~50 minutes of compilation per test run

### Alpine Linux
```bash
alpine:3.18
```
- **Purpose:** Lightweight testing and keepalive containers
- **Used by:** `manifests/cni/ipoib-cni-daemonset.yaml`, `tests/02-verify-multus-ipoib.sh`
- **Size:** ~7 MB

### Ubuntu Linux
```bash
ubuntu:22.04
```
- **Purpose:** Fallback testing image (if rdma-test-tools not available)
- **Used by:** Legacy test configurations
- **Size:** ~77 MB
- **Note:** Replaced by `cornelis/rdma-test-tools:latest` in main tests

### BusyBox
```bash
busybox:latest
```
- **Purpose:** Minimal testing container for network connectivity
- **Used by:** `tests/01-verify-flannel-ipoib.sh`
- **Size:** ~1.5 MB

---

## Pre-Pull Script

### Option 1: Manual Pre-Pull (All Nodes)

```bash
#!/bin/bash
# Pre-pull all required images on all nodes

IMAGES=(
    # CNI/Networking
    "ghcr.io/k8snetworkplumbingwg/multus-cni:v4.0.2"
    "ghcr.io/k8snetworkplumbingwg/multus-cni:v4.0.2-thick"
    "ghcr.io/flannel-io/flannel:v0.28.1"
    "ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1"
    "docker.io/flannel/flannel:v0.25.4"
    "docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel1"
    "ghcr.io/k8snetworkplumbingwg/whereabouts:v0.8.0"
    
    # System
    "registry.k8s.io/pause:3.9"
    
    # Testing
    "cornelis/rdma-test-tools:latest"
    "alpine:3.18"
    "ubuntu:22.04"
    "busybox:latest"
)

echo "Pre-pulling ${#IMAGES[@]} container images..."

for image in "${IMAGES[@]}"; do
    echo "Pulling $image..."
    docker pull "$image" || ctr -n k8s.io image pull "$image"
done

echo "✓ All images pre-pulled successfully"
```

### Option 2: Kubernetes DaemonSet Pre-Pull

Create a DaemonSet that pulls images on all nodes:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: image-prepull
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: image-prepull
  template:
    metadata:
      labels:
        name: image-prepull
    spec:
      initContainers:
      - name: prepull-rdma-tools
        image: cornelis/rdma-test-tools:latest
        command: ['sh', '-c', 'echo "Image pulled"']
      - name: prepull-alpine
        image: alpine:3.18
        command: ['sh', '-c', 'echo "Image pulled"']
      - name: prepull-ubuntu
        image: ubuntu:22.04
        command: ['sh', '-c', 'echo "Image pulled"']
      - name: prepull-busybox
        image: busybox:latest
        command: ['sh', '-c', 'echo "Image pulled"']
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
```

---

## Locally Built Images

These images must be built locally before use:

### cn-ipoib-cni
```bash
# Build from source
cd plugins/cni-plugins/cn-ipoib-cni
make build

# Binary installed to: /opt/cni/bin/ipoib (via Ansible)
```
- **Purpose:** Custom IPoIB CNI plugin with Cornelis patches
- **Used by:** Multus and Flannel IPoIB configurations
- **Note:** Binary is deployed to nodes, not used as container image

---

## Registry Configuration

### Docker Hub (Public)
- Most images are pulled from public registries
- No authentication required
- Rate limits may apply (100 pulls per 6 hours for anonymous users)

### GitHub Container Registry (GHCR)
- Used for CNI images (Multus, Flannel, Whereabouts)
- No authentication required for public images
- Higher rate limits than Docker Hub

### Private Registry (Optional)
To use a private registry, re-tag and push images:

```bash
PRIVATE_REGISTRY="registry.example.com"

for image in "${IMAGES[@]}"; do
    # Pull from public registry
    docker pull "$image"
    
    # Re-tag for private registry
    NEW_TAG="${PRIVATE_REGISTRY}/${image#*/}"
    docker tag "$image" "$NEW_TAG"
    
    # Push to private registry
    docker push "$NEW_TAG"
done
```

---

## Maintenance

### Update Frequency
- **CNI images:** Check for updates monthly
- **System images:** Check for security updates weekly
- **Test images:** Rebuild when dependencies update

### Version Pinning
All images use pinned versions except:
- `cornelis/rdma-test-tools:latest` (custom, version in Dockerfile)
- `busybox:latest` (minimal risk, rarely changes)

### Security Scanning
Recommended tools:
- `docker scan <image>` (Docker Desktop)
- `trivy image <image>` (Aqua Security)
- `grype <image>` (Anchore)

---

## Troubleshooting

### Image pull failures
```bash
# Check network connectivity
curl -I https://ghcr.io
curl -I https://registry.k8s.io

# Check Docker/containerd status
systemctl status docker
systemctl status containerd

# Check disk space
df -h /var/lib/docker
df -h /var/lib/containerd
```

### Rate limit errors (Docker Hub)
```bash
# Authenticate to increase rate limit
docker login

# Or use a mirror/cache
# Edit /etc/docker/daemon.json:
{
  "registry-mirrors": ["https://mirror.example.com"]
}
```

### Large image size (rdma-test-tools)
The `cornelis/rdma-test-tools` image is ~2.5 GB due to compiled libraries. To reduce size:
- Use multi-stage build (remove build dependencies)
- Compress layers with `docker build --squash`
- Use a private registry with compression
