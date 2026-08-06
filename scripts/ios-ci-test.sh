#!/usr/bin/env bash
# Build and test iOS in distinct measured phases using one explicit DerivedData.

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ios_dir="$root_dir/packages/ios-app"
derived_data="${TRON_IOS_CI_DERIVED_DATA:-$ios_dir/build/ci-derived-data}"
result_bundle="${TRON_IOS_CI_RESULT_BUNDLE:-$ios_dir/build/TestResults.xcresult}"
metrics_path="${TRON_IOS_CI_METRICS:-$ios_dir/build/ios-ci-metrics.json}"
enumeration_path="${TRON_IOS_CI_ENUMERATION:-$ios_dir/build/ios-test-enumeration.json}"
destination="${TRON_IOS_CI_DESTINATION:-platform=iOS Simulator,OS=26.2,name=iPhone 17 Pro}"
parallel_workers="${TRON_IOS_CI_PARALLEL_WORKERS:-1}"

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

start_build="$(date +%s)"
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
  start_test="$(date +%s)"
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

if [[ "$build_status" -ne 0 ]]; then
  exit "$build_status"
fi
exit "$test_status"
