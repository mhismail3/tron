#!/usr/bin/env bash
set -euo pipefail
# Build staging only: never install, launch, or re-sign the upstream executor.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/cua-driver-release.json"
read -r VERSION REVISION SHA256 BINARY_SHA256 SIGNER < <(python3 - "$PIN" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1]))
for key, pattern in [('version', r'\d+\.\d+\.\d+'), ('revision', r'[a-f0-9]{40}'), ('archiveSHA256', r'[a-f0-9]{64}'), ('binarySHA256', r'[a-f0-9]{64}'), ('upstreamSigner', r'[A-Z0-9]{10}')]:
    assert re.fullmatch(pattern, p[key])
print(p['version'], p['revision'], p['archiveSHA256'], p['binarySHA256'], p['upstreamSigner'])
PY
)
URL="https://github.com/trycua/cua/releases/download/cua-driver-rs-v${VERSION}/cua-driver-rs-${VERSION}-darwin-universal-binary.tar.gz"
OUT="${1:?Pass a generated staging directory}"
CACHE="${TRON_CUA_CACHE:-$ROOT/.build/cua}/cua-driver-rs-${VERSION}-darwin-universal-binary.tar.gz"
[[ ! -L "$OUT" && ! -L "$CACHE" ]] || { echo 'Refusing symlinked Cua build output/cache' >&2; exit 1; }
mkdir -p "$(dirname "$CACHE")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tron-cua.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
if [[ ! -f "$CACHE" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 --max-time 120 "$URL" -o "$STAGE/release.tar.gz"
  printf '%s  %s\n' "$SHA256" "$STAGE/release.tar.gz" | shasum -a 256 -c -
  mv "$STAGE/release.tar.gz" "$CACHE"
fi
printf '%s  %s\n' "$SHA256" "$CACHE" | shasum -a 256 -c -
tar -xzf "$CACHE" -C "$STAGE" cua-driver
[[ -f "$STAGE/cua-driver" && ! -L "$STAGE/cua-driver" ]] || exit 1
printf '%s  %s\n' "$BINARY_SHA256" "$STAGE/cua-driver" | shasum -a 256 -c -
codesign --verify --strict -R "=anchor apple generic and certificate leaf[subject.OU] = \"$SIGNER\" and identifier \"cua-driver\"" "$STAGE/cua-driver"
lipo "$STAGE/cua-driver" -verify_arch arm64 x86_64
mkdir -p "$OUT"
install -m 0755 "$STAGE/cua-driver" "$OUT/cua-driver"
install -m 0644 "$ROOT/scripts/cua-driver-LICENSE.txt" "$OUT/LICENSE.txt"
install -m 0644 "$PIN" "$OUT/manifest.json"
