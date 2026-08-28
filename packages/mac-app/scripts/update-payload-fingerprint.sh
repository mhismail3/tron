#!/usr/bin/env bash
# Replace exactly one payloadFingerprint value without reserializing the JSON.
# This preserves launcher-sensitive strings such as `app/**` verbatim.
set -euo pipefail

manifest="${1:-}"
fingerprint="${2:-}"
[[ -f "$manifest" && ! -L "$manifest" ]] || { echo "manifest is not a regular file" >&2; exit 64; }
[[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || { echo "fingerprint must be 64 lowercase hex characters" >&2; exit 64; }

temporary="${manifest}.tmp.$$"
[[ ! -e "$temporary" ]] || { echo "temporary manifest path already exists" >&2; exit 73; }
trap 'rm -f "$temporary"' EXIT
cp -p "$manifest" "$temporary"
PAYLOAD_FINGERPRINT="$fingerprint" /usr/bin/perl -0pi -e '
    my $count = s/("payloadFingerprint"\s*:\s*")[0-9a-f]{64}(")/$1 . $ENV{"PAYLOAD_FINGERPRINT"} . $2/ge;
    die "expected exactly one payloadFingerprint field\n" unless $count == 1;
' "$temporary"
mv "$temporary" "$manifest"
trap - EXIT
