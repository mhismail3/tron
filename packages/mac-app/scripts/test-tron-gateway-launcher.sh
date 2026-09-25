#!/usr/bin/env bash
# Temporary fixture for the C launcher's selection and fingerprint boundary.
# It builds no app and writes only under mktemp; run on macOS with clang.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-launcher-fixture.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
APP_ROOT="$TMP/Contents"
BUNDLE="$APP_ROOT/Resources/Gateway"
HELPER="$APP_ROOT/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
HASH="$SCRIPT_DIR/hash-gateway-payload.sh"
NODE_ROOT="${TRON_NODE_ROOT:-}"
if [[ -z "$NODE_ROOT" ]]; then
  NODE_EXECUTABLE="$(command -v node 2>/dev/null || true)"
  [[ -n "$NODE_EXECUTABLE" ]] || { echo "pinned Node is unavailable" >&2; exit 2; }
  NODE_EXECUTABLE="$(realpath "$NODE_EXECUTABLE")"
  NODE_ROOT="$(cd "$(dirname "$NODE_EXECUTABLE")/.." && pwd -P)"
fi
EXPECTED_NODE_VERSION="$(<"$REPO_ROOT/.node-version")"
[[ -x "$NODE_ROOT/bin/node" \
    && "$($NODE_ROOT/bin/node --version 2>/dev/null || true)" == "v$EXPECTED_NODE_VERSION" \
    && -f "$NODE_ROOT/lib/node_modules/npm/package.json" ]] \
  || { echo "TRON_NODE_ROOT or PATH must select the pinned official Node $EXPECTED_NODE_VERSION toolchain" >&2; exit 2; }
mkdir -p "$(dirname "$HELPER")" "$BUNDLE" "$APP_ROOT/Resources"
printf '%s\n' 'fixture helper' > "$APP_ROOT/Resources/TronSearchEmbeddingHelper"
SEARCH_HELPER="$(realpath "$APP_ROOT/Resources/TronSearchEmbeddingHelper")"
xcrun --sdk macosx clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
  "$SCRIPT_DIR/tron-gateway-launcher.c" -o "$HELPER"

make_payload() {
  local root="$1" version="$2" marker="$3" epoch="${4:-01234567-89ab-cdef-0123-456789abcdef}" fingerprint
  mkdir -p "$root/app/dist" "$root/app/scripts" "$root/app/node_modules" "$root/runtime"
  printf '#!/bin/sh\nprintf "%%s\\n" "$TRON_GATEWAY_PAYLOAD_ROOT"\nexit 0\n' > "$root/app/dist/index.js"
  dd if=/dev/zero bs=1024 count=2 2>/dev/null | tr '\\0' '#' >> "$root/app/dist/index.js"
  chmod 755 "$root/app/dist/index.js"
  printf '{"name":"fixture"}\n' > "$root/app/package.json"
  printf '{"name":"fixture","lockfileVersion":3}\n' > "$root/app/package-lock.json"
  printf '%s\n' 'TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test' > "$root/app/PushService.xcconfig"
  printf '%s\n' '// fixture helper' > "$root/app/scripts/ensure-node-pty-helper.mjs"
  printf '%s\n' '// fixture updater' > "$root/app/scripts/gateway-payload-deploy.mjs"
  mkdir -p "$root/app/node_modules/@earendil-works/pi-coding-agent/dist" "$root/app/node_modules/.bin"
  printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","bin":{"pi":"dist/cli.js"}}' > "$root/app/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf '%s\n' '#!/usr/bin/env node' > "$root/app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  chmod 755 "$root/app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  ln -s ../@earendil-works/pi-coding-agent/dist/cli.js "$root/app/node_modules/.bin/pi"
  printf '%s\n' '#!/bin/sh' '[ -n "$TRON_GATEWAY_BUNDLED_PAYLOAD_ROOT" ] || exit 9' '[ "$(command -v npm)" = "$TRON_GATEWAY_PAYLOAD_ROOT/runtime/bin-arm64/npm" ] || exit 11' "[ \"\$TRON_GATEWAY_SEARCH_EMBEDDING_HELPER\" = \"$SEARCH_HELPER\" ] || { printf 'search helper mismatch: %s\\n' \"\$TRON_GATEWAY_SEARCH_EMBEDDING_HELPER\" >&2; exit 12; }" '[ "${TRON_FIXTURE_WRITE_STDERR:-0}" != 1 ] || printf "fixture Gateway stderr\\n" >&2' 'printf "%s\\n" "$TRON_GATEWAY_PAYLOAD_ROOT"' 'exit 0' > "$root/runtime/node-arm64"
  # Keep each fake runtime over the canonical minimum size without embedding
  # NUL bytes that would make the shell fixture itself invalid.
  dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\\0' '#' >> "$root/runtime/node-arm64"
  cp "$root/runtime/node-arm64" "$root/runtime/node-x64"
  chmod 755 "$root/runtime/node-arm64" "$root/runtime/node-x64"
  mkdir -p "$root/runtime/npm-arm64/bin" "$root/runtime/npm-x64/bin"
  cp -R "$NODE_ROOT/lib/node_modules/npm/." "$root/runtime/npm-arm64/"
  cp -R "$NODE_ROOT/lib/node_modules/npm/." "$root/runtime/npm-x64/"
  mkdir -p "$root/runtime/xcodegen/bin" "$root/runtime/xcodegen/share/xcodegen/SettingPresets"
  cp "$root/runtime/node-arm64" "$root/runtime/xcodegen/bin/xcodegen"
  chmod 755 "$root/runtime/xcodegen/bin/xcodegen"
  printf '%s\n' 'PRODUCT_NAME: $TARGET_NAME' > "$root/runtime/xcodegen/share/xcodegen/SettingPresets/base.yml"
  mkdir -p "$root/app/nested/one" "$root/runtime/nested/one"
  printf 'nested fixture bytes\n' > "$root/app/nested/one/data.txt"
  dd if=/dev/zero bs=1048576 count=4 2>/dev/null | tr '\\0' 'L' > "$root/runtime/nested/one/large.bin"
  ln -s ../../nested/one/data.txt "$root/app/node_modules/.bin/nested-data"
  mkdir -p "$root/runtime/bin-arm64" "$root/runtime/bin-x64"
  ln -s ../node-arm64 "$root/runtime/bin-arm64/node"
  ln -s ../node-x64 "$root/runtime/bin-x64/node"
  ln -s ../npm-arm64/bin/npm-cli.js "$root/runtime/bin-arm64/npm"
  ln -s ../npm-x64/bin/npm-cli.js "$root/runtime/bin-x64/npm"
  ln -s ../../app/node_modules/.bin/pi "$root/runtime/bin-arm64/pi"
  ln -s ../../app/node_modules/.bin/pi "$root/runtime/bin-x64/pi"
  fingerprint="$("$HASH" "$root")"
  printf '{"schema":1,"kind":"tron-gateway-payload","channel":"stable","version":"%s","gatewayVersion":"fixture","protocolVersion":"5","minProtocolVersion":"5","nodeVersion":"fixture","sourceRevision":"0123456789abcdef0123456789abcdef01234567","runtimeEpoch":"%s","payloadFingerprint":"%s","dependencyTreeCoverage":"app/** and runtime/** regular files"}\n' "$version" "$epoch" "$fingerprint" > "$root/manifest.json"
  chmod -R a-w "$root"
}

