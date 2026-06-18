# CNI Binary & Container Image Installation Guide

This guide covers the installation and management of CNI binaries **and the
device-plugin container image** on Kubernetes nodes.

## Overview

As of the latest architecture update, CNI binaries **and the
`cn-rdma-shared-dev-plugin` container image** are installed during
**Step 1 (Node Preparation)** rather than during CNI deployment. This provides:

- **Faster iteration** - CNI configuration changes don't require binary or image reinstallation
- **Clearer separation** - Node setup vs. CNI configuration are distinct phases
- **Easier troubleshooting** - Binary and image build issues are caught early
- **Air-gapped friendly** - No registry pull at deploy time for cluster-internal images

## What Setup Installs

### CNI Binaries (at `/opt/cni/bin/` on each node)

| Binary | Source | Version | Purpose |
|--------|--------|---------|---------|
| `ipoib` | Built from source (Go) | Latest | CN IPoIB CNI plugin for InfiniBand networking |
| `multus` | GitHub release | see `automation/config/package-requirements.yaml` | Meta-plugin for multi-interface orchestration |
| `flannel` | GitHub release | see `automation/config/package-requirements.yaml` | Flannel CNI plugin for overlay networking |
| `host-local` | Flannel release | see `automation/config/package-requirements.yaml` | IPAM plugin for local IP management |
| `bridge` | Flannel release | see `automation/config/package-requirements.yaml` | Bridge CNI plugin (if not present) |

### Container Images (in containerd `k8s.io` namespace on each node)

| Image | Source | Build Tool | Consumer |
|-------|--------|------------|----------|
| `localhost/cn-rdma-shared-dev-plugin:latest` | `plugins/device-plugins/cn-rdma-shared-dev-plugin/Dockerfile.cornelis` (Cornelis fork, multi-stage `Go builder` → `alpine:latest`) | `buildah bud` → `buildah push oci-archive:` → `ctr -n k8s.io images import` | `manifests/device-plugins/rdma-cdi-device-plugin.yaml` DaemonSet (`imagePullPolicy: Never`) for the `rdma-shared-device` workflow |

> The `localhost/cornelis/rdma-test-tools:latest` test image is **not**
> installed by the setup phase. It is a separate test prerequisite — see the
> RDMA shared device-plugin deployment guide
> [../deployment/rdma-cdi-device-plugin.md](../deployment/rdma-cdi-device-plugin.md)
> and the [testing documentation](../testing/README.md).

## Installation Process

### Automated Installation (Recommended)

CNI binaries are automatically installed when running node setup:

```bash
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml \
  -e "operation=setup" \
  --ask-pass
```

### Installation Steps

The automated installation performs these steps on each node:

1. **Install Go Toolchain**
   - Attempts package manager installation (apt/dnf/zypper)
   - Falls back to official Go tarball if package unavailable
   - Requires Go >= 1.19
   - Configures PATH in `/etc/profile.d/go.sh`

2. **Build cn-ipoib-cni**
   - Copies source to `/tmp/cn-ipoib-cni-build`
   - Runs `make build`
   - Installs binary to `/opt/cni/bin/ipoib`
   - Sets permissions to 0755

3. **Install Multus CNI**
   - Downloads from GitHub: `k8snetworkplumbingwg/multus-cni`
   - Verifies SHA256 checksum
   - Extracts to `/opt/cni/bin/multus`
   - Sets permissions to 0755

4. **Install Flannel CNI**
   - Downloads from GitHub: `flannel-io/cni-plugin`
   - Verifies SHA256 checksum
   - Extracts binaries: `flannel`, `bridge`, `host-local`
   - Preserves existing binaries (only installs if missing)
   - Sets permissions to 0755

