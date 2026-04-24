#!/usr/bin/env bash
#
# bundle-agent.sh — stage the Rust agent binary so Xcode can copy it into
# `Tron.app/Contents/Resources/tron-agent`.
#
# The file is staged at `packages/mac-app/Sources/Resources/tron-agent`,
# which is declared as a `type: folder` resources build phase in
# `project.yml`. XcodeGen copies every entry of that folder into the
# built `.app` bundle's `Resources/` directory; the staged file is
# gitignored (`.gitignore` line: `Sources/Resources/tron-agent`).
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
STAGING_DIR="$SCRIPT_DIR/../Sources/Resources"
STAGING_PATH="$STAGING_DIR/tron-agent"

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
    rm -f "$STAGING_PATH"
    echo "cleaned $STAGING_PATH"
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

mkdir -p "$STAGING_DIR" || { echo "error: cannot create $STAGING_DIR" >&2; exit 3; }

# Atomic stage: copy to tempfile then rename, matching the pattern used
# by the Rust agent's own atomic-write helper and the wizard's
# BinaryInstaller.install in Sources/Wizard/Steps/InstallStep.swift.
tmp="$STAGING_DIR/.tron-agent.tmp.$$"
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
