#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-npm-bytecode.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/npm" <<'NPM'
#!/usr/bin/env bash
set -euo pipefail
python3 -c 'import sys; sys.pycache_prefix = None; sys.path.insert(0, sys.argv[1]); import gyp_probe' "$TRON_TEST_NPM_TREE"
NPM
chmod +x "$TMP/fakebin/npm"
printf '#!/bin/sh\necho "v%s"\n' "$(<"$ROOT/.node-version")" > "$TMP/fakebin/node"
chmod +x "$TMP/fakebin/node"

make_tree() {
  local tree="$1"
  rm -rf "$tree"
  mkdir -p "$tree/gyp_probe"
  printf '%s\n' 'VALUE = 1' > "$tree/gyp_probe/__init__.py"
  printf '%s\n' '{"name":"npm-fixture","version":"0.0.0"}' > "$tree/package.json"
}

run_toolchain() {
  local tron="$1" tree="$2"
  env -u PYTHONDONTWRITEBYTECODE PATH="$TMP/fakebin:$PATH" TRON_NODE_BIN="$TMP/fakebin/node" TRON_TEST_NPM_TREE="$tree" "$tron" build gateway >"$TMP/ci.log" 2>&1 \
    || { cat "$TMP/ci.log" >&2; fail "scripts/tron build gateway failed"; }
}

has_pycache() {
  [[ -n "$(find "$1" -name __pycache__ -print -quit)" ]]
}

digest() {
  python3 "$ROOT/scripts/hash-npm-runtime.py" "$1"
}

make_tree "$TMP/clean"
clean_digest="$(digest "$TMP/clean")"
run_toolchain "$ROOT/scripts/tron" "$TMP/clean"
has_pycache "$TMP/clean" && fail "scripts/tron wrote __pycache__ into the npm tree"
[[ "$(digest "$TMP/clean")" == "$clean_digest" ]] || fail "scripts/tron changed the npm tree digest"

mkdir -p "$TMP/mutant/scripts" "$TMP/mutant/packages/gateway"
sed '/^export PYTHONDONTWRITEBYTECODE=1$/d' "$ROOT/scripts/tron" > "$TMP/mutant/scripts/tron"
chmod +x "$TMP/mutant/scripts/tron"
cp "$ROOT/scripts/tron-node" "$TMP/mutant/scripts/"
cp "$ROOT/.node-version" "$TMP/mutant/"
if grep -q '^export PYTHONDONTWRITEBYTECODE=1$' "$TMP/mutant/scripts/tron"; then
  fail "mutant control did not remove the flag"
fi
make_tree "$TMP/control"
control_digest="$(digest "$TMP/control")"
run_toolchain "$TMP/mutant/scripts/tron" "$TMP/control"
has_pycache "$TMP/control" || fail "mutant control did not reproduce __pycache__; the probe cannot detect pollution"
[[ "$(digest "$TMP/control")" != "$control_digest" ]] || fail "mutant control did not change the npm tree digest"

echo "scripts/tron keeps the pinned npm tree free of interpreter caches: passed"