make_payload "$BUNDLE" fixture bundled
expected_bundle_fingerprint="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$BUNDLE/manifest.json")"
[[ "$("$HELPER" --fingerprint "$BUNDLE")" == "$expected_bundle_fingerprint" ]] || {
  echo "launcher fingerprint mode diverged from the canonical shell hash" >&2; exit 1;
}
node_fingerprint="$("$NODE_ROOT/bin/node" --input-type=module - "$REPO_ROOT/scripts/gateway-payload-deploy.mjs" "$BUNDLE" <<'NODE'
import { pathToFileURL } from "node:url";
const { payloadFingerprint } = await import(pathToFileURL(process.argv[2]));
console.log(await payloadFingerprint(process.argv[3]));
NODE
)"
[[ "$node_fingerprint" == "$expected_bundle_fingerprint" ]] || {
  echo "Node fingerprint diverged from the canonical shell hash" >&2; exit 1;
}
control_path="$BUNDLE/app/control$(printf '\001')byte"
chmod u+w "$BUNDLE/app"
printf 'control path\n' > "$control_path"
if "$HASH" "$BUNDLE" >/dev/null 2>&1; then
  echo "canonical hash admitted a control byte in a payload path" >&2; exit 1
fi
if "$HELPER" --fingerprint "$BUNDLE" >/dev/null 2>&1; then
  echo "launcher fingerprint admitted a control byte in a payload path" >&2; exit 1
fi
if "$NODE_ROOT/bin/node" --input-type=module - "$REPO_ROOT/scripts/gateway-payload-deploy.mjs" "$BUNDLE" >/dev/null 2>&1 <<'NODE'
import { pathToFileURL } from "node:url";
const { payloadFingerprint } = await import(pathToFileURL(process.argv[2]));
await payloadFingerprint(process.argv[3]);
NODE
then
  echo "Node fingerprint admitted a control byte in a payload path" >&2; exit 1
fi
rm "$control_path"
chmod a-w "$BUNDLE/app"
"$HELPER" --verify-payload "$BUNDLE" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 || {
  echo "launcher payload verification mode rejected the valid fixture" >&2; exit 1;
}
STALE_NPM="$TMP/invalid-stale-npm"
cp -R "$BUNDLE" "$STALE_NPM"
chmod -R u+w "$STALE_NPM"
printf '%s\n' '{"name":"npm","version":"stale"}' > "$STALE_NPM/runtime/npm-arm64/package.json"
if "$HASH" "$STALE_NPM" >/dev/null 2>&1; then
  echo "canonical hash admitted stale npm metadata" >&2; exit 1
fi
OVERSIZED_PACKAGE="$TMP/invalid-oversized-package"
cp -R "$BUNDLE" "$OVERSIZED_PACKAGE"
chmod -R u+w "$OVERSIZED_PACKAGE"
# The manifest records the fingerprint of these bytes, so recompute it and bind
# the oversized document to the fixture before the size rule is exercised.
{
  printf '{"name":"fixture","padding":"'
  dd if=/dev/zero bs=65536 count=1 2>/dev/null | tr '\\0' 'p'
  printf '"}\n'
} > "$OVERSIZED_PACKAGE/app/package.json"
oversized_fingerprint="$("$HASH" "$OVERSIZED_PACKAGE")"
sed "s/\"payloadFingerprint\":\"[^\"]*\"/\"payloadFingerprint\":\"$oversized_fingerprint\"/" \
  "$OVERSIZED_PACKAGE/manifest.json" > "$OVERSIZED_PACKAGE/manifest.tmp"
