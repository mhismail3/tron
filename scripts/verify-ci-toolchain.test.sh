#!/usr/bin/env bash
# Isolated structural test for the canonical Node pin verifier.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-toolchain-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/config" "$TMP/.github/workflows" "$TMP/packages/mac-app/scripts"
cp "$ROOT/scripts/verify-ci-toolchain.sh" "$TMP/scripts/verify-ci-toolchain.sh"
cp "$ROOT/config/ci-toolchain.env" "$TMP/config/ci-toolchain.env"
cp "$ROOT/packages/mac-app/scripts/bundle-gateway.sh" "$TMP/packages/mac-app/scripts/bundle-gateway.sh"
cp "$ROOT/.github/workflows/ci.yml" "$TMP/.github/workflows/ci.yml"
cat > "$TMP/node" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'v%s\n' "${FAKE_NODE_VERSION:?}"
else
  exit 64
fi
EOF
chmod +x "$TMP/node"

printf '23.1.4\n' > "$TMP/.node-version"
(
  cd "$TMP"
  FAKE_NODE_VERSION=23.1.4 PATH="$TMP:$PATH" scripts/verify-ci-toolchain.sh node
)

for malformed in $'23.1\n' $'23.1.4\n\n'; do
  printf '%s' "$malformed" > "$TMP/.node-version"
  if (
    cd "$TMP"
    FAKE_NODE_VERSION=23.1.4 PATH="$TMP:$PATH" scripts/verify-ci-toolchain.sh node
  ); then
    echo "malformed Node pin was accepted" >&2
    exit 1
  fi
done

echo "isolated Node pin structure checks passed"
