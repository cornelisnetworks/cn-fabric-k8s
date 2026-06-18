#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-localhost/cornelis/rdma-test-tools}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
INVENTORY="${INVENTORY:-../../../automation/inventory/hosts.yaml}"

echo "=========================================="
echo "Build and Deploy RDMA Test Tools Image"
echo "=========================================="
echo "Image: ${FULL_IMAGE}"
echo "Inventory: ${INVENTORY}"
echo ""

# Step 1: Build the image locally
echo "[1/4] Building image locally..."
cd "${SCRIPT_DIR}"
# Pass IMAGE_NAME and IMAGE_TAG to ensure build.sh uses the same name/tag
IMAGE_NAME="${IMAGE_NAME}" IMAGE_TAG="${IMAGE_TAG}" ./build.sh

if [ $? -ne 0 ]; then
    echo "✗ Error: Image build failed"
    exit 1
fi

# Step 2: Save image to tarball
echo ""
echo "[2/4] Saving image to tarball..."
TARBALL="/tmp/rdma-test-tools-$(date +%Y%m%d-%H%M%S).tar"

# Detect container builder
if command -v nerdctl &> /dev/null; then
    BUILDER="nerdctl"
elif command -v docker &> /dev/null; then
    BUILDER="docker"
else
    echo "✗ Error: No container builder found (nerdctl or docker)"
    exit 1
fi

${BUILDER} save -o "${TARBALL}" "${FULL_IMAGE}"

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to save image"
    exit 1
fi

echo "✓ Image saved to: ${TARBALL}"
echo "  Size: $(du -h ${TARBALL} | cut -f1)"

# Step 3: Copy tarball to all nodes
echo ""
echo "[3/4] Copying image to cluster nodes..."

if [ ! -f "${INVENTORY}" ]; then
    echo "✗ Error: Inventory file not found: ${INVENTORY}"
    exit 1
fi

cd "$(dirname ${INVENTORY})/../playbooks"

ansible -i "${INVENTORY}" k8s_nodes -m copy -a "src=${TARBALL} dest=/tmp/" --ask-pass

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to copy image to nodes"
    exit 1
fi

# Step 4: Import image on all nodes
echo ""
echo "[4/4] Importing image on all nodes..."

TARBALL_NAME=$(basename "${TARBALL}")

ansible -i "${INVENTORY}" k8s_nodes -m shell -a "ctr -n k8s.io images import /tmp/${TARBALL_NAME} && rm -f /tmp/${TARBALL_NAME}" --ask-pass

if [ $? -ne 0 ]; then
    echo "✗ Error: Failed to import image on nodes"
    exit 1
fi

# Cleanup local tarball
rm -f "${TARBALL}"

echo ""
echo "=========================================="
echo "✓ Image deployed successfully!"
echo "=========================================="
echo ""
echo "Verify on nodes:"
echo "  ansible -i ${INVENTORY} k8s_nodes -m shell -a 'crictl images | grep rdma-test' --ask-pass"
echo ""