mv "$OVERSIZED_PACKAGE/manifest.tmp" "$OVERSIZED_PACKAGE/manifest.json"
chmod -R a-w "$OVERSIZED_PACKAGE"
# 64 KiB is the bound the Swift validator applies to app/package.json.
if "$HELPER" --verify-payload "$OVERSIZED_PACKAGE" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  echo "launcher payload validation admitted an oversized package document" >&2; exit 1
fi
# One refused fixture per identity rule the launcher enforces. The manifest is
# not fingerprinted, so only the field under test changes while the payload
# bytes stay valid. Values are test literals evaluated by the fixture helper.
IDENTITY="$TMP/invalid-identity"
cp -R "$BUNDLE" "$IDENTITY"
chmod -R u+w "$IDENTITY"
cp "$BUNDLE/manifest.json" "$TMP/pristine-manifest.json"
chmod 644 "$TMP/pristine-manifest.json"
# Each case starts from the pristine manifest so only the rule under test can
# reject it, and passes the field's own value as the expected one, so a
# rejection can never come from the expected-identity comparison instead.
identity_rule() {
  local field="$1" expression="$2" value
  local node_argument=fixture gateway_argument=fixture revision_argument=0123456789abcdef0123456789abcdef01234567
  chmod u+w "$IDENTITY/manifest.json"
  cp "$TMP/pristine-manifest.json" "$IDENTITY/manifest.json"
  value="$(python3 - "$IDENTITY/manifest.json" "$field" "$expression" <<'PY'
import json, sys
path, field, expression = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
if expression == "absent":
    del manifest[field]
    value = ""
else:
    manifest[field] = value = eval(expression)
# The launcher also requires manifest version and gatewayVersion to agree.
if field == "gatewayVersion":
    manifest["version"] = value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
print(value)
PY
)"
  chmod a-w "$IDENTITY/manifest.json"
  [[ "$field" == nodeVersion ]] && node_argument="$value"
  [[ "$field" == gatewayVersion ]] && gateway_argument="$value"
  [[ "$field" == sourceRevision ]] && revision_argument="$value"
  "$HELPER" --verify-payload "$IDENTITY" stable "$node_argument" "$gateway_argument" "$revision_argument" >/dev/null 2>&1 && {
    echo "launcher payload validation admitted $field=$expression" >&2; exit 1
  }
  return 0
}
identity_rule gatewayVersion '"a" * 128'
identity_rule gatewayVersion '"1.0 beta"'
identity_rule gatewayVersion '"\u00e9" * 64'
identity_rule nodeVersion '"a" * 128'
identity_rule nodeVersion '"22/23"'
identity_rule sourceRevision 'absent'
identity_rule sourceRevision '"source"'
identity_rule sourceRevision '"A" * 40'
identity_rule sourceRevision '"a" * 41'
identity_rule runtimeEpoch 'absent'
identity_rule runtimeEpoch '"epoch"'
identity_rule runtimeEpoch '"e" * 36'
identity_rule runtimeEpoch '"01234567-89AB-CDEF-0123-456789ABCDEF"'
identity_rule channel '"preview"'
# Codable and JSON.parse both hide these; the launcher's exact key set does not.
identity_key_rule() {
  local label="$1" pair="$2"
  chmod u+w "$IDENTITY/manifest.json"
  cp "$TMP/pristine-manifest.json" "$IDENTITY/manifest.json"
  python3 - "$IDENTITY/manifest.json" "$pair" <<'PY'
import json, sys
path, pair = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = json.dumps(json.load(handle))
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text[:-1] + "," + pair + "}")
PY
  chmod a-w "$IDENTITY/manifest.json"
  "$HELPER" --verify-payload "$IDENTITY" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1 && {
    echo "launcher payload validation admitted $label" >&2; exit 1
  }
  return 0
}
identity_key_rule "an unknown manifest key" '"unexpected":"x"'
identity_key_rule "a repeated manifest key" '"version":"fixture"'

DIRECTORY_LINK="$TMP/invalid-directory-link"
cp -R "$BUNDLE" "$DIRECTORY_LINK"
chmod -R u+w "$DIRECTORY_LINK"
ln -s dist "$DIRECTORY_LINK/app/linked-directory"
chmod -R a-w "$DIRECTORY_LINK"
if "$HASH" "$DIRECTORY_LINK" >/dev/null 2>&1; then
  echo "canonical hash admitted an internal directory symlink" >&2; exit 1
fi
if "$HELPER" --fingerprint "$DIRECTORY_LINK" >/dev/null 2>&1; then
  echo "launcher fingerprint admitted an internal directory symlink" >&2; exit 1
