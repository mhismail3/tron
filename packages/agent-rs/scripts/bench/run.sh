#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/scripts/bench/baselines"
STAMP="$(date +"%Y%m%d-%H%M%S")"
OUT_FILE="${OUT_DIR}/baseline-${STAMP}.json"

mkdir -p "${OUT_DIR}"

echo "Running tron-bench scenarios..."
cargo run -p tron-bench --release -- \
  --scenario all \
  --iterations 100 \
  --concurrency 16 \
  --output "${OUT_FILE}"

echo "Benchmark baseline written to: ${OUT_FILE}"
