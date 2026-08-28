#!/usr/bin/env bash
# Behavioral check for the post-build manifest fingerprint rewrite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-manifest-rewrite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/manifest.json"
printf '%s' '{"schema":1,"kind":"tron-gateway-payload","dependencyTreeCoverage":"app/** and runtime/** regular files","payloadFingerprint":"0000000000000000000000000000000000000000000000000000000000000000"}' > "$MANIFEST"
chmod 0444 "$MANIFEST"
EXPECTED="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
"$SCRIPT_DIR/update-payload-fingerprint.sh" "$MANIFEST" "$EXPECTED"
[[ "$(cat "$MANIFEST")" == "{\"schema\":1,\"kind\":\"tron-gateway-payload\",\"dependencyTreeCoverage\":\"app/** and runtime/** regular files\",\"payloadFingerprint\":\"$EXPECTED\"}" ]]
/usr/bin/python3 - "$MANIFEST" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o444
PY
if "$SCRIPT_DIR/update-payload-fingerprint.sh" "$MANIFEST" bad >/dev/null 2>&1; then
    echo "invalid fingerprint was accepted" >&2
    exit 1
fi
echo "payload fingerprint rewrite preserved manifest JSON and rejected invalid input"
