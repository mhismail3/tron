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
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/packages/mac-app/cua-driver-release.json")"
CACHE="$TEMP/cache/cua-driver-rs-${VERSION}-darwin-universal-binary.tar.gz"
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

# Xcode releases disagree about whether one -verify_arch operation accepts
# multiple architectures. The production verifier uses the stable -archs
# projection and compares an exact, order-independent set instead.
VERIFY_ARCHITECTURES="$ROOT/packages/mac-app/scripts/verify-macho-architectures.sh"
mkdir -p "$TEMP/bin"
printf '%s\n' \
  '#!/bin/sh' \
  'test "$1" = -archs && test "$#" = 2 || exit 64' \
  'test "${TRON_TEST_LIPO_FAIL:-0}" = 0 || exit 1' \
  'printf "%s\n" "${TRON_TEST_LIPO_ARCHS:-}"' > "$TEMP/bin/lipo"
chmod +x "$TEMP/bin/lipo"
TRON_TEST_LIPO_ARCHS='arm64 x86_64' PATH="$TEMP/bin:/usr/bin:/bin" \
  "$VERIFY_ARCHITECTURES" "$TEMP/untrusted/cua-driver" arm64 x86_64
TRON_TEST_LIPO_ARCHS='x86_64 arm64' PATH="$TEMP/bin:/usr/bin:/bin" \
  "$VERIFY_ARCHITECTURES" "$TEMP/untrusted/cua-driver" arm64 x86_64
for rejected in missing extra duplicate empty failure; do
  case "$rejected" in
    missing) command=("$VERIFY_ARCHITECTURES" "$TEMP/untrusted/cua-driver" arm64 x86_64); arches=arm64; fail=0 ;;
    extra) command=("$VERIFY_ARCHITECTURES" "$TEMP/untrusted/cua-driver" arm64 x86_64); arches='arm64 x86_64 i386'; fail=0 ;;
    duplicate) command=("$VERIFY_ARCHITECTURES" "$TEMP/untrusted/cua-driver" arm64 arm64); arches='arm64 x86_64'; fail=0 ;;
    empty) command=("$VERIFY_ARCHITECTURES" "$TEMP/untrusted/cua-driver" arm64 x86_64); arches=''; fail=0 ;;
    failure) command=("$VERIFY_ARCHITECTURES" "$TEMP/untrusted/cua-driver" arm64 x86_64); arches='arm64 x86_64'; fail=1 ;;
  esac
  if TRON_TEST_LIPO_ARCHS="$arches" TRON_TEST_LIPO_FAIL="$fail" PATH="$TEMP/bin:/usr/bin:/bin" \
    "${command[@]}" >"$TEMP/result" 2>&1; then
    echo "invalid architecture result was accepted: $rejected" >&2; exit 1
  fi
done
printf 'Cua architecture controls passed\n'
