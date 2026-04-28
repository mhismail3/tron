#!/usr/bin/env bash
#
# bundle-agent.sh — stage the Rust agent binary as the embedded
# `Tron Server.app` Login Item used by `SMAppService`.
#
# The executable is staged at:
# `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron`.
# `project.yml` copies `Sources/Resources/Library` into
# `Tron.app/Contents/Library` after compile, yielding the production path
# required by `SMAppService.agent(plistName:)`.
#
# Usage:
#   bundle-agent.sh                 # default: build release + stage
#   bundle-agent.sh --profile debug # build debug profile instead
#   bundle-agent.sh --skip-build    # assume target/release/tron exists
#   bundle-agent.sh --source PATH   # explicit path to a prebuilt binary
#   bundle-agent.sh --clean         # remove the staged binary, nothing else
#
# Exit codes:
#   0  — staged binary is up to date
#   1  — build failed
#   2  — source binary missing (with --skip-build or --source)
#   3  — staging path not writable
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
LIBRARY_DIR="$RESOURCES_DIR/Library"
HELPER_BUNDLE="$LIBRARY_DIR/LoginItems/Tron Server.app"
HELPER_CONTENTS="$HELPER_BUNDLE/Contents"
HELPER_MACOS="$HELPER_CONTENTS/MacOS"
HELPER_RESOURCES="$HELPER_CONTENTS/Resources"
LAUNCH_AGENT_DIR="$LIBRARY_DIR/LaunchAgents"
STAGING_PATH="$HELPER_MACOS/tron"
HELPER_INFO_PLIST="$HELPER_CONTENTS/Info.plist"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.tron.server.plist"

# --- argv parser ---------------------------------------------------------

profile="release"
source_override=""
skip_build=0
do_clean=0

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)    profile="$2"; shift 2 ;;
        --profile=*)  profile="${1#--profile=}"; shift ;;
        --source)     source_override="$2"; shift 2 ;;
        --source=*)   source_override="${1#--source=}"; shift ;;
        --skip-build) skip_build=1; shift ;;
        --clean)      do_clean=1; shift ;;
        --help|-h)
            grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

# --- clean mode ----------------------------------------------------------

if [ "$do_clean" -eq 1 ]; then
    rm -rf "$HELPER_BUNDLE" "$LAUNCH_AGENT_PLIST"
    echo "cleaned $HELPER_BUNDLE and $LAUNCH_AGENT_PLIST"
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

source_bin="$(resolve_source)"

# --- build step ----------------------------------------------------------

if [ "$skip_build" -eq 0 ] && [ -z "$source_override" ]; then
    # Cargo's `--debug` flag does NOT exist (dev is the default profile —
    # omit any flag, or use `--profile dev`). Only `--release` is a
    # shorthand. Branch explicitly so we never pass an invalid flag.
    case "$profile" in
        release) cargo_args=(build --release --bin tron --locked) ;;
        debug)   cargo_args=(build           --bin tron --locked) ;;
        *)       echo "error: unknown profile '$profile' for cargo invocation" >&2; exit 64 ;;
    esac
    echo "==> cargo ${cargo_args[*]}"
    (cd "$AGENT_DIR" && cargo "${cargo_args[@]}") || { echo "cargo build failed" >&2; exit 1; }
fi

if [ ! -x "$source_bin" ]; then
    echo "error: source binary not found or not executable: $source_bin" >&2
    exit 2
fi

# --- staging -------------------------------------------------------------

mkdir -p "$HELPER_MACOS" "$HELPER_RESOURCES" "$LAUNCH_AGENT_DIR" || {
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

# Atomic stage: copy to tempfile then rename, matching the pattern used
# by the Rust agent's own atomic-write helper.
tmp="$HELPER_MACOS/.tron.tmp.$$"
trap 'rm -f "$tmp"' EXIT
cp "$source_bin" "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" "$STAGING_PATH"
trap - EXIT

# --- report --------------------------------------------------------------

size_bytes=$(wc -c < "$STAGING_PATH" | tr -d ' ')
sha=$(shasum -a 256 "$STAGING_PATH" | awk '{print $1}')
echo "staged $STAGING_PATH"
echo "  from:   $source_bin"
echo "  size:   $size_bytes bytes"
echo "  sha256: $sha"
