#!/bin/bash
# Build the rdma-test-tools image on a cluster node and distribute the
# resulting OCI archive to every k8s_node, importing it into containerd's
# k8s.io namespace so kubelet sees the tag for imagePullPolicy=Never.
#
# Why build on a node and not on the workstation?
#  * The build needs ~30 GB of intermediate layers and ~30 min of CPU.
#  * The build host needs internet egress for github + open-mpi + osu sources.
#  * The cluster nodes have both, plus they're already running containerd.
#
# Inventory authentication: this script uses the inventory's ansible_password
# (set in automation/inventory/hosts.yaml) by default. No --ask-pass prompt.
# Pass ASK_PASS=1 to opt back into the interactive prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-localhost/cornelis/rdma-test-tools}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
INVENTORY="${INVENTORY:-${SCRIPT_DIR}/../../../automation/inventory/hosts.yaml}"
BUILD_NODE="${BUILD_NODE:-control-plane}"
ASK_PASS="${ASK_PASS:-0}"
ANSIBLE_PASS="${ANSIBLE_PASS:-}"

# When ASK_PASS=1, --ask-pass is added to every ansible invocation. Default
# is to rely on ansible_password / ansible_ssh_private_key_file from the
# inventory so this script is usable in unattended CI runs.
ASK_PASS_FLAG=""
if [ "${ASK_PASS}" = "1" ]; then
    ASK_PASS_FLAG="--ask-pass"
fi
ANSIBLE_PASS_FLAG=""
if [ -n "${ANSIBLE_PASS}" ]; then
    ANSIBLE_PASS_FLAG="-e ansible_password=${ANSIBLE_PASS}"
fi

# OCI archive ref name. Without this annotation `ctr images import` keeps the
# blobs but does NOT (re)bind the destination tag, leaving operators in a
# confusing stale-:latest state. The tar gets `org.opencontainers.image.ref.name`
# set explicitly via the `oci-archive:<path>:<ref>` syntax below.
OCI_REF="${FULL_IMAGE}"

echo "=========================================="
echo "Build RDMA Test Tools Image on Node"
echo "=========================================="
echo "Image:       ${FULL_IMAGE}"
echo "Build node:  ${BUILD_NODE}"
echo "Inventory:   ${INVENTORY}"
echo "Ask-pass:    ${ASK_PASS}"
echo ""

if [ ! -f "${INVENTORY}" ]; then
    echo "✗ Error: Inventory file not found: ${INVENTORY}"
    exit 1
fi

# Step 1: Create tarball of build context
echo "[1/5] Creating build context tarball..."
TARBALL="/tmp/rdma-build-context-$(date +%Y%m%d-%H%M%S).tar.gz"
cd "${SCRIPT_DIR}"
tar czf "${TARBALL}" Dockerfile build.sh README.md hfi1_user.h

echo "✓ Build context: ${TARBALL} ($(du -h ${TARBALL} | cut -f1))"

# Step 2: Copy build context to build node
echo ""
echo "[2/5] Copying build context to ${BUILD_NODE}..."
cd "$(dirname ${INVENTORY})/../playbooks"

ansible -i "${INVENTORY}" "${BUILD_NODE}" -m copy -a "src=${TARBALL} dest=/tmp/" ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG}

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to copy build context"
    rm -f "${TARBALL}"
    exit 1
fi

TARBALL_NAME=$(basename "${TARBALL}")

# Step 3: Extract and build on node
echo ""
echo "[3/5] Building image on ${BUILD_NODE}..."
echo "  (This will take ~30-45 minutes - source-build libfabric/OPX + Open MPI + OSU benchmarks)"

ansible -i "${INVENTORY}" "${BUILD_NODE}" -m shell \
    -a "cd /tmp && rm -rf rdma-build && mkdir -p rdma-build && cd rdma-build && tar xzf /tmp/${TARBALL_NAME} && buildah bud --shm-size=5120m -f Dockerfile -t ${FULL_IMAGE} . >/tmp/rdma-build.log 2>&1; rc=\$?; tail -100 /tmp/rdma-build.log; exit \$rc" \
    --timeout 7200 \
    ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG}

BUILD_RESULT=$?

if [ ${BUILD_RESULT} -ne 0 ]; then
    echo ""
    echo "✗ Error: Image build failed on ${BUILD_NODE}"
    rm -f "${TARBALL}"
    exit 1
fi

# Step 4: Save and distribute to other nodes
echo ""
echo "[4/5] Saving image to OCI archive on ${BUILD_NODE}..."

IMAGE_TARBALL="rdma-test-tools-image.tar"

# CRITICAL: the `:${OCI_REF}` suffix sets the ref.name annotation so
# `ctr -n k8s.io images import` rebinds the destination tag. Without it the
# blobs land but the tag pointer stays on the prior image — silent staleness.
ansible -i "${INVENTORY}" "${BUILD_NODE}" -m shell -a "rm -f /tmp/${IMAGE_TARBALL} && buildah push ${FULL_IMAGE} oci-archive:/tmp/${IMAGE_TARBALL}:${OCI_REF}" ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG}

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to save image"
    rm -f "${TARBALL}"
    exit 1
fi

# Step 5: Copy to other nodes and import
echo ""
echo "[5/5] Distributing image to all cluster nodes..."

# First, fetch the image tarball from build node
echo "  Fetching image from ${BUILD_NODE}..."
ansible -i "${INVENTORY}" "${BUILD_NODE}" -m fetch -a "src=/tmp/${IMAGE_TARBALL} dest=/tmp/${IMAGE_TARBALL} flat=yes" ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG}

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to fetch image from ${BUILD_NODE}"
    rm -f "${TARBALL}"
    exit 1
fi

# Copy to all nodes
echo "  Copying to all nodes..."
ansible -i "${INVENTORY}" k8s_nodes -m copy -a "src=/tmp/${IMAGE_TARBALL} dest=/tmp/" ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG}

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to copy image to nodes"
    rm -f "${TARBALL}" "/tmp/${IMAGE_TARBALL}"
    exit 1
fi

# Import on all nodes: remove stale tag first so :latest gets rebound cleanly,
# then import. The `|| true` on the rm keeps fresh nodes (no prior tag) silent.
echo "  Importing on all nodes..."
ansible -i "${INVENTORY}" k8s_nodes -m shell -a "ctr -n k8s.io images rm ${FULL_IMAGE} 2>/dev/null || true; ctr -n k8s.io images import /tmp/${IMAGE_TARBALL} && rm -f /tmp/${IMAGE_TARBALL}" ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG}

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to import image on nodes"
    rm -f "${TARBALL}" "/tmp/${IMAGE_TARBALL}"
    exit 1
fi

# Cleanup
echo ""
echo "Cleaning up..."
ansible -i "${INVENTORY}" "${BUILD_NODE}" -m shell -a "rm -rf /tmp/rdma-build /tmp/${TARBALL_NAME}" ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG} > /dev/null 2>&1
rm -f "${TARBALL}" "/tmp/${IMAGE_TARBALL}"

echo ""
echo "=========================================="
echo "✓ Image built and deployed successfully!"
echo "=========================================="
echo ""
echo "Verify on nodes:"
echo "  ansible -i ${INVENTORY} k8s_nodes -m shell -a 'crictl images | grep rdma-test' ${ASK_PASS_FLAG} ${ANSIBLE_PASS_FLAG}"
echo ""
