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
)
if ((clean)); then
    rm -rf "$PAYLOAD_DIR"
    rm -f "${launchers[@]}" \
        "$HELPER_DIR/Resources/AppIcon.icns"
    echo "cleaned generated Tron Gateway payloads"
    exit 0
fi

required=(
    "$GATEWAY_DIR/package.json"
    "$GATEWAY_DIR/package-lock.json"
    "$REPO_ROOT/scripts/gateway-payload-deploy.mjs"
    "$SCRIPT_DIR/tron-gateway-launcher.c"
    "$HELPER_DIR/Info.plist"
    "$LIBRARY_DIR/LaunchAgents/com.tron.server.plist"
)
for path in "${required[@]}"; do
    [[ -f "$path" ]] || { echo "missing required source: $path" >&2; exit 3; }
done

# Xcode and LaunchAgents may provide a sanitized PATH. Resolve the development
# toolchain once, before any install/build work, and use the same paths for all
# subsequent invocations. The fallback is intentionally bounded: only the
# user's standard nvm directory and the two conventional Homebrew prefixes are
# considered.
resolve_tool() {
    local tool="$1" override_name="$2" override="${!2:-}" candidate nvm_root version_dir
    if [[ -n "$override" ]]; then
        if [[ "$override" != /* || ! -x "$override" ]]; then
            echo "$override_name must be an absolute path to an executable (got: $override)" >&2
            exit 127
        fi
        printf '%s\n' "$override"
        return
    fi

    candidate="$(command -v "$tool" 2>/dev/null || true)"
    if [[ "$candidate" == /* && -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
    fi

    nvm_root="${NVM_DIR:-${HOME:-}/.nvm}/versions/node"
    if [[ -d "$nvm_root" ]]; then
        # Sorting makes selection stable when multiple nvm versions are present.
        while IFS= read -r version_dir; do
            candidate="$version_dir/bin/$tool"
            if [[ -x "$candidate" ]]; then
                printf '%s\n' "$candidate"
                return
            fi
        done < <(find "$nvm_root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort -r)
    fi

    for candidate in "/opt/homebrew/bin/$tool" "/usr/local/bin/$tool"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    echo "unable to find executable $tool; set $override_name to an absolute path, put $tool on PATH, or install it under \$HOME/.nvm or Homebrew" >&2
    exit 127
}

NODE_BIN="$(resolve_tool node TRON_NODE_BIN)"
NPM_BIN="$(resolve_tool npm TRON_NPM_BIN)"
# npm's launcher commonly uses /usr/bin/env node; make the resolved Node
# directory available even when Xcode supplied no useful PATH.
export PATH="$(dirname "$NODE_BIN")${PATH:+:$PATH}"

if ((!skip_install)); then
    echo "==> installing locked gateway dependencies"
    (cd "$GATEWAY_DIR" && "$NPM_BIN" ci --ignore-scripts=false && "$NPM_BIN" run build)
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

mkdir -p "$APP_DIR/dist" "$APP_DIR/scripts" "$RUNTIME_DIR" \
    "$HELPER_DIR/MacOS" "$HELPER_DIR/Resources"
# Permit replacing a previously staged immutable payload during an explicit
# bundle operation; publication directories remain read-only afterward.
chmod -R u+w "$PAYLOAD_DIR" 2>/dev/null || true
rm -rf "$APP_DIR/dist" "$APP_DIR/node_modules"
cp -R "$GATEWAY_DIR/dist" "$APP_DIR/dist"
cp "$GATEWAY_DIR/package.json" "$GATEWAY_DIR/package-lock.json" "$APP_DIR/"
cp "$GATEWAY_DIR/scripts/ensure-node-pty-helper.mjs" "$APP_DIR/scripts/"
cp "$REPO_ROOT/scripts/gateway-payload-deploy.mjs" "$APP_DIR/scripts/"
# npm prune in the source tree would damage developer dependencies. Install an
# independent production tree directly into the generated app payload.
(cd "$APP_DIR" && "$NPM_BIN" ci --omit=dev --ignore-scripts=false)

stage_node arm64 "$NODE_ARM64_SHA256"
stage_node x64 "$NODE_X64_SHA256"

launcher_temp="$(mktemp -d)/tron"
xcrun clang -Os -Wall -Wextra -arch arm64 -arch x86_64 \
    -mmacosx-version-min=15.0 "$SCRIPT_DIR/tron-gateway-launcher.c" -o "$launcher_temp"
for destination in "${launchers[@]}"; do
    install -m 0755 "$launcher_temp" "$destination"
done
rm -rf "$(dirname "$launcher_temp")"

for required_payload in \
    "$APP_DIR/dist/index.js" "$APP_DIR/package.json" "$APP_DIR/package-lock.json" \
    "$APP_DIR/scripts/ensure-node-pty-helper.mjs" "$APP_DIR/scripts/gateway-payload-deploy.mjs" \
    "$APP_DIR/node_modules" "$RUNTIME_DIR/node-arm64" "$RUNTIME_DIR/node-x64"; do
    [[ -e "$required_payload" ]] || { echo "missing required staged payload: $required_payload" >&2; exit 3; }
done

cp "$RESOURCES_DIR/AppIcon.icns" "$HELPER_DIR/Resources/AppIcon.icns"

GATEWAY_VERSION="$("$NODE_BIN" -p "require('$GATEWAY_DIR/package.json').version")"
SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
RUNTIME_EPOCH="$(uuidgen | tr '[:upper:]' '[:lower:]')"
# Hash the complete staged dependency tree, not merely the compiled entrypoint.
# The helper is standalone so release validation can exercise the same coverage.
# The signed launcher hashes the complete tree in-process; the shell helper
# remains the readable cross-implementation fixture but is intentionally not
# process-per-file on this large build path.
PAYLOAD_FINGERPRINT="$("${launchers[0]}" --fingerprint "$PAYLOAD_DIR")"
printf '{"schema":1,"kind":"tron-gateway-payload","channel":"stable","version":"%s","gatewayVersion":"%s","nodeVersion":"%s","sourceRevision":"%s","runtimeEpoch":"%s","payloadFingerprint":"%s","dependencyTreeCoverage":"app/** and runtime/** regular files"}\n' \
    "$GATEWAY_VERSION" "$GATEWAY_VERSION" "$NODE_VERSION" "$SOURCE_REVISION" "$RUNTIME_EPOCH" "$PAYLOAD_FINGERPRINT" \
    > "$PAYLOAD_DIR/manifest.json"
# Version payloads are immutable after publication; current.json remains the
# only mutable deployment pointer. The launcher uses this as its bounded
# anti-tampering check and does not claim to re-hash the tree.
chmod -R a-w "$PAYLOAD_DIR"

printf 'staged Tron Gateway %s with Node %s (fingerprint %s)\n' \
    "$GATEWAY_VERSION" "$NODE_VERSION" "$PAYLOAD_FINGERPRINT"
for destination in "${launchers[@]}"; do
    printf '  %s (architectures: %s)\n' "$destination" "$(lipo -archs "$destination")"
done