fi
if "$HELPER" --verify-payload "$DIRECTORY_LINK" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  echo "launcher payload validation admitted an internal directory symlink" >&2; exit 1
fi
UNFINGERPRINTED_LINK="$TMP/invalid-unfingerprinted-link"
cp -R "$BUNDLE" "$UNFINGERPRINTED_LINK"
chmod -R u+w "$UNFINGERPRINTED_LINK"
printf 'hidden\n' > "$UNFINGERPRINTED_LINK/unfingerprinted.js"
ln -s ../unfingerprinted.js "$UNFINGERPRINTED_LINK/app/linked-file"
chmod -R a-w "$UNFINGERPRINTED_LINK"
if "$HASH" "$UNFINGERPRINTED_LINK" >/dev/null 2>&1; then
  echo "canonical hash admitted a link outside fingerprinted payload trees" >&2; exit 1
fi
if "$HELPER" --fingerprint "$UNFINGERPRINTED_LINK" >/dev/null 2>&1; then
  echo "launcher fingerprint admitted a link outside fingerprinted payload trees" >&2; exit 1
fi
if "$HELPER" --verify-payload "$UNFINGERPRINTED_LINK" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  echo "launcher payload validation admitted a link outside fingerprinted payload trees" >&2; exit 1
fi
for invalid_kind in missing empty malformed symlink; do
  INVALID="$TMP/invalid-$invalid_kind"
  cp -R "$BUNDLE" "$INVALID"
  chmod -R u+w "$INVALID"
  case "$invalid_kind" in
    missing) rm "$INVALID/app/PushService.xcconfig" ;;
    empty) printf '%s\n' 'TRON_PUSH_SERVICE_ORIGIN =' > "$INVALID/app/PushService.xcconfig" ;;
    malformed) printf '%s\n' 'TRON_PUSH_SERVICE_ORIGIN = http:/$()/push.example.test' > "$INVALID/app/PushService.xcconfig" ;;
    symlink) rm "$INVALID/app/PushService.xcconfig"; ln -s package.json "$INVALID/app/PushService.xcconfig" ;;
  esac
  chmod -R a-w "$INVALID"
  if "$HELPER" --verify-payload "$INVALID" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
    echo "launcher admitted $invalid_kind stable PushService.xcconfig" >&2; exit 1
  fi
done
for invalid_alias in missing regular wrong-target absolute-target; do
  INVALID="$TMP/invalid-node-alias-$invalid_alias"
  cp -R "$BUNDLE" "$INVALID"
  chmod -R u+w "$INVALID"
  alias="$INVALID/runtime/bin-arm64/node"
  rm "$alias"
  case "$invalid_alias" in
    missing) ;;
    regular) printf '#!/bin/sh\nexit 0\n' > "$alias"; chmod 755 "$alias" ;;
    wrong-target) ln -s ../node-x64 "$alias" ;;
    absolute-target) ln -s "$INVALID/runtime/node-arm64" "$alias" ;;
  esac
  chmod -R a-w "$INVALID"
  if "$HELPER" --verify-payload "$INVALID" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
    echo "launcher admitted invalid runtime Node alias: $invalid_alias" >&2; exit 1
  fi
done
for invalid_alias in missing regular wrong-target absolute-target; do
  INVALID="$TMP/invalid-npm-alias-$invalid_alias"
  cp -R "$BUNDLE" "$INVALID"
  chmod -R u+w "$INVALID"
  alias="$INVALID/runtime/bin-arm64/npm"
  rm "$alias"
  case "$invalid_alias" in
    missing) ;;
    regular) printf '#!/bin/sh\nexit 0\n' > "$alias"; chmod 755 "$alias" ;;
    wrong-target) ln -s ../npm-x64/bin/npm-cli.js "$alias" ;;
    absolute-target) ln -s "$INVALID/runtime/npm-arm64/bin/npm-cli.js" "$alias" ;;
  esac
  chmod -R a-w "$INVALID"
  if "$HELPER" --verify-payload "$INVALID" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
    echo "launcher admitted invalid runtime npm alias: $invalid_alias" >&2; exit 1
  fi
done
for invalid_alias in missing regular wrong-target absolute-target; do
  INVALID="$TMP/invalid-pi-alias-$invalid_alias"
  cp -R "$BUNDLE" "$INVALID"
  chmod -R u+w "$INVALID"
  alias="$INVALID/runtime/bin-arm64/pi"
  rm "$alias"
  case "$invalid_alias" in
    missing) ;;
    regular) printf '#!/bin/sh\nexit 0\n' > "$alias"; chmod 755 "$alias" ;;
    wrong-target) ln -s ../node-arm64 "$alias" ;;
    absolute-target) ln -s "$INVALID/app/node_modules/.bin/pi" "$alias" ;;
  esac
  chmod -R a-w "$INVALID"
  if "$HELPER" --verify-payload "$INVALID" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
    echo "launcher admitted invalid runtime Pi alias: $invalid_alias" >&2; exit 1
  fi
