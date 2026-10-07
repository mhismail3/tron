#!/usr/bin/env bash
# Two real builds, then refused runtime mutations. Runs in this checkout and
# restores the valid published runtimes on every exit. The first build downloads
# Node; --skip-download skips runtime downloads, not production npm installation.
# Retains packages/mac-app/test-results/bundle-gateway-rebuild.log.
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
restore_runtime() {
    chmod u+w "$PAYLOAD_DIR/runtime"
    rm -f "$PAYLOAD_DIR/runtime/node-x64"
    local npm="$PAYLOAD_DIR/runtime/npm-x64"
    if [[ -L "$npm" ]]; then
        unlink "$npm"
    else
        # find's default physical walk leaves symlink targets untouched.
        find "$npm" -type d -exec chmod u+w {} +
        rm -rf "$npm"
    fi
    cp -p "$TMP/node-x64" "$PAYLOAD_DIR/runtime/node-x64"
    /usr/bin/ditto "$TMP/npm-x64" "$npm"
    chmod a-w "$PAYLOAD_DIR/runtime"
    tampered=0
}
restore() {
    local status=$?
    if ((tampered)); then restore_runtime; fi
    find "$TMP" -type d -exec chmod u+w {} +
    rm -rf "$TMP"
    exit "$status"
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

step() { printf '==> %s\n' "$*" | tee -a "$LOG"; }
fail() { printf 'FAIL: %s (log: %s)\n' "$*" "$LOG" | tee -a "$LOG" >&2; exit 1; }
bundle() { "$SCRIPT_DIR/bundle-gateway.sh" "$@" >>"$LOG" 2>&1; }
manifest_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$PAYLOAD_DIR/manifest.json" "$1"
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
leftovers() { find "$RESOURCES_DIR" -maxdepth 1 -name '.tron-gateway-*' -print; }
snapshot() {
    # Independent oracle for the whole published tree, including symlink targets
    # and permissions. A rejected build must not replace even an invalid tree.
    python3 - "$PAYLOAD_DIR" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
digest = hashlib.sha256()
for directory, dirs, files in os.walk(root, followlinks=False):
    for name in sorted(['.'] + dirs + files):
        path = os.path.join(directory, name)
        mode = os.lstat(path).st_mode
        digest.update(os.path.relpath(path, root).encode() + b'\0')
        digest.update(str(mode).encode() + b'\0')
        if stat.S_ISLNK(mode):
            digest.update(os.readlink(path).encode() + b'\0')
        elif stat.S_ISREG(mode):
            with open(path, 'rb') as stream:
                digest.update(stream.read())
    dirs.sort()
print(digest.hexdigest())
PY
}

install_args=(--skip-install)
[[ -d "$GATEWAY_DIR/node_modules" && -f "$GATEWAY_DIR/dist/index.js" ]] || install_args=()
step "first build downloads the pinned runtimes"
bundle ${install_args[@]+"${install_args[@]}"} || fail "first build failed"
first_epoch="$(manifest_field runtimeEpoch)"

step "read-only verify works without a source Node/npm toolchain"
valid_payload_snapshot="$(snapshot)"
valid_launcher_sha="$(sha "$RESOURCES_DIR/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron")"
set +e
PATH="/usr/bin:/bin" HOME="$TMP/no-source-home" NVM_DIR="$TMP/no-source-nvm" \
    TRON_NODE_BIN="$TMP/no-source-node/bin/node" \
    "$SCRIPT_DIR/bundle-gateway.sh" --verify-only >"$TMP/verify-without-source-node.log" 2>&1
verify_status=$?
set -e
cat "$TMP/verify-without-source-node.log" >> "$LOG"
[[ "$verify_status" -eq 0 ]] || fail "read-only verification required an ambient/source Node/npm toolchain (status $verify_status)"
[[ "$(snapshot)" == "$valid_payload_snapshot" ]] || fail "read-only verification changed the published tree"
[[ "$(sha "$RESOURCES_DIR/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron")" == "$valid_launcher_sha" ]] || fail "read-only verification changed the published launcher"
[[ -z "$(leftovers)" ]] || fail "read-only verification left temporary publication roots: $(leftovers)"
if grep -Eq 'installing locked gateway dependencies|downloading pinned Node' "$TMP/verify-without-source-node.log"; then
    fail "read-only verification attempted an install or download"
fi

step "second build reuses the published runtimes (--skip-install --skip-download)"
bundle --skip-install --skip-download || fail "second build with --skip-download failed"
bundle --verify-only || fail "second build published a payload that does not verify"
[[ "$(manifest_field runtimeEpoch)" != "$first_epoch" ]] || fail "second build did not publish a new payload"
[[ "$(sha "$PAYLOAD_DIR/runtime/node-arm64")" == "$TRON_NODE_ARM64_RUNTIME_SHA256" ]] || fail "arm64 runtime is not the pinned one"
[[ "$(sha "$PAYLOAD_DIR/runtime/node-x64")" == "$TRON_NODE_X64_RUNTIME_SHA256" ]] || fail "x64 runtime is not the pinned one"
[[ -z "$(leftovers)" ]] || fail "staging or backup roots were left: $(leftovers)"

cp -p "$PAYLOAD_DIR/runtime/node-x64" "$TMP/node-x64"
/usr/bin/ditto "$PAYLOAD_DIR/runtime/npm-x64" "$TMP/npm-x64"
for mutation in node-hash node-symlink npm-version npm-content npm-root-symlink npm-child-symlink; do
    step "refuse $mutation without changing the published tree"
    tampered=1
    chmod u+w "$PAYLOAD_DIR/runtime"
    npm="$PAYLOAD_DIR/runtime/npm-x64"
    case "$mutation" in
        node-hash)
            rm -f "$PAYLOAD_DIR/runtime/node-x64"
            cp -p "$PAYLOAD_DIR/runtime/node-arm64" "$PAYLOAD_DIR/runtime/node-x64"
            expected_status=3; diagnostic='Node x64 binary checksum mismatch' ;;
        node-symlink)
            rm -f "$PAYLOAD_DIR/runtime/node-x64"
            ln -s "$TMP/node-x64" "$PAYLOAD_DIR/runtime/node-x64"
            expected_status=2; diagnostic='requires a published Node runtime' ;;
        npm-version)
            chmod u+w "$npm/package.json"
            python3 - "$npm/package.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as stream:
    data = json.load(stream)