5. **Install buildah toolchain** (if not already present, via the
   node's package manager — `dnf install buildah` on RHEL, `apt-get
   install buildah` on Debian/Ubuntu, `zypper install buildah` on SUSE).
   Required to build the cn-rdma-shared-dev-plugin container image.

6. **Build cn-rdma-shared-dev-plugin container image** (see the
   dedicated section [cn-rdma-shared-dev-plugin container image](#cn-rdma-shared-dev-plugin-container-image)
   below for the full pipeline).

7. **Verify Installation**
   - Checks all binaries exist and are executable
   - Reports binary sizes and versions (if available)
   - Verifies `localhost/cn-rdma-shared-dev-plugin:latest` is present in
     containerd's `k8s.io` namespace
   - Fails if any required binary or the image is missing

8. **Optional Cleanup**
   - Removes Go toolchain (if `--cleanup-build-deps` specified)
   - Removes build artifacts and source files
   - Preserves installed CNI binaries and container image

## cn-rdma-shared-dev-plugin Container Image

The `rdma-shared-device` deployment workflow runs a DaemonSet that exposes
Cornelis SuperNIC (HFI) devices as the schedulable Kubernetes resource
`cornelis.com/hfi`. The DaemonSet container image is built **on each node**
during node setup — not on the Ansible controller and never pulled from a
public registry.

### Build Pipeline

The setup script (`automation/scripts/setup-node.sh`) runs the helper
`build_cn_rdma_shared_dp_image()` from
`automation/scripts/lib/package-manager.sh`. The pipeline is:

1. **Stage source tree**: the Ansible setup-node task already synced
   `plugins/device-plugins/cn-rdma-shared-dev-plugin/` to
   `/tmp/plugins/device-plugins/cn-rdma-shared-dev-plugin/` on the node
   (excluding `build/` and `.git`). The helper copies it to
   `/tmp/cn-rdma-shared-dp-build/`.
2. **Build the image** with `buildah`:
   ```bash
   buildah bud -t localhost/cn-rdma-shared-dev-plugin:latest \
               -f Dockerfile.cornelis .
   ```
   `Dockerfile.cornelis` is a self-contained multi-stage build
   (Go builder stage → `alpine:latest`) that compiles
   `./cmd/cn-rdma-shared-dp` inside the builder stage and copies the
   resulting binary to `/usr/bin/cn-rdma-shared-dp` in the runtime
   stage. The upstream Mellanox `Dockerfile` and the plugin's `Makefile`
   `build` target are not used by this pipeline.
3. **Export to OCI archive** with the ref-name annotation, so that
   `ctr` rebinds the `:latest` tag on import:
   ```bash
   buildah push localhost/cn-rdma-shared-dev-plugin:latest \
                oci-archive:/tmp/cn-rdma-shared-dev-plugin-image.tar:localhost/cn-rdma-shared-dev-plugin:latest
   ```
4. **Import into containerd's `k8s.io` namespace** (the only namespace
   that kubelet reads):
   ```bash
   ctr -n k8s.io images rm localhost/cn-rdma-shared-dev-plugin:latest 2>/dev/null || true
   ctr -n k8s.io images import /tmp/cn-rdma-shared-dev-plugin-image.tar
   ```
   > **RKE2 note:** On RKE2 nodes, `ctr` defaults to the host containerd socket
   > (`/run/containerd/containerd.sock`), not the RKE2 containerd socket
   > (`/run/k3s/containerd/containerd.sock`). Importing via the host socket places
   > the image in the wrong namespace — kubelet will not find it and pods will fail
   > with `ImagePullBackOff` even with `imagePullPolicy: Never`. On RKE2, pass the
   > socket explicitly:
   > ```bash
   > CTR="ctr --address /run/k3s/containerd/containerd.sock"
   > $CTR -n k8s.io images rm localhost/cn-rdma-shared-dev-plugin:latest 2>/dev/null || true
   > $CTR -n k8s.io images import /tmp/cn-rdma-shared-dev-plugin-image.tar
   > ```
5. **Verify the tag is bound** via
   `ctr -n k8s.io images ls -q | grep -F localhost/cn-rdma-shared-dev-plugin:latest`.
   The Ansible setup-node task also runs this check as a post-condition.

### Why a Per-node In-cluster Build?

- **No registry dependency.** The image never leaves the node, so we
  don't need a private registry to ship a Cornelis-internal build to a
  cluster.
- **Architectural symmetry with cn-ipoib-cni.** Both Cornelis plugins
  are built at setup time from the in-tree source synced to the node.
- **Reproducibility.** Every node runs the exact same Dockerfile
  against the exact same source tree, so the cluster-wide image is
  deterministic per commit.

### Skipping the Image Build

Set `SKIP_RDMA_PLUGIN_BUILD=true` to skip the image build (for example,
during iterative testing on a node where the image is already present
from a previous run, or on a cluster where you intend to import a
pre-built archive out-of-band):

```bash
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml \
  -e "operation=setup" \
  -e "skip_rdma_plugin_build=true"
```

When set, the setup script logs `Skipping cn-rdma-shared-dev-plugin
build (SKIP_RDMA_PLUGIN_BUILD=true)` and only verifies that
`localhost/cn-rdma-shared-dev-plugin:latest` is present in containerd.

### Manual Rebuild on a Single Node

```bash
# From the source tree on the node
cd <repo-root>/plugins/device-plugins/cn-rdma-shared-dev-plugin

# Build, archive, and import
buildah bud -t localhost/cn-rdma-shared-dev-plugin:latest -f Dockerfile.cornelis .
buildah push localhost/cn-rdma-shared-dev-plugin:latest \
    oci-archive:/tmp/cn-rdma-shared-dev-plugin-image.tar:localhost/cn-rdma-shared-dev-plugin:latest
# On kubeadm:
ctr -n k8s.io images rm localhost/cn-rdma-shared-dev-plugin:latest 2>/dev/null || true
ctr -n k8s.io images import /tmp/cn-rdma-shared-dev-plugin-image.tar
# On RKE2 (ctr defaults to host containerd, not RKE2's /run/k3s/containerd/containerd.sock):
CTR="ctr --address /run/k3s/containerd/containerd.sock"
$CTR -n k8s.io images rm localhost/cn-rdma-shared-dev-plugin:latest 2>/dev/null || true
$CTR -n k8s.io images import /tmp/cn-rdma-shared-dev-plugin-image.tar

# Verify
ctr -n k8s.io images ls -q | grep -F localhost/cn-rdma-shared-dev-plugin:latest
crictl images | grep cn-rdma-shared-dev-plugin
```

### Restart the DaemonSet to Pick Up a Fresh Image

`imagePullPolicy: Never` means kubelet will only re-read the image when
the pod is restarted. After rebuilding on all nodes:

```bash
kubectl rollout restart daemonset/rdma-shared-device-plugin -n kube-system
kubectl rollout status  daemonset/rdma-shared-device-plugin -n kube-system
```

## Configuration Options

### Version Pinning

Control CNI binary versions via Ansible variables:

```bash
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml \
  -e "operation=setup" \
  -e "go_version=1.21.5" \
  -e "multus_version=$(yq -r '.cni_artifacts.multus.version' automation/config/package-requirements.yaml)" \
  -e "flannel_version=$(yq -r '.cni_artifacts.flannel.version' automation/config/package-requirements.yaml)" \
  --ask-pass
```

### Build Dependency Cleanup

Remove Go toolchain after installation to save disk space (~500MB):

```bash
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml \
  -e "operation=setup" \
  -e "cleanup_build_deps=true" \
  --ask-pass
```

**Note:** If you clean up build dependencies, you'll need to reinstall Go to rebuild cn-ipoib-cni.

## Manual Installation

If you need to manually install CNI binaries on a node:

### 1. Install Go Toolchain

```bash
# Option A: Package manager (RHEL/CentOS)
sudo dnf install golang

# Option B: Official tarball
wget https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.21.5.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
```

### 2. Build and Install cn-ipoib-cni

```bash
cd /path/to/cn-fabric-k8s/plugins/cni-plugins/cn-ipoib-cni
make build
sudo mkdir -p /opt/cni/bin
sudo cp build/ipoib /opt/cni/bin/ipoib
sudo chmod 0755 /opt/cni/bin/ipoib
```

### 3. Install Multus CNI

```bash
MULTUS_VERSION=$(yq -r '.cni_artifacts.multus.version' automation/config/package-requirements.yaml)
wget https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/${MULTUS_VERSION}/multus-cni_${MULTUS_VERSION}_linux_amd64.tar.gz
tar -xzf multus-cni_${MULTUS_VERSION}_linux_amd64.tar.gz
sudo cp multus-cni /opt/cni/bin/multus
sudo chmod 0755 /opt/cni/bin/multus
```

### 4. Install Flannel CNI

```bash
# FLANNEL_VERSION is e.g. v1.9.0-flannel1. The release artifact embeds the
# upstream CNI-plugins version with the "-flannelN" suffix stripped, so the
# tarball name is cni-plugin-flannel-linux-${arch}-v${version}.tgz
# (see automation/scripts/lib/package-manager.sh). For amd64 the arch is "amd64".
FLANNEL_VERSION=$(yq -r '.cni_artifacts.flannel.version' automation/config/package-requirements.yaml)
arch=amd64
FLANNEL_NO_SUFFIX="${FLANNEL_VERSION%-flannel*}"   # e.g. v1.9.0
tarball="cni-plugin-flannel-linux-${arch}-${FLANNEL_NO_SUFFIX}.tgz"
wget https://github.com/flannel-io/cni-plugin/releases/download/${FLANNEL_VERSION}/${tarball}
tar -xzf "${tarball}"
sudo cp flannel-${arch} /opt/cni/bin/flannel
sudo chmod 0755 /opt/cni/bin/flannel
```

### 5. Verify Installation

```bash
ls -lh /opt/cni/bin/{ipoib,multus,flannel,host-local}
```

## Verification

### Check Binary Installation

```bash
# On each node
ls -lh /opt/cni/bin/
```

Expected output:
```
-rwxr-xr-x 1 root root  15M Mar 29 22:00 flannel
-rwxr-xr-x 1 root root 4.2M Mar 29 22:00 host-local
-rwxr-xr-x 1 root root  12M Mar 29 22:00 ipoib
-rwxr-xr-x 1 root root  58M Mar 29 22:00 multus
```

### Verify Binary Executability

```bash
# Test each binary
test -x /opt/cni/bin/ipoib && echo "ipoib: OK" || echo "ipoib: FAIL"
test -x /opt/cni/bin/multus && echo "multus: OK" || echo "multus: FAIL"
test -x /opt/cni/bin/flannel && echo "flannel: OK" || echo "flannel: FAIL"
test -x /opt/cni/bin/host-local && echo "host-local: OK" || echo "host-local: FAIL"
```

### Check CNI Deployment Pre-flight

CNI deployment playbooks automatically verify binaries before configuration:

```bash
# This will fail if binaries are missing
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml cni-deploy.yaml \
  -e "deploy_cni=multus-ipoib" \
  --ask-pass
```

## Troubleshooting

### Issue: Binary Not Found

**Symptom:** CNI deployment fails with "binary not found" error

**Solution:**
```bash
# Re-run node setup
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml \
  -e "operation=setup" \
  --ask-pass
```

### Issue: Go Build Failure

**Symptom:** cn-ipoib-cni build fails during node setup

**Causes:**
- Go version too old (< 1.19)
- Missing build dependencies
- Insufficient disk space

**Solution:**
```bash
# Check Go version
go version

# Check disk space
df -h /tmp

# Manually build on node
cd /tmp/cn-ipoib-cni-build
make build
```

### Issue: Checksum Verification Failure

**Symptom:** Multus or Flannel download fails checksum verification

**Causes:**
- Network corruption during download
- GitHub release changed
- Incorrect version specified

**Solution:**
```bash
MULTUS_VERSION=$(yq -r '.cni_artifacts.multus.version' automation/config/package-requirements.yaml)

# Re-download with verbose output
wget -v https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/${MULTUS_VERSION}/multus-cni_${MULTUS_VERSION}_linux_amd64.tar.gz

# Verify checksum manually
sha256sum multus-cni_${MULTUS_VERSION}_linux_amd64.tar.gz
```

### Issue: Binary Not Executable

**Symptom:** Binary exists but is not executable

**Solution:**
```bash
# Fix permissions
sudo chmod 0755 /opt/cni/bin/{ipoib,multus,flannel,host-local}
```

### Issue: Disk Space Issues

**Symptom:** Node setup fails due to insufficient disk space

**Causes:**
- Go toolchain requires ~500MB
- Build artifacts require ~200MB
- Downloaded tarballs require ~100MB

**Solution:**
```bash
# Check disk space
df -h /tmp /opt

# Clean up after installation
sudo rm -rf /tmp/cn-ipoib-cni-build
sudo rm -rf /usr/local/go  # If Go not needed after build

# Or use cleanup flag during setup
ansible-playbook ... -e "cleanup_build_deps=true"
```

## Updating CNI Binaries

### Update All Binaries

```bash
# Re-run node setup with new versions
cd automation/playbooks
ansible-playbook -i ../inventory/hosts.yaml node-management.yaml \
  -e "operation=setup" \
  -e "multus_version=v4.2.4" \
  -e "flannel_version=v1.9.0-flannel1" \
  --ask-pass
```

### Update Single Binary

```bash
# Example: Update Multus only
MULTUS_VERSION=$(yq -r '.cni_artifacts.multus.version' automation/config/package-requirements.yaml)
wget https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/${MULTUS_VERSION}/multus-cni_${MULTUS_VERSION}_linux_amd64.tar.gz
tar -xzf multus-cni_${MULTUS_VERSION}_linux_amd64.tar.gz
sudo cp multus-cni /opt/cni/bin/multus
sudo chmod 0755 /opt/cni/bin/multus

# Restart Multus pods
kubectl delete pods -n kube-system -l app=multus
```

### Rebuild cn-ipoib-cni

```bash
# On each node
cd /path/to/cn-fabric-k8s/plugins/cni-plugins/cn-ipoib-cni
git pull  # Get latest changes
make clean
make build
sudo cp build/ipoib /opt/cni/bin/ipoib
sudo chmod 0755 /opt/cni/bin/ipoib

# Restart CNI pods if needed
kubectl delete pods -n kube-system -l app=ipoib-cni
```

## System Requirements

### Disk Space

| Component | Size | Location | Cleanup |
|-----------|------|----------|---------|
| Go toolchain | ~500MB | `/usr/local/go` | Optional (use `--cleanup-build-deps`) |
| cn-ipoib-cni source | ~50MB | `/tmp/cn-ipoib-cni-build` | Automatic |
| Build artifacts | ~150MB | `/tmp/cn-ipoib-cni-build/build` | Automatic |
| Downloaded tarballs | ~100MB | `/tmp/*.tar.gz` | Automatic |
| Installed binaries | ~90MB | `/opt/cni/bin/` | Permanent |

**Total during installation:** ~850MB  
**Total after cleanup:** ~90MB (binaries only) or ~590MB (with Go)

### Network Requirements

- Access to `go.dev` (Go downloads)
- Access to `github.com` (Multus and Flannel releases)
- Bandwidth: ~200MB download per node

### Build Requirements

- Go >= 1.19
- `make` utility
- `gcc` compiler (for cgo dependencies)
- `git` (if building from repository)

## See Also

- [Node Setup Guide](../operations/ansible-guide.md#step-1-prepare-nodes)
- [CNI Deployment Guide](../deployment/multus-ipoib-cni.md)
- [Troubleshooting Guide](../operations/troubleshooting.md)
