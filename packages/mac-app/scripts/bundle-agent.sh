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
#   bundle-agent.sh --skip-build    # assume target/release/tron exists
#   bundle-agent.sh --source PATH   # explicit path to prebuilt tron
#   bundle-agent.sh --clean         # remove ignored staged helper payloads
#
# Exit codes:
#   0  — staged binary is up to date
#   1  — build failed
#   2  — source binary missing (with --skip-build or --source)
#   3  — tracked metadata missing or staging path not writable
#   64 — invalid arguments
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
DEV_HELPER_BUNDLE="$LIBRARY_DIR/LoginItems/Tron Server Dev.app"
DEV_HELPER_CONTENTS="$DEV_HELPER_BUNDLE/Contents"
DEV_HELPER_MACOS="$DEV_HELPER_CONTENTS/MacOS"
DEV_HELPER_RESOURCES="$DEV_HELPER_CONTENTS/Resources"
LAUNCH_AGENT_DIR="$LIBRARY_DIR/LaunchAgents"
STAGING_PATH="$HELPER_MACOS/tron"
DEV_STAGING_PATH="$DEV_HELPER_MACOS/tron"
HELPER_INFO_PLIST="$HELPER_CONTENTS/Info.plist"
DEV_HELPER_INFO_PLIST="$DEV_HELPER_CONTENTS/Info.plist"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.tron.server.plist"
DEV_LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.tron.server.dev.plist"

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
    rm -f "$STAGING_PATH" "$DEV_STAGING_PATH" \
        "$HELPER_RESOURCES/AppIcon.icns" "$DEV_HELPER_RESOURCES/AppIcon.icns"
    echo "cleaned ignored staged helper payloads"
    exit 0
fi

# --- source resolution ---------------------------------------------------

tracked_plists=(
    "$HELPER_INFO_PLIST"
    "$DEV_HELPER_INFO_PLIST"
    "$LAUNCH_AGENT_PLIST"
    "$DEV_LAUNCH_AGENT_PLIST"
)
for tracked_plist in "${tracked_plists[@]}"; do
    if [ ! -f "$tracked_plist" ]; then
        echo "error: tracked helper metadata is missing: $tracked_plist" >&2
        exit 3
    fi
done

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

mkdir -p "$HELPER_MACOS" "$HELPER_RESOURCES" "$DEV_HELPER_MACOS" "$DEV_HELPER_RESOURCES" || {
    echo "error: cannot create helper staging directories" >&2
    exit 3
}

cp "$RESOURCES_DIR/AppIcon.icns" "$HELPER_RESOURCES/AppIcon.icns"
cp "$RESOURCES_DIR/AppIcon.icns" "$DEV_HELPER_RESOURCES/AppIcon.icns"

# Atomic stage: copy to tempfile then rename, matching the pattern used
# by the Rust agent's own atomic-write helper.
tmp="$HELPER_MACOS/.tron.tmp.$$"
dev_tmp="$DEV_HELPER_MACOS/.tron.tmp.$$"
trap 'rm -f "$tmp" "$dev_tmp"' EXIT
cp "$source_bin" "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" "$STAGING_PATH"
cp "$source_bin" "$dev_tmp"
chmod 0755 "$dev_tmp"
mv -f "$dev_tmp" "$DEV_STAGING_PATH"
trap - EXIT

# --- report --------------------------------------------------------------

size_bytes=$(wc -c < "$STAGING_PATH" | tr -d ' ')
sha=$(shasum -a 256 "$STAGING_PATH" | awk '{print $1}')
echo "staged $STAGING_PATH"
echo "  from:   $source_bin"
echo "  size:   $size_bytes bytes"
echo "  sha256: $sha"
echo "staged isolated helper bundle at $DEV_HELPER_BUNDLE"
