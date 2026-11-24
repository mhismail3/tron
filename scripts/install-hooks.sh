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

PRE_PUSH="$HOOK_DIR/pre-push"

cat > "$PRE_PUSH" << 'HOOK'
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh — do not edit by hand.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX

exec python3 "$ROOT/tools/verify/gate.py" --pre-push "$1"
HOOK

chmod +x "$PRE_PUSH"

echo "✅ Installed pre-commit hook in Git's hooks directory → $PRE_COMMIT"
echo "   It runs only scripts/personal-info-guard.sh --staged."
echo "✅ Installed pre-push hook → $PRE_PUSH"
echo "   A push to main runs the gate unless scripts/tron gate already checked that exact commit."
echo "   Hooks are local convention: git push --no-verify bypasses them; the server does not enforce the gate."
