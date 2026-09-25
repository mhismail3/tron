#!/usr/bin/env bash
# Keep the skill catalog canonical and retain shared/platform safety guards.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "agent policy: $*" >&2; exit 1; }
[[ -f "$ROOT/.agents/skills/tron-ios/SKILL.md" ]] || fail "missing canonical iOS skill"
[[ -f "$ROOT/.agents/skills/NOTICE.md" ]] || fail "missing skill adaptation notice"
[[ -f "$ROOT/.agents/README.md" ]] || fail "missing .agents README"
python3 - "$ROOT" <<'PY' || fail "skill catalog contract"
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
skills_root = root / ".agents" / "skills"
for harness in (".pi", ".claude", ".codex"):
    if any((root / harness / "skills").rglob("*.md")):
        raise SystemExit("project skills must live under .agents/skills, not harness copies")

# The linked catalog owns the inventory; do not mirror its names here.
catalog = (root / ".agents" / "README.md").read_text()
expected = set(re.findall(r"\[[^\]]+\]\((skills/[^)]+/SKILL\.md)\)", catalog))
paths = sorted(skills_root.rglob("SKILL.md"))
actual = {path.relative_to(root / ".agents").as_posix() for path in paths}
if actual != expected:
    missing = sorted(expected - actual)
    unlisted = sorted(actual - expected)
    raise SystemExit(f"skill catalog mismatch; missing={missing}, unlisted={unlisted}")

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
        key = key.strip()
        if key in fields:
            raise SystemExit(f"{path.relative_to(root)}: duplicate frontmatter field: {key}")
        fields[key] = value.strip()
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

PY
grep -Fq 'SIGSTOP' "$ROOT/AGENTS.md" \
  || fail "shared guidance lacks Gateway work-suspension stop rule"
# Scan tracked and not-yet-tracked source so the check is trustworthy before
# commit as well as in CI. Only the untouched external caller and bounded
# compatibility implementation and policy tests may spell retired names.
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
