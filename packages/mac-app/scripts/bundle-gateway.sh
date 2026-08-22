#!/usr/bin/env bash
# Stage the exact Tron Gateway, its production dependencies, Node runtimes, and
# tiny universal Login Item launcher into the Mac wrapper's resource tree.
#
# Usage:
#   bundle-gateway.sh                  build and stage everything
#   bundle-gateway.sh --skip-install   reuse an existing gateway node_modules
#   bundle-gateway.sh --skip-download  reuse already staged Node runtimes
#   bundle-gateway.sh --clean          remove only generated payloads
#   bundle-gateway.sh --verify-only    verify existing payload without mutation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GATEWAY_DIR="$REPO_ROOT/packages/gateway"
RESOURCES_DIR="$SCRIPT_DIR/../Sources/Resources"
PAYLOAD_DIR="$RESOURCES_DIR/Gateway"
APP_DIR="$PAYLOAD_DIR/app"
RUNTIME_DIR="$PAYLOAD_DIR/runtime"
LIBRARY_DIR="$RESOURCES_DIR/Library"
HELPER_DIR="$LIBRARY_DIR/LoginItems/Tron Agent.app/Contents"
NODE_VERSION_FILE="$REPO_ROOT/.node-version"
[[ -f "$NODE_VERSION_FILE" ]] || { echo "missing canonical Node version file: $NODE_VERSION_FILE" >&2; exit 3; }
NODE_VERSION="$(<"$NODE_VERSION_FILE")"
NODE_VERSION_LINES="$(awk 'END { print NR }' "$NODE_VERSION_FILE")"
[[ "$NODE_VERSION_LINES" == 1 && "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "invalid canonical Node version in $NODE_VERSION_FILE" >&2
    exit 3
}
# Pinned binary integrity metadata. The canonical version remains .node-version;
# these hashes only authorize the exact runtime artifacts staged below.
NODE_ARM64_SHA256="913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4"
NODE_X64_SHA256="bf0e0ff20d4e5a16436d1ec372e47161e52be8e487db8070ae3f06b01efbba0c"
if [[ -n "${NVM_DIR:-}" && "$NVM_DIR" != /* ]]; then
    echo "relative NVM_DIR is not allowed" >&2
    exit 127
fi
skip_install=0
skip_download=0
clean=0
verify_only=0

while (($#)); do
    case "$1" in
        --skip-install) skip_install=1 ;;
        --skip-download) skip_download=1 ;;
        --clean) clean=1 ;;
        --verify-only) verify_only=1 ;;
        --help|-h) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
    shift
done

launchers=(
    "$HELPER_DIR/MacOS/tron"
)

# Generated output is disposable, but its parents are owned source-tree
# directories. Walk with lstat and unlink symlinks instead of ever allowing a
# recursive operation to follow an attacker-controlled ancestor.
assert_owned_ancestors() {
    local path="$1" cursor="$1" info
    while [[ "$cursor" == "$REPO_ROOT"/* || "$cursor" == "$REPO_ROOT" ]]; do
        if [[ -e "$cursor" || -L "$cursor" ]]; then
            info="$(stat -f '%HT' "$cursor" 2>/dev/null || true)"
            [[ "$info" != "Symbolic Link" && ! -L "$cursor" ]] || {
                echo "generated bundle path has a symlinked ancestor: $path" >&2
                exit 78
            }
        fi
        [[ "$cursor" == "$REPO_ROOT" ]] && break
        cursor="$(dirname "$cursor")"
    done
}
safe_remove_tree() {
    local path="$1" entry
    [[ -e "$path" || -L "$path" ]] || return 0
    if [[ -L "$path" ]]; then
        unlink "$path"
        return 0
    fi
    if [[ -d "$path" ]]; then
        chmod u+w "$path"
        while IFS= read -r -d '' entry; do safe_remove_tree "$entry"; done < <(find "$path" -mindepth 1 -maxdepth 1 -print0)
        rmdir "$path"
    else
        unlink "$path"
    fi
}
assert_owned_ancestors "$RESOURCES_DIR"
assert_owned_ancestors "$PAYLOAD_DIR"
assert_owned_ancestors "$APP_DIR"
assert_owned_ancestors "$RUNTIME_DIR"
assert_owned_ancestors "$HELPER_DIR"
assert_owned_ancestors "$HELPER_DIR/MacOS"
assert_owned_ancestors "$HELPER_DIR/Resources"
if ((clean)); then
    safe_remove_tree "$PAYLOAD_DIR"
    safe_remove_tree "$HELPER_DIR/MacOS/tron"
    safe_remove_tree "$HELPER_DIR/Resources/AppIcon.icns"
    echo "cleaned generated Tron Gateway payloads"
    exit 0
fi

required=(
    "$GATEWAY_DIR/package.json"
    "$GATEWAY_DIR/package-lock.json"
    "$REPO_ROOT/scripts/gateway-payload-deploy.mjs"
    "$SCRIPT_DIR/tron-gateway-launcher.c"
    "$SCRIPT_DIR/verify-gateway-payload.sh"
    "$HELPER_DIR/Info.plist"
    "$LIBRARY_DIR/LaunchAgents/com.tron.server.plist"
)
for path in "${required[@]}"; do
    [[ -f "$path" ]] || { echo "missing required source: $path" >&2; exit 3; }
done

if ((verify_only)); then
    "$SCRIPT_DIR/verify-gateway-payload.sh" "$PAYLOAD_DIR" "$HELPER_DIR/MacOS/tron"
    exit 0
fi

# Xcode and LaunchAgents may provide a sanitized PATH. Resolve the exact
# canonical Node once, before any install/build work, and derive npm from that
# same directory. A wrong ambient Node is skipped in favor of the exact nvm
# directory; Homebrew is considered only after its version is proved.
node_matches_pin() {
    local candidate="$1" actual
    [[ -x "$candidate" ]] || return 1
    actual="$("$candidate" --version 2>/dev/null || true)"
    [[ "$actual" == "v${NODE_VERSION}" ]]
}
resolve_pinned_node() {
    local candidate nvm_node
    if [[ -n "${TRON_NODE_BIN:-}" ]]; then
        candidate="$TRON_NODE_BIN"
        [[ "$candidate" == /* ]] || { echo "TRON_NODE_BIN must be absolute" >&2; exit 127; }
        node_matches_pin "$candidate" || { echo "TRON_NODE_BIN is not Node v${NODE_VERSION}" >&2; exit 127; }
        printf '%s\n' "$candidate"
        return
    fi
    candidate="$(command -v node 2>/dev/null || true)"
    if [[ "$candidate" == /* ]] && node_matches_pin "$candidate"; then
        printf '%s\n' "$candidate"
        return
    fi
    nvm_node="${NVM_DIR:-${HOME:-}/.nvm}/versions/node/v${NODE_VERSION}/bin/node"
    if node_matches_pin "$nvm_node"; then
        printf '%s\n' "$nvm_node"
        return
    fi
    for candidate in "/opt/homebrew/bin/node" "/usr/local/bin/node"; do
        if node_matches_pin "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    echo "unable to find exact Node v${NODE_VERSION}; checked PATH, the pinned nvm directory, and Homebrew" >&2
    exit 127
}

NODE_BIN="$(resolve_pinned_node)"
NPM_BIN="$(dirname "$NODE_BIN")/npm"
[[ "$NODE_BIN" == /* && "$NPM_BIN" == /* && -x "$NPM_BIN" ]] || { echo "missing npm sibling of pinned Node: $NPM_BIN" >&2; exit 127; }
# npm's launcher commonly uses /usr/bin/env node; make only the resolved Node
# directory first on PATH so all subprocesses use this exact toolchain.
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

validate_node_runtime() {
    local arch="$1" expected="$2" destination="$RUNTIME_DIR/node-$1"
    local expected_arch="arm64"; [[ "$arch" == x64 ]] && expected_arch="x86_64"
    [[ -x "$destination" ]] || { echo "missing staged Node runtime: $destination" >&2; exit 2; }

    local actual
    actual="$(shasum -a 256 "$destination" | awk '{print $1}')" || {
        echo "unable to hash staged Node runtime: $destination" >&2
        exit 3
    }
    [[ "$actual" == "$expected" ]] || {
        echo "Node $arch binary checksum mismatch" >&2
        exit 3
    }

    local file_tool lipo_tool file_description lipo_arches
    file_tool="$(command -v file 2>/dev/null || true)"
    lipo_tool="$(command -v lipo 2>/dev/null || true)"
    [[ -n "$file_tool" || -n "$lipo_tool" ]] || {
        echo "unable to verify Mach-O architecture: neither file nor lipo is available" >&2
        exit 3
    }
    if [[ -n "$file_tool" ]]; then
        file_description="$("$file_tool" "$destination")" || {
            echo "unable to inspect staged Node $arch runtime" >&2
            exit 3
        }
        [[ "$file_description" == *"Mach-O"* ]] || {
            echo "Node $arch runtime is not a Mach-O binary" >&2
            exit 3
        }
    fi
    if [[ -n "$lipo_tool" ]]; then
        lipo_arches="$("$lipo_tool" -archs "$destination" 2>/dev/null)" || {
            echo "unable to inspect staged Node $arch architecture" >&2
            exit 3
        }
        [[ "$lipo_arches" == "$expected_arch" ]] || {
            echo "Node $arch architecture mismatch (expected $expected_arch, got $lipo_arches)" >&2
            exit 3
        }
    elif [[ "$file_description" != *"$expected_arch"* ]]; then
        echo "Node $arch architecture mismatch (expected $expected_arch)" >&2
        exit 3
    fi
}

stage_node() {
    local arch="$1" expected="$2" destination="$RUNTIME_DIR/node-$1"
    if ((skip_download)); then
        validate_node_runtime "$arch" "$expected"
        return
    fi
    local archive="node-v${NODE_VERSION}-darwin-${arch}.tar.gz"
    local temp
    temp="$(mktemp -d)"
    curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/${archive}" -o "$temp/$archive"
    tar -xzf "$temp/$archive" -C "$temp"
    install -m 0755 "$temp/node-v${NODE_VERSION}-darwin-${arch}/bin/node" "$destination"
    rm -rf "$temp"
    # Downloaded binaries receive the same immutable hash/version/architecture
    # proof as pre-staged binaries before the payload is published.
    validate_node_runtime "$arch" "$expected"
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
xcrun --sdk macosx clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
    "$SCRIPT_DIR/tron-gateway-launcher.c" -o "$launcher_temp"
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
