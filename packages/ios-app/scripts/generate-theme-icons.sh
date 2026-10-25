#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tron-theme-icons.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc "$root/Sources/UI/Theme/ThemeColor.swift" "$root/scripts/generate-theme-icons.swift" -o "$tmp/generate"
"$tmp/generate" "$root"