done
EXTERNAL="$TMP/home/.tron/gateway/payloads/stable/versions/v2"
make_payload "$EXTERNAL" v2 external
mkdir -p "$(dirname "$EXTERNAL")"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v2","payloadFingerprint":"%s"}\n' "$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$EXTERNAL/manifest.json")" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
# The launcher appends its own records to the deploy timeline the helper owns.
# This fixture keeps that file writable while the payload store stays read-only.
LAUNCHER_LOG="$TMP/home/.tron/logs/deploy.jsonl"
mkdir -p "$(dirname "$LAUNCHER_LOG")"
: > "$LAUNCHER_LOG"
reset_launcher_log() {
  chmod u+w "$LAUNCHER_LOG"
  : > "$LAUNCHER_LOG"
}
BUNDLED_EPOCH="$(sed -n 's/.*"runtimeEpoch":"\([^"]*\)".*/\1/p' "$BUNDLE/manifest.json")"
chmod -R a-w "$TMP/home/.tron"

valid="$(HOME="$TMP/home" "$HELPER" --version)"
EXTERNAL_REAL="$(cd "$EXTERNAL" && pwd -P)"
[[ "$valid" == "$EXTERNAL_REAL" ]] || { echo "valid fixture did not select external payload: $valid" >&2; exit 1; }

STDERR_LOG="$TMP/home/.tron/logs/gateway-stderr.log"
chmod u+w "$TMP/home/.tron/logs"
rm -f "$STDERR_LOG"
supervised_result="$(HOME="$TMP/home" TRON_GATEWAY_SUPERVISED=1 TRON_FIXTURE_WRITE_STDERR=1 "$HELPER")"
[[ "$supervised_result" == "$EXTERNAL_REAL" ]] || { echo "supervised launcher failed to start the selected payload: $supervised_result" >&2; exit 1; }
grep -q '^fixture Gateway stderr$' "$STDERR_LOG" || { echo "supervised payload stderr was not captured in Tron home" >&2; exit 1; }
rm "$STDERR_LOG"
version_result="$(HOME="$TMP/home" TRON_GATEWAY_SUPERVISED=1 "$HELPER" --version)"
[[ "$version_result" == "$EXTERNAL_REAL" && ! -e "$STDERR_LOG" ]] || { echo "--version unexpectedly created the stderr capture" >&2; exit 1; }
foreground_stderr="$TMP/foreground.stderr"
foreground_result="$(env -u TRON_GATEWAY_SUPERVISED HOME="$TMP/home" TRON_FIXTURE_WRITE_STDERR=1 "$HELPER" 2>"$foreground_stderr")"
[[ "$foreground_result" == "$EXTERNAL_REAL" && ! -e "$STDERR_LOG" ]] || { echo "non-supervised launcher unexpectedly created the stderr capture" >&2; exit 1; }
grep -q '^fixture Gateway stderr$' "$foreground_stderr" || { echo "non-supervised payload stderr was not inherited" >&2; exit 1; }
chmod 500 "$TMP/home/.tron/logs"
unwritable_result="$(HOME="$TMP/home" TRON_GATEWAY_SUPERVISED=1 TRON_FIXTURE_WRITE_STDERR=1 "$HELPER" 2>"$TMP/unwritable-logs.stderr")"
chmod 700 "$TMP/home/.tron/logs"
[[ "$unwritable_result" == "$EXTERNAL_REAL" && ! -e "$STDERR_LOG" ]] || { echo "unwritable stderr directory prevented payload launch" >&2; exit 1; }
grep -q '^fixture Gateway stderr$' "$TMP/unwritable-logs.stderr" || { echo "failed stderr capture did not preserve inherited stderr" >&2; exit 1; }
chmod a-w "$TMP/home/.tron/logs"
BUNDLE_REAL="$(cd "$BUNDLE" && pwd -P)"
# A previously selected, internally valid payload from another wire generation
# must be ignored after a Mac app replacement so the bundled lockstep Gateway
# becomes the migration bootstrap instead of relaunching the old protocol.
chmod -R u+w "$TMP/home"
INCOMPATIBLE="$TMP/home/.tron/gateway/payloads/stable/versions/v3-protocol"
cp -R "$EXTERNAL" "$INCOMPATIBLE"
chmod -R u+w "$INCOMPATIBLE"
python3 - "$INCOMPATIBLE/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["version"] = "v3-protocol"
manifest["protocolVersion"] = "3"
manifest["minProtocolVersion"] = "3"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, separators=(",", ":"))
    handle.write("\n")
PY
INCOMPATIBLE_FINGERPRINT="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$INCOMPATIBLE/manifest.json")"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v3-protocol","payloadFingerprint":"%s"}\n' "$INCOMPATIBLE_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
chmod -R a-w "$TMP/home"
reset_launcher_log
incompatible_result="$(HOME="$TMP/home" "$HELPER" --version 2> "$TMP/incompatible-error")"
[[ "$incompatible_result" == "$BUNDLE_REAL" ]] || { echo "incompatible selected protocol did not use bundled migration fallback: $incompatible_result" >&2; exit 1; }
python3 - "$LAUNCHER_LOG" "$INCOMPATIBLE_FINGERPRINT" "$BUNDLED_EPOCH" <<'PY'
import json, sys
# A refused external selection leaves one bundled-fallback record naming the
# refused selection, why it was refused, and the payload that runs instead.
path, fingerprint, epoch = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    records = [json.loads(line) for line in handle if line.strip()]
assert len(records) == 1, records
record = records[0]
assert (record["event"], record["level"], record["source"], record["process"]) == ("launcher.bundled-fallback", "warning", "launcher", "launcher"), record
assert record["payloadVersion"] == "fixture" and record["runtimeEpoch"] == epoch, record
assert "v3-protocol" in record["message"] and fingerprint in record["message"], record
PY
chmod -R u+w "$TMP/home"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v2","payloadFingerprint":"%s"}\n' "$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$EXTERNAL/manifest.json")" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
chmod -R a-w "$TMP/home"
# Channel names are exact selectors, stable/dev, and the empty-value default.
# Invalid values must be rejected before recovery can touch a sibling marker or lock.
for supported_channel in stable dev; do
  supported_result="$(TRON_GATEWAY_CHANNEL="$supported_channel" HOME="$TMP/home" "$HELPER" --version)"
  [[ "$supported_result" == "$BUNDLE_REAL" || "$supported_result" == "$EXTERNAL_REAL" ]] || { echo "supported channel failed: $supported_channel" >&2; exit 1; }
