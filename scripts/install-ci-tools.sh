#!/usr/bin/env bash
# Install checksum-pinned Apple/release helpers into a repository cache.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ci-toolchain.env"
CACHE="${TRON_CI_TOOLS_DIR:-$ROOT/.ci-tools}"
BIN="$CACHE/bin"; DOWNLOADS="$CACHE/downloads"; SHARE="$CACHE/share"
mkdir -p "$BIN" "$DOWNLOADS" "$SHARE"

fetch() {
  local url="$1" sha="$2" out="$3"
  if [[ ! -f "$out" ]] || [[ "$(shasum -a 256 "$out" | awk '{print $1}')" != "$sha" ]]; then
    curl -fsSL --retry 3 "$url" -o "$out"
  fi
  [[ "$(shasum -a 256 "$out" | awk '{print $1}')" == "$sha" ]] || { echo "checksum mismatch: $out" >&2; exit 1; }
}

for tool in "$@"; do
  case "$tool" in
    xcodegen)
      archive="$DOWNLOADS/xcodegen-$TRON_CI_XCODEGEN_VERSION.zip"
      fetch "$TRON_CI_XCODEGEN_URL" "$TRON_CI_XCODEGEN_SHA256" "$archive"
      stage="$CACHE/xcodegen-$TRON_CI_XCODEGEN_VERSION"; rm -rf "$stage"; mkdir -p "$stage"
      ditto -x -k "$archive" "$stage"
      executable="$(find "$stage" -type f -name xcodegen -perm -111 | head -1)"
      presets="$(find "$stage" -type d -path '*/share/xcodegen/SettingPresets' | head -1)"
      [[ -n "$executable" ]] || { echo "xcodegen executable missing" >&2; exit 1; }
      [[ -n "$presets" ]] || { echo "xcodegen setting presets missing" >&2; exit 1; }
      ln -sfn "$executable" "$BIN/xcodegen"
      ln -sfn "$(dirname "$presets")" "$SHARE/xcodegen"
      ;;
    asc)
      case "$(uname -m)" in
        arm64) url="$TRON_CI_ASC_MACOS_ARM64_URL"; sha="$TRON_CI_ASC_MACOS_ARM64_SHA256" ;;
        x86_64) url="$TRON_CI_ASC_MACOS_AMD64_URL"; sha="$TRON_CI_ASC_MACOS_AMD64_SHA256" ;;
        *) echo "unsupported architecture" >&2; exit 1 ;;
      esac
      executable="$CACHE/asc-$TRON_CI_ASC_VERSION-$(uname -m)"
      fetch "$url" "$sha" "$executable"; chmod 0755 "$executable"; ln -sfn "$executable" "$BIN/asc"
      ;;
    *) echo "unsupported CI tool: $tool" >&2; exit 64 ;;
  esac
done
printf '%s\n' "$BIN" >> "${GITHUB_PATH:-/dev/null}"
export PATH="$BIN:$PATH"
