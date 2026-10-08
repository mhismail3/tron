#!/usr/bin/env bash
# Install checksum-pinned CI and release tools into a repository cache.
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

node_architecture() {
  case "$(uname -m)" in
    arm64|aarch64) printf arm64 ;;
    x86_64) printf x64 ;;
    *) echo "unsupported Node archive architecture: $(uname -m)" >&2; return 2 ;;
  esac
}

install_node_locked() {
  local version="$1" architecture="$2" work="$3" archive_sha archive_name node_root archive sums entry actual_sha
  local archive_tmp="" sums_tmp="" stage="" runtime_digest npm_digest expected_runtime_sha
  version="$(<"$ROOT/.node-version")"
  if [[ "$architecture" == arm64 ]]; then archive_sha="$TRON_NODE_ARM64_ARCHIVE_SHA256"; else archive_sha="$TRON_NODE_X64_ARCHIVE_SHA256"; fi
  archive_name="node-v$version-darwin-$architecture.tar.gz"
  archive="$DOWNLOADS/$archive_name"
  sums="$DOWNLOADS/node-v$version-SHASUMS256.txt"
  node_root="$CACHE/node-v$version-$architecture"
  if [[ -e "$archive" ]]; then
    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual_sha" == "$archive_sha" ]] || { echo "cached Node archive checksum mismatch: $archive" >&2; return 1; }
  else
    archive_tmp="$(mktemp "$work/archive.XXXXXX")"
    curl -fsSL --retry 3 "$TRON_NODE_ARCHIVE_BASE_URL/v$version/$archive_name" -o "$archive_tmp"
    actual_sha="$(shasum -a 256 "$archive_tmp" | awk '{print $1}')"
    [[ "$actual_sha" == "$archive_sha" ]] || { echo "Node archive checksum mismatch: $archive_tmp" >&2; return 1; }
  fi
  if [[ -e "$sums" ]]; then
    entry="$(awk -v name="$archive_name" '$2 == name || $2 == "*" name {print $1}' "$sums" 2>/dev/null || true)"
  else
    sums_tmp="$(mktemp "$work/sums.XXXXXX")"
    curl -fsSL --retry 3 "$TRON_NODE_ARCHIVE_BASE_URL/v$version/SHASUMS256.txt" -o "$sums_tmp"
    entry="$(awk -v name="$archive_name" '$2 == name || $2 == "*" name {print $1}' "$sums_tmp")"
  fi
  [[ "$entry" == "$archive_sha" ]] || { echo "Node SHASUMS256 entry disagrees with pinned checksum: $archive_name" >&2; return 1; }

  # Publish only fully downloaded inputs; interrupted curl runs leave no cache
  # entry that could be mistaken for a completed archive on the next attempt.
  if [[ -n "$sums_tmp" ]]; then mv "$sums_tmp" "$sums"; sums_tmp=""; fi
  if [[ -n "$archive_tmp" ]]; then mv "$archive_tmp" "$archive"; archive_tmp=""; fi
  if [[ ! -e "$node_root" ]]; then
    stage="$(mktemp -d "$work/extract.XXXXXX")"
    tar -xzf "$archive" -C "$stage" --strip-components=1
    mv "$stage" "$node_root"
    stage=""
  fi
  [[ -x "$node_root/bin/node" && -f "$node_root/lib/node_modules/npm/package.json" ]] || {
    echo "cached Node installation is incomplete: $node_root" >&2; return 1;
  }
  if [[ "$architecture" == arm64 ]]; then expected_runtime_sha="$TRON_NODE_ARM64_RUNTIME_SHA256"; else expected_runtime_sha="$TRON_NODE_X64_RUNTIME_SHA256"; fi
  runtime_digest="$(shasum -a 256 "$node_root/bin/node" | awk '{print $1}')"
  [[ "$runtime_digest" == "$expected_runtime_sha" ]] || {
    echo "cached Node runtime checksum mismatch: $node_root/bin/node" >&2; return 1;
  }
  npm_digest="$(python3 "$ROOT/scripts/hash-npm-runtime.py" "$node_root/lib/node_modules/npm")"
  [[ "$npm_digest" == "$TRON_NODE_NPM_TREE_SHA256" ]] || {
    echo "cached Node npm tree checksum mismatch: $node_root" >&2; return 1;
  }
}

install_node() {
  local version architecture lock
  version="$(<"$ROOT/.node-version")"
  architecture="$(node_architecture)"
  lock="$CACHE/.node-v$version-$architecture.lock"
  lockf -k "$lock" "$BASH" "$ROOT/scripts/install-ci-tools.sh" --install-node-locked "$version" "$architecture"
}

if [[ "${1:-}" == --install-node-locked ]]; then
  shift
  (
    work="$(mktemp -d "$CACHE/.node-install.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    install_node_locked "$1" "$2" "$work"
  )
  exit $?
fi

for tool in "$@"; do
  case "$tool" in
    node) install_node ;;
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
    *) echo "unsupported CI tool: $tool" >&2; exit 64 ;;
  esac
done
printf '%s\n' "$BIN" >> "${GITHUB_PATH:-/dev/null}"
export PATH="$BIN:$PATH"