done
default_result="$(TRON_GATEWAY_CHANNEL= HOME="$TMP/home" "$HELPER" --version)"
[[ "$default_result" == "$EXTERNAL_REAL" ]] || { echo "empty channel did not default to stable: $default_result" >&2; exit 1; }
for invalid_channel in debug ../ a/b "$(printf 'x%.0s' {1..65})"; do
  set +e
  TRON_GATEWAY_CHANNEL="$invalid_channel" HOME="$TMP/home" "$HELPER" --version > "$TMP/invalid-channel-result" 2> "$TMP/invalid-channel-error"
  INVALID_STATUS=$?
  set -e
  [[ "$INVALID_STATUS" -eq 78 ]] || { echo "invalid channel was not rejected: $invalid_channel ($INVALID_STATUS)" >&2; exit 1; }
  [[ ! -e "$TMP/home/.tron/gateway/pending-attempt.json" && ! -e "$TMP/home/.tron/gateway/pending-attempt.json.lock" ]] || { echo "invalid channel touched an outside marker or lock: $invalid_channel" >&2; exit 1; }
done
# An existing channel root symlink is unsafe: no marker or selection access may
# escape into its target, and bundled fallback is not allowed to hide it.
chmod -R u+w "$TMP/home"
mkdir -p "$TMP/outside"
ln -s "$TMP/outside" "$TMP/home/.tron/gateway/payloads/dev"
set +e
TRON_GATEWAY_CHANNEL=dev HOME="$TMP/home" "$HELPER" --version > "$TMP/symlink-result" 2> "$TMP/symlink-error"
SYMLINK_STATUS=$?
set -e
[[ "$SYMLINK_STATUS" -eq 78 ]] || { echo "symlinked channel root was accepted: $SYMLINK_STATUS" >&2; exit 1; }
[[ ! -e "$TMP/outside/pending-attempt.json" && ! -e "$TMP/outside/current.json" ]] || { echo "symlinked channel escaped into outside store" >&2; exit 1; }
rm "$TMP/home/.tron/gateway/payloads/dev"
chmod -R a-w "$TMP/home"
chmod -R u+w "$EXTERNAL"
printf '# tampered\n' >> "$EXTERNAL/app/dist/index.js"
chmod -R a-w "$EXTERNAL"
set +e
tampered_result="$(HOME="$TMP/home" "$HELPER" --version 2> "$TMP/tampered-error")"
tampered_status=$?
set -e
[[ "$tampered_status" -eq 0 ]] || { echo "tampered existing external payload did not use bundled fallback: $tampered_status" >&2; exit 1; }
[[ "$tampered_result" == "$BUNDLE_REAL" ]] || { echo "tampered external payload did not fall back to bundled payload: $tampered_result" >&2; exit 1; }
# A payload from before the runtime alias contract can still be present at
# rollout. Even with a self-consistent legacy fingerprint it must be rejected
# as the selected external payload and use the trusted new bundled fallback.
chmod -R u+w "$TMP/home"
LEGACY="$TMP/home/.tron/gateway/payloads/stable/versions/legacy"
make_payload "$LEGACY" legacy legacy
chmod -R u+w "$LEGACY"
rm -rf "$LEGACY/runtime/bin-arm64" "$LEGACY/runtime/bin-x64"
LEGACY_FINGERPRINT="$("$HELPER" --fingerprint "$LEGACY")"
python3 - "$LEGACY/manifest.json" "$LEGACY_FINGERPRINT" <<'PY'
import json, sys
path, fingerprint = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["payloadFingerprint"] = fingerprint
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, separators=(",", ":"))
    handle.write("\n")
