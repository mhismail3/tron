#!/usr/bin/env bash
# Temporary fixture for the C launcher's selection and fingerprint boundary.
# It builds no app and writes only under mktemp; run on macOS with clang.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-launcher-fixture.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
APP_ROOT="$TMP/Contents"
BUNDLE="$APP_ROOT/Resources/Gateway"
HELPER="$APP_ROOT/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
HASH="$SCRIPT_DIR/hash-gateway-payload.sh"
mkdir -p "$(dirname "$HELPER")" "$BUNDLE"
xcrun --sdk macosx clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
  "$SCRIPT_DIR/tron-gateway-launcher.c" -o "$HELPER"

make_payload() {
  local root="$1" version="$2" marker="$3" fingerprint
  mkdir -p "$root/app/dist" "$root/app/scripts" "$root/app/node_modules" "$root/runtime"
  printf '#!/bin/sh\nprintf "%%s\\n" "$TRON_GATEWAY_PAYLOAD_ROOT"\nexit 0\n' > "$root/app/dist/index.js"
  dd if=/dev/zero bs=1024 count=2 2>/dev/null | tr '\\0' '#' >> "$root/app/dist/index.js"
  chmod 755 "$root/app/dist/index.js"
  printf '{"name":"fixture"}\n' > "$root/app/package.json"
  printf '{"name":"fixture","lockfileVersion":3}\n' > "$root/app/package-lock.json"
  printf '%s\n' 'TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test' > "$root/app/PushService.xcconfig"
  printf '%s\n' '// fixture helper' > "$root/app/scripts/ensure-node-pty-helper.mjs"
  printf '%s\n' '// fixture updater' > "$root/app/scripts/gateway-payload-deploy.mjs"
  mkdir -p "$root/app/node_modules/@earendil-works/pi-coding-agent/dist"
  printf '%s\n' '#!/usr/bin/env node' > "$root/app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  chmod 755 "$root/app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  printf '%s\n' '#!/bin/sh' '[ -n "$TRON_GATEWAY_BUNDLED_PAYLOAD_ROOT" ] || exit 9' 'printf "%s\\n" "$TRON_GATEWAY_PAYLOAD_ROOT"' 'exit 0' > "$root/runtime/node-arm64"
  # Keep each fake runtime over the canonical minimum size without embedding
  # NUL bytes that would make the shell fixture itself invalid.
  dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\\0' '#' >> "$root/runtime/node-arm64"
  cp "$root/runtime/node-arm64" "$root/runtime/node-x64"
  chmod 755 "$root/runtime/node-arm64" "$root/runtime/node-x64"
  mkdir -p "$root/runtime/xcodegen/bin" "$root/runtime/xcodegen/share/xcodegen/SettingPresets"
  cp "$root/runtime/node-arm64" "$root/runtime/xcodegen/bin/xcodegen"
  chmod 755 "$root/runtime/xcodegen/bin/xcodegen"
  printf '%s\n' 'PRODUCT_NAME: $TARGET_NAME' > "$root/runtime/xcodegen/share/xcodegen/SettingPresets/base.yml"
  mkdir -p "$root/runtime/bin-arm64" "$root/runtime/bin-x64"
  ln -s ../node-arm64 "$root/runtime/bin-arm64/node"
  ln -s ../node-x64 "$root/runtime/bin-x64/node"
  ln -s ../../app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js "$root/runtime/bin-arm64/pi"
  ln -s ../../app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js "$root/runtime/bin-x64/pi"
  fingerprint="$("$HASH" "$root")"
  printf '{"schema":1,"kind":"tron-gateway-payload","channel":"stable","version":"%s","gatewayVersion":"fixture","protocolVersion":"4","minProtocolVersion":"4","nodeVersion":"fixture","sourceRevision":"0123456789abcdef0123456789abcdef01234567","runtimeEpoch":"01234567-89ab-cdef-0123-456789abcdef","payloadFingerprint":"%s","dependencyTreeCoverage":"app/** and runtime/** regular files"}\n' "$version" "$fingerprint" > "$root/manifest.json"
  chmod -R a-w "$root"
}

