#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
SOURCE_PAYLOAD="$SCRIPT_DIR/../Sources/Resources/Gateway"
SOURCE_APP="$SCRIPT_DIR/../Sources/Resources/Library/LoginItems/Tron Agent.app"
VERIFY="$SCRIPT_DIR/verify-gateway-payload.sh"
TMP_ROOT="$(realpath "${TMPDIR:-/tmp}")"
TMP="$(mktemp -d "$TMP_ROOT/tron-payload-verifier.XXXXXX")"
make_writable() {
    local root="$1"
    [[ "$root" == "$TMP" || "$root" == "$TMP"/* ]] || {
        echo "refusing to mutate path outside fixture: $root" >&2
        return 1
    }
    [[ -e "$root" || -L "$root" ]] || return 0
    find -P "$root" \( -type d -exec chmod u+rwx {} + \) -o \( -type f -exec chmod u+w {} + \)
}
trap 'make_writable "$TMP" || true; rm -rf "$TMP"' EXIT
[[ -d "$SOURCE_PAYLOAD" && -d "$SOURCE_APP" ]] || {
    echo "run bundle-gateway.sh before the isolated payload verifier fixtures" >&2
    exit 2
}

PAYLOAD="$TMP/Gateway"
APP="$TMP/Tron Agent.app"
HELPER="$APP/Contents/MacOS/tron"
EXPECTED_CHANNEL="$(plutil -extract channel raw -o - "$SOURCE_PAYLOAD/manifest.json" 2>/dev/null || true)"
[[ "$EXPECTED_CHANNEL" == stable || "$EXPECTED_CHANNEL" == dev ]] || { echo "generated payload channel is invalid" >&2; exit 2; }
copy_tree() {
    local source="$1" destination="$2"
    if cp -cR "$source" "$destination" 2>/dev/null; then return 0; fi
    cp -R "$source" "$destination"
}
reset_fixture() {
    make_writable "$PAYLOAD"
    make_writable "$APP"
    rm -rf "$PAYLOAD" "$APP"
    mkdir -p "$PAYLOAD" "$APP"
    copy_tree "$SOURCE_PAYLOAD/." "$PAYLOAD/"
    copy_tree "$SOURCE_APP/." "$APP/"
    if [[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
        make_writable "$PAYLOAD"
        sed "s/\"sourceRevision\":\"[^\"]*\"/\"sourceRevision\":\"$SOURCE_REVISION\"/" \
            "$PAYLOAD/manifest.json" > "$PAYLOAD/manifest.tmp"
        mv "$PAYLOAD/manifest.tmp" "$PAYLOAD/manifest.json"
    fi
    chmod -R a-w "$PAYLOAD" "$APP"
}
expect_rejected() {
    local label="$1"
    if "$VERIFY" "$PAYLOAD" "$HELPER" "$EXPECTED_CHANNEL" >"$TMP/$label.out" 2>"$TMP/$label.err"; then
        echo "$label fixture was accepted" >&2
        exit 1
    fi
}

reset_fixture
if ! "$VERIFY" "$PAYLOAD" "$HELPER" "$EXPECTED_CHANNEL" >"$TMP/baseline.log" 2>&1; then
    echo "payload verifier fixtures: generated-input precondition failed; adversarial matrix not run" >&2
    cat "$TMP/baseline.log" >&2
    echo "Explicitly prepare current unsigned inputs with packages/mac-app/scripts/bundle-gateway.sh, then rerun." >&2
    echo "Staging may install/download dependencies; this test never does. Do not substitute a signed installed app or rewrite pins to accept stale bytes." >&2
    exit 2
fi

reset_fixture
chmod u+w "$PAYLOAD/app/dist/index.js"
printf '\n# tampered fixture\n' >> "$PAYLOAD/app/dist/index.js"
chmod a-w "$PAYLOAD/app/dist/index.js"
expect_rejected tampered-app-file

reset_fixture
chmod u+w "$PAYLOAD/app/package.json"
expect_rejected owner-writable-payload
grep -q 'published payload tree is writable' "$TMP/owner-writable-payload.err" || {
    echo "owner-writable payload was not rejected by the early mode check" >&2
    exit 1
}

for write_mode in g+w o+w; do
    reset_fixture
    chmod "$write_mode" "$PAYLOAD/app/package.json"
    expect_rejected "$write_mode-writable-payload"
    grep -q 'published payload tree is writable' "$TMP/$write_mode-writable-payload.err"
done

reset_fixture
chmod 000 "$PAYLOAD/runtime/npm-x64/lib"
expect_rejected unreadable-subtree
chmod 555 "$PAYLOAD/runtime/npm-x64/lib"
grep -q 'cannot inspect published payload permissions' "$TMP/unreadable-subtree.err"

reset_fixture
chmod u+w "$APP/Contents/MacOS" "$HELPER"
printf 'forged-byte' >> "$HELPER"
chmod 755 "$HELPER"
expect_rejected forged-valid-universal-helper

reset_fixture
chmod u+w "$PAYLOAD/runtime/node-x64"
cp "$PAYLOAD/runtime/node-arm64" "$PAYLOAD/runtime/node-x64"
chmod a-w "$PAYLOAD/runtime/node-x64"
expect_rejected wrong-runtime-version

reset_fixture
make_writable "$PAYLOAD"
sed 's/"version":"[^"]*"/"version":"9.9.9"/' "$PAYLOAD/manifest.json" > "$PAYLOAD/manifest.tmp"
mv "$PAYLOAD/manifest.tmp" "$PAYLOAD/manifest.json"
chmod -R a-w "$PAYLOAD" "$APP"
expect_rejected valid-version-tamper

reset_fixture
make_writable "$PAYLOAD"
sed 's/"nodeVersion":"[^"]*"/"nodeVersion":"99.99.99"/' "$PAYLOAD/manifest.json" > "$PAYLOAD/manifest.tmp"
mv "$PAYLOAD/manifest.tmp" "$PAYLOAD/manifest.json"
chmod -R a-w "$PAYLOAD" "$APP"
expect_rejected valid-node-version-manifest-tamper

reset_fixture
make_writable "$PAYLOAD"
printf '{"schema":1,"kind":"forged"}\n' > "$PAYLOAD/manifest.json"
chmod -R a-w "$PAYLOAD" "$APP"
expect_rejected malformed-manifest

printf 'payload verifier fixtures: valid, app fingerprint tamper, forged helper identity, runtime version/architecture, manifest identity, and malformed manifest rejected\n'