PY
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"legacy","payloadFingerprint":"%s"}\n' "$LEGACY_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
chmod -R a-w "$TMP/home"
legacy_result="$(HOME="$TMP/home" "$HELPER" --version 2> "$TMP/legacy-error")"
[[ "$legacy_result" == "$BUNDLE_REAL" ]] || { echo "legacy external payload without aliases did not use bundled fallback: $legacy_result" >&2; exit 1; }
# A published candidate gets one launch attempt. A second launch with the
# still-pending marker must restore the validated previous selection atomically.
chmod -R u+w "$TMP/home"
PREVIOUS="$TMP/home/.tron/gateway/payloads/stable/versions/v1"
CANDIDATE="$TMP/home/.tron/gateway/payloads/stable/versions/v3"
make_payload "$PREVIOUS" v1 previous
CANDIDATE_EPOCH="fedcba98-7654-3210-fedc-ba9876543210"
make_payload "$CANDIDATE" v3 candidate "$CANDIDATE_EPOCH"
CANDIDATE_FINGERPRINT="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$CANDIDATE/manifest.json")"
PREVIOUS_FINGERPRINT="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$PREVIOUS/manifest.json")"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v3","payloadFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
printf '{"schema":1,"kind":"tron-gateway-pending-attempt","channel":"stable","attempt":"pending","version":"v3","payloadFingerprint":"%s","previousVersion":"v1","previousFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" "$PREVIOUS_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json"
chmod -R a-w "$TMP/home"
chmod u+w "$TMP/home/.tron/gateway/payloads/stable"
reset_launcher_log
first_attempt="$(HOME="$TMP/home" "$HELPER" --version)"
CANDIDATE_REAL="$(cd "$CANDIDATE" && pwd -P)"
[[ "$first_attempt" == "$CANDIDATE_REAL" ]] || { echo "pending candidate did not receive its first launch: $first_attempt" >&2; exit 1; }
second_attempt="$(HOME="$TMP/home" "$HELPER" --version)"
PREVIOUS_REAL="$(cd "$PREVIOUS" && pwd -P)"
[[ "$second_attempt" == "$PREVIOUS_REAL" ]] || { echo "pending candidate did not roll back on second launch: $second_attempt" >&2; exit 1; }
python3 - "$LAUNCHER_LOG" "$CANDIDATE_EPOCH" <<'PY'
import json, sys
# A candidate that consumed its attempt and then failed leaves one launch
# record and one rollback record naming the candidate and the restored version.
path, candidate_epoch = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    records = [json.loads(line) for line in handle if line.strip()]
assert len(records) == 2, records
launched, rolled_back = records
assert (launched["event"], launched["level"], launched["source"], launched["process"]) == ("launcher.candidate-launched", "info", "launcher", "launcher"), launched
assert launched["payloadVersion"] == "v3" and launched["runtimeEpoch"] == candidate_epoch, launched
assert (rolled_back["event"], rolled_back["level"], rolled_back["source"], rolled_back["process"]) == ("launcher.candidate-rolled-back", "error", "launcher", "launcher"), rolled_back
assert rolled_back["payloadVersion"] == "v3" and rolled_back["runtimeEpoch"] == candidate_epoch, rolled_back
assert "v3" in rolled_back["message"] and "v1" in rolled_back["message"], rolled_back
assert rolled_back["timestamp"].endswith("Z") and "T" in rolled_back["timestamp"], rolled_back
PY
# The deploy helper looks this real record up to name the failed candidate.
cat > "$TMP/launcher-cause-check.mjs" <<'JS'
const { candidateStartupFailure } = await import(process.argv[2]);
const [home, epoch] = process.argv.slice(3);
const since = "2000-01-01T00:00:00.000Z";
const lookup = async (candidate) => (await candidateStartupFailure(home, candidate, since)) ?? null;
console.log(JSON.stringify({
  byVersion: await lookup({ version: "v3" }),
  byEpoch: await lookup({ runtimeEpoch: epoch }),
  unrelated: await lookup({ version: "v9", runtimeEpoch: "00000000-0000-0000-0000-000000000000" }),
}));
JS
LAUNCHER_CAUSE="$("$NODE_ROOT/bin/node" "$TMP/launcher-cause-check.mjs" "$REPO_ROOT/scripts/gateway-payload-deploy.mjs" "$TMP/home/.tron" "$CANDIDATE_EPOCH")"
python3 - "$LAUNCHER_CAUSE" <<'PY'
import json, sys
# The reported deploy error leads with the launcher's own rollback record.
result = json.loads(sys.argv[1])
for key in ("byVersion", "byEpoch"):
    cause = result[key]
    assert cause is not None and cause.startswith("New build was rolled back by the launcher: "), result
    assert "v3" in cause and "v1" in cause, result
assert result["unrelated"] is None, result
PY
# Once the authenticated helper atomically commits under the shared attempt
# lock, a concurrent/subsequent launcher must preserve the candidate.
chmod -R u+w "$TMP/home"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v3","payloadFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
printf '{"schema":1,"kind":"tron-gateway-pending-attempt","channel":"stable","attempt":"launched","version":"v3","payloadFingerprint":"%s","previousVersion":"v1","previousFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" "$PREVIOUS_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json"
mkdir "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json.lock"
chmod -R a-w "$TMP/home"
chmod u+w "$TMP/home/.tron/gateway/payloads/stable"
HOME="$TMP/home" "$HELPER" --version > "$TMP/committed-result" &
RACING_LAUNCHER=$!
sleep 0.1
kill -0 "$RACING_LAUNCHER" 2>/dev/null || { echo "launcher did not honor the shared attempt lock" >&2; exit 1; }
printf '{"schema":1,"kind":"tron-gateway-pending-attempt","channel":"stable","attempt":"committed","version":"v3","payloadFingerprint":"%s","previousVersion":"v1","previousFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" "$PREVIOUS_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json.tmp-commit"
mv "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json.tmp-commit" "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json"
rmdir "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json.lock"
wait "$RACING_LAUNCHER"
committed_attempt="$(cat "$TMP/committed-result")"
[[ "$committed_attempt" == "$CANDIDATE_REAL" ]] || { echo "committed candidate was incorrectly rolled back: $committed_attempt" >&2; exit 1; }
[[ ! -e "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json" ]] || { echo "committed candidate marker was not consumed" >&2; exit 1; }

