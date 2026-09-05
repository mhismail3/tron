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

# Patterns to ban. Split at the final | so regex alternations remain intact.
PATTERNS=(
    "/Users/${DEV_USER}|raw home path; use /Users/<USER> or runtime-resolved home paths"
    "${DEV_USER_ENCODED}|Claude-Code encoded developer path"
    "github\\.com/${DEV_USER}|personal GitHub handle"
    "(^|[^[:alnum:]_])${DEV_USER}([^[:alnum:]_]|$)|plain developer username; use generic product/source wording"
    'mhismail3|personal GitHub handle; use a generic placeholder or configured repository URL'
    'mhismail\.com|personal domain; use configured feedback recipient'
    '"mh"[[:space:]]*\+[[:space:]]*"is"[[:space:]]*\+[[:space:]]*"mail"|split personal handle construction'
    '"mh"[[:space:]]*,[[:space:]]*"is"[[:space:]]*,[[:space:]]*"mail"|split personal handle regression needle outside allowlisted tests'
    '"tron@"[[:space:]]*\+[[:space:]]*"mh"|split personal feedback email construction'
)

# Only this needle-definition file is exempt. Git owns source membership and
# ignored generated output; tracked files must not disappear behind an allowlist.
EXCLUDE_SELF=':(top,exclude,literal)scripts/personal-info-guard.sh'

mode="${1:-full}"
offenders_total=0
SCAN_PATHS=()

path_list=$(mktemp "${TMPDIR:-/tmp}/tron-personal-info-guard.XXXXXX") || {
    echo "personal-info-guard: could not allocate source-file list" >&2
    exit 2
}
trap 'rm -f "$path_list"' EXIT
if [ "$mode" = "--staged" ]; then
    # The index, not later working-tree edits, owns what will be committed.
    inventory=(git diff --cached --name-only --diff-filter=ACMR -z)
    grep_mode=(--cached)
else
    inventory=(git ls-files --cached --others --exclude-standard -z)
    # Inventory already excluded ignored untracked files. Reapplying ignore
    # rules in grep also hides force-tracked files, violating the full scan.
    grep_mode=(--untracked --no-exclude-standard)
fi
if ! "${inventory[@]}" > "$path_list"; then
    echo "personal-info-guard: failed to read the source inventory" >&2
    exit 2
fi
while IFS= read -r -d '' source_file; do
    SCAN_PATHS+=(":(literal)$source_file")
done < "$path_list"
rm -f "$path_list"
trap - EXIT

scan_pattern() {
    local entry="$1"
    local pattern="${entry%|*}"
    local desc="${entry##*|}"
    local hits
    local grep_status

    if [ "${#SCAN_PATHS[@]}" -eq 0 ]; then
        return
    fi
    # NUL-delimited inventory becomes literal pathspecs, including newlines,
    # spaces and glob characters. No independently maintained root allowlist.
    if hits=$(git grep "${grep_mode[@]}" -nE -e "$pattern" -- \
        "${SCAN_PATHS[@]}" "$EXCLUDE_SELF" 2>&1); then
        grep_status=0
    else
        grep_status=$?
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
    echo "The repository guard scans tracked and nonignored untracked source, or staged blobs in --staged mode."
    exit 1
fi

echo "✅ OK — no personal-info leaks in source."
exit 0
