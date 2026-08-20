#!/usr/bin/env bash
# Print a deterministic SHA-256 over every regular file in a staged payload.
# Coverage is deliberately complete for app/ (including node_modules) and
# runtime/, excluding only the root manifest that records this result.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: hash-gateway-payload.sh PAYLOAD_ROOT" >&2; exit 64; }
ROOT="$1"
[[ -d "$ROOT/app" && -d "$ROOT/runtime" ]] || {
    echo "payload must contain app/ and runtime/" >&2
    exit 2
}
[[ -z "$(find "$ROOT/app" "$ROOT/runtime" -type l -print -quit)" ]] || {
    echo "payload must not contain symlinks" >&2
    exit 2
}
(
    cd "$ROOT"
    find app runtime -type f -print | LC_ALL=C sort | while IFS= read -r file; do
        shasum -a 256 "$file"
    done
) | shasum -a 256 | awk '{print $1}'
