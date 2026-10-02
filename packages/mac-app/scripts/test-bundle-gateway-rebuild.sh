#!/usr/bin/env bash
# Two real Gateway bundle builds in this checkout, the second reusing the
# published runtimes with --skip-download exactly as scripts/tron-dev does, then
# a tampered published runtime that --skip-download must refuse without changing
# the published payload. Leaves a valid published payload behind.
#
# Needs network for the first build's pinned Node downloads. The log is kept at
# packages/mac-app/test-results/bundle-gateway-rebuild.log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
GATEWAY_DIR="$REPO_ROOT/packages/gateway"
RESOURCES_DIR="$SCRIPT_DIR/../Sources/Resources"
PAYLOAD_DIR="$RESOURCES_DIR/Gateway"
RESULTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)/test-results"
LOG="$RESULTS_DIR/bundle-gateway-rebuild.log"
# shellcheck disable=SC1091
source "$REPO_ROOT/config/ci-toolchain.env"

mkdir -p "$RESULTS_DIR"
: > "$LOG"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-bundle-rebuild.XXXXXX")"
tampered=0
restore() {
    local status=$?
    if ((tampered)); then
        chmod u+w "$PAYLOAD_DIR/runtime"
        rm -f "$PAYLOAD_DIR/runtime/node-x64"
        cp -p "$TMP/node-x64" "$PAYLOAD_DIR/runtime/node-x64"
        chmod a-w "$PAYLOAD_DIR/runtime"
    fi
    rm -rf "$TMP"
    exit "$status"
}
trap restore EXIT

step() { printf '==> %s\n' "$*" | tee -a "$LOG"; }
fail() { printf 'FAIL: %s (log: %s)\n' "$*" "$LOG" | tee -a "$LOG" >&2; exit 1; }
bundle() { "$SCRIPT_DIR/bundle-gateway.sh" "$@" >>"$LOG" 2>&1; }
manifest_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$PAYLOAD_DIR/manifest.json" "$1"
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
leftovers() { find "$RESOURCES_DIR" -maxdepth 1 -name '.tron-gateway-*' -print; }

# scripts/tron-dev always builds with --skip-install; install once if this
# checkout has no Gateway build to reuse.
install_args=(--skip-install)
[[ -d "$GATEWAY_DIR/node_modules" && -f "$GATEWAY_DIR/dist/index.js" ]] || install_args=()

step "first build downloads the pinned runtimes"
bundle ${install_args[@]+"${install_args[@]}"} || fail "first build failed"
first_epoch="$(manifest_field runtimeEpoch)"

step "second build reuses the published runtimes (--skip-install --skip-download)"
bundle --skip-install --skip-download || fail "second build with --skip-download failed"
bundle --verify-only || fail "second build published a payload that does not verify"
[[ "$(manifest_field runtimeEpoch)" != "$first_epoch" ]] || fail "second build did not publish a new payload"
[[ "$(sha "$PAYLOAD_DIR/runtime/node-arm64")" == "$TRON_NODE_ARM64_RUNTIME_SHA256" ]] || fail "arm64 runtime is not the pinned one"
[[ "$(sha "$PAYLOAD_DIR/runtime/node-x64")" == "$TRON_NODE_X64_RUNTIME_SHA256" ]] || fail "x64 runtime is not the pinned one"
[[ -z "$(leftovers)" ]] || fail "staging or backup roots were left: $(leftovers)"

step "a published runtime that does not match its pin is refused"
cp -p "$PAYLOAD_DIR/runtime/node-x64" "$TMP/node-x64"
tampered=1
chmod u+w "$PAYLOAD_DIR/runtime"
rm -f "$PAYLOAD_DIR/runtime/node-x64"
# A real Mach-O with the wrong hash and architecture.
cp -p "$PAYLOAD_DIR/runtime/node-arm64" "$PAYLOAD_DIR/runtime/node-x64"
chmod a-w "$PAYLOAD_DIR/runtime"
published_manifest="$(sha "$PAYLOAD_DIR/manifest.json")"
set +e
bundle --skip-install --skip-download
status=$?
set -e
[[ $status -eq 3 ]] || fail "tampered runtime was not refused with status 3 (status $status)"
grep -q 'Node x64 binary checksum mismatch' "$LOG" || fail "refusal did not name the x64 checksum"
[[ "$(sha "$PAYLOAD_DIR/manifest.json")" == "$published_manifest" ]] || fail "refused build changed the published manifest"
[[ "$(sha "$PAYLOAD_DIR/runtime/node-x64")" == "$TRON_NODE_ARM64_RUNTIME_SHA256" ]] || fail "refused build changed the published runtime"
[[ -z "$(leftovers)" ]] || fail "refused build left staging or backup roots: $(leftovers)"

chmod u+w "$PAYLOAD_DIR/runtime"
rm -f "$PAYLOAD_DIR/runtime/node-x64"
cp -p "$TMP/node-x64" "$PAYLOAD_DIR/runtime/node-x64"
chmod a-w "$PAYLOAD_DIR/runtime"
tampered=0
bundle --verify-only || fail "restored payload does not verify"
step "passed: a second build reuses verified published runtimes and refuses a tampered one"
