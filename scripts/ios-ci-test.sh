#!/usr/bin/env bash
# Thin CI adapter: the canonical runner owns toolchain, simulator, process, and test semantics.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/packages/ios-app"
ci_identity="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-ios}"
ci_identity="${ci_identity//[^A-Za-z0-9._-]/-}"

export TRON_IOS_TEST_EPHEMERAL=1
export TRON_IOS_TEST_DEVICE_NAME="Tron iOS Tests CI $ci_identity"
export TRON_IOS_TEST_STATE_DIR="${RUNNER_TEMP:-$IOS/build}/tron-ios-test-state-$ci_identity"
export TRON_IOS_TEST_DERIVED_DATA="${TRON_IOS_CI_DERIVED_DATA:-$IOS/build/ci-derived-data}"
export TRON_IOS_TEST_RESULTS_DIR="${TRON_IOS_CI_RESULTS_DIR:-$IOS/build/test-runs}"
metrics_path="${TRON_IOS_CI_METRICS:-$IOS/build/ios-ci-metrics.json}"

if [[ "${1:-run}" == cleanup ]]; then
  TRON_IOS_TEST_PRESERVE_ARTIFACTS=1 exec "$ROOT/scripts/tron-ios-test" clean
elif (($#)); then
  echo "usage: scripts/ios-ci-test.sh [cleanup]" >&2
  exit 64
fi

cleanup_simulator() {
  TRON_IOS_TEST_PRESERVE_ARTIFACTS=1 "$ROOT/scripts/tron-ios-test" clean >/dev/null 2>&1 || true
}
trap cleanup_simulator EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

set +e
"$ROOT/scripts/tron-ios-test" checkpoint
status=$?
set -e

mkdir -p "$(dirname "$metrics_path")"
TRON_CI_STATUS="$status" TRON_CI_RESULTS="$TRON_IOS_TEST_RESULTS_DIR" TRON_CI_METRICS="$metrics_path" \
python3 - <<'PY'
import json, os
from pathlib import Path
results = Path(os.environ["TRON_CI_RESULTS"])
latest = results / "latest"
metadata = {}
summary = {}
processes = {}
if latest.is_symlink():
    run = latest.resolve()
    try: metadata = json.loads((run / "metadata.json").read_text())
    except (OSError, json.JSONDecodeError): pass
    try: summary = json.loads((run / "summary.json").read_text())
    except (OSError, json.JSONDecodeError): pass
    for phase in ("build", "test"):
        try: processes[phase] = json.loads((run / f"{phase}-evidence/process.json").read_text())
        except (OSError, json.JSONDecodeError): pass
value = {
    "schema": "tron.ios-ci-metrics.v2",
    "exit_code": int(os.environ["TRON_CI_STATUS"]),
    "run": metadata,
    "processes": processes,
    "test_summary": summary,
}
Path(os.environ["TRON_CI_METRICS"]).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
PY

exit "$status"
