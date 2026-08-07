#!/usr/bin/env bash
# Build and test iOS in distinct measured phases using one explicit DerivedData.

set -euo pipefail

log_ci_event() {
  local event="$1" details="${2:-}" timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  details="${details//$'\r'/ }"
  details="${details//$'\n'/ }"
  printf 'timestamp=%s level=info component=ios-ci-test event=%s%s\n' \
    "$timestamp" "$event" "$([[ -n "$details" ]] && printf ' %s' "$details")"
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios_dir="$root_dir/packages/ios-app"
derived_data="${TRON_IOS_CI_DERIVED_DATA:-$ios_dir/build/ci-derived-data}"
result_bundle="${TRON_IOS_CI_RESULT_BUNDLE:-$ios_dir/build/TestResults.xcresult}"
metrics_path="${TRON_IOS_CI_METRICS:-$ios_dir/build/ios-ci-metrics.json}"
enumeration_path="${TRON_IOS_CI_ENUMERATION:-$ios_dir/build/ios-test-enumeration.json}"
destination="${TRON_IOS_CI_DESTINATION:-platform=iOS Simulator,OS=26.2,name=iPhone 17 Pro}"
parallel_workers="${TRON_IOS_CI_PARALLEL_WORKERS:-1}"
enumerate_tests="${TRON_IOS_CI_ENUMERATE_TESTS:-false}"

mkdir -p "$(dirname "$metrics_path")" "$(dirname "$result_bundle")"
for generated_output in "$result_bundle" "$enumeration_path" "$metrics_path"; do
  if [[ -e "$generated_output" ]]; then
    case "$generated_output" in
      "$ios_dir"/build/*) rm -rf -- "$generated_output" ;;
      *) echo "error: refusing to replace generated output outside packages/ios-app/build: $generated_output" >&2; exit 1 ;;
    esac
  fi
done
cd "$ios_dir"

log_ci_event ci_started \
  "destination='$destination' parallel_workers=$parallel_workers enumerate_tests=$enumerate_tests"
start_build="$(date +%s)"
log_ci_event build_started "scheme=Tron_Beta action=build-for-testing"
set +e
xcodebuild build-for-testing \
  -project TronMobile.xcodeproj \
  -scheme 'Tron Beta' \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  -showBuildTimingSummary \
  -quiet
build_status=$?
set -e
end_build="$(date +%s)"
log_ci_event build_completed \
  "exit_status=$build_status duration_seconds=$((end_build - start_build))"

start_test="$end_build"
end_test="$end_build"
test_status=125
if [[ "$build_status" -eq 0 ]]; then
  test_args=()
  if [[ "$parallel_workers" -gt 1 ]]; then
    test_args+=( -parallel-testing-enabled YES -parallel-testing-worker-count "$parallel_workers" )
  else
    test_args+=( -parallel-testing-enabled NO )
  fi
  if [[ "$enumerate_tests" == "true" ]]; then
    log_ci_event enumeration_started "format=json style=flat"
    xcodebuild test-without-building \
      -project TronMobile.xcodeproj \
      -scheme 'Tron Beta' \
      -destination "$destination" \
      -derivedDataPath "$derived_data" \
      -enumerate-tests \
      -test-enumeration-style flat \
      -test-enumeration-format json \
      -test-enumeration-output-path "$enumeration_path" \
      -quiet
    log_ci_event enumeration_completed "format=json style=flat"
  fi
  start_test="$(date +%s)"
  log_ci_event test_started \
    "action=test-without-building parallel_workers=$parallel_workers"
  set +e
  xcodebuild test-without-building \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    -showBuildTimingSummary \
    "${test_args[@]}" \
    -quiet
  test_status=$?
  set -e
  end_test="$(date +%s)"
  log_ci_event test_completed \
    "exit_status=$test_status duration_seconds=$((end_test - start_test))"
fi

summary_path="$(mktemp)"
trap 'rm -f "$summary_path"' EXIT
if [[ -d "$result_bundle" ]]; then
  xcrun xcresulttool get test-results summary --path "$result_bundle" > "$summary_path" 2>/dev/null || printf '{}\n' > "$summary_path"
else
  printf '{}\n' > "$summary_path"
fi
TRON_BUILD_SECONDS="$((end_build - start_build))" \
TRON_BUILD_STATUS="$build_status" \
TRON_TEST_SECONDS="$((end_test - start_test))" \
TRON_TEST_STATUS="$test_status" \
TRON_PARALLEL_WORKERS="$parallel_workers" \
TRON_XCRESULT_SUMMARY="$summary_path" \
TRON_TEST_ENUMERATION="$enumeration_path" \
TRON_METRICS_PATH="$metrics_path" \
python3 - <<'PY'
import hashlib, json, os, platform, subprocess
from pathlib import Path

summary_bytes = Path(os.environ["TRON_XCRESULT_SUMMARY"]).read_bytes()
summary = json.loads(summary_bytes)
counts = {}
for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"):
    value = summary.get(key)
    if isinstance(value, int):
        counts[key] = value
manifest = Path("../../config/ci-toolchain.env").read_bytes()
enumeration = Path(os.environ["TRON_TEST_ENUMERATION"])
document = {
    "schema": "tron.ios-ci-metrics.v1",
    "build_seconds": int(os.environ["TRON_BUILD_SECONDS"]),
    "build_exit_code": int(os.environ["TRON_BUILD_STATUS"]),
    "test_seconds": int(os.environ["TRON_TEST_SECONDS"]),
    "test_exit_code": int(os.environ["TRON_TEST_STATUS"]),
    "parallel_workers": int(os.environ["TRON_PARALLEL_WORKERS"]),
    "enumerated_tests": enumeration.exists(),
    "counts": counts,
    "runner_arch": platform.machine(),
    "runner_os": platform.platform(),
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "sdk": subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip(),
    "toolchain_manifest_sha256": hashlib.sha256(manifest).hexdigest(),
    "xcresult_summary_sha256": hashlib.sha256(summary_bytes).hexdigest(),
    "test_enumeration_sha256": hashlib.sha256(enumeration.read_bytes()).hexdigest() if enumeration.exists() else None,
}
Path(os.environ["TRON_METRICS_PATH"]).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY

metrics_sha256="$(shasum -a 256 "$metrics_path" | awk '{print $1}')"
log_ci_event metrics_written \
  "schema=tron.ios-ci-metrics.v1 sha256=$metrics_sha256"

if [[ "$build_status" -ne 0 ]]; then
  log_ci_event ci_completed "exit_status=$build_status phase=build"
  exit "$build_status"
fi
log_ci_event ci_completed "exit_status=$test_status phase=test"
exit "$test_status"
