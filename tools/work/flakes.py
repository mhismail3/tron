"""Failure classes, flake evidence and owned quarantine for the gate (README.md#flakes, #1106).

A failing shard is classified from its own output: `timeout`, `assertion` (named tests
failed) or `setup` (it failed before any test reported). Failing test IDs come from the
vitest JSON report the shard writes, XCTest's `Test Case ... failed` lines and
`node --test`'s failure marks.

Flakes are outages, never something to retry until green (the maintainer's rule,
#1102). A failure gets one isolated rerun only to classify it: when it timed out, or
when one of its tests already has flake evidence. A rerun that passes makes the
failure a confirmed flake:

- named tests are quarantined that day in `<git common dir>/work/gate/quarantine.json`
  with an owner issue (filed through `work issue create`) and an exit date. The gate
  passes only because the quarantine is recorded and printed;
- a timeout with no failing test is `infra` (load, not code): it is recorded for
  admission (`gate report`) and not quarantined.

Quarantined tests still run and report. A shard whose only failures are quarantined
passes with them listed; once an entry expires, its failures block again.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
import tempfile
from datetime import date, timedelta
from pathlib import Path
from typing import Dict, List, Optional

import ledger

MAX_TESTS = 20
QUARANTINE_DAYS = 7
# An entry without an owner issue (filing failed) lasts one day: someone must own it.
UNOWNED_DAYS = 1
_XCTEST = re.compile(r"Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' failed")
_NODE_TEST = re.compile(r"^\s*✖ (.+?) \(\d[\d.]*ms\)\s*$", re.M)


def _cwd(root: Path, command: str) -> Path:
    cwd = re.match(r"\s*cd (\S+) &&", command)
    return (root / (cwd.group(1) if cwd else ".")).resolve()


def _vitest_report(root: Path, command: str) -> Optional[Path]:
    match = re.search(r"--outputFile\.json=(\S+)", command)
    return (_cwd(root, command) / match.group(1)).resolve() if match else None


def failed_tests(root: Path, command: str, log: Optional[Path]) -> List[str]:
    """The IDs of the tests that failed in one shard run, from its reports and log."""
    tests: List[str] = []
    report = _vitest_report(root, command)
    if report and report.exists():
        try:
            data = json.loads(report.read_text())
        except (OSError, ValueError):
            data = {}
        for result in data.get("testResults", []):
            name = str(result.get("name", ""))
            if Path(name).is_absolute():
                # Test IDs are relative to the package the shard runs in, so they match across worktrees.
                try:
                    name = str(Path(name).resolve().relative_to(_cwd(root, command)))
                except ValueError:
                    name = Path(name).name
            failures = [a for a in result.get("assertionResults", []) if a.get("status") == "failed"]
            tests += [f"{name} > {a.get('fullName') or a.get('title')}" for a in failures]
            if result.get("status") == "failed" and not failures:
                tests.append(name)
    text = log.read_text(errors="replace") if log and log.exists() else ""
    tests += [f"{cls}/{method}" for cls, method in _XCTEST.findall(text)]
    if "node --test" in command:
        tests += [name for name in _NODE_TEST.findall(text) if not name.startswith("tests ")]
    return list(dict.fromkeys(tests))[:MAX_TESTS]


_XCTEST_CASE = re.compile(r"Test Case '-\[[^\]]+\]' (?:passed|failed) \((\d+(?:\.\d+)?) seconds\)")


def test_seconds(log: Optional[Path]) -> float:
    """Summed XCTest case time in a shard's log: wall time minus this is the shard's
    overhead (boot, install, lease, xcodebuild start; #1109)."""
    text = log.read_text(errors="replace") if log and log.exists() else ""
    return round(sum(float(value) for value in _XCTEST_CASE.findall(text)), 1)


def failure_class(outcome: str, tests: List[str]) -> Optional[str]:
    if outcome == "timeout":
        return "timeout"
    if outcome == "fail":
        return "assertion" if tests else "setup"
    return None


def flake_history(common: Path) -> set:
    """Tests with evidence of failing and then passing on an unchanged cache key."""
    failed_by_key: Dict[str, set] = {}
    flaky: set = set()
    for row in ledger.rows(common / "work" / "gate" / "metrics.jsonl"):
        key = row.get("key")
        if row.get("outcome") in ("fail", "timeout") and row.get("failedTests"):
            failed_by_key.setdefault(key, set()).update(row["failedTests"])
        elif row.get("outcome") == "pass" and key in failed_by_key:
            flaky |= failed_by_key.pop(key)
    return flaky


def _store(common: Path) -> Path:
    return common / "work" / "gate" / "quarantine.json"


def entries(common: Path) -> List[dict]:
    path = _store(common)
    try:
        return json.loads(path.read_text()) if path.exists() else []
    except ValueError:
        return []


def active(common: Path, today: Optional[date] = None) -> Dict[str, dict]:
    today = today or date.today()
    return {entry["test"]: entry for entry in entries(common) if date.fromisoformat(entry["until"]) >= today}


def expired(common: Path, today: Optional[date] = None) -> List[dict]:
    today = today or date.today()
    return [entry for entry in entries(common) if date.fromisoformat(entry["until"]) < today]


def _write(common: Path, rows: List[dict]) -> None:
    path = _store(common)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(rows, indent=2) + "\n")
    temporary.replace(path)


