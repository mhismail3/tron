#!/usr/bin/env bash
# Real-boundary regression for scripts/tron-node, the one repository resolver for
# the pinned development Node (#242). Every case runs the real resolver (and the
# real scripts/tron entry point) in a temporary checkout with stand-in toolchains.
#
# Failure modes:
#   1. A Gateway payload runtime first on PATH (as in every Tron agent shell)
#      answers the pinned version and owns an npm alias, and is chosen over the
#      pinned nvm Node.
#   2. With only that payload runtime available, the resolver picks it or fails
#      without saying why and how to install the pinned Node.
#   3. TRON_NODE_BIN is ignored, or a refused TRON_NODE_BIN silently falls back.
#   4. A Node of the wrong version or without sibling npm is accepted.
#   5. `scripts/tron` Gateway commands run whatever `node` is first on PATH rather
#      than the resolved one (the mutant control reproduces this with the
#      pre-#242 `exec node`).
#   6. `tron-node exec` does not put the resolved Node first or drops
#      PYTHONDONTWRITEBYTECODE (#638).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-node-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
VERSION="$(<"$ROOT/.node-version")"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# The checkout under test: only what the resolver and scripts/tron read.
CHECKOUT="$TMP/checkout"
mkdir -p "$CHECKOUT/scripts" "$CHECKOUT/packages/gateway/dist/admin"
cp "$ROOT/scripts/tron-node" "$ROOT/scripts/tron" "$CHECKOUT/scripts/"
cp "$ROOT/.node-version" "$CHECKOUT/"
echo 'process.stdout.write("diagnose ran\n")' > "$CHECKOUT/packages/gateway/dist/admin/diagnose.js"

# A stand-in Node that answers `--version` with $2, records every other
# invocation under its own name, and refuses to run anything.
toolchain() {
  local dir="$1" version="$2" name="$3"
  mkdir -p "$dir"
  cat > "$dir/node" <<NODE
#!/bin/sh
if [ "\${1:-}" = --version ]; then echo "v$version"; exit 0; fi
echo "$name \$*" >> "$TMP/invocations"
echo "$name" ran
NODE
  printf '#!/bin/sh\nexit 0\n' > "$dir/npm"
  chmod +x "$dir/node" "$dir/npm"
}

NVM="$TMP/nvm"
toolchain "$NVM/versions/node/v$VERSION/bin" "$VERSION" nvm
# A payload in the layout bundle-gateway.sh stages and the Gateway installs:
# <payload>/manifest.json, runtime/node-<arch>, runtime/bin-<arch>/{node,npm}.
PAYLOAD="$TMP/payloads/stable/versions/1/runtime"
toolchain "$PAYLOAD/real" "$VERSION" payload
mv "$PAYLOAD/real/node" "$PAYLOAD/node-arm64"
mkdir -p "$PAYLOAD/bin-arm64"
ln -s ../node-arm64 "$PAYLOAD/bin-arm64/node"
ln -s ../real/npm "$PAYLOAD/bin-arm64/npm"
echo '{}' > "$PAYLOAD/../manifest.json"
GATEWAY_PATH="$PAYLOAD/bin-arm64:/usr/bin:/bin"
EMPTY_HOME="$TMP/home"
mkdir -p "$EMPTY_HOME"

resolve() { env -i HOME="$EMPTY_HOME" "$@" "$CHECKOUT/scripts/tron-node" 2>"$TMP/stderr"; }

# 1. The pinned nvm Node wins over the payload runtime first on PATH.
chosen="$(resolve PATH="$GATEWAY_PATH" NVM_DIR="$NVM")" || fail "resolver failed with nvm present: $(cat "$TMP/stderr")"
[[ "$chosen" == "$NVM/versions/node/v$VERSION/bin/node" ]] || fail "chose $chosen over the pinned nvm Node"
pass "pinned nvm Node is chosen over a Gateway payload runtime first on PATH"

# 2. Payload only: refused, by name, with the reason and the install hint.
if resolve PATH="$GATEWAY_PATH" NVM_DIR="$TMP/no-nvm" >/dev/null; then fail "resolver accepted the payload runtime"; fi
grep -qF "$PAYLOAD/bin-arm64/node: it is a Gateway payload runtime" "$TMP/stderr" || fail "payload refusal is not named: $(cat "$TMP/stderr")"
grep -qF "nvm install $VERSION" "$TMP/stderr" || fail "refusal does not say how to install the pinned Node"
pass "a lone Gateway payload runtime is refused with its reason and the install hint"

# An app-bundle runtime is refused the same way.
APP="$TMP/Tron.app/Contents/Resources/bin"
toolchain "$APP" "$VERSION" app
if resolve PATH="$APP:/usr/bin:/bin" NVM_DIR="$TMP/no-nvm" >/dev/null; then fail "resolver accepted an app-bundle runtime"; fi
grep -qF "it is inside an app bundle" "$TMP/stderr" || fail "app-bundle refusal is not named"
pass "an app-bundle runtime is refused"

