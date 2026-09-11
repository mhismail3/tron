#!/usr/bin/env bash
# Negative staging controls: no network, native execution, signing, or install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/cache" "$TEMP/out" "$TEMP/untrusted"
printf 'prior artifact' > "$TEMP/out/cua-driver"
printf 'untrusted source' > "$TEMP/untrusted/cua-driver"
chmod +x "$TEMP/untrusted/cua-driver"
CACHE="$TEMP/cache/cua-driver-rs-0.28.0-darwin-universal-binary.tar.gz"
printf 'bad archive' > "$CACHE"
if TRON_CUA_CACHE="$TEMP/cache" TRON_CUA_SOURCE_DIR="$TEMP/untrusted" \
  "$ROOT/packages/mac-app/scripts/ensure-cua-driver.sh" "$TEMP/out" > "$TEMP/result" 2>&1; then
  echo 'unverified source/archive was accepted' >&2; exit 1
fi
[[ "$(<"$TEMP/out/cua-driver")" == 'prior artifact' ]]
rm "$CACHE"; ln -s "$TEMP/untrusted/cua-driver" "$CACHE"
if TRON_CUA_CACHE="$TEMP/cache" "$ROOT/packages/mac-app/scripts/ensure-cua-driver.sh" "$TEMP/out" > "$TEMP/result" 2>&1; then
  echo 'symlink cache was accepted' >&2; exit 1
fi
grep -q 'Refusing symlinked' "$TEMP/result"
[[ "$(<"$TEMP/out/cua-driver")" == 'prior artifact' ]]
printf 'Cua asset rejection controls passed\n'
