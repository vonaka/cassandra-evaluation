#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCAL_RESULTS="${SCRIPT_DIR}/Docker/results"

usage() {
    echo "Usage: $0 <remote-host> <remote-dir>"
    echo "  Example: $0 user@remote-host '~/accord'"
    exit 0
}

die() { echo "Error: $*" >&2; exit 1; }

[ $# -eq 2 ] || { usage; exit 1; }
REMOTE_HOST="$1"
REMOTE_DIR="$2"

mkdir -p "${LOCAL_RESULTS}"

scp "${REMOTE_HOST}:${REMOTE_DIR}/Docker/results/cdf.pdf" "${LOCAL_RESULTS}/cdf.pdf"

evince "${LOCAL_RESULTS}/cdf.pdf"