# 3. TRON_NODE_BIN is honoured over nvm, and a refused one never falls back.
toolchain "$TMP/explicit" "$VERSION" explicit
chosen="$(resolve PATH="$GATEWAY_PATH" NVM_DIR="$NVM" TRON_NODE_BIN="$TMP/explicit/node")" || fail "TRON_NODE_BIN refused"
[[ "$chosen" == "$TMP/explicit/node" ]] || fail "TRON_NODE_BIN ignored; chose $chosen"
if resolve PATH="$GATEWAY_PATH" NVM_DIR="$NVM" TRON_NODE_BIN="$PAYLOAD/bin-arm64/node" >/dev/null; then
  fail "a payload TRON_NODE_BIN fell back or was accepted"
fi
grep -qF "TRON_NODE_BIN=$PAYLOAD/bin-arm64/node is refused: it is a Gateway payload runtime" "$TMP/stderr" || fail "TRON_NODE_BIN refusal not explained"
if resolve PATH="$GATEWAY_PATH" NVM_DIR="$NVM" TRON_NODE_BIN=explicit/node >/dev/null; then fail "relative TRON_NODE_BIN accepted"; fi
pass "TRON_NODE_BIN is honoured and a refused one fails loudly"

# 4. Wrong version and a missing npm are skipped in favour of a later candidate.
toolchain "$TMP/old" "1.0.0" old
toolchain "$TMP/nonpm" "$VERSION" nonpm
rm "$TMP/nonpm/npm"
toolchain "$TMP/ambient" "$VERSION" ambient
# The proven Node is last on PATH, so it is chosen only if both earlier ones
# are skipped (and before any host Homebrew Node).
chosen="$(resolve PATH="$TMP/old:$TMP/nonpm:$TMP/ambient:/usr/bin:/bin" NVM_DIR="$TMP/no-nvm")" || fail "a proven ambient Node was refused: $(cat "$TMP/stderr")"
[[ "$chosen" == "$TMP/ambient/node" ]] || fail "chose $chosen instead of the proven ambient Node"
if resolve TRON_NODE_BIN="$TMP/old/node" >/dev/null; then fail "wrong-version TRON_NODE_BIN accepted"; fi
grep -qF "reports v1.0.0, not v$VERSION" "$TMP/stderr" || fail "wrong version not reported: $(cat "$TMP/stderr")"
if resolve TRON_NODE_BIN="$TMP/nonpm/node" >/dev/null; then fail "TRON_NODE_BIN without npm accepted"; fi
grep -qF "has no sibling npm" "$TMP/stderr" || fail "missing npm not reported"
pass "version and sibling-npm checks hold; a proven ambient Node is used"

# 5. scripts/tron runs its Node commands under the resolved Node, not PATH's.
: > "$TMP/invocations"
env -i HOME="$EMPTY_HOME" PATH="$GATEWAY_PATH" NVM_DIR="$NVM" "$CHECKOUT/scripts/tron" diagnose >/dev/null || fail "scripts/tron diagnose failed"
grep -q '^nvm .*diagnose.js' "$TMP/invocations" || fail "scripts/tron diagnose did not run the pinned Node: $(cat "$TMP/invocations")"
! grep -q '^payload' "$TMP/invocations" || fail "scripts/tron diagnose ran the payload runtime"
# Mutant control: the pre-#242 entry point (`exec node` from PATH) must be caught.
sed '/^    use_pinned_node$/d' "$CHECKOUT/scripts/tron" > "$TMP/mutant-tron"
cp "$TMP/mutant-tron" "$CHECKOUT/scripts/tron"
: > "$TMP/invocations"
env -i HOME="$EMPTY_HOME" PATH="$GATEWAY_PATH" NVM_DIR="$NVM" "$CHECKOUT/scripts/tron" diagnose >/dev/null || true
grep -q '^payload' "$TMP/invocations" || fail "mutant control did not reach the payload runtime; the probe proves nothing"
cp "$ROOT/scripts/tron" "$CHECKOUT/scripts/tron"
pass "scripts/tron Gateway commands run the resolved Node (mutant control caught)"

# 6. exec puts the resolved Node first and sets PYTHONDONTWRITEBYTECODE.
out="$(env -i HOME="$EMPTY_HOME" PATH="$GATEWAY_PATH" NVM_DIR="$NVM" "$CHECKOUT/scripts/tron-node" exec /bin/sh -c 'command -v node; echo "$PYTHONDONTWRITEBYTECODE"')"
[[ "$out" == "$NVM/versions/node/v$VERSION/bin/node"$'\n'1 ]] || fail "exec environment wrong: $out"
pass "tron-node exec runs under the resolved Node with PYTHONDONTWRITEBYTECODE=1"

echo "scripts/tron-node: all cases passed"
