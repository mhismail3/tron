#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <baseline-json> [iterations] [concurrency]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE="$1"
ITERATIONS="${2:-100}"
CONCURRENCY="${3:-16}"
OUT_DIR="${ROOT_DIR}/scripts/bench/baselines"
STAMP="$(date +"%Y%m%d-%H%M%S")"
OUT_FILE="${OUT_DIR}/compare-${STAMP}.json"

mkdir -p "${OUT_DIR}"

echo "Running benchmark comparison against baseline: ${BASELINE}"
cargo run -p tron-bench --release -- \
  --scenario all \
  --iterations "${ITERATIONS}" \
  --concurrency "${CONCURRENCY}" \
  --baseline "${BASELINE}" \
  --enforce-gates \
  --output "${OUT_FILE}"

echo "Comparison report written to: ${OUT_FILE}"
