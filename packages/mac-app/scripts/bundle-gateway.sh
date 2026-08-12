#!/usr/bin/env bash
# Stage the exact Tron Gateway, its production dependencies, Node runtimes, and
# tiny universal Login Item launcher into the Mac wrapper's resource tree.
#
# Usage:
#   bundle-gateway.sh                  build and stage everything
#   bundle-gateway.sh --skip-install   reuse an existing gateway node_modules
#   bundle-gateway.sh --skip-download  reuse already staged Node runtimes
#   bundle-gateway.sh --clean          remove only generated payloads
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GATEWAY_DIR="$REPO_ROOT/packages/gateway"
RESOURCES_DIR="$SCRIPT_DIR/../Sources/Resources"
PAYLOAD_DIR="$RESOURCES_DIR/Gateway"
APP_DIR="$PAYLOAD_DIR/app"
RUNTIME_DIR="$PAYLOAD_DIR/runtime"
LIBRARY_DIR="$RESOURCES_DIR/Library"
HELPER_DIR="$LIBRARY_DIR/LoginItems/Tron Agent.app/Contents"
DEV_HELPER_DIR="$LIBRARY_DIR/LoginItems/Tron Agent Dev.app/Contents"
NODE_VERSION="22.22.0"
NODE_ARM64_SHA256="5ed4db0fcf1eaf84d91ad12462631d73bf4576c1377e192d222e48026a902640"
NODE_X64_SHA256="5ea50c9d6dea3dfa3abb66b2656f7a4e1c8cef23432b558d45fb538c7b5dedce"
skip_install=0
skip_download=0
clean=0

while (($#)); do
    case "$1" in
        --skip-install) skip_install=1 ;;
        --skip-download) skip_download=1 ;;
        --clean) clean=1 ;;
        --help|-h) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
    shift
done

launchers=(
    "$HELPER_DIR/MacOS/tron"
    "$DEV_HELPER_DIR/MacOS/tron"
)
if ((clean)); then
    rm -rf "$PAYLOAD_DIR"
    rm -f "${launchers[@]}" \
        "$HELPER_DIR/Resources/AppIcon.icns" \
        "$DEV_HELPER_DIR/Resources/AppIcon.icns"
    echo "cleaned generated Tron Gateway payloads"
    exit 0
fi

required=(
    "$GATEWAY_DIR/package.json"
    "$GATEWAY_DIR/package-lock.json"
    "$SCRIPT_DIR/tron-gateway-launcher.c"
    "$HELPER_DIR/Info.plist"
    "$DEV_HELPER_DIR/Info.plist"
    "$LIBRARY_DIR/LaunchAgents/com.tron.server.plist"
    "$LIBRARY_DIR/LaunchAgents/com.tron.server.dev.plist"
)
for path in "${required[@]}"; do
    [[ -f "$path" ]] || { echo "missing required source: $path" >&2; exit 3; }
done

if ((!skip_install)); then
    echo "==> installing locked gateway dependencies"
    (cd "$GATEWAY_DIR" && npm ci --ignore-scripts=false && npm run build)
else
    [[ -d "$GATEWAY_DIR/node_modules" && -f "$GATEWAY_DIR/dist/index.js" ]] || {
        echo "--skip-install requires packages/gateway/node_modules and dist/index.js" >&2
        exit 2
    }
fi

stage_node() {
    local arch="$1" expected="$2" destination="$RUNTIME_DIR/node-$1"
    if ((skip_download)); then
        [[ -x "$destination" ]] || { echo "missing staged Node runtime: $destination" >&2; exit 2; }
        return
    fi
    local archive="node-v${NODE_VERSION}-darwin-${arch}.tar.gz"
    local temp
    temp="$(mktemp -d)"
    curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/${archive}" -o "$temp/$archive"
    local actual
    actual="$(shasum -a 256 "$temp/$archive" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || { echo "Node $arch checksum mismatch" >&2; rm -rf "$temp"; exit 3; }
    tar -xzf "$temp/$archive" -C "$temp"
    install -m 0755 "$temp/node-v${NODE_VERSION}-darwin-${arch}/bin/node" "$destination"
    rm -rf "$temp"
}

mkdir -p "$APP_DIR/dist" "$RUNTIME_DIR" \
    "$HELPER_DIR/MacOS" "$HELPER_DIR/Resources" \
    "$DEV_HELPER_DIR/MacOS" "$DEV_HELPER_DIR/Resources"
rm -rf "$APP_DIR/dist" "$APP_DIR/node_modules"
cp -R "$GATEWAY_DIR/dist" "$APP_DIR/dist"
cp "$GATEWAY_DIR/package.json" "$GATEWAY_DIR/package-lock.json" "$APP_DIR/"
# npm prune in the source tree would damage developer dependencies. Install an
# independent production tree directly into the generated app payload.
(cd "$APP_DIR" && npm ci --omit=dev --ignore-scripts=false)

stage_node arm64 "$NODE_ARM64_SHA256"
stage_node x64 "$NODE_X64_SHA256"

launcher_temp="$(mktemp -d)/tron"
xcrun clang -Os -Wall -Wextra -arch arm64 -arch x86_64 \
    -mmacosx-version-min=15.0 "$SCRIPT_DIR/tron-gateway-launcher.c" -o "$launcher_temp"
for destination in "${launchers[@]}"; do
    install -m 0755 "$launcher_temp" "$destination"
done
rm -rf "$(dirname "$launcher_temp")"

cp "$RESOURCES_DIR/AppIcon.icns" "$HELPER_DIR/Resources/AppIcon.icns"
cp "$RESOURCES_DIR/AppIcon.icns" "$DEV_HELPER_DIR/Resources/AppIcon.icns"

printf 'staged Tron Gateway %s with Node %s\n' \
    "$(node -p "require('$GATEWAY_DIR/package.json').version")" "$NODE_VERSION"
for destination in "${launchers[@]}"; do
    printf '  %s (architectures: %s)\n' "$destination" "$(lipo -archs "$destination")"
done
