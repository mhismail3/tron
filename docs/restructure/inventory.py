#!/usr/bin/env python3
"""Phase-A structure inventory: one ledger row per tracked file and per ignored/untracked path.

  python3 docs/restructure/inventory.py build   # regenerate docs/restructure/inventory.tsv
  python3 docs/restructure/inventory.py check   # fail on any tracked/ignored path without a row

Mechanical columns come from Git, manifests (tools/ownership) and the filesystem. Audit
columns (purpose, callers, cluster, verdict, target, note) come from docs/restructure/audit/*.tsv
(per-file tooling audit) and MODULE_VERDICTS below (module-level verdict for package code).
This is migration scaffolding for docs/restructure/structure-plan.md, deleted with its last slice.
"""

from __future__ import annotations

import csv
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "ownership"))
import ownership  # noqa: E402

LEDGER = HERE / "inventory.tsv"
AUDIT = HERE / "audit"
COLUMNS = ["path", "status", "kind", "module", "layer", "size", "last_commit", "purpose",
           "callers", "cluster", "verdict", "target", "note"]


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args],
                          check=True, capture_output=True, text=True).stdout


def kind_of(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    if name.endswith(".module.json"):
        return "manifest"
    if re.search(r"\.(test|integration\.test|e2e\.test)\.(ts|mjs|js)$", name) or re.match(r"test[-_].*\.(py|sh|js)$", name) \
            or re.search(r"(Tests?|UITests)\.swift$", name) or "/Tests/" in path or "/UITests/" in path \
            or "/E2ETests/" in path or "/ProfilingTests/" in path or "/SwiftAppUITests/" in path or "/push-relay/tests/" in path:
        return "test"
    if "/locks/" in path or "/Goldens/" in path or name.endswith(".golden.json"):
        return "golden"
    if re.search(r"/(test-fixtures|Fixtures|fixtures|test-support)/", "/" + path) or path.startswith("packages/protocol-fixtures/"):
        return "fixture"
    if name.endswith(".md"):
        return "doc"
    if re.search(r"(-pin|-baseline|-patch)\.json$|package-lock\.json$|Package\.resolved$|\.tgz$|node-headers\.json$|cua-driver-release\.json$", name) \
            or "/artifacts/" in path or "/third_party/" in path or path in (".node-version", "VERSION.env", "config/ci-toolchain.env"):
        return "pin"
    if re.search(r"(^|/)(project\.yml|package\.json|tsconfig[^/]*\.json|vitest[^/]*\.ts|wrangler\.toml|\.oxlintrc\.json|\.gitignore|\.gitattributes|dependabot\.yml|work\.json|environment\.toml)$", path) \
            or name.endswith((".xcconfig", ".entitlements", ".xctestplan", ".plist")) or path.startswith("config/"):
        return "config"
    if path.startswith(("scripts/", "tools/")) or re.match(r"packages/[^/]+/scripts/", path) or name.endswith((".sh", ".py")):
        return "tooling"
    if re.search(r"\.(png|jpg|jpeg|pdf|caf|ttf|otf|icns|json|txt|svg|css|html)$", name) or ".xcassets/" in path or ".icon/" in path:
        return "asset"
    return "source"


def last_commits(paths: set[str]) -> dict[str, str]:
    """First (newest) date each path appears in history; one git log pass."""
    out: dict[str, str] = {}
    date = ""
    proc = subprocess.Popen(["git", "-C", str(ROOT), "-c", "core.quotepath=false", "log", "--format=%x00%cs", "--name-only", "HEAD"],
                            stdout=subprocess.PIPE, text=True)
    assert proc.stdout
    for line in proc.stdout:
        line = line.rstrip("\n")
        if line.startswith("\0"):
            date = line[1:]
        elif line and line in paths and line not in out:
            out[line] = date
            if len(out) == len(paths):
                break
    proc.kill()
    return out


def du(path: Path) -> int:
    if path.is_symlink() or path.is_file():
        return path.lstat().st_size
    total = 0
    for base, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += (Path(base) / f).lstat().st_size
            except OSError:
                pass
    return total


def human(n: int) -> str:
    for unit in ("B", "K", "M", "G"):
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.1f}T"


def primary_tree() -> Path:
    """Ignored residue is audited in the primary checkout, the tree people and agents see."""
    return Path(git("worktree", "list", "--porcelain").splitlines()[0].split(" ", 1)[1])


def ignored_paths() -> list[tuple[str, str]]:
    rows = []
    status = subprocess.run(["git", "-C", str(primary_tree()), "-c", "core.quotepath=false", "status", "--ignored",
                             "--porcelain", "--untracked-files=normal"], check=True, capture_output=True, text=True).stdout
    for line in status.splitlines():
        code, path = line[:2], line[3:].strip('"')
        if code in ("!!", "??"):
            rows.append((path.rstrip("/"), "ignored" if code == "!!" else "untracked"))
    return rows


