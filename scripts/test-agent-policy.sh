#!/usr/bin/env bash
# Keep agent guidance canonical and prevent unsafe iOS delivery instructions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "agent policy: $*" >&2; exit 1; }
[[ -f "$ROOT/.agents/skills/tron-ios/SKILL.md" ]] || fail "missing canonical iOS skill"
[[ -f "$ROOT/.agents/README.md" ]] || fail "missing .agents README"
[[ ! -e "$ROOT/.codex/skills/tron-ios/SKILL.md" ]] || fail "retired Codex iOS skill remains"
# Scan tracked and not-yet-tracked source so the check is trustworthy before
# commit as well as in CI. Only the untouched external caller and bounded
# compatibility implementation/tests may spell retired names.
python3 - "$ROOT" <<'PY' || fail "stale iOS build guidance outside bounded compatibility"
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
allowed = {
    ".codex/environments/environment.toml",
    "scripts/tron-ios-device",
    "scripts/tron-ios-device-test",
    "scripts/test-agent-policy.sh",
    "packages/ios-app/scripts/test-build-matrix-policy.sh",
}
paths = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
).decode().split("\0")
pattern = re.compile(r"Tron Beta|Tron Fast|ProdDebug|DeviceTest|TronMobileBeta|TronMobileProd")
stale = []
for relative in paths:
    if not relative or relative in allowed:
        continue
    path = root / relative
    if not path.is_file():
        continue
    try:
        source = path.read_text()
    except UnicodeDecodeError:
        continue
    if pattern.search(source):
        stale.append(relative)
if stale:
    print("\n".join(stale), file=sys.stderr)
    raise SystemExit(1)
PY
skill="$ROOT/.agents/skills/tron-ios/SKILL.md"
grep -Eq 'Tron Device.*LocalDevice' "$skill" || fail "skill lacks canonical device pair"
grep -Fq 'Never install Release or DevicePerformance' "$skill" || fail "skill lacks release install stop rule"
grep -Fq 'signed artifacts are' "$skill" || fail "skill lacks artifact authority guidance"
! grep -Eq 'TRON_IOS_SCHEME=Tron([^ ]|$)|TRON_IOS_CONFIGURATION=Prod([^A-Za-z]|$)' "$skill" \
  || fail "skill contains unsafe legacy install guidance"
printf '%s\n' "agent guidance policy passed"
