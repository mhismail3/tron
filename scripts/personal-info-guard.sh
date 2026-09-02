#!/usr/bin/env bash
# personal-info-guard.sh — fail when personal-developer identifiers leak into source.
#
# Scans the source tree for high-impact patterns that would break or embarrass
# when shipped to a different user:
#
#   /Users/<developer>     — raw filesystem path that won't exist for other users
#   -Users-<developer>-    — Claude-Code-encoded form of the same path
#   github.com/<developer> — personal GitHub handle
#   mhismail3              — personal GitHub handle, including split-string forms
#   mhismail.com           — personal feedback domain
#   bare developer username in product source, docs, or examples
#
# The guard constructs the developer-username needle from fragments so the guard
# itself does not normalize the source-identity string it bans.
#
# Exit codes: 0 = clean, 1 = offenders found, 2 = setup error.
#
# Usage:
#   scripts/personal-info-guard.sh                # full repo scan
#   scripts/personal-info-guard.sh --staged       # only staged changes (pre-commit)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEV_USER='m''oose'
DEV_USER_ENCODED='-Users-'"$DEV_USER"'-'

# Patterns to ban. Each line: <regex>|<short description>
PATTERNS=(
    "/Users/${DEV_USER}|raw home path; should be /Users/<USER> or use paths.rs helpers"
    "${DEV_USER_ENCODED}|Claude-Code encoded developer path"
    "github\\.com/${DEV_USER}|personal GitHub handle"
    "\\b${DEV_USER}\\b|plain developer username; use generic product/source wording"
    'mhismail3|personal GitHub handle; use a generic placeholder or configured repository URL'
    'mhismail\.com|personal domain; use configured feedback recipient'
    '"mh"[[:space:]]*\+[[:space:]]*"is"[[:space:]]*\+[[:space:]]*"mail"|split personal handle construction'
    '"mh"[[:space:]]*,[[:space:]]*"is"[[:space:]]*,[[:space:]]*"mail"|split personal handle regression needle outside allowlisted tests'
    '"tron@"[[:space:]]*\+[[:space:]]*"mh"|split personal feedback email construction'
)

# Regression-guard files construct personal-info needles from fragments. Each
# entry is matched as a glob against the file path relative to repo root.
ALLOWLIST_PATHS=(
    'scripts/personal-info-guard.sh'
    '.git/*'
    'target/*'
    'node_modules/*'
    'packages/ios-app/.build/*'
    'packages/ios-app/TronMobile.xcodeproj/*'
    '.tron/*'
)

# Full scans intentionally name every tracked source/documentation root so a
# root can be added or removed only with a conscious scan-scope edit.
SCAN_PATHS=(
    '.agents'
    '.codex'
    '.github'
    '.gitignore'
    'AGENTS.md'
    'CONTRIBUTING.md'
    'README.md'
    'VERSION.env'
    'packages/gateway'
    'packages/ios-app'
    'packages/mac-app'
    'scripts'
)

# Build a single grep-include filter that excludes the allowlist.
# `git grep` is fast and respects `.gitignore`.
EXCLUDE_ARGS=()
for p in "${ALLOWLIST_PATHS[@]}"; do
    EXCLUDE_ARGS+=(":(exclude)$p")
done

mode="${1:-full}"
offenders_total=0
STAGED_PATHS=()

if [ "$mode" = "--staged" ]; then
    staged_list=$(mktemp "${TMPDIR:-/tmp}/tron-personal-info-guard.XXXXXX") || {
        echo "personal-info-guard: could not allocate staged-file list" >&2
        exit 2
    }
    trap 'rm -f "$staged_list"' EXIT
    if ! git diff --cached --name-only --diff-filter=ACMR -z > "$staged_list"; then
        echo "personal-info-guard: failed to read the staged index" >&2
        exit 2
    fi
    while IFS= read -r -d '' staged_file; do
        STAGED_PATHS+=(":(literal)$staged_file")
    done < "$staged_list"
    rm -f "$staged_list"
    trap - EXIT
fi

scan_pattern() {
    local entry="$1"
    local pattern="${entry%%|*}"
    local desc="${entry##*|}"
    local hits
    local grep_status

    if [ "$mode" = "--staged" ]; then
        # Pre-commit gate: scan the *staged blobs*, not the working tree.
        # The two can differ when the developer staged file A v1, then kept
        # editing it on disk to v2 — only v1 is about to be committed.
        # `git grep --cached` reads from the index, which is exactly what
        # `git commit` will record.
        #
        # Restrict to files actually staged (added/modified/copied/renamed —
        # `--diff-filter=ACMR`) so we don't re-scan the entire index every
        # commit. The checked loader above retains NUL-delimited names as
        # literal pathspecs and fails closed before any pattern scan.
        if [ "${#STAGED_PATHS[@]}" -eq 0 ]; then
            return
        fi
        if hits=$(git grep --cached -nE -e "$pattern" -- \
            "${STAGED_PATHS[@]}" "${EXCLUDE_ARGS[@]}" 2>&1); then
            grep_status=0
        else
            grep_status=$?
        fi
    else
        # Full repo scan via git grep (respects .gitignore).
        if hits=$(git grep -nE -e "$pattern" -- \
            "${SCAN_PATHS[@]}" "${EXCLUDE_ARGS[@]}" 2>&1); then
            grep_status=0
        else
            grep_status=$?
        fi
    fi

    if [ "$grep_status" -eq 1 ]; then
        hits=""
    elif [ "$grep_status" -ne 0 ]; then
        echo "personal-info-guard: git grep failed while checking $desc" >&2
        echo "$hits" >&2
        exit 2
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
    echo "User-specific values belong in ~/.tron runtime state, not the source tree."
    echo "The repository guard scans every shipped client and gateway source."
    exit 1
fi

echo "✅ OK — no personal-info leaks in source."
exit 0
