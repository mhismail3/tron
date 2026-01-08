#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.tron/transcribe"
TARGET_FILE="$TARGET_DIR/config.json"

mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/config.sample.json" "$TARGET_FILE"

printf "Wrote %s\n" "$TARGET_FILE"