make_payload "$BUNDLE" fixture bundled
expected_bundle_fingerprint="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$BUNDLE/manifest.json")"
[[ "$("$HELPER" --fingerprint "$BUNDLE")" == "$expected_bundle_fingerprint" ]] || {
  echo "launcher fingerprint mode diverged from the canonical shell hash" >&2; exit 1;
}
"$HELPER" --verify-payload "$BUNDLE" stable fixture fixture 0123456789abcdef0123456789abcdef01234567 || {
  echo "launcher payload verification mode rejected the valid fixture" >&2; exit 1;
}
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
  INVALID="$TMP/invalid-pi-alias-$invalid_alias"
  cp -R "$BUNDLE" "$INVALID"
  chmod -R u+w "$INVALID"
  alias="$INVALID/runtime/bin-arm64/pi"
  rm "$alias"
  case "$invalid_alias" in
    missing) ;;
    regular) printf '#!/bin/sh\nexit 0\n' > "$alias"; chmod 755 "$alias" ;;
    wrong-target) ln -s ../node-arm64 "$alias" ;;
    absolute-target) ln -s "$INVALID/app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js" "$alias" ;;
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
chmod -R a-w "$TMP/home/.tron"

valid="$(HOME="$TMP/home" "$HELPER" --version)"
EXTERNAL_REAL="$(cd "$EXTERNAL" && pwd -P)"
[[ "$valid" == "$EXTERNAL_REAL" ]] || { echo "valid fixture did not select external payload: $valid" >&2; exit 1; }
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
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v3-protocol","payloadFingerprint":"%s"}\n' "$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$INCOMPATIBLE/manifest.json")" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
chmod -R a-w "$TMP/home"
incompatible_result="$(HOME="$TMP/home" "$HELPER" --version 2> "$TMP/incompatible-error")"
[[ "$incompatible_result" == "$BUNDLE_REAL" ]] || { echo "incompatible selected protocol did not use bundled migration fallback: $incompatible_result" >&2; exit 1; }
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
make_payload "$CANDIDATE" v3 candidate
CANDIDATE_FINGERPRINT="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$CANDIDATE/manifest.json")"
PREVIOUS_FINGERPRINT="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$PREVIOUS/manifest.json")"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v3","payloadFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
printf '{"schema":1,"kind":"tron-gateway-pending-attempt","channel":"stable","attempt":"pending","version":"v3","payloadFingerprint":"%s","previousVersion":"v1","previousFingerprint":"%s"}\n' "$CANDIDATE_FINGERPRINT" "$PREVIOUS_FINGERPRINT" > "$TMP/home/.tron/gateway/payloads/stable/pending-attempt.json"
chmod -R a-w "$TMP/home"
chmod u+w "$TMP/home/.tron/gateway/payloads/stable"
first_attempt="$(HOME="$TMP/home" "$HELPER" --version)"
CANDIDATE_REAL="$(cd "$CANDIDATE" && pwd -P)"
[[ "$first_attempt" == "$CANDIDATE_REAL" ]] || { echo "pending candidate did not receive its first launch: $first_attempt" >&2; exit 1; }
second_attempt="$(HOME="$TMP/home" "$HELPER" --version)"
PREVIOUS_REAL="$(cd "$PREVIOUS" && pwd -P)"
[[ "$second_attempt" == "$PREVIOUS_REAL" ]] || { echo "pending candidate did not roll back on second launch: $second_attempt" >&2; exit 1; }
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
set +e
HOME="$TMP/home" "$HELPER" --version > "$TMP/malformed-result" 2> "$TMP/malformed-error"
MALFORMED_STATUS=$?
set -e
[[ "$MALFORMED_STATUS" -eq 75 ]] || { echo "malformed attempt marker did not return retry status: $MALFORMED_STATUS" >&2; exit 1; }
[[ ! -s "$TMP/malformed-result" ]] || { echo "malformed attempt marker executed a payload" >&2; exit 1; }

printf 'launcher fixture: valid external fingerprint and bundled migration root pass; tampered payload uses trusted bundled fallback; pending candidate crash-rolls back; committed candidate persists; held locks fail closed; stale locks recover; malformed markers fail closed\n'
