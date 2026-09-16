#!/usr/bin/env bash
# Verify the exact npm CLI projected beside the bundled Node runtime can perform
# the SDK package-manager removal operation without an ambient PATH.
set -euo pipefail

NODE_ROOT="${TRON_NODE_ROOT:-/tmp/tron-consolidation-toolchain-01a0a43d.4qlkoC/node-v22.22.0-darwin-arm64}"
[[ -x "$NODE_ROOT/bin/node" && -f "$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js" ]] || {
    echo "set TRON_NODE_ROOT to an official Node ${NODE_VERSION:-22.22.0} archive root" >&2
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