def _file_issue(root: Path, step: str, tests: List[str], log: Optional[Path]) -> Optional[int]:
    """The owner issue for a newly quarantined test, filed through the audited work CLI."""
    area = {"ios": "ios", "mac": "mac", "gateway": "gateway", "relay": "relay"}.get(step.split(".")[0], "tooling")
    # Outside the worktree: the gate refuses a tree that changes while it runs.
    body = Path(tempfile.mkstemp(prefix="tron-quarantine-", suffix=".md")[1])
    try:
        body.write_text("A gate shard failed and then passed on an isolated rerun with the same cache key, so the "
                        f"gate quarantined these tests in `{step}` (they still run and report; their failures do "
                        "not block until the quarantine expires):\n\n" + "\n".join(f"- `{t}`" for t in tests)
                        + f"\n\nFix the flake, then remove the entry with `scripts/tron gate quarantine remove "
                        f"<test>`. Evidence: `scripts/tron gate report --since 1d`.\n")
        done = subprocess.run([str(Path(__file__).resolve().parent / "cli.py"), "issue", "create",
                               "--title", f"Flaky test in {step}: {tests[0][:120]}", "--body-file", str(body),
                               "--kind", "kind:bug", "--area", f"area:{area}"], cwd=root, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        body.unlink(missing_ok=True)
    match = re.search(r"created issue #(\d+)", done.stdout)
    return int(match.group(1)) if match and done.returncode == 0 else None


def quarantine(root: Path, common: Path, step: str, tests: List[str], log: Optional[Path]) -> dict:
    """Quarantine confirmed flaky tests today, with an owner issue and an exit date."""
    issue = _file_issue(root, step, tests, log)
    until = date.today() + timedelta(days=QUARANTINE_DAYS if issue else UNOWNED_DAYS)
    rows = [entry for entry in entries(common) if entry["test"] not in tests]
    added = [{"test": test, "step": step, "issue": issue, "since": date.today().isoformat(),
              "until": until.isoformat(), "evidence": str(log) if log else ""} for test in tests]
    _write(common, rows + added)
    return {"issue": issue, "until": until.isoformat()}


def command(root: Path, common: Path, action: str, test: Optional[str], issue: Optional[int], days: int) -> int:
    """`gate quarantine list|add|remove`: the maintainer's and owners' hand on the store."""
    rows = entries(common)
    if action == "list":
        today = date.today()
        for entry in rows:
            state = "EXPIRED" if date.fromisoformat(entry["until"]) < today else "active"
            owner = f"#{entry['issue']}" if entry.get("issue") else "NO OWNER"
            print(f"{state:<8} {entry['until']}  {owner:<9} {entry['step']}: {entry['test']}")
        return 0
    if not test:
        raise SystemExit("gate quarantine: name the test")
    if action == "remove":
        kept = [entry for entry in rows if entry["test"] != test]
        _write(common, kept)
        print(f"gate: removed {len(rows) - len(kept)} quarantine entries for {test}")
        return 0
    if not issue:
        raise SystemExit("gate quarantine add: every quarantined test has an owner issue (--issue N)")
    step = next((entry["step"] for entry in rows if entry["test"] == test), "")
    kept = [entry for entry in rows if entry["test"] != test]
    until = (date.today() + timedelta(days=days)).isoformat()
    _write(common, kept + [{"test": test, "step": step, "issue": issue, "since": date.today().isoformat(),
                            "until": until, "evidence": "added by hand"}])
    print(f"gate: quarantined {shlex.quote(test)} until {until}, owned by #{issue}")
    return 0
