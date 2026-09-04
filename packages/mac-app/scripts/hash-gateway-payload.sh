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
    app/node_modules runtime/node-arm64 runtime/node-x64 \
    runtime/xcodegen/bin/xcodegen \
    runtime/xcodegen/share/xcodegen/SettingPresets/base.yml; do
    [[ -e "$ROOT/$required" && ! -L "$ROOT/$required" ]] || {
        echo "required payload entry is missing or symlinked: $required" >&2; exit 2;
    }
done
[[ -x "$ROOT/runtime/xcodegen/bin/xcodegen" ]] || {
    echo "required payload XcodeGen is not executable" >&2; exit 2;
}
PI_CLI="$ROOT/app/node_modules/.bin/pi"
PI_PACKAGE="$ROOT/app/node_modules/@earendil-works/pi-coding-agent"
[[ -L "$PI_CLI" && ! -L "$PI_PACKAGE" ]] || { echo "required npm Pi projection or package root is missing or substituted" >&2; exit 2; }
PI_REAL="$(realpath "$PI_CLI")"; PI_PACKAGE_REAL="$(realpath "$PI_PACKAGE")"; PI_NODE_MODULES_REAL="$(realpath "$ROOT/app/node_modules")"
[[ "$PI_PACKAGE_REAL" == "$PI_NODE_MODULES_REAL"/* && "$PI_REAL" == "$PI_PACKAGE_REAL"/* && -f "$PI_REAL" && -x "$PI_REAL" ]] || {
    echo "required npm Pi projection or package root escapes app/node_modules" >&2; exit 2;
}
for architecture in arm64 x64; do
    directory="$ROOT/runtime/bin-$architecture"
    alias="$directory/node"
    pi_alias="$directory/pi"
    [[ -d "$directory" && ! -L "$directory" && -L "$alias" \
        && "$(readlink "$alias")" == "../node-$architecture" \
        && "$(realpath "$alias")" == "$(realpath "$ROOT/runtime/node-$architecture")" ]] || {
        echo "required runtime Node alias is invalid: $architecture" >&2; exit 2;
    }
    [[ -L "$pi_alias" && "$(readlink "$pi_alias")" == "../../app/node_modules/.bin/pi" \
        && "$(realpath "$pi_alias")" == "$PI_REAL" ]] || {
        echo "required runtime Pi alias is invalid: $architecture" >&2; exit 2;
    }
done

# Validate links before hashing. realpath rejects dangling links, and the
# target checks permit only regular files inside app/ or runtime/, preventing
# links from escaping either the payload root or deterministic coverage.
while IFS= read -r entry; do
    if [[ -L "$entry" ]]; then
        target="$(realpath "$entry" 2>/dev/null)" || {
            echo "payload contains a dangling symlink: $entry" >&2; exit 2;
        }
        case "$target" in
            "$ROOT"|"$ROOT"/*) ;;
            *) echo "payload symlink escapes root: $entry" >&2; exit 2 ;;
        esac
        case "$target" in
            "$ROOT/app"/*|"$ROOT/runtime"/*) ;;
            *) echo "payload symlink target is outside fingerprinted payload trees: $entry" >&2; exit 2 ;;
        esac
        [[ -f "$target" ]] || {
            echo "payload symlink target is not a regular file: $entry" >&2; exit 2;
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
