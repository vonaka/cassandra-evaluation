#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
    echo "Usage: $0 <remote-host> <remote-dir>"
    echo "  Example: $0 user@remote-host '~/accord'"
    exit 0
}

die() { echo "Error: $*" >&2; exit 1; }

[ $# -eq 2 ] || { usage; exit 1; }
REMOTE_HOST="$1"
REMOTE_DIR="$2"

TMPCSV=$(mktemp /tmp/cdf_XXXXXX.csv)
trap "rm -f ${TMPCSV}" EXIT

scp -q "${REMOTE_HOST}:${REMOTE_DIR}/Docker/results/cdf.csv" "${TMPCSV}"

python3 - "${TMPCSV}" <<'PYEOF'
import csv, sys
from collections import defaultdict

path = sys.argv[1]
with open(path) as f:
    rows = list(csv.DictReader(f))

protocols = sorted({r['protocol'] for r in rows})
ops       = sorted({r['op']       for r in rows if r['p100'] != 'unknown'})
cities    = sorted({r['city']     for r in rows if r['p100'] != 'unknown'})

PCTS = ('avg', 'p50', 'p95', 'p99', 'p100')

def fmt_i(v):
    return f"{v:>8}"

def fmt_f(v):
    return f"{float(v)/1000:>8.1f}" if v and v != 'unknown' else f"{'N/A':>8}"

def get_vals(r):
    return {
        'avg':  r.get('avg_latency_us', 'unknown'),
        'p50':  r.get('p50', 'unknown'),
        'p95':  r.get('p95', 'unknown'),
        'p99':  r.get('p99', 'unknown'),
        'p100': r.get('p100', 'unknown'),
    }

HDR = f"  {'protocol':<22} {'op':<12} {'p50(ms)':>8} {'p95(ms)':>8} {'p99(ms)':>8} {'p100(ms)':>9} {'avg(ms)':>8}"
SEP = f"  {'-'*22} {'-'*12} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8}"

def print_row(proto, op, vals):
    print(f"  {proto:<22} {op:<12}", end="")
    for p in ('p50', 'p95', 'p99', 'p100'):
        v = vals[p]
        print(fmt_i(int(v)) if v and v != 'unknown' else f"{'N/A':>8}", end="")
    print(fmt_f(vals['avg']), end="")
    print()

# ── Per city ──────────────────────────────────────────────────────────────────
print("=" * 78)
print("PER CITY  (latencies in ms)")
print("=" * 78)
for city in cities:
    print(f"\n  {city}")
    print(HDR)
    print(SEP)
    for proto in protocols:
        for op in ops:
            matches = [r for r in rows if r['protocol']==proto and r['op']==op and r['city']==city and r['p100']!='unknown']
            if not matches:
                continue
            print_row(proto, op, get_vals(matches[0]))

# ── All sites (max across cities) ─────────────────────────────────────────────
print()
print("=" * 78)
print("ALL SITES — max across cities  (latencies in ms)")
print("=" * 78)
print(HDR)
print(SEP)
agg = defaultdict(lambda: {'avg': 0.0, 'p50': 0, 'p95': 0, 'p99': 0, 'p100': 0})
for r in rows:
    if r['p100'] == 'unknown':
        continue
    key = (r['protocol'], r['op'])
    v = get_vals(r)
    if v['avg'] and v['avg'] != 'unknown':
        agg[key]['avg'] = max(agg[key]['avg'], float(v['avg']))
    for p in ('p50', 'p95', 'p99', 'p100'):
        if v[p] and v[p] != 'unknown':
            agg[key][p] = max(agg[key][p], int(v[p]))
for proto in protocols:
    for op in ops:
        key = (proto, op)
        if key not in agg:
            continue
        print_row(proto, op, {p: str(agg[key][p]) for p in PCTS})
PYEOF
