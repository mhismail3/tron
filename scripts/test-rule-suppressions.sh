#!/usr/bin/env bash
# Real ast-grep CLI regression for source-comment suppression bypasses.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_dir="$(mktemp -d "$ROOT/packages/ios-app/Sources/UI/.rule-suppression.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
probe="$probe_dir/Probe.swift"
relative="${probe#"$ROOT"/}"
expect_failure() {
  local name="$1" expected="$2" output status
  set +e
  output="$("$ROOT/scripts/tron" rules check --files "$relative" --format agent 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "$name unexpectedly passed" >&2; exit 1; }
  grep -Fq "$expected" <<<"$output" || { echo "$name missed expected diagnostic: $output" >&2; exit 1; }
  printf 'passed: %s\n' "$name"
}
expect_clean() {
  local name="$1" output
  output="$("$ROOT/scripts/tron" rules check --files "$relative" --format agent 2>&1)" || {
    echo "$name unexpectedly failed: $output" >&2; exit 1;
  }
  printf 'passed: %s\n' "$name"
}

cat > "$probe" <<'SWIFT'
// ast-grep-ignore: ios.presentation.raw-sheet
struct Probe: View { var body: some View { view.sheet(item: $item) { Text("probe") } } }
SWIFT
expect_failure "targeted next-line ignore cannot hide AST finding" "App-owned sheets use the activity-managed presentation modifiers."

cat > "$probe" <<'SWIFT'
// ast-grep-ignore: ios.presentation.raw-sheet
let note = "no rule violation"
SWIFT
expect_failure "targeted unused ignore is reported by ast-grep" "Remove unused ast-grep suppression directives"

cat > "$probe" <<'SWIFT'
struct Probe: View { var body: some View { view.sheet(item: $item) { Text("probe") } // ast-grep-ignore: ios.presentation.raw-sheet,no-ignore
} }
SWIFT
expect_failure "targeted trailing no-ignore cannot hide AST finding" "App-owned sheets use the activity-managed presentation modifiers."

cat > "$probe" <<'SWIFT'
// ast-grep-ignore

struct Probe: View { var body: some View { view.sheet(item: $item) { Text("probe") } } }
SWIFT
expect_failure "file-wide ignore is rejected" "Do not use file-wide ast-grep suppression directives."

cat > "$probe" <<'SWIFT'
let note = "ast-grep-ignore: ios.presentation.raw-sheet .sheet(item:)"
SWIFT
expect_clean "string text mentioning ignore syntax is not treated as a directive"