data['version'] = '0.0.0'
with open(path, 'w') as stream:
    json.dump(data, stream)
PY
            chmod a-w "$npm/package.json"
            expected_status=2; diagnostic='staged npm runtime version is not pinned' ;;
        npm-content)
            chmod u+w "$npm/README.md"
            printf '\ntampered\n' >> "$npm/README.md"
            chmod a-w "$npm/README.md"
            expected_status=2; diagnostic='staged npm runtime content is not from the pinned Node archive' ;;
        npm-root-symlink)
            find "$npm" -type d -exec chmod u+w {} +
            rm -rf "$npm"
            ln -s "$TMP/npm-x64" "$npm"
            expected_status=2; diagnostic='requires a published npm runtime' ;;
        npm-child-symlink)
            chmod u+w "$npm"
            find "$npm/lib" -type d -exec chmod u+w {} +
            rm -rf "$npm/lib"
            ln -s "$TMP/npm-x64/lib" "$npm/lib"
            chmod a-w "$npm"
            expected_status=2; diagnostic='staged npm runtime contains unsafe content' ;;
    esac
    chmod a-w "$PAYLOAD_DIR/runtime"
    published_snapshot="$(snapshot)"
    attempt_log="$TMP/$mutation.log"
    set +e
    "$SCRIPT_DIR/bundle-gateway.sh" --skip-install --skip-download >"$attempt_log" 2>&1
    status=$?
    set -e
    cat "$attempt_log" >> "$LOG"
    [[ $status -eq $expected_status ]] || fail "$mutation was not refused with status $expected_status (status $status)"
    grep -q "$diagnostic" "$attempt_log" || fail "$mutation refusal did not name its cause"
    [[ "$(snapshot)" == "$published_snapshot" ]] || fail "$mutation refusal changed the published tree"
    [[ -z "$(leftovers)" ]] || fail "$mutation refusal left private roots: $(leftovers)"
    restore_runtime
done
bundle --verify-only || fail "restored payload does not verify"
step "passed: second build reuses exact pinned runtimes; Node/npm tampering and symlinks are refused atomically"
