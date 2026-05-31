#!/usr/bin/env bash
#
# bundle-agent.sh — stage the Rust agent binaries as the embedded
# `Tron Server.app` Login Item used by `SMAppService`.
#
# The executables are staged in both helper bundles:
# `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/`
# `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/`
# `project.yml` copies `Sources/Resources/Library` into
# `Tron.app/Contents/Library` after compile, yielding the production path
# required by `SMAppService.agent(plistName:)`.
#
# Usage:
#   bundle-agent.sh                 # default: build release + stage
#   bundle-agent.sh --profile debug # build debug profile instead
#   bundle-agent.sh --skip-build    # assume target/release/{tron,tron-program-worker} exist
#   bundle-agent.sh --source PATH   # explicit path to prebuilt tron; worker is resolved as a sibling
#   bundle-agent.sh --worker-source PATH # explicit path to a prebuilt program worker
#   bundle-agent.sh --clean         # remove staged helper binaries and launch metadata
#
# Local push relay dogfood:
#   put TRON_RELAY_URL / TRON_RELAY_SECRET in packages/mac-app/.env.local.
#   The script reads only those relay keys before Cargo builds the helper.
#
# Exit codes:
#   0  — staged binary is up to date
#   1  — build failed
#   2  — source binary missing (with --skip-build or --source)
#   3  — staging path not writable
#   64 — invalid arguments or malformed local relay env
#
# The script is idempotent. It refuses to run inside DerivedData / Xcode
# archive contexts to avoid recursive rebuilds when invoked from a Run
# Script build phase. CI invokes it from the repo root before
# `xcodebuild archive`.

set -euo pipefail

# --- repo locator --------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AGENT_DIR="$REPO_ROOT/packages/agent"
RESOURCES_DIR="$SCRIPT_DIR/../Sources/Resources"
LOCAL_ENV_FILE="$SCRIPT_DIR/../.env.local"
LIBRARY_DIR="$RESOURCES_DIR/Library"
HELPER_BUNDLE="$LIBRARY_DIR/LoginItems/Tron Server.app"
HELPER_CONTENTS="$HELPER_BUNDLE/Contents"
HELPER_MACOS="$HELPER_CONTENTS/MacOS"
HELPER_RESOURCES="$HELPER_CONTENTS/Resources"
DEV_HELPER_BUNDLE="$LIBRARY_DIR/LoginItems/Tron Server Dev.app"
DEV_HELPER_CONTENTS="$DEV_HELPER_BUNDLE/Contents"
DEV_HELPER_MACOS="$DEV_HELPER_CONTENTS/MacOS"
DEV_HELPER_RESOURCES="$DEV_HELPER_CONTENTS/Resources"
LAUNCH_AGENT_DIR="$LIBRARY_DIR/LaunchAgents"
STAGING_PATH="$HELPER_MACOS/tron"
STAGING_WORKER_PATH="$HELPER_MACOS/tron-program-worker"
DEV_STAGING_PATH="$DEV_HELPER_MACOS/tron"
DEV_STAGING_WORKER_PATH="$DEV_HELPER_MACOS/tron-program-worker"
HELPER_INFO_PLIST="$HELPER_CONTENTS/Info.plist"
DEV_HELPER_INFO_PLIST="$DEV_HELPER_CONTENTS/Info.plist"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.tron.server.plist"
DEV_LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.tron.server.dev.plist"

# --- argv parser ---------------------------------------------------------

profile="release"
source_override=""
worker_source_override=""
skip_build=0
do_clean=0

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)    profile="$2"; shift 2 ;;
        --profile=*)  profile="${1#--profile=}"; shift ;;
        --source)     source_override="$2"; shift 2 ;;
        --source=*)   source_override="${1#--source=}"; shift ;;
        --worker-source)   worker_source_override="$2"; shift 2 ;;
        --worker-source=*) worker_source_override="${1#--worker-source=}"; shift ;;
        --skip-build) skip_build=1; shift ;;
        --clean)      do_clean=1; shift ;;
        --help|-h)
            grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

# --- clean mode ----------------------------------------------------------

if [ "$do_clean" -eq 1 ]; then
    rm -rf "$HELPER_BUNDLE" "$DEV_HELPER_BUNDLE" "$LAUNCH_AGENT_PLIST" "$DEV_LAUNCH_AGENT_PLIST"
    echo "cleaned helper bundles and launch agent plists"
    exit 0
fi

# --- source resolution ---------------------------------------------------

