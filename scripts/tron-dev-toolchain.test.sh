#!/usr/bin/env bash
# Isolated resolver checks for scripts/tron-dev. No real Tron state is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/tron-dev"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-dev-toolchain.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/path" "$TMP/nvm/versions/node/v22.22.0/bin"
make_node() {
  local path="$1" version="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then printf 'v$version\\n'; exit 0; fi
if [[ -n "\${TRON_TOOLCHAIN_LOG:-}" ]]; then printf '%s\\n' "\$*" >> "\$TRON_TOOLCHAIN_LOG"; fi
case "\${3:-}" in
  resolve-command-host) printf '127.0.0.1\\n' ;;
  status) printf '{}\\n' ;;
esac
EOF
  chmod +x "$path"
}
make_node "$TMP/path/node" 21.0.0
make_node "$TMP/nvm/versions/node/v22.22.0/bin/node" 22.22.0
touch "$TMP/nvm/versions/node/v22.22.0/bin/npm"
chmod +x "$TMP/nvm/versions/node/v22.22.0/bin/npm"

# A wrong ambient Node is skipped for the exact nvm candidate. The executable
# preflight proves the resolved Node actually runs both state-helper calls.
HOME="$TMP/home" NVM_DIR="$TMP/nvm" PATH="$TMP/path:/usr/bin:/bin" \
  TRON_TOOLCHAIN_LOG="$TMP/right.log" "$SCRIPT" preflight >/dev/null
[[ -s "$TMP/right.log" ]]
grep -q 'resolve-command-host' "$TMP/right.log"
grep -q 'status' "$TMP/right.log"
[[ ! -e "$TMP/home/.tron-dev" ]]

# Read-only/status and invalid commands never create lifecycle state.
rm -rf "$TMP/home"
HOME="$TMP/home" NVM_DIR="$TMP/nvm" PATH="$TMP/path:/usr/bin:/bin" "$SCRIPT" status >/dev/null
[[ ! -e "$TMP/home/.tron-dev" ]]
if HOME="$TMP/home" NVM_DIR="$TMP/nvm" PATH="$TMP/path:/usr/bin:/bin" "$SCRIPT" invalid >/dev/null 2>&1; then
  echo "invalid command unexpectedly passed" >&2
  exit 1
fi
[[ ! -e "$TMP/home/.tron-dev" ]]

# Relative NVM_DIR is rejected before any state mutation.
if HOME="$TMP/home" NVM_DIR="relative-nvm" PATH="$TMP/path:/usr/bin:/bin" "$SCRIPT" status >/dev/null 2>&1; then
  echo "relative NVM_DIR unexpectedly passed" >&2
  exit 1
fi
[[ ! -e "$TMP/home/.tron-dev" ]]

# A wrong Node with no pinned fallback fails before creating ~/.tron-dev.
rm -rf "$TMP/home"
if HOME="$TMP/home" NVM_DIR="$TMP/missing" PATH="$TMP/path:/usr/bin:/bin" "$SCRIPT" preflight >/dev/null 2>&1; then
  echo "wrong-only Node unexpectedly passed" >&2
  exit 1
fi
[[ ! -e "$TMP/home/.tron-dev" ]]

# The selected Node must have its own npm sibling; ambient npm is irrelevant.
rm -rf "$TMP/home"
rm "$TMP/nvm/versions/node/v22.22.0/bin/npm"
if HOME="$TMP/home" NVM_DIR="$TMP/nvm" PATH="$TMP/path:/usr/bin:/bin" "$SCRIPT" preflight >/dev/null 2>&1; then
  echo "mismatched npm sibling unexpectedly passed" >&2
  exit 1
fi
[[ ! -e "$TMP/home/.tron-dev" ]]

echo "isolated tron-dev toolchain checks passed"
