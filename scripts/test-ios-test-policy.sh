#!/usr/bin/env bash
# Static ownership policy for deterministic iOS simulator test execution.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "iOS test policy: $*" >&2; exit 1; }

runner="$ROOT/scripts/tron-ios-test"
e2e="$ROOT/scripts/ios-gateway-e2e-test"
ci="$ROOT/scripts/ios-ci-test.sh"
development="$ROOT/scripts/tron-ios-simulator"

[[ -x "$runner" && -x "$ROOT/scripts/ios-test-process.py" && -x "$ROOT/scripts/ios-test-simulator.py" ]] \
  || fail "canonical runner owners must be executable"
grep -Fq 'ios-test-process.py' "$runner" || fail "unit runner bypasses the process owner"
grep -Fq -- '-collect-test-diagnostics "$diagnostics"' "$runner" || fail "unit runner lacks explicit diagnostic policy"
grep -Fq 'run_tests never' "$runner" || fail "routine unit tests must disable diagnostic collection"
grep -Fq 'run_tests always' "$runner" || fail "verbose collection must remain explicit diagnose behavior"
grep -Fq 'platform=iOS Simulator,id=$simulator_id' "$runner" || fail "unit runner lacks exact-UDID destination"

grep -Fq 'ios-test-process.py' "$e2e" || fail "E2E bypasses the process owner"
grep -Fq 'ios-test-simulator.py' "$e2e" || fail "E2E bypasses the simulator owner"
grep -Fq -- '-collect-test-diagnostics never' "$e2e" || fail "routine E2E diagnostics must be disabled"
! grep -Fq 'DiagnosticCollectionPolicy' "$e2e" || fail "E2E must not patch numeric diagnostic policy"
! grep -Eq 'platform=iOS Simulator,(OS=[^,]+,)?name=' "$e2e" || fail "E2E contains a name-only destination"

! grep -Eq 'xcodebuild[[:space:]]+(build-for-testing|test-without-building|test([[:space:]]|$))' "$development" \
  || fail "Development simulator helper must never run tests"
! grep -Fq 'xcodebuild' "$ci" || fail "CI adapter must not own an Xcode command body"
! grep -Fq -- '-destination' "$ci" || fail "CI adapter must not construct destinations"

grep -Fq 'if: always()' "$ROOT/.github/workflows/ci.yml" || fail "CI evidence/cleanup must be unconditional"
grep -Fq 'scripts/ios-ci-test.sh cleanup' "$ROOT/.github/workflows/ci.yml" || fail "CI lacks exact owned-simulator cleanup"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$ROOT/.github/workflows/ci.yml" \
  || fail "CI artifact uploader must be pinned"

python3 - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
active = [root / name for name in ("AGENTS.md", "README.md", "CONTRIBUTING.md", "packages/ios-app/README.md")]
active += sorted((root / "packages/ios-app/docs").glob("*.md"))
active += [root / ".agents/skills/tron-ios/SKILL.md"]
name_destination = re.compile(r"platform=iOS Simulator,(?:OS=[^,]+,)?name=")
raw_test = re.compile(r"xcodebuild\s+(?:build-for-testing|test-without-building)")
for path in active:
    text = path.read_text()
    if name_destination.search(text):
        raise SystemExit(f"name-only simulator destination in active guidance: {path.relative_to(root)}")
    raw_matches = [
        match for match in raw_test.finditer(text)
        if "TronMac" not in text[match.start():match.start() + 240]
        and "Tron Device Performance" not in text[match.start():match.start() + 240]
    ]
    if raw_matches:
        raise SystemExit(f"raw Xcode test recipe in active guidance: {path.relative_to(root)}")
workflow = (root / ".github/workflows/ci.yml").read_text()
manifest = (root / "config/ci-toolchain.env").read_text()
xcode_pin = re.search(r"^TRON_CI_XCODE_VERSION=(.+)$", manifest, re.M).group(1)
if re.search(rf'xcode-version:\s*["\']?{re.escape(xcode_pin)}', workflow):
    raise SystemExit("workflow duplicates the manifest Xcode version literal")
for deleted in ("scripts/generate-ios-icons.mjs", "packages/ios-app/package.json", "packages/ios-app/bun.lock"):
    for path in [item for item in active if item.name != "test-execution-simulator-consolidation-plan.md"] + [root / ".github/workflows/ci.yml"]:
        if deleted in path.read_text():
            raise SystemExit(f"active reference to deleted orphan: {path.relative_to(root)} -> {deleted}")
print("iOS test execution ownership policy passed")
PY
