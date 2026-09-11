#!/usr/bin/env bash
set -euo pipefail
# Build staging only: never install, launch, or re-sign the upstream executor.
VERSION=0.28.0
REVISION=1b50c02e2d34734f64d2d22f54eb76cc97b4a663
SHA256=aaaa29538fe7b1f103afb4eddeefe2dc137690f91f8074e333cfe0e76b49918d
BINARY_SHA256=e0d802a126a8fc90af74ef9cccd7dde5ba82feea26c3a2ad8c492ad1f444bb1e
URL="https://github.com/trycua/cua/releases/download/cua-driver-rs-v${VERSION}/cua-driver-rs-${VERSION}-darwin-universal-binary.tar.gz"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
codesign --verify --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "YCK386LBJ7" and identifier "cua-driver"' "$STAGE/cua-driver"
lipo "$STAGE/cua-driver" -verify_arch arm64 x86_64
mkdir -p "$OUT"
install -m 0755 "$STAGE/cua-driver" "$OUT/cua-driver"
install -m 0644 "$ROOT/scripts/cua-driver-LICENSE.txt" "$OUT/LICENSE.txt"
printf '{"version":"%s","revision":"%s","githubPrerelease":true,"upstreamSigner":"YCK386LBJ7","archiveSHA256":"%s","binarySHA256":"%s"}\n' "$VERSION" "$REVISION" "$SHA256" "$BINARY_SHA256" > "$OUT/manifest.json"