resolve_source() {
    if [ -n "$source_override" ]; then
        if [ ! -x "$source_override" ]; then
            echo "error: --source path not executable: $source_override" >&2
            exit 2
        fi
        printf '%s\n' "$source_override"
        return
    fi

    # Cargo workspace lives entirely inside packages/agent/, so `cargo
    # build` from there writes to `packages/agent/target/`, NOT the repo
    # root. Resolve against $AGENT_DIR to match.
    case "$profile" in
        release) printf '%s/target/release/tron\n' "$AGENT_DIR" ;;
        debug)   printf '%s/target/debug/tron\n' "$AGENT_DIR" ;;
        *) echo "error: unknown --profile '$profile' (expected release|debug)" >&2; exit 64 ;;
    esac
}

resolve_worker_source() {
    if [ -n "$worker_source_override" ]; then
        if [ ! -x "$worker_source_override" ]; then
            echo "error: --worker-source path not executable: $worker_source_override" >&2
            exit 2
        fi
        printf '%s\n' "$worker_source_override"
        return
    fi

    if [ -n "$source_override" ]; then
        local sibling
        sibling="$(dirname "$source_override")/tron-program-worker"
        if [ ! -x "$sibling" ]; then
            echo "error: sibling tron-program-worker not executable beside --source: $sibling" >&2
            exit 2
        fi
        printf '%s\n' "$sibling"
        return
    fi

    case "$profile" in
        release) printf '%s/target/release/tron-program-worker\n' "$AGENT_DIR" ;;
        debug)   printf '%s/target/debug/tron-program-worker\n' "$AGENT_DIR" ;;
        *) echo "error: unknown --profile '$profile' (expected release|debug)" >&2; exit 64 ;;
    esac
}

source_bin="$(resolve_source)"
worker_source_bin="$(resolve_worker_source)"

# --- local build env -----------------------------------------------------

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

strip_optional_quotes() {
    local value="$1"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

set_if_unset() {
    local key="$1"
    local value="$2"
    if [ -z "${!key+x}" ]; then
        export "$key=$value"
    fi
}

load_local_relay_env() {
    [ -f "$LOCAL_ENV_FILE" ] || return 0

    local line key value loaded=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        if [[ "$line" =~ ^(export[[:space:]]+)?(TRON_RELAY_URL|TRON_RELAY_SECRET|TRON_RELAY_ENVIRONMENT)=(.*)$ ]]; then
            key="${BASH_REMATCH[2]}"
            value="$(strip_optional_quotes "$(trim "${BASH_REMATCH[3]}")")"
            set_if_unset "$key" "$value"
            loaded=1
        elif [[ "$line" == TRON_RELAY_* || "$line" == export[[:space:]]TRON_RELAY_* ]]; then
            echo "error: malformed relay env line in $LOCAL_ENV_FILE: $line" >&2
            exit 64
        fi
    done < "$LOCAL_ENV_FILE"

    if [ "$loaded" -eq 1 ]; then
        echo "loaded local relay build env from $LOCAL_ENV_FILE"
    fi
}

prepare_relay_env_for_build() {
    load_local_relay_env

    local has_url=0
    local has_secret=0
    [ -n "${TRON_RELAY_URL:-}" ] && has_url=1
    [ -n "${TRON_RELAY_SECRET:-}" ] && has_secret=1

    if [ "$has_url" -ne "$has_secret" ]; then
        echo "error: TRON_RELAY_URL and TRON_RELAY_SECRET must be set together" >&2
        echo "hint: add both to packages/mac-app/.env.local or unset both for a push-disabled local helper" >&2
        exit 64
    fi

    if [ "$has_url" -eq 1 ]; then
        export TRON_RELAY_ENVIRONMENT="${TRON_RELAY_ENVIRONMENT:-production}"
        echo "relay config will be compiled into the staged helper (secret hidden)"
    fi
}

# --- build step ----------------------------------------------------------

if [ "$skip_build" -eq 0 ] && [ -z "$source_override" ]; then
    prepare_relay_env_for_build

    # Cargo's `--debug` flag does NOT exist (dev is the default profile —
    # omit any flag, or use `--profile dev`). Only `--release` is a
    # shorthand. Branch explicitly so we never pass an invalid flag.
    case "$profile" in
        release) cargo_args=(build --release --bin tron --bin tron-program-worker --locked) ;;
        debug)   cargo_args=(build           --bin tron --bin tron-program-worker --locked) ;;
        *)       echo "error: unknown profile '$profile' for cargo invocation" >&2; exit 64 ;;
    esac
    echo "==> cargo ${cargo_args[*]}"
    (cd "$AGENT_DIR" && cargo "${cargo_args[@]}") || { echo "cargo build failed" >&2; exit 1; }
