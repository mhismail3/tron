#!/usr/bin/env bash
# Exercise the checksum-pinned Node cache without touching a developer install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-node-cache.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
CACHE="$TMP/cache"
case "$(uname -m)" in
  arm64|aarch64) NODE_ARCH=arm64 ;;
  x86_64) NODE_ARCH=x64 ;;
  *) echo "unsupported Node archive architecture: $(uname -m)" >&2; exit 2 ;;
esac
REAL_CURL="$(command -v curl)"
mkdir -p "$TMP/mock-bin"
cat > "$TMP/mock-bin/curl" <<'CURL'
#!/usr/bin/env bash
printf 'download\n' >> "$TRON_TEST_CURL_COUNT"
exec "$TRON_TEST_REAL_CURL" "$@"
CURL
chmod +x "$TMP/mock-bin/curl"
export TRON_CI_TOOLS_DIR="$CACHE" TRON_TEST_CURL_COUNT="$TMP/curl-count" TRON_TEST_REAL_CURL="$REAL_CURL"
PATH="$TMP/mock-bin:$PATH"
export PATH
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
