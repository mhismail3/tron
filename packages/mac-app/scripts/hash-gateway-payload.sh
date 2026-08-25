#!/usr/bin/env bash
# Print a deterministic SHA-256 over every regular file and safe symlink in a
# staged payload. Symlink target digests are part of the canonical line format.
# Coverage is deliberately complete for app/ (including node_modules) and
# runtime/, excluding only the root manifest that records this result.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: hash-gateway-payload.sh PAYLOAD_ROOT" >&2; exit 64; }
ROOT="$1"
[[ ! -L "$ROOT" && -d "$ROOT" ]] || { echo "payload root must be a regular directory" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd -P)"
[[ -d "$ROOT/app" && ! -L "$ROOT/app" && -d "$ROOT/runtime" && ! -L "$ROOT/runtime" ]] || {
    echo "payload must contain regular app/ and runtime/ directories" >&2
    exit 2
}
for required in \
    app/dist/index.js app/package.json app/package-lock.json app/PushService.xcconfig \
    app/scripts/ensure-node-pty-helper.mjs app/scripts/gateway-payload-deploy.mjs \
    app/node_modules runtime/node-arm64 runtime/node-x64; do
    [[ -e "$ROOT/$required" && ! -L "$ROOT/$required" ]] || {
        echo "required payload entry is missing or symlinked: $required" >&2; exit 2;
    }
done

# Validate links before hashing. realpath rejects dangling links, and the
# target's type check rejects links to special entries while path matching
# prevents links from escaping the payload root.
while IFS= read -r entry; do
    if [[ -L "$entry" ]]; then
        target="$(realpath "$entry" 2>/dev/null)" || {
            echo "payload contains a dangling symlink: $entry" >&2; exit 2;
        }
        case "$target" in
            "$ROOT"|"$ROOT"/*) ;;
            *) echo "payload symlink escapes root: $entry" >&2; exit 2 ;;
        esac
        [[ -f "$target" || -d "$target" ]] || {
            echo "payload symlink targets a special entry: $entry" >&2; exit 2;
        }
    fi
done < <(find "$ROOT/app" "$ROOT/runtime" -print)

find "$ROOT/app" "$ROOT/runtime" ! -type f ! -type d ! -type l -print -quit | grep -q . && {
    echo "payload contains an unsupported entry" >&2; exit 2;
}
(
    cd "$ROOT"
    find app runtime \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
        if [[ -L "$file" ]]; then
            # readlink emits the target followed by LF; hash exactly those
            # bytes, matching the JS and Swift implementations.
            targetDigest="$(readlink "$file" | shasum -a 256 | awk '{print $1}')"
            printf 'symlink:%s  %s\n' "$targetDigest" "$file"
        else
            shasum -a 256 "$file"
        fi
    done
) | shasum -a 256 | awk '{print $1}'
