#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE_TAG="local/cassandra-accord:latest"

usage() {
    echo "Usage: $0 <remote-host> <remote-dir>"
    echo "  Copies evaluation scripts and Docker image to the remote machine."
    echo "  Example: $0 user@remote-host ~/accord"
    exit 0
}

die() { echo "Error: $*" >&2; exit 1; }

[ $# -eq 2 ] || { usage; exit 1; }
REMOTE_HOST="$1"
REMOTE_DIR="$2"

# Check Docker access locally
if docker info >/dev/null 2>&1; then
    USE_SG_DOCKER=0
elif sg docker -c "docker info" >/dev/null 2>&1; then
    USE_SG_DOCKER=1
else
    die "Docker is not accessible. Make sure Docker is running and you are in the 'docker' group."
fi

# Check the image exists locally
if [ "$USE_SG_DOCKER" -eq 1 ]; then
    sg docker -c "docker image inspect ${IMAGE_TAG}" >/dev/null 2>&1 \
        || die "Image '${IMAGE_TAG}' not found locally. Run build_accord_image.sh first."
else
    docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1 \
        || die "Image '${IMAGE_TAG}' not found locally. Run build_accord_image.sh first."
fi

# ── Step 1: Sync evaluation scripts ──────────────────────────────────────────
echo "[1/3] Syncing evaluation scripts to ${REMOTE_HOST}:${REMOTE_DIR}..."
ssh "${REMOTE_HOST}" "mkdir -p ${REMOTE_DIR}"
rsync -avz --delete \
    --exclude '.git/' \
    --exclude 'Docker/logs/' \
    --exclude 'Docker/results/' \
    "${SCRIPT_DIR}/" "${REMOTE_HOST}:${REMOTE_DIR}/"

# ── Step 2: Prune Docker on remote ───────────────────────────────────────────
echo "[2/4] Pruning unused Docker data on remote..."
ssh "${REMOTE_HOST}" "docker system prune -f --volumes && sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log 2>/dev/null || true"

# ── Step 3: Transfer Docker image ─────────────────────────────────────────────
echo "[3/4] Transferring Docker image '${IMAGE_TAG}' (streaming directly to remote)..."
if [ "$USE_SG_DOCKER" -eq 1 ]; then
    sg docker -c "docker save ${IMAGE_TAG}" | gzip | ssh "${REMOTE_HOST}" "docker load"
else
    docker save "${IMAGE_TAG}" | gzip | ssh "${REMOTE_HOST}" "docker load"
fi

# ── Step 3: Remote setup ──────────────────────────────────────────────────────
echo "[4/4] Setting up remote environment..."
ssh "${REMOTE_HOST}" bash <<REMOTE
set -euo pipefail

mkdir -p "${REMOTE_DIR}/Docker/logs"
mkdir -p "${REMOTE_DIR}/Docker/results"

if ! python3 -c "import docker" 2>/dev/null; then
    echo "  Installing python3-docker..."
    sudo apt-get install -y python3-docker
else
    echo "  python3-docker already installed."
fi
REMOTE

echo ""
echo "Done. To run the benchmark:"
echo "  ssh ${REMOTE_HOST}"
echo "  cd ${REMOTE_DIR}/Docker && ./cdf.sh --protocols=accord --nodes=3"
