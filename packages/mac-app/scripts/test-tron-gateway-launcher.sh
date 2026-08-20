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
  "$SCRIPT_DIR/tron-gateway-launcher.c" -o "$HELPER"

make_payload() {
  local root="$1" version="$2" marker="$3" fingerprint
  mkdir -p "$root/app/dist" "$root/app/scripts" "$root/app/node_modules" "$root/runtime"
  printf '#!/bin/sh\nprintf "%%s\\n" "$TRON_GATEWAY_PAYLOAD_ROOT"\nexit 0\n' > "$root/app/dist/index.js"
  dd if=/dev/zero bs=1024 count=2 2>/dev/null | tr '\\0' '#' >> "$root/app/dist/index.js"
  chmod 755 "$root/app/dist/index.js"
  printf '{"name":"fixture"}\n' > "$root/app/package.json"
  printf '{"name":"fixture","lockfileVersion":3}\n' > "$root/app/package-lock.json"
  printf '%s\n' '// fixture helper' > "$root/app/scripts/ensure-node-pty-helper.mjs"
  printf '%s\n' '// fixture updater' > "$root/app/scripts/gateway-payload-deploy.mjs"
  printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$TRON_GATEWAY_PAYLOAD_ROOT"' 'exit 0' > "$root/runtime/node-arm64"
  # Keep each fake runtime over the canonical minimum size without embedding
  # NUL bytes that would make the shell fixture itself invalid.
  dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\\0' '#' >> "$root/runtime/node-arm64"
  cp "$root/runtime/node-arm64" "$root/runtime/node-x64"
  chmod 755 "$root/runtime/node-arm64" "$root/runtime/node-x64"
  fingerprint="$("$HASH" "$root")"
  printf '{"schema":1,"kind":"tron-gateway-payload","channel":"stable","version":"%s","gatewayVersion":"fixture","nodeVersion":"fixture","sourceRevision":"%s","runtimeEpoch":"epoch-%s","payloadFingerprint":"%s"}\n' "$version" "$marker" "$marker" "$fingerprint" > "$root/manifest.json"
  chmod -R a-w "$root"
}

make_payload "$BUNDLE" bundled bundled
expected_bundle_fingerprint="$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$BUNDLE/manifest.json")"
[[ "$("$HELPER" --fingerprint "$BUNDLE")" == "$expected_bundle_fingerprint" ]] || {
  echo "launcher fingerprint mode diverged from the canonical shell hash" >&2; exit 1;
}
EXTERNAL="$TMP/home/.tron/gateway/payloads/stable/versions/v2"
make_payload "$EXTERNAL" v2 external
mkdir -p "$(dirname "$EXTERNAL")"
printf '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"v2","payloadFingerprint":"%s"}\n' "$(sed -n 's/.*payloadFingerprint":"\([0-9a-f]*\)".*/\1/p' "$EXTERNAL/manifest.json")" > "$TMP/home/.tron/gateway/payloads/stable/current.json"
chmod -R a-w "$TMP/home/.tron"

valid="$(HOME="$TMP/home" "$HELPER" --version)"
EXTERNAL_REAL="$(cd "$EXTERNAL" && pwd -P)"
[[ "$valid" == "$EXTERNAL_REAL" ]] || { echo "valid fixture did not select external payload: $valid" >&2; exit 1; }
chmod -R u+w "$EXTERNAL"
printf '# tampered\n' >> "$EXTERNAL/app/dist/index.js"
chmod -R a-w "$EXTERNAL"
fallback="$(HOME="$TMP/home" "$HELPER" --version)"
BUNDLE_REAL="$(cd "$BUNDLE" && pwd -P)"
[[ "$fallback" == "$BUNDLE_REAL" ]] || { echo "tampered fixture did not fall back to bundle: $fallback" >&2; exit 1; }
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
printf 'launcher fixture: valid external fingerprint passes; tampered payload falls back safely; pending candidate gets one launch then rolls back\n'
