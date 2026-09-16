#!/usr/bin/env bash
# Verify the exact npm CLI projected beside the bundled Node runtime can perform
# the SDK package-manager removal operation without an ambient PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
NODE_ROOT="${TRON_NODE_ROOT:-}"
if [[ -z "$NODE_ROOT" ]]; then
    NODE_EXECUTABLE="$(command -v node 2>/dev/null || true)"
    [[ -n "$NODE_EXECUTABLE" ]] || { echo "pinned Node is unavailable" >&2; exit 2; }
    NODE_EXECUTABLE="$(realpath "$NODE_EXECUTABLE")"
    NODE_ROOT="$(cd "$(dirname "$NODE_EXECUTABLE")/.." && pwd -P)"
fi
EXPECTED_NODE_VERSION="$(<"$REPO_ROOT/.node-version")"
[[ -x "$NODE_ROOT/bin/node" \
    && "$($NODE_ROOT/bin/node --version 2>/dev/null || true)" == "v$EXPECTED_NODE_VERSION" \
    && -f "$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js" ]] || {
    echo "TRON_NODE_ROOT or PATH must select the pinned official Node $EXPECTED_NODE_VERSION toolchain" >&2
    exit 2
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-gateway-npm.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
RUNTIME="$TMP/runtime"
PROJECT="$TMP/project"
mkdir -p "$RUNTIME/bin-arm64" "$RUNTIME/npm-arm64" "$PROJECT/node_modules/synthetic-package" "$TMP/home" "$TMP/cache"
cp "$NODE_ROOT/bin/node" "$RUNTIME/node-arm64"
cp -R "$NODE_ROOT/lib/node_modules/npm/." "$RUNTIME/npm-arm64/"
ln -s ../node-arm64 "$RUNTIME/bin-arm64/node"
ln -s ../npm-arm64/bin/npm-cli.js "$RUNTIME/bin-arm64/npm"
printf '%s\n' '{"name":"synthetic-package","version":"1.0.0"}' > "$PROJECT/node_modules/synthetic-package/package.json"
printf '%s\n' '{"name":"fixture-project","version":"1.0.0","dependencies":{"synthetic-package":"file:node_modules/synthetic-package"}}' > "$PROJECT/package.json"

# Deliberately omit the host PATH. npm itself and node are both resolved only
# through the architecture-specific bundle projection.
PATH="$RUNTIME/bin-arm64:/usr/bin:/bin" \
HOME="$TMP/home" \
npm_config_cache="$TMP/cache" \
npm_config_update_notifier=false \
  "$RUNTIME/bin-arm64/npm" uninstall synthetic-package --prefix "$PROJECT" --offline --ignore-scripts >/dev/null
[[ ! -e "$PROJECT/node_modules/synthetic-package" ]] || {
    echo "bundled npm did not remove the synthetic package" >&2
    exit 1
}
printf 'bundled npm removal passed (sanitized PATH, isolated HOME/cache)\n'
