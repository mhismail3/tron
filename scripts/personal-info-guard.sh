#!/usr/bin/env bash
# personal-info-guard.sh — fail when personal-developer identifiers leak into source.
#
# Scans the source tree for high-impact patterns that would break or embarrass
# when shipped to a different user:
#
#   /Users/moose           — raw filesystem path that won't exist for other users
#   -Users-moose-          — Claude-Code-encoded form of the same path
#   github.com/moose       — URL to a non-existent GitHub repo
#   e.g. moose@            — placeholder / example text leaking the username
#
# These differ from intentional uses of "moose":
#   - paths.rs constructs needles from string parts as part of the regression
#     guard (`format!("/Users/{}", "moose")`) — that's the test, not a leak.
#   - auth_tests.rs uses literals like "moose@macbook" as test fixtures.
#   - ContentView.swift comments mention "Circuit moose logo" (internal name).
#
# Allowlist below covers those intentional cases. Everything else is a fail.
#
# Exit codes: 0 = clean, 1 = offenders found, 2 = setup error.
#
# Usage:
#   scripts/personal-info-guard.sh                # full repo scan
#   scripts/personal-info-guard.sh --staged       # only staged changes (pre-commit)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Patterns to ban. Each line: <regex>|<short description>
PATTERNS=(
    '/Users/moose|raw home path; should be /Users/<USER> or use paths.rs helpers'
    '\-Users\-moose\-|Claude-Code encoded developer path'
    'github\.com/moose|wrong GitHub handle (real repo is mhismail3/tron)'
    'e\.g\. moose@|placeholder text leaking developer username'
    '"moose@iphone"|hardcoded example matching developer device'
)

# Files / directories that may legitimately contain "moose" (test fixtures,
# regression-guard needle construction, internal nicknames). Each entry is
# matched as a glob against the file path relative to repo root.
ALLOWLIST_PATHS=(
    'packages/agent/src/core/foundation/paths.rs'
    'packages/agent/src/server/rpc/handlers/auth_tests.rs'
    'packages/ios-app/Sources/Views/Chat/ContentView.swift'
    'scripts/personal-info-guard.sh'
    '.git/*'
    'target/*'
    'node_modules/*'
    'packages/ios-app/.build/*'
    'packages/ios-app/TronMobile.xcodeproj/*'
    '.tron/*'
)

# Build a single grep-include filter that excludes the allowlist.
# `git grep` is fast and respects `.gitignore`.
EXCLUDE_ARGS=()
for p in "${ALLOWLIST_PATHS[@]}"; do
    EXCLUDE_ARGS+=(":(exclude)$p")
done

mode="${1:-full}"
offenders_total=0

scan_pattern() {
    local entry="$1"
    local pattern="${entry%%|*}"
    local desc="${entry##*|}"
    local hits

    if [ "$mode" = "--staged" ]; then
        # Pre-commit gate: scan the *staged blobs*, not the working tree.
        # The two can differ when the developer staged file A v1, then kept
        # editing it on disk to v2 — only v1 is about to be committed.
        # `git grep --cached` reads from the index, which is exactly what
        # `git commit` will record.
        #
        # Restrict to files actually staged (added/modified/copied/renamed —
        # `--diff-filter=ACMR`) so we don't re-scan the entire index every
        # commit. `xargs -0r` avoids invoking grep with zero args (which
        # would scan everything) when the staged set is empty.
        local staged_files
        staged_files=$(git diff --cached --name-only --diff-filter=ACMR -z)
        if [ -z "$staged_files" ]; then
            return
        fi
        hits=$(printf '%s' "$staged_files" \
            | xargs -0r git grep --cached -nE "$pattern" -- "${EXCLUDE_ARGS[@]}" 2>/dev/null \
            || true)
    else
        # Full repo scan via git grep (respects .gitignore)
        hits=$(git grep -nE "$pattern" -- . "${EXCLUDE_ARGS[@]}" 2>/dev/null || true)
    fi

    if [ -n "$hits" ]; then
        echo ""
        echo "❌ Offenders for pattern: $pattern"
        echo "   Reason: $desc"
        echo ""
        echo "$hits" | sed 's/^/    /'
        local count
        count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
        offenders_total=$((offenders_total + count))
    fi
}

echo "personal-info-guard: scanning ($mode)…"

for entry in "${PATTERNS[@]}"; do
    scan_pattern "$entry"
done

if [ "$offenders_total" -gt 0 ]; then
    echo ""
    echo "❌ FAIL — $offenders_total personal-info offender(s) found."
    echo ""
    echo "User-specific values belong in MEMORY.md or ~/.tron/ runtime files,"
    echo "not the source tree. See packages/agent/src/core/foundation/paths.rs"
    echo "for the regression-guard pattern that catches Rust offenders at test time."
    exit 1
fi

echo "✅ OK — no personal-info leaks in source."
exit 0
