#!/usr/bin/env bash
# Exercise the checksum-pinned Node cache without touching a developer install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-node-cache.XXXXXX")"
CHILD_PIDS=()
cleanup() {
  local pid
  if ((${#CHILD_PIDS[@]})); then
    for pid in "${CHILD_PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
  CHILD_PIDS=()
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CACHE="$TMP/cache"
case "$(uname -m)" in
  arm64|aarch64) NODE_ARCH=arm64 ;;
  x86_64) NODE_ARCH=x64 ;;
  *) echo "unsupported Node archive architecture: $(uname -m)" >&2; exit 2 ;;
esac
REAL_CURL="$(command -v curl)"
REAL_TAR="$(command -v tar)"
mkdir -p "$TMP/mock-bin"
cat > "$TMP/mock-bin/curl" <<'CURL'
#!/usr/bin/env bash
printf 'download\n' >> "$TRON_TEST_CURL_COUNT"
if [[ "${TRON_TEST_FAIL_ARCHIVE:-0}" == 1 && "$*" == *.tar.gz* ]]; then
  output=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == -o ]]; then output="$argument"; break; fi
    previous="$argument"
  done
  printf 'partial archive' > "$output"
  exit 22
fi
exec "$TRON_TEST_REAL_CURL" "$@"
CURL
cat > "$TMP/mock-bin/tar" <<'TAR'
#!/usr/bin/env bash
if [[ "${TRON_TEST_DELAY_TAR:-0}" == 1 ]]; then sleep 1; fi
exec "$TRON_TEST_REAL_TAR" "$@"
TAR
chmod +x "$TMP/mock-bin/curl" "$TMP/mock-bin/tar"
export TRON_CI_TOOLS_DIR="$CACHE" TRON_TEST_CURL_COUNT="$TMP/curl-count" TRON_TEST_REAL_CURL="$REAL_CURL" TRON_TEST_REAL_TAR="$REAL_TAR"
PATH="$TMP/mock-bin:$PATH"
export PATH
if TRON_TEST_FAIL_ARCHIVE=1 "$ROOT/scripts/install-ci-tools.sh" node >/dev/null 2>&1; then
  echo "interrupted Node archive download unexpectedly succeeded" >&2; exit 1
fi
archive="$CACHE/downloads/node-v$(<"$ROOT/.node-version")-darwin-$NODE_ARCH.tar.gz"
[[ ! -e "$archive" ]] || { echo "interrupted download left a published partial archive" >&2; exit 1; }
: > "$TRON_TEST_CURL_COUNT"
"$ROOT/scripts/install-ci-tools.sh" node
first_downloads="$(wc -l < "$TRON_TEST_CURL_COUNT" | tr -d ' ')"
[[ "$first_downloads" -eq 2 ]] || { echo "expected SHASUMS and archive downloads, got $first_downloads" >&2; exit 1; }
NODE_ROOT="$CACHE/node-v$(<"$ROOT/.node-version")-$NODE_ARCH"
[[ -x "$NODE_ROOT/bin/node" && -f "$NODE_ROOT/lib/node_modules/npm/package.json" ]] || {
  echo "pinned Node cache was not installed" >&2; exit 1;
}
"$ROOT/scripts/install-ci-tools.sh" node
[[ "$(wc -l < "$TRON_TEST_CURL_COUNT" | tr -d ' ')" -eq "$first_downloads" ]] || {
  echo "second Node install downloaded cached inputs again" >&2; exit 1;
}
CONCURRENT_CACHE="$TMP/concurrent-cache"
mkdir -p "$CONCURRENT_CACHE/downloads"
cp "$CACHE/downloads/node-v$(<"$ROOT/.node-version")-darwin-$NODE_ARCH.tar.gz" "$CONCURRENT_CACHE/downloads/"
cp "$CACHE/downloads/node-v$(<"$ROOT/.node-version")-SHASUMS256.txt" "$CONCURRENT_CACHE/downloads/"
TRON_CI_TOOLS_DIR="$CONCURRENT_CACHE" TRON_TEST_DELAY_TAR=1 "$ROOT/scripts/install-ci-tools.sh" node > "$TMP/concurrent-1.log" 2>&1 & first_pid=$!
CHILD_PIDS+=("$first_pid")
TRON_CI_TOOLS_DIR="$CONCURRENT_CACHE" TRON_TEST_DELAY_TAR=1 "$ROOT/scripts/install-ci-tools.sh" node > "$TMP/concurrent-2.log" 2>&1 & second_pid=$!
CHILD_PIDS+=("$second_pid")
first_status=0
second_status=0
wait "$first_pid" || first_status=$?
wait "$second_pid" || second_status=$?
CHILD_PIDS=()
if [[ "$first_status" -ne 0 || "$second_status" -ne 0 ]]; then
  cat "$TMP/concurrent-1.log" "$TMP/concurrent-2.log" >&2
  echo "concurrent Node cache installers failed (statuses $first_status, $second_status)" >&2
  exit 1
