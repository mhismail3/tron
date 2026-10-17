#!/usr/bin/env bash
# Real ast-grep CLI fixtures for the migrated iOS source-policy boundaries.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_fixtures="$ROOT/packages/ios-app/Sources/UI/.rule-boundaries.$RANDOM.$$"
engine_fixtures="$ROOT/packages/ios-app/SwiftAppEngine/UI/.rule-boundaries.$RANDOM.$$"
mkdir -p "$source_fixtures" "$engine_fixtures"
trap 'rm -rf "$source_fixtures" "$engine_fixtures"' EXIT
src_rel="${source_fixtures#"$ROOT"/}"
engine_rel="${engine_fixtures#"$ROOT"/}"
fail_with() {
  local name="$1" file="$2" needle="$3" from="${4:-$ROOT}" output status
  set +e
  output="$(cd "$from" && "$ROOT/scripts/tron" rules check --files "$file" --format agent 2>&1)"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { echo "$name unexpectedly passed" >&2; exit 1; }
  grep -Fq "$needle" <<<"$output" || { echo "$name missed '$needle': $output" >&2; exit 1; }
  printf 'passed: %s\n' "$name"
}
pass_clean() {
  local name="$1" file="$2" output
  output="$("$ROOT/scripts/tron" rules check --files "$file" --format agent 2>&1)" || {
    echo "$name unexpectedly failed: $output" >&2; exit 1;
  }
  printf 'passed: %s\n' "$name"
}

cat > "$source_fixtures/Host.swift" <<'SWIFT'
struct Host: View {
  var body: some View {
    item.tronManagedSheet(isPresented: $shown, identity: "draft") {
      Wrapper { Draft<Int>() }
    }
    TronProgressiveSheetLink(accessibilityLabel: "progressive") { ProgressiveDraft() } label: { EmptyView() }
    settingsLink(title: "settings") { SettingsDraft() }
    Row(title: "destination", destination: { DestinationDraft() })
  }
}
SWIFT
cat > "$source_fixtures/DraftOne.swift" <<'SWIFT'
struct Draft<T>: View {
  @State private var text = "one"
  var body: some View { EmptyView() }
}
SWIFT
cat > "$source_fixtures/DraftTwo.swift" <<'SWIFT'
struct Draft<T>: View {
  @State private var text = "two" // view-local: typed locally
  var body: some View { EmptyView() }
}
SWIFT
cat > "$source_fixtures/Progressive.swift" <<'SWIFT'
struct ProgressiveDraft: View {
  @State private var text = "bad"
  var body: some View { EmptyView() }
}
SWIFT
cat > "$source_fixtures/Settings.swift" <<'SWIFT'
struct SettingsDraft: View {
  @State private var text = "bad"
  var body: some View { EmptyView() }
}
SWIFT
cat > "$source_fixtures/Destination.swift" <<'SWIFT'
struct DestinationDraft: View {
  @State private var text = "bad"
  var body: some View { EmptyView() }
}
SWIFT
host_rel="$src_rel/Host.swift"
fail_with "nested managed closure and generic view roots, even when only Host changed" "$host_rel" "$src_rel/DraftOne.swift:2" "$ROOT/packages/ios-app"
fail_with "only changed Draft file is checked through unchanged Host" "$src_rel/DraftTwo.swift" "$src_rel/DraftTwo.swift:2"
fail_with "progressive sheet link destination is a root" "$host_rel" "$src_rel/Progressive.swift:2"
fail_with "settingsLink trailing destination is a root" "$host_rel" "$src_rel/Settings.swift:2"
fail_with "any destination argument closure is a root" "$host_rel" "$src_rel/Destination.swift:2"

cat > "$source_fixtures/Host.swift" <<'SWIFT'
struct Host: View { var body: some View { item.tronManagedSheet(isPresented: $shown, identity: "draft") { Draft() } } }
SWIFT
cat > "$source_fixtures/DraftOne.swift" <<'SWIFT'
struct Draft: View {
  @PresentationState private var draft = "safe"
  var body: some View { EmptyView() }
}
struct Unrelated: View { @State private var state = 1 }
SWIFT
pass_clean "presentation state and unrelated state pass" "$host_rel"

cat > "$source_fixtures/Loading.swift" <<'SWIFT'
struct LoadingProbe: View {
  var body: some View {
    ProgressView("value: a string, not a value argument")
  }
}
SWIFT
fail_with "spinner decision inspects AST argument label, not substring" "$src_rel/Loading.swift" "shared presentation pulse"
cat > "$source_fixtures/Loading.swift" <<'SWIFT'
struct LoadingProbe: View { var body: some View { ProgressView(value: 1, total: 3) } }
SWIFT
pass_clean "determinate spinner is accepted" "$src_rel/Loading.swift"
cat > "$source_fixtures/Loading.swift" <<'SWIFT'
struct LoadingProbe: View { var body: some View { Text("Loading Home…") } }
SWIFT
fail_with "loading text literal is rejected" "$src_rel/Loading.swift" "visible loading"
cat > "$source_fixtures/Loading.swift" <<'SWIFT'
struct LoadingProbe: View { var body: some View { Text("Preparing details…") } }
SWIFT
pass_clean "exact allowed text pair stays allowed" "$src_rel/Loading.swift"
cat > "$source_fixtures/Loading.swift" <<'SWIFT'
struct LoadingProbe: View { var body: some View { Text(TronSheetLoadingHostModifier.self) } }
SWIFT
fail_with "host identifier mention is rejected" "$src_rel/Loading.swift" "only presentation surfaces"
cat > "$source_fixtures/Loading.swift" <<'SWIFT'
let harmless = "TronSheetLoadingHostModifier ProgressView() Text(\"Loading Home…\")"
// TronSheetLoadingHostModifier ProgressView()
SWIFT
pass_clean "comments and literals are not loading policy syntax" "$src_rel/Loading.swift"

cat > "$source_fixtures/Loading.swift" <<'SWIFT'
struct LoadingProbe: View { var body: some View { ProgressView() } }
SWIFT
pass_clean "exact spinner path allowance does not bleed into other checks" "packages/ios-app/Sources/UI/Chat/HomePinnedRow.swift"

cat > "$engine_fixtures/Host.swift" <<'SWIFT'
struct EngineHost: View { var body: some View { item.tronManagedSheet(isPresented: $shown, identity: "x") { SharedDraft() } } }
SWIFT
cat > "$source_fixtures/SharedDraft.swift" <<'SWIFT'
struct SharedDraft: View { @State private var text = "source-only" }
SWIFT
pass_clean "sheet view indexes remain separate by source root" "$engine_rel/Host.swift"

printf 'passed: AST rule boundary fixtures complete\n'
