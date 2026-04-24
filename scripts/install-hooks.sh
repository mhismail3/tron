#!/usr/bin/env bash
# install-hooks.sh — install repo-managed git hooks into the local .git/hooks/.
#
# Run once per clone: `scripts/install-hooks.sh`. Idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_DIR="$ROOT/.git/hooks"

if [ ! -d "$HOOK_DIR" ]; then
    echo "❌ $HOOK_DIR does not exist — are you in a git repo?"
    exit 1
fi

# Pre-commit hook: runs staged-source guards before each commit.
PRE_COMMIT="$HOOK_DIR/pre-commit"

cat > "$PRE_COMMIT" << 'HOOK'
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh — do not edit by hand.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

if git diff --cached --name-only --diff-filter=ACMR | grep -Eq '^packages/agent/.*\.rs$'; then
    echo "rustfmt-guard: checking packages/agent formatting..."
    (cd "$ROOT/packages/agent" && cargo fmt --all -- --check)
fi

exec "$ROOT/scripts/personal-info-guard.sh" --staged
HOOK

chmod +x "$PRE_COMMIT"

echo "✅ Installed pre-commit hook → $PRE_COMMIT"
echo "   It runs rustfmt for staged Rust changes and scripts/personal-info-guard.sh --staged."