fi
CONCURRENT_ROOT="$CONCURRENT_CACHE/node-v$(<"$ROOT/.node-version")-$NODE_ARCH"
[[ -x "$CONCURRENT_ROOT/bin/node" ]] || { echo "concurrent Node cache did not publish" >&2; exit 1; }
[[ -z "$(find "$CONCURRENT_ROOT" -mindepth 1 -maxdepth 1 -name 'extract.*' -print -quit)" ]] || {
  echo "concurrent extraction published a nested duplicate" >&2; exit 1;
}
# A custom cache must remain the selected cache even when PATH leads with a
# developer-like Node whose npm tree is polluted.
DEVELOPER="$TMP/developer"
mkdir -p "$DEVELOPER/bin" "$DEVELOPER/lib/node_modules/npm/node_modules/node-gyp/gyp/pylib/gyp/__pycache__"
cp "$NODE_ROOT/bin/node" "$DEVELOPER/bin/node"
cp -R "$NODE_ROOT/lib/node_modules/npm/." "$DEVELOPER/lib/node_modules/npm/"
printf polluted > "$DEVELOPER/lib/node_modules/npm/node_modules/node-gyp/gyp/pylib/gyp/__pycache__/bad.pyc"
FIXTURE_ROOT="$TMP/repository"
mkdir -p "$FIXTURE_ROOT/config" "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/packages/mac-app/scripts"
cp "$ROOT/.node-version" "$FIXTURE_ROOT/"
cp "$ROOT/config/ci-toolchain.env" "$FIXTURE_ROOT/config/"
cp "$ROOT/scripts/install-ci-tools.sh" "$ROOT/scripts/hash-npm-runtime.py" "$FIXTURE_ROOT/scripts/"
cp "$ROOT/packages/mac-app/scripts/test-tron-gateway-npm.sh" "$FIXTURE_ROOT/packages/mac-app/scripts/"
[[ ! -e "$FIXTURE_ROOT/.ci-tools" ]] || { echo "fixture default cache unexpectedly exists" >&2; exit 1; }
env -u TRON_NODE_ROOT TRON_CI_TOOLS_DIR="$CACHE" PATH="$DEVELOPER/bin:/usr/bin:/bin" \
  "$FIXTURE_ROOT/packages/mac-app/scripts/test-tron-gateway-npm.sh"
# Both cached inputs are immutable trust boundaries, not merely download hints.
chmod -R u+w "$NODE_ROOT"
printf 'tampered\n' >> "$NODE_ROOT/lib/node_modules/npm/package.json"
if "$ROOT/scripts/install-ci-tools.sh" node >/dev/null 2>&1; then
  echo "tampered extracted npm tree was accepted" >&2; exit 1
fi
rm -rf "$NODE_ROOT"
archive="$CACHE/downloads/node-v$(<"$ROOT/.node-version")-darwin-$NODE_ARCH.tar.gz"
printf 'tampered\n' >> "$archive"
if "$ROOT/scripts/install-ci-tools.sh" node >/dev/null 2>&1; then
  echo "tampered Node archive was accepted" >&2; exit 1
fi
printf 'checksum-pinned Node cache tamper checks passed\n'
