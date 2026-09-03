#!/usr/bin/env bash
# Keep project skills canonical and prevent unsafe engineering/iOS guidance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "agent policy: $*" >&2; exit 1; }
[[ -f "$ROOT/.agents/skills/tron-ios/SKILL.md" ]] || fail "missing canonical iOS skill"
[[ -f "$ROOT/.agents/skills/NOTICE.md" ]] || fail "missing skill adaptation notice"
[[ -f "$ROOT/.agents/README.md" ]] || fail "missing .agents README"
[[ ! -e "$ROOT/.codex/skills/tron-ios/SKILL.md" ]] || fail "retired Codex iOS skill remains"
python3 - "$ROOT" <<'PY' || fail "engineering skill suite contract"
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
skills_root = root / ".agents" / "skills"
expected = {
    "tron-ios",
    "tron-documentation-auditor",
    "tron-codebase-auditor",
    "tron-test-suite-auditor",
    "tron-architecture-auditor",
    "tron-persistence-auditor",
    "tron-performance-optimizer",
    "tron-dependency-upgrader",
    "tron-code-modernizer",
    "tron-benchmark-comparator",
    "tron-surgical-change-implementer",
}
paths = sorted(skills_root.glob("*/SKILL.md"))
actual = {path.parent.name for path in paths}
if actual != expected:
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    raise SystemExit(f"skill inventory mismatch; missing={missing}, unexpected={unexpected}")

names = set()
for path in paths:
    source = path.read_text()
    parts = source.split("---", 2)
    if len(parts) != 3 or parts[0] != "":
        raise SystemExit(f"{path.relative_to(root)}: malformed YAML frontmatter")
    fields = {}
    for line in parts[1].strip().splitlines():
        key, separator, value = line.partition(":")
        if not separator:
            raise SystemExit(f"{path.relative_to(root)}: malformed frontmatter line {line!r}")
        fields[key.strip()] = value.strip()
    if set(fields) != {"name", "description"}:
        raise SystemExit(f"{path.relative_to(root)}: frontmatter must contain only name and description")
    name = fields["name"]
    description = fields["description"]
    if name != path.parent.name:
        raise SystemExit(f"{path.relative_to(root)}: name does not match directory")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) or len(name) > 64:
        raise SystemExit(f"{path.relative_to(root)}: invalid skill name")
    if not description or len(description) > 1024 or "<" in description or ">" in description:
        raise SystemExit(f"{path.relative_to(root)}: invalid skill description")
    if name in names:
        raise SystemExit(f"duplicate skill name: {name}")
    names.add(name)

    if name == "tron-ios":
        continue
    body = parts[2]
    if "## Workflow" not in body or "## Report" not in body:
        raise SystemExit(f"{path.relative_to(root)}: missing Workflow or Report contract")
    lowered = body.lower()
    if "gateway" not in lowered or "never" not in lowered:
        raise SystemExit(f"{path.relative_to(root)}: missing Tron Gateway safety boundary")
    if any(marker in source for marker in ("claude plugin", ".codex-plugin", "ln-21-", "ln-31-")):
        raise SystemExit(f"{path.relative_to(root)}: imported host-specific upstream structure")

for name in (
    "tron-documentation-auditor",
    "tron-codebase-auditor",
    "tron-test-suite-auditor",
    "tron-architecture-auditor",
    "tron-persistence-auditor",
):
    source = (skills_root / name / "SKILL.md").read_text().lower()
    if "read-only" not in source:
        raise SystemExit(f"{name}: audit skill must be explicitly read-only")

notice = (skills_root / "NOTICE.md").read_text()
if "bf5d418f05140306b9d583368ff1f44b48ee36c2" not in notice or "MIT License" not in notice:
    raise SystemExit("skill adaptation notice lacks pinned provenance or license")
PY
grep -Fq "    '.agents'" "$ROOT/scripts/personal-info-guard.sh" \
  || fail "personal-info guard does not scan canonical agent guidance"
grep -Fq 'SIGSTOP' "$ROOT/.agents/skills/tron-performance-optimizer/SKILL.md" \
  || fail "performance skill lacks Gateway work-suspension stop rule"
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
    "scripts/check-agent-policy.sh",
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