def load_audit() -> dict[str, dict]:
    rows: dict[str, dict] = {}
    for tsv in sorted(AUDIT.glob("*.tsv")) if AUDIT.exists() else []:
        with tsv.open() as handle:
            for row in csv.DictReader(handle, delimiter="\t"):
                if row.get("path"):
                    rows[row["path"].strip()] = row
    return rows


# Module-level verdicts for package code and docs (structure-plan.md §2/§6). Per-file tooling
# verdicts come from audit/*.tsv; everything owned by a module listed here inherits its row.
MODULE_VERDICTS: dict[str, tuple[str, str, str]] = {}  # module id -> (purpose, verdict, target)
MODULE_FILE = HERE / "modules.tsv"


def load_modules() -> None:
    if MODULE_FILE.exists():
        with MODULE_FILE.open() as handle:
            for row in csv.DictReader(handle, delimiter="\t"):
                MODULE_VERDICTS[row["module"]] = (row["purpose"], row["verdict"], row["target"])


def load_targets() -> list[dict]:
    path = HERE / "targets.tsv"
    return list(csv.DictReader(path.open(), delimiter="\t")) if path.exists() else []


def target_for(path: str, targets: list[dict]) -> dict:
    """First matching plan decision; it overrides the scouts' per-file suggestion."""
    import fnmatch
    for row in targets:
        if fnmatch.fnmatchcase(path, row["pattern"]):
            target = row["target"]
            if target.endswith("/"):
                target += path.rsplit("/", 1)[-1]
            return {**row, "target": target}
    return {}


KIND = {"helper": "lib", "tool": "entry", "check": "entry", "guard": "entry", "entry-helper": "entry",
        "maintainer tool": "entry", "data": "pin", "generated": "fixture"}


def build() -> int:
    result, errors = ownership.check()
    owner = {path: (mid, data["layer"]) for mid, data in result["modules"].items() for path in data["owned"]}
    tracked = result["tracked"]
    dates = last_commits(set(tracked))
    audit = load_audit()
    targets = load_targets()
    load_modules()
    rows = []
    for path in tracked:
        mid, layer = owner.get(path, ("UNOWNED", ""))
        a = dict(audit.get(path, {}))
        plan = target_for(path, targets)
        if plan:
            a.update(verdict=plan["verdict"], target=plan["target"], cluster=plan["cluster"] or a.get("cluster", ""),
                     note="; ".join(x for x in (plan["note"] if plan["note"] != "-" else "", a.get("note", "")) if x))
        mpurpose, mverdict, mtarget = MODULE_VERDICTS.get(mid, ("", "", ""))
        full = ROOT / path
        rows.append({
            "path": path, "status": "tracked", "kind": KIND.get(a.get("kind", ""), a.get("kind")) or kind_of(path), "module": mid, "layer": layer,
            "size": human(full.lstat().st_size) if full.exists() or full.is_symlink() else "missing",
            "last_commit": dates.get(path, ""),
            "purpose": a.get("purpose") or mpurpose,
            "callers": a.get("code_callers", ""), "cluster": a.get("cluster", ""),
            "verdict": a.get("verdict") or mverdict, "target": a.get("target") or mtarget, "note": a.get("note", ""),
        })
    for path, status in ignored_paths():
        a = audit.get(path, {})
        full = primary_tree() / path
        rows.append({
            "path": path, "status": status, "kind": a.get("kind") or "residue", "module": "-", "layer": "-",
            "size": human(du(full)) if full.exists() else "missing", "last_commit": "-",
            "purpose": a.get("purpose", ""), "callers": a.get("code_callers", ""), "cluster": a.get("cluster", ""),
            "verdict": a.get("verdict", ""), "target": a.get("target", ""), "note": a.get("note", ""),
        })
    with LEDGER.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({k: str(v).replace("\t", " ").replace("\n", " ") for k, v in row.items()})
    missing = [r["path"] for r in rows if not r["verdict"]]
    print(f"inventory: {len(rows)} rows ({len(tracked)} tracked, {len(rows) - len(tracked)} ignored/untracked); "
          f"{len(missing)} without a verdict; ownership violations: {len(errors)}")
    return 0


def check() -> int:
    with LEDGER.open() as handle:
        ledger = {row["path"]: row for row in csv.DictReader(handle, delimiter="\t")}
    tracked = [p for p in git("ls-files", "-z").split("\0") if p]
    expected = tracked + [p for p, _ in ignored_paths()]
    missing = [p for p in expected if p not in ledger]
    no_verdict = [p for p in expected if p in ledger and not ledger[p]["verdict"]]
    stale = sorted(set(ledger) - set(expected))
    for p in missing:
        print(f"missing row: {p}")
    for p in no_verdict:
        print(f"no verdict: {p}")
    print(f"inventory check: {len(tracked)} tracked + {len(expected) - len(tracked)} ignored/untracked expected; "
          f"{len(ledger)} ledger rows; {len(missing)} unaccounted; {len(no_verdict)} without verdict; {len(stale)} stale rows")
    return 1 if missing or no_verdict else 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    sys.exit(build() if command == "build" else check())
