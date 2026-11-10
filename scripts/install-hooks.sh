#!/usr/bin/env bash
# install-hooks.sh — install repo-managed git hooks into Git's hooks directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_DIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path hooks)"
mkdir -p "$HOOK_DIR"

PRE_COMMIT="$HOOK_DIR/pre-commit"

cat > "$PRE_COMMIT" << 'HOOK'
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh — do not edit by hand.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

exec "$ROOT/scripts/personal-info-guard.sh" --staged
HOOK

chmod +x "$PRE_COMMIT"

echo "✅ Installed pre-commit hook in Git's hooks directory → $PRE_COMMIT"
echo "   It runs only scripts/personal-info-guard.sh --staged; no build or test admission."
