#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOCKER_BUILD_CONTEXT="${SCRIPT_DIR}/../cassandra-docker-library/5.1-accord"
CONFIG_FILE="${SCRIPT_DIR}/Docker/exp.config"
IMAGE_TAG="local/cassandra-accord:latest"

usage() {
    echo "Usage: $0 <cassandra-source-dir>"
    echo "  Patches cassandra.yaml with Accord settings, builds Cassandra,"
    echo "  and creates Docker image '${IMAGE_TAG}'."
    exit 0
}

die() { echo "Error: $*" >&2; exit 1; }

[ $# -eq 1 ] || { usage; exit 1; }
CASSANDRA_SRC=$(cd "$1" && pwd) || die "Cannot access directory '$1'"

[ -f "${CASSANDRA_SRC}/build.xml" ]          || die "'${CASSANDRA_SRC}' does not look like a Cassandra source tree (missing build.xml)"
[ -f "${CASSANDRA_SRC}/conf/cassandra.yaml" ] || die "'${CASSANDRA_SRC}/conf/cassandra.yaml' not found"
[ -d "${DOCKER_BUILD_CONTEXT}" ]              || die "Docker build context not found: ${DOCKER_BUILD_CONTEXT}"
[ -f "${CONFIG_FILE}" ]                        || die "exp.config not found: ${CONFIG_FILE}"

# Check Docker access (local machines may require sg docker)
if docker info >/dev/null 2>&1; then
    USE_SG_DOCKER=0
elif sg docker -c "docker info" >/dev/null 2>&1; then
    USE_SG_DOCKER=1
else
    die "Docker is not accessible. Make sure Docker is running and you are in the 'docker' group."
fi

# ── Step 1: Patch cassandra.yaml ─────────────────────────────────────────────
echo "[1/4] Patching accord settings in ${CASSANDRA_SRC}/conf/cassandra.yaml..."
python3 - "${CASSANDRA_SRC}/conf/cassandra.yaml" <<'PYEOF'
import sys, re

yaml_path = sys.argv[1]
with open(yaml_path, 'r') as f:
    content = f.read()

ACCORD_BLOCK = """accord:
  enabled: true
  queue_submission_model: SIGNAL
  queue_thread_count: 8
  replica_execution: ALL
  send_stable: FOR_READS_OR_NONE_IF_FASTEXEC
  send_minimal: false
  ephemeral_reads: true
  fast_read_execution: MAY_BYPASS_COMMANDSFORKEY
  fast_write_execution: MAY_BYPASS_COMMANDSFORKEY
  shard_durability_target_splits: 8
  shard_durability_max_splits: 16
  command_store_shard_count: 8
  shard_durability_cycle: 1m
  catchup_on_start_fail_latency: 2m"""

lines = content.splitlines(keepends=True)
accord_start = next((i for i, l in enumerate(lines) if re.match(r'^accord\s*:', l)), None)

if accord_start is not None:
    accord_end = accord_start + 1
    while accord_end < len(lines):
        l = lines[accord_end]
        if l.strip() and l[0] not in (' ', '\t', '#'):
            break
        accord_end += 1
    new_lines = lines[:accord_start] + [ACCORD_BLOCK + '\n'] + lines[accord_end:]
    action = "updated"
else:
    new_lines = lines + ['\n' + ACCORD_BLOCK + '\n']
    action = "appended"

with open(yaml_path, 'w') as f:
    f.writelines(new_lines)
print(f"  accord block {action} in {yaml_path}")
PYEOF

# ── Step 2: Build Cassandra ───────────────────────────────────────────────────
echo "[2/4] Building Cassandra with 'ant artifacts' (this will take a while)..."
cd "${CASSANDRA_SRC}"
ant realclean
ant artifacts

TARBALL=$(ls build/apache-cassandra-*-bin.tar.gz 2>/dev/null | head -1)
[ -n "${TARBALL}" ] || die "No build/apache-cassandra-*-bin.tar.gz found after 'ant artifacts'"
echo "  Built: ${TARBALL}"

# ── Step 3: Build Docker image ────────────────────────────────────────────────
echo "[3/4] Building Docker image '${IMAGE_TAG}'..."
cp "${CASSANDRA_SRC}/${TARBALL}" "${DOCKER_BUILD_CONTEXT}/cassandra-bin.tgz"
if [ "$USE_SG_DOCKER" -eq 1 ]; then
    sg docker -c "docker build -t ${IMAGE_TAG} ${DOCKER_BUILD_CONTEXT}"
else
    docker build -t "${IMAGE_TAG}" "${DOCKER_BUILD_CONTEXT}"
fi

# ── Step 4: Update exp.config ─────────────────────────────────────────────────
echo "[4/4] Updating ${CONFIG_FILE}..."
if grep -q '^accord_cassandra_image=' "${CONFIG_FILE}"; then
    sed -i "s|^accord_cassandra_image=.*|accord_cassandra_image=${IMAGE_TAG}|" "${CONFIG_FILE}"
else
    echo "accord_cassandra_image=${IMAGE_TAG}" >> "${CONFIG_FILE}"
fi
echo "  accord_cassandra_image=${IMAGE_TAG}"

echo ""
echo "Done. '${IMAGE_TAG}' is ready. Run the benchmark with:"
echo "  cd ${SCRIPT_DIR}/Docker && ./cdf.sh --protocols=accord --nodes=3"
