# RDMA Test Tools Container Image

Pre-built container image used by every Kubernetes networking test in this
repo (`tests/01-verify-flannel-ipoib.sh`, `tests/02-verify-multus-ipoib.sh`,
`tests/03-verify-rdma-shared-device.sh`). Building all the userspace stacks
once into a single image saves ~50 min of source builds per test run and
ships a libfabric that contains a working **OPX** provider, so MPI tests
can drive Cornelis Networks HFI hardware over the `ofi` MTL.

The image is built on a Rocky Linux 9.5 base. The toolchain comes from the
public Rocky BaseOS / AppStream / CRB and EPEL repos. The OPX-enabled stack
is built from public upstream source — no internal Cornelis RPM repo is
required:

* `libfabric` is cloned from `github.com/ofiwg/libfabric` and configured with
  `--enable-opx=yes` (the OPX provider has been upstream since libfabric 1.15
  and is the preferred Omni-Path provider in the 2.x line).
* `Open MPI` is cloned from `github.com/open-mpi/ompi` and built against that
  libfabric so it exposes the OFI MTL.

PSM2 is not built. For CN5000 the OPX provider drives the `hfi1` hardware
natively over OFI and does not depend on `libpsm2`; the MPI tests pin the
runtime path to OPX (`--mca mtl ofi --mca mtl_ofi_provider_include opx`,
`FI_PROVIDER=opx`). Building requires outbound internet access to GitHub and
the OSU download host, not a Cornelis RPM repo.

## Contents

| Component                | Source                                                | Notes |
|--------------------------|-------------------------------------------------------|-------|
| Base                     | `docker.io/rockylinux/rockylinux:9.5`                 | Matches the HFI driver/firmware support matrix. |
| libfabric                | `github.com/ofiwg/libfabric` tag `v2.0.0` (source)    | Built `--enable-opx=yes` (OPX-only); psm2/verbs/usnic/efa disabled. Installs to `/usr`. |
| Open MPI                 | `github.com/open-mpi/ompi` tag `v4.1.8` (source)      | Built `--with-ofi` against the OPX libfabric; bundled hwloc/libevent/pmix. Installed under `/usr/mpi/gcc/openmpi-4.1.8-hfi/`. PATH and LD_LIBRARY_PATH are pre-set. |
| RDMA tools               | `rdma-core`, `libibverbs-utils`, `infiniband-diags`, `perftest`, `fabtests` | Rocky AppStream/CRB |
| UCX                      | `ucx ucx-ib ucx-rdmacm ucx-cma ucx-devel`             | Rocky AppStream |
| OSU Micro-Benchmarks     | 7.3 (default; override via `OSU_VERSION`)             | Built from source against the bundled Open MPI; installed under `/usr/local`. |
| SSH                      | `openssh-server`, `openssh-clients`                   | Used by MPI launcher; `memlock` set to unlimited. |

## Build args

| Arg                 | Default | Purpose |
|---------------------|---------|---------|
| `LIBFABRIC_VERSION` | `2.0.0` | libfabric git tag (built with the OPX provider); the leading `v` is added by the Dockerfile. |
| `OPENMPI_VERSION`   | `4.1.8` | Open MPI git tag; keep on the 4.1.8 line or update the `/usr/mpi/gcc/openmpi-4.1.8-hfi` paths to match. |
| `OSU_VERSION`       | `7.3`   | OSU Micro-Benchmarks tarball version. |

## Building

This directory ships three entry points:

| Script                | Where it runs            | What it does |
|-----------------------|--------------------------|--------------|
| `build.sh`            | Any host with `docker`/`nerdctl` and internet egress | Local-only build, no distribution. Useful for CI smoke tests. |
| `build-and-deploy.sh` | Workstation              | Builds locally, then `docker save | ansible copy | ctr import` to every k8s_node. Requires a local container builder. |
| `build-on-node.sh`    | Workstation, builds on a cluster node | Builds on `${BUILD_NODE}` (default `control-plane`) via `buildah`, exports an OCI archive, distributes it to every k8s_node, and `ctr -n k8s.io images import`s it. This is the recommended path because the cluster nodes already have buildah, internet egress, and the bandwidth. |

Default build:

```bash
cd tests/images/rdma-test-tools

# Local build (development smoke test)
./build.sh

# Production build + deploy via cluster node
./build-on-node.sh
```

Override OSU version:

```bash
OSU_VERSION=7.4 ./build.sh
```

`build-on-node.sh` (above) is the canonical end-to-end build-and-deploy
entry point: it builds on a cluster node, exports an OCI archive, distributes
it to every k8s_node, and imports it into containerd's `k8s.io` namespace.
See the "Operational gotcha — OCI archive ref name" section below for the
archive ref-name detail that makes the containerd re-import rebind the tag
correctly.

## Operational gotcha — OCI archive ref name

`build-on-node.sh` exports the image with:

```
buildah push <image> oci-archive:/tmp/rdma-test-tools-image.tar:<image-ref>
```

The trailing `:<image-ref>` sets `org.opencontainers.image.ref.name` in the
archive index. Without that annotation, `ctr -n k8s.io images import` lands
the blobs in containerd but does **not** rebind the destination tag — so the
tag keeps pointing at whatever image was there before, silently. The
distribution step also runs `ctr -n k8s.io images rm <image>` before each
import so the rebind happens cleanly.

If you hand-roll a build, replicate this pattern or you will spend half an
hour wondering why your pods are running the old image.

## Inventory authentication for unattended runs

`build-on-node.sh` reads `ansible_password` from
`automation/inventory/hosts.yaml` by default (no `--ask-pass`). Set
`ASK_PASS=1` if you want the interactive password prompt back.

