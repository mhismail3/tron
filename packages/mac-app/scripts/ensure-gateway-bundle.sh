#!/usr/bin/env bash
# Ensure the generated Mac Gateway payload exists before Xcode copies it into
# the app. The shipped helper uses this payload and never needs a global Pi
# installation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/../Sources/Resources"
PAYLOAD_DIR="$RESOURCES_DIR/Gateway"

required_files=(
    "$PAYLOAD_DIR/manifest.json"
    "$PAYLOAD_DIR/app/dist/index.js"
    "$PAYLOAD_DIR/app/package.json"
    "$PAYLOAD_DIR/app/package-lock.json"
)
required_directories=(
    "$PAYLOAD_DIR/app/node_modules"
)
required_executables=(
    "$PAYLOAD_DIR/runtime/node-arm64"
    "$PAYLOAD_DIR/runtime/node-x64"
    "$RESOURCES_DIR/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
    "$RESOURCES_DIR/Library/LoginItems/Tron Agent Dev.app/Contents/MacOS/tron"
)

needs_bundle=0
for path in "${required_files[@]}"; do
    if [[ ! -f "$path" ]]; then
        needs_bundle=1
        break
    fi
done
if ((needs_bundle == 0)) && ! grep -Eq '"kind":"tron-gateway-payload"' "$PAYLOAD_DIR/manifest.json"; then
    needs_bundle=1
fi
if ((needs_bundle == 0)); then
    for path in "${required_directories[@]}"; do
        if [[ ! -d "$path" ]]; then
            needs_bundle=1
            break
        fi
    done
fi
if ((needs_bundle == 0)); then
    for path in "${required_executables[@]}"; do
        if [[ ! -x "$path" ]]; then
            needs_bundle=1
            break
        fi
    done
fi

if ((needs_bundle)); then
    echo "==> Mac Gateway payload is incomplete; staging bundled Gateway and Node runtimes"
    exec "$SCRIPT_DIR/bundle-gateway.sh"
fi

echo "Mac Gateway payload is ready (embedded Gateway, production dependencies, and Node runtimes)"
