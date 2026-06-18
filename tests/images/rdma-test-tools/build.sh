#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-cornelis/rdma-test-tools}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=========================================="
echo "Building RDMA Test Tools Container Image"
echo "=========================================="
echo "Image: ${FULL_IMAGE}"
echo "Build context: ${SCRIPT_DIR}"
echo ""

# Detect container builder
if command -v nerdctl &> /dev/null; then
    BUILDER="nerdctl"
elif command -v docker &> /dev/null; then
    BUILDER="docker"
else
    echo "✗ Error: No container builder found (nerdctl or docker)"
    exit 1
fi

echo "Using builder: ${BUILDER}"
echo ""

echo "Building image..."
if ! ${BUILDER} build \
    -f "${SCRIPT_DIR}/Dockerfile" \
    -t "${FULL_IMAGE}" "${SCRIPT_DIR}"; then
    echo ""
    echo "✗ Image build failed"
    exit 1
fi

echo ""
echo "✓ Image built successfully: ${FULL_IMAGE}"
echo ""
echo "Image details:"
${BUILDER} images "${IMAGE_NAME}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" 2>/dev/null || ${BUILDER} images "${IMAGE_NAME}"
echo ""
echo "To push to registry:"
echo "  ${BUILDER} push ${FULL_IMAGE}"
echo ""
echo "To test the image:"
echo "  ${BUILDER} run --rm -it ${FULL_IMAGE} bash"
echo "  # Inside container:"
echo "  #   ucx_info -v"
echo "  #   mpirun --version"
echo "  #   ibv_devinfo --version"