# A fresh lock that remains held through the bounded wait must fail closed:
# neither the candidate nor the bundled fallback may execute.
chmod -R u+w "$TMP/home"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v3","payloadFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
printf '{"schema":1,"kind":"tron-gateway-pending-attempt","channel":"stable","attempt":"launched","version":"v3","payloadFingerprint":"%s","previousVersion":"v1","previousFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" "$PREVIOUS_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json"
LOCK="$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json.lock"
mkdir "$LOCK"
chmod -R a-w "$TMP/home"
chmod u+w "$TMP/home/.tron/gateway/payloads/stable"
set +e
HOME="$TMP/home" "$HELPER" --version > "$TMP/held-lock-result" 2> "$TMP/held-lock-error"
HELD_LOCK_STATUS=$?
set -e
[[ "$HELD_LOCK_STATUS" -eq 75 ]] || { echo "held attempt lock did not return retry status: $HELD_LOCK_STATUS" >&2; exit 1; }
[[ ! -s "$TMP/held-lock-result" ]] || { echo "held attempt lock executed a payload" >&2; exit 1; }
grep -q 'candidate attempt is locked' "$TMP/held-lock-error" || { echo "held attempt lock failure was not diagnostic" >&2; exit 1; }

# A crash-stale lock is removed under the existing policy; the launched marker
# then rolls back before any candidate execution.
touch -t 200001010000 "$LOCK"
stale_recovery="$(HOME="$TMP/home" "$HELPER" --version)"
[[ "$stale_recovery" == "$PREVIOUS_REAL" ]] || { echo "stale lock recovery did not roll back before launch: $stale_recovery" >&2; exit 1; }
[[ ! -e "$LOCK" ]] || { echo "stale attempt lock was not removed" >&2; exit 1; }

# Once a marker exists, malformed recovery metadata is never a safe no-op. The
# launcher must fail closed rather than execute the currently selected candidate.
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v3","payloadFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
printf '{"schema":1,"kind":"tron-gateway-pending-attempt","channel":"stable","attempt":"launched"}\n' > "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json"
reset_launcher_log
set +e
HOME="$TMP/home" "$HELPER" --version > "$TMP/malformed-result" 2> "$TMP/malformed-error"
MALFORMED_STATUS=$?
set -e
[[ "$MALFORMED_STATUS" -eq 75 ]] || { echo "malformed attempt marker did not return retry status: $MALFORMED_STATUS" >&2; exit 1; }
[[ ! -s "$TMP/malformed-result" ]] || { echo "malformed attempt marker executed a payload" >&2; exit 1; }
python3 - "$LAUNCHER_LOG" <<'PY'
import json, sys
# A malformed marker refuses the pending selection with one record and no
# payload identity, because no readable version named one.
with open(sys.argv[1], encoding="utf-8") as handle:
    records = [json.loads(line) for line in handle if line.strip()]
assert len(records) == 1, records
record = records[0]
assert (record["event"], record["level"], record["source"], record["process"]) == ("launcher.selection-rejected", "warning", "launcher", "launcher"), record
assert "payloadVersion" not in record and "runtimeEpoch" not in record, record
assert "malformed" in record["message"], record
PY

# An attempt marker naming a candidate the store no longer selects refuses the
# pending selection with the version that marker claimed.
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v1","payloadFingerprint":"%s"}\n' "$PREVIOUS_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
printf '{"schema":1,"kind":"tron-gateway-pending-attempt","channel":"stable","attempt":"launched","version":"v3","payloadFingerprint":"%s","previousVersion":"v1","previousFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" "$PREVIOUS_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json"
reset_launcher_log
set +e
HOME="$TMP/home" "$HELPER" --version > "$TMP/mismatch-result" 2> "$TMP/mismatch-error"
MISMATCH_STATUS=$?
set -e
[[ "$MISMATCH_STATUS" -eq 75 ]] || { echo "mismatched attempt marker did not return retry status: $MISMATCH_STATUS" >&2; exit 1; }
[[ ! -s "$TMP/mismatch-result" ]] || { echo "mismatched attempt marker executed a payload" >&2; exit 1; }
python3 - "$LAUNCHER_LOG" "$CANDIDATE_EPOCH" <<'PY'
import json, sys
# The refused marker names the candidate it claimed and the selection it
# disagrees with; neither payload runs.
path, epoch = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    records = [json.loads(line) for line in handle if line.strip()]
assert len(records) == 1, records
record = records[0]
assert (record["event"], record["level"], record["source"], record["process"]) == ("launcher.selection-rejected", "warning", "launcher", "launcher"), record
assert record["payloadVersion"] == "v3" and record["runtimeEpoch"] == epoch, record
assert "v3" in record["message"] and "v1" in record["message"], record
PY

printf 'launcher fixture: supervised stderr capture, foreground/version no-capture, unwritable-log launch, payload selection and fingerprint, fallback, candidate rollback and commit, lock recovery, and deploy-cause records pass\n'