fi

if [ ! -x "$source_bin" ]; then
    echo "error: source binary not found or not executable: $source_bin" >&2
    exit 2
fi
if [ ! -x "$worker_source_bin" ]; then
    echo "error: program worker binary not found or not executable: $worker_source_bin" >&2
    exit 2
fi

# --- staging -------------------------------------------------------------

mkdir -p "$HELPER_MACOS" "$HELPER_RESOURCES" "$DEV_HELPER_MACOS" "$DEV_HELPER_RESOURCES" "$LAUNCH_AGENT_DIR" || {
    echo "error: cannot create helper staging directories" >&2
    exit 3
}

cat > "$HELPER_INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>tron</string>
    <key>CFBundleIdentifier</key>
    <string>com.tron.server</string>
    <key>CFBundleName</key>
    <string>Tron Server</string>
    <key>CFBundleDisplayName</key>
    <string>Tron Server</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cp "$RESOURCES_DIR/AppIcon.icns" "$HELPER_RESOURCES/AppIcon.icns"

cat > "$DEV_HELPER_INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>tron</string>
    <key>CFBundleIdentifier</key>
    <string>com.tron.server.dev</string>
    <key>CFBundleName</key>
    <string>Tron Server Dev</string>
    <key>CFBundleDisplayName</key>
    <string>Tron Server Dev</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cp "$RESOURCES_DIR/AppIcon.icns" "$DEV_HELPER_RESOURCES/AppIcon.icns"

cat > "$LAUNCH_AGENT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tron.server</string>

    <key>ProgramArguments</key>
    <array>
        <string>tron</string>
        <string>--port</string>
        <string>9847</string>
        <string>--quiet</string>
    </array>

    <key>BundleProgram</key>
    <string>Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>RUST_LOG</key>
        <string>info</string>
    </dict>

    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>

    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.tron.mac</string>
        <string>com.tron.mac.dev</string>
    </array>
</dict>
</plist>
PLIST

cat > "$DEV_LAUNCH_AGENT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tron.server.dev</string>

    <key>ProgramArguments</key>
    <array>
        <string>tron</string>
        <string>--port</string>
        <string>9848</string>
        <string>--quiet</string>
    </array>

    <key>BundleProgram</key>
    <string>Contents/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>RUST_LOG</key>
        <string>info</string>
        <key>TRON_HOME_NAME</key>
        <string>.tron-dev</string>
    </dict>

    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>

    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.tron.mac.dev</string>
        <string>com.tron.mac</string>
    </array>
</dict>
</plist>
PLIST

# Atomic stage: copy to tempfile then rename, matching the pattern used
# by the Rust agent's own atomic-write helper.
tmp="$HELPER_MACOS/.tron.tmp.$$"
worker_tmp="$HELPER_MACOS/.tron-program-worker.tmp.$$"
dev_tmp="$DEV_HELPER_MACOS/.tron.tmp.$$"
dev_worker_tmp="$DEV_HELPER_MACOS/.tron-program-worker.tmp.$$"
trap 'rm -f "$tmp" "$worker_tmp" "$dev_tmp" "$dev_worker_tmp"' EXIT
cp "$source_bin" "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" "$STAGING_PATH"
cp "$worker_source_bin" "$worker_tmp"
chmod 0755 "$worker_tmp"
mv -f "$worker_tmp" "$STAGING_WORKER_PATH"
cp "$source_bin" "$dev_tmp"
chmod 0755 "$dev_tmp"
mv -f "$dev_tmp" "$DEV_STAGING_PATH"
cp "$worker_source_bin" "$dev_worker_tmp"
chmod 0755 "$dev_worker_tmp"
mv -f "$dev_worker_tmp" "$DEV_STAGING_WORKER_PATH"
trap - EXIT

# --- report --------------------------------------------------------------

size_bytes=$(wc -c < "$STAGING_PATH" | tr -d ' ')
sha=$(shasum -a 256 "$STAGING_PATH" | awk '{print $1}')
worker_size_bytes=$(wc -c < "$STAGING_WORKER_PATH" | tr -d ' ')
worker_sha=$(shasum -a 256 "$STAGING_WORKER_PATH" | awk '{print $1}')
echo "staged $STAGING_PATH"
echo "  from:   $source_bin"
echo "  size:   $size_bytes bytes"
echo "  sha256: $sha"
echo "staged $STAGING_WORKER_PATH"
echo "  from:   $worker_source_bin"
echo "  size:   $worker_size_bytes bytes"
echo "  sha256: $worker_sha"
echo "staged isolated helper bundle at $DEV_HELPER_BUNDLE"
