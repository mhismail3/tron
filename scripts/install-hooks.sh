#!/usr/bin/env bash
# install-hooks.sh — install repo-managed git hooks into Git's hooks directory.
#
# Run once per clone, from the main checkout or any linked worktree:
# `scripts/install-hooks.sh`. Idempotent. Git resolves the hooks directory
# (common directory or core.hooksPath), so every worktree shares one hook.
# Regression: scripts/test-personal-info-guard.py PreCommitHookInstallTests.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A linked worktree's .git is a file; ask Git instead of assuming $ROOT/.git/hooks.
HOOK_DIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path hooks)"
mkdir -p "$HOOK_DIR"

# Pre-commit hook: runs staged-source guards before each commit.
PRE_COMMIT="$HOOK_DIR/pre-commit"

cat > "$PRE_COMMIT" << 'HOOK'
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh — do not edit by hand.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

if git diff --cached --name-only --diff-filter=ACMR | grep -Eq '^packages/gateway/.*\.(ts|json)$'; then
    echo "gateway-guard: checking TypeScript..."
    (cd "$ROOT/packages/gateway" && npm run build)
fi

exec "$ROOT/scripts/personal-info-guard.sh" --staged
HOOK

chmod +x "$PRE_COMMIT"

echo "✅ Installed pre-commit hook → $PRE_COMMIT (shared by every worktree of this clone)"
echo "   It checks staged gateway TypeScript and runs scripts/personal-info-guard.sh --staged."