## Validating the image

The Dockerfile's final layer already runs build-time verification
(`fi_info -l`, `ompi_info`, `ucx_info -v`). To re-check an existing image:

```bash
# UCX, Open MPI, OSU presence
docker run --rm cornelis/rdma-test-tools:latest ucx_info -v
docker run --rm cornelis/rdma-test-tools:latest mpirun --version
docker run --rm cornelis/rdma-test-tools:latest \
    ls /usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_bw

# Providers compiled into libfabric (does NOT require HFI hardware)
docker run --rm cornelis/rdma-test-tools:latest \
    sh -c 'fi_info -l | grep -E "^(opx|udp|tcp|sockets):"'

# Open MPI was built with the OFI MTL (does NOT require HFI hardware)
docker run --rm cornelis/rdma-test-tools:latest \
    sh -c 'ompi_info | grep "MCA mtl: ofi" && echo "OFI MTL present"'

# OPX provider can actually open a Cornelis HFI device
# (REQUIRES: Cornelis HFI hardware + hfi1 kernel module on the host)
docker run --rm --privileged --device=/dev/infiniband \
    cornelis/rdma-test-tools:latest fi_info -p opx
```

## Build time / image size

Approximate full-build time on a typical cluster node: 30–45 minutes
(source-build libfabric/OPX + Open MPI + OSU). Approximate image size:
~900 MB uncompressed including the build toolchain.

## Caveats

* **Outbound internet access is required at build time.** The build clones
  libfabric and Open MPI from GitHub and downloads the OSU tarball. Builds
  on an air-gapped host will fail at the `git clone` / `wget` steps.
* **Public upstream libfabric, not the Cornelis OPX RPM.** This image builds
  the OPX provider from the upstream `v2.0.0` tag. It does not carry any
  downstream patches or MCA defaults that may be present in a Cornelis-built
  `libfabric-2.0.0-1552` RPM. The self-check proves OPX is compiled in, not
  support/perf parity with a certified Cornelis build.
* **No HFI hardware in the build environment.** Build-time verification
  cannot run `fi_info -p opx` because the build host typically has no
  `hfi1` device. The Dockerfile only checks that the OPX provider is
  *compiled into* libfabric (`fi_info -l`) and that Open MPI has the OFI
  MTL component (`ompi_info`). End-to-end OPX validation happens at test
  time on a node with Cornelis HFI hardware, driven by
  `tests/03-verify-rdma-shared-device.sh` sections [11] and [12] on
  CN5000 HFIs.

## Updating versions

Either edit the `ARG` defaults in the Dockerfile or pass `--build-arg` at
build time:

```bash
docker build \
    --build-arg LIBFABRIC_VERSION=2.0.0 \
    --build-arg OPENMPI_VERSION=4.1.8 \
    --build-arg OSU_VERSION=7.4 \
    -t cornelis/rdma-test-tools:next \
    .
```

## Troubleshooting

### `fi_info -l` does not list `opx`
* The libfabric `./configure` step must report `opx ... yes`. Because the
  Dockerfile passes `--enable-opx=yes`, configure hard-fails if the OPX
  prerequisites (`libuuid-devel`, `numactl-devel`, `kernel-headers`) are
  missing, so a successful build implies OPX is present.
* `ldd $(which fi_info)` should resolve `libfabric.so.1` to `/usr/lib64`. If
  it resolves to a distro path, the source build did not overwrite the distro
  libfabric — confirm the source build ran after the `dnf install` layer.

### `ompi_info` shows no `mtl: ofi` component
* Open MPI must be configured `--with-ofi=/usr` against the OPX libfabric. If
  the OFI MTL is missing, libfabric headers/libs were not found at configure
  time — check the libfabric build layer succeeded and `which mpirun` resolves
  to `/usr/mpi/gcc/openmpi-4.1.8-hfi/bin/mpirun` and not `/usr/bin/mpirun`.

### `fi_info -p opx` fails on a node with HFI hardware
* The OPX provider needs `/dev/hfi1*` and the `hfi1` kernel module on the
  host. Verify with `lsmod | grep hfi1` and `ls /dev/hfi1*`.
* The pod must request the corresponding CDI/RDMA resource so the device
  is actually mounted into the container.
* If `fi_info -p opx` returns `FATAL: HFI has no active ports` on a
  CN5000, confirm OPX is present with `fi_info -l | grep opx` and check
  `fi_info --version`.

### `ctr images import` succeeds but pods still run the old image
* You probably hit the OCI archive ref-name gotcha above. Either rebuild
  with `build-on-node.sh` (which sets the ref name correctly) or run
  `ctr -n k8s.io images rm localhost/cornelis/rdma-test-tools:latest`
  on every node, then re-import.

### Build fails at `git clone` or `wget`
* The build needs outbound access to `github.com` (libfabric, Open MPI) and
  `mvapich.cse.ohio-state.edu` (OSU). From the build node, confirm those hosts
  are reachable. Behind a proxy, pass the proxy env into the builder.

## Maintenance

Rebuild this image when:
* A newer `libfabric` tag ships OPX fixes, or a newer `Open MPI` tag is
  desired (bump `LIBFABRIC_VERSION` / `OPENMPI_VERSION`).
* OSU Micro-Benchmarks have a relevant release.
* The Rocky Linux 9.5 base has security updates.

Recommended cadence: monthly, or whenever any of the three verification
scripts (`tests/01-verify-flannel-ipoib.sh`,
`tests/02-verify-multus-ipoib.sh`,
`tests/03-verify-rdma-shared-device.sh`) fail at the libfabric or MPI
sections.
