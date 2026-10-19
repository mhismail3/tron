"""Module-issue ledger (README.md "Ledger"; restructure plan §6.7 V8, §9.2).

Compares Git-tracked paths and their manifest owners (tools/ownership) with the
file checklists in module issues on GitHub. Ownership logic lives only in
tools/ownership; this module adds the issue side.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import tracking
from gh import Gh, GhError

LABEL = "restructure"
STATES = ("unreviewed", "keep", "delete", "simplify", "done")
MODULE = re.compile(r"Module: `([^`\s]+)`")
SYNCED = re.compile(r"^Ledger sync: `([0-9a-f]{40})`", re.MULTILINE)
ENTRY = re.compile(r"^- \[[ x]\] `([^`]+)` — (.+)$")
FILES_HEADING = "## Files"
FILES_TITLE = "## Files (ledger; states: unreviewed|keep|delete|simplify|move→<dest>|done)"
BODY_LIMIT = 64 * 1024  # tracking.edit_issue's byte bound
AREA_LABELS = {"gateway": ["area:gateway"], "ios-app": ["area:ios"], "mac-app": ["area:mac"],
               "push-relay": ["area:relay"], "protocol-fixtures": ["area:gateway", "area:ios"], "repo": ["area:tooling"]}
# Issues closed as not planned or duplicate are not module issues any more (recovery path for a duplicate).
RETIRED = {"NOT_PLANNED", "DUPLICATE"}
ISSUES = """
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 50, after: $cursor, labels: ["restructure"], states: [OPEN, CLOSED]) {
      pageInfo { hasNextPage endCursor }
      nodes { number state stateReason title body
              parent { number title parent { number title } } }
    }
  }
}
"""


class LedgerError(RuntimeError):
    pass


class Unavailable(LedgerError):
    """GitHub evidence could not be read: never reported as a clean result."""


def area_labels(key: str) -> List[str]:
    package = key.split("/", 1)[0]
    if package not in AREA_LABELS:
        raise LedgerError(f"no area label is declared for package {package!r}")
    return AREA_LABELS[package]


def valid_state(state: str) -> bool:
    return state in STATES or (state.startswith("move→") and len(state) > len("move→"))


def ownership(root: Path, revision: Optional[str] = None) -> Tuple[dict, List[str]]:
    sys.path.insert(0, str(root / "tools" / "ownership"))
    import ownership as owners  # noqa: E402  (the one ownership authority)
    try:
        return owners.check(revision)
    except owners.GitError as error:
        raise LedgerError(f"ownership: {error}") from error


def git(root: Path, *args: str) -> str:
    done = subprocess.run(["git", "-C", str(root), "-c", "core.quotepath=false", *args],
                          capture_output=True, text=True)
    if done.returncode:
        raise LedgerError(done.stderr.strip() or f"git {args[0]} failed")
    return done.stdout


def parse(issue: dict) -> dict:
    """Module id, recorded sync revision and checklist of one issue body; malformed lines are kept as problems."""
    body = issue.get("body") or ""
    first = next((line for line in body.splitlines() if line.strip()), "")
    module = MODULE.search(first)
    entries: List[Tuple[str, str]] = []
    problems: List[str] = []
    section, sections = False, 0
    for number, line in enumerate(body.splitlines(), 1):
        if line.startswith("## "):
            section = line.startswith(FILES_HEADING)
            if section and sections:
                problems.append(f"line {number} starts a second Files section")
            sections += section
            continue
        if not section or not line.strip() or line.startswith("Ledger sync: "):
            continue
        match = ENTRY.match(line)
        if not match:
            problems.append(f"line {number} is not '- [ ] `path` — state'")
        elif not valid_state(match.group(2)):
            problems.append(f"line {number} has unknown state {match.group(2)!r}")
        else:
            entries.append((match.group(1), match.group(2)))
    synced = SYNCED.search(body)
    parent = issue.get("parent") or {}
    return {"number": issue["number"], "state": issue["state"], "reason": issue.get("stateReason"),
            "module": module.group(1) if module else None, "entries": entries, "problems": problems,
            "synced": synced.group(1) if synced else None, "body": body,
            "area": parent.get("number"), "areaTitle": parent.get("title"),
            "phase": (parent.get("parent") or {}).get("number")}


def module_issues(gh: Gh) -> List[dict]:
    try:
        owner, name = tracking._repository(gh)
        found, cursor = [], None
        while True:
            page = gh.graphql(ISSUES, owner=owner, name=name, cursor=cursor)["repository"]["issues"]
            found += [parse(issue) for issue in page["nodes"]]
            if not page["pageInfo"]["hasNextPage"]:
                break
            cursor = page["pageInfo"]["endCursor"]
    except (GhError, tracking.TrackingError, KeyError, TypeError) as error:
        raise Unavailable(f"GitHub module issues unavailable: {error}") from error
    return [issue for issue in found if issue["module"] and issue["reason"] not in RETIRED]


def compare(local: dict, owner_errors: List[str], issues: List[dict]) -> dict:
    modules = local["modules"]
    tracked = set(local["tracked"])
    owner_of = {path: key for key, module in modules.items() for path in module["owned"]}
    by_module: Dict[str, List[dict]] = defaultdict(list)
    for issue in issues:
        by_module[issue["module"]].append(issue)
    violations = [f"ownership: {error}" for error in owner_errors]
    listed: Dict[str, List[int]] = defaultdict(list)
    for key, found in sorted(by_module.items()):
        if len(found) > 1:
            violations.append(f"duplicate module issues for {key}: " + ", ".join(f"#{i['number']}" for i in found))
        for issue in found:
            ref = f"#{issue['number']} ({key})"
            violations += [f"{ref}: {problem}" for problem in issue["problems"]]
            if key not in modules:
                if issue["state"] == "OPEN":
                    violations.append(f"{ref}: no {key} manifest exists")
                continue
            if issue["area"] is None:
                violations.append(f"{ref}: has no Area epic parent")
            seen = Counter(path for path, _ in issue["entries"])
            violations += [f"{ref}: lists {path} more than once" for path, n in seen.items() if n > 1]
            for path in seen:
                listed[path].append(issue["number"])
                if path not in tracked:
                    violations.append(f"{ref}: lists {path}, which is not a tracked file")
                elif owner_of.get(path) != key:
                    violations.append(f"{ref}: lists {path}, owned by {owner_of.get(path, 'no module')}")
            for path in modules[key]["owned"]:
                if path not in seen:
                    violations.append(f"unchecklisted: {path} (missing from {ref})")
    violations += [f"checklisted more than once: {path} in " + ", ".join(f"#{n}" for n in numbers)
                   for path, numbers in sorted(listed.items()) if len(set(numbers)) > 1]
    unissued = sorted(key for key in modules if key not in by_module)
    violations += [f"unissued module: {key} ({len(modules[key]['owned'])} paths, {modules[key]['manifest']})"
                   for key in unissued]

    rows = []
    for key in sorted(modules):
        issue = (by_module.get(key) or [None])[0]
        states = Counter()
        if issue:
            current = dict(issue["entries"])
            states.update("move" if current.get(path, "unreviewed").startswith("move→") else current.get(path, "unreviewed")
                          for path in modules[key]["owned"] if path in current)
        rows.append({"module": key, "paths": len(modules[key]["owned"]), "issue": issue and issue["number"],
                     "area": issue and issue["area"], "phase": issue and issue["phase"],
                     "states": dict(states)})
    return {"violations": sorted(set(violations)), "rows": rows, "tracked": len(tracked)}


def rollup(rows: List[dict]) -> List[str]:
    def total(group: List[dict]) -> str:
        states = Counter()
        for row in group:
            states.update(row["states"])
        listed = sum(states.values())
        paths = sum(row["paths"] for row in group)
        detail = ", ".join(f"{state} {states[state]}" for state in (*STATES, "move") if states[state])
        return f"{listed}/{paths} checklisted" + (f" ({detail})" if detail else "")
    lines = []
    for label, field in (("phase", "phase"), ("area", "area")):
        groups: Dict[object, List[dict]] = defaultdict(list)
        for row in rows:
            groups[row[field] if row["issue"] else "(no issue)"].append(row)
        for value in sorted(groups, key=lambda v: (not isinstance(v, int), str(v) if not isinstance(v, int) else v)):
            name = f"#{value}" if isinstance(value, int) else value or "(no parent)"
            lines.append(f"{label} {name}: {len(groups[value])} modules, {total(groups[value])}")
    lines.append(f"epic: {len(rows)} modules, {total(rows)}")
    return lines


def report(gh_factory, root: Path, module: Optional[str], json_path: Optional[Path]) -> int:
    local, owner_errors = ownership(root)
    if module:
        if module not in local["modules"]:
            raise LedgerError(f"no module {module!r}; see scripts/tron ownership --modules")
        print("\n".join(local["modules"][module]["owned"]))
        return 0
    try:
        issues = module_issues(gh_factory())
    except (Unavailable, GhError) as error:
        for line in owner_errors:
            print(f"ownership: {line}")
        print(f"ledger: GitHub unavailable ({error}); checklists NOT checked; "
              f"ownership {'clean' if not owner_errors else f'{len(owner_errors)} violation(s)'}")
        return 3
    model = compare(local, owner_errors, issues)
    for line in model["violations"]:
        print(line)
    for line in rollup(model["rows"]):
        print(line)
    issued = sum(1 for row in model["rows"] if row["issue"])
    state = f"{len(model['violations'])} violation(s)" if model["violations"] else "every path checklisted exactly once"
    print(f"ledger: {len(model['rows'])} modules ({issued} with issues), {model['tracked']} tracked paths, {state}")
    if json_path:
        json_path.write_text(json.dumps(model, indent=2, sort_keys=True) + "\n")
    return 1 if model["violations"] else 0


def head_with_clean_index(root: Path) -> str:
    if subprocess.run(["git", "-C", str(root), "diff", "--cached", "--quiet"]).returncode:
        raise LedgerError("the index differs from HEAD; commit first so the recorded sync revision is exact")
    return git(root, "rev-parse", "HEAD").strip()


def checklist(owned: List[str], states: Dict[str, str], revision: str) -> str:
    lines = [FILES_TITLE, f"Ledger sync: `{revision}` (`scripts/tron work ledger --sync`; edit states, not paths)", ""]
    for path in owned:
        if "`" in path:
            raise LedgerError(f"{path!r} cannot be listed in a Markdown code span")
        state = states.get(path, "unreviewed")
        lines.append(f"- [{'x' if state == 'done' else ' '}] `{path}` — {state}")
    return "\n".join(lines)


def replace_files(body: str, section: str) -> str:
    lines = body.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith(FILES_HEADING)), None)
    if start is None:
        return body.rstrip() + "\n\n" + section + "\n"
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[:start] + section.splitlines() + ([""] + lines[end:] if end < len(lines) else [])) + "\n"


def sync(gh: Gh, root: Path, config: dict, number: int) -> int:
    revision = head_with_clean_index(root)
    local, owner_errors = ownership(root, revision)  # committed manifests: the checklist matches its revision
    if owner_errors:
        raise LedgerError(f"ownership has {len(owner_errors)} violation(s); fix them first (scripts/tron ownership)")
    issues = module_issues(gh)
    issue = next((i for i in issues if i["number"] == number), None)
    if issue is None:
        raise LedgerError(f"#{number} is not a module issue (needs the {LABEL} label and a Module: `<id>` line)")
    if issue["problems"]:
        raise LedgerError(f"#{number} checklist is malformed: " + "; ".join(issue["problems"]))
    key = issue["module"]
    if key not in local["modules"]:
        raise LedgerError(f"#{number} names {key}, which has no manifest")
    owned = local["modules"][key]["owned"]
    tracked = set(local["tracked"])
    current = dict(issue["entries"])
    # A path listed by exactly one module issue carries its state to whichever module owns it now.
    elsewhere: Dict[str, List[str]] = defaultdict(list)
    for other in issues:
        if other["number"] != number:
            for path, state in other["entries"]:
                elsewhere[path].append(state)
    # Renames and owner changes are read from Git between the recorded revision and HEAD.
    # -B lets a path whose content was replaced pair with the file that replaced it.
    renames: Dict[str, str] = {}
    base_paths: set = set()
    base = issue["synced"]
    if base and subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{base}^{{commit}}"],
                               capture_output=True).returncode == 0:
        base_paths = set(git(root, "ls-tree", "-r", "--name-only", base).splitlines())
        for line in git(root, "diff", "-B", "-M", "--name-status", base, revision).splitlines():
            parts = line.split("\t")
            if parts[0].startswith("R") and len(parts) == 3:
                renames[parts[2]] = parts[1]
    elif any(path not in tracked for path in current):
        raise LedgerError(f"#{number} lists paths that no longer exist and has no reachable sync revision, so "
                          "renames cannot be followed; restore the revision or record the states by hand")
    moved_to = {old: new for new, old in renames.items()}
    owner_of = {path: other for other, module in local["modules"].items() for path in module["owned"]}
    listing = {(other["module"], path) for other in issues for path, _ in other["entries"]}
    numbers = {other["module"]: other["number"] for other in issues}

    def unique_elsewhere(path: Optional[str]) -> Optional[str]:
        found = elsewhere.get(path) or []
        return found[0] if len(found) == 1 else None

    states, notes, blockers = {}, [], []
    for path in owned:
        source = renames.get(path)
        if source and (source in current or unique_elsewhere(source)):
            states[path] = current.get(source) or unique_elsewhere(source)
            origin = "" if source in current else " (from another module issue)"
            notes.append(f"renamed {source} → {path} — {states[path]}{origin}")
        elif path in current:
            states[path] = current[path]
        elif path in base_paths and unique_elsewhere(path):
            # The same file changed owner; a brand-new file at a stale listed path does not inherit.
            states[path] = unique_elsewhere(path)
            notes.append(f"carried {path} — {states[path]} from another module issue")
        else:
            notes.append(f"added {path} — unreviewed")

    # Every other listed entry leaves the checklist. Its audit state must go somewhere visible:
    # a paired rename already carried it; another module's issue must list the destination
    # first; content that vanished without a Git pairing leaves only as unreviewed or delete.
    for path, state in current.items():
        replaced = path in renames and renames[path] != path
        if path in owned and not replaced:
            continue
        if path in moved_to and moved_to[path] in owned:
            if not replaced:
                continue
        destination = None if replaced else (path if path in tracked else moved_to.get(path))
        if destination is None:
            if state in ("unreviewed", "delete"):
                notes.append(f"dropped {path} — {state} ({'content replaced' if replaced else 'deleted'})")
            else:
                blockers.append(f"{path} ({state}) {'had its content replaced' if replaced else 'vanished'} without a "
                                "rename Git can pair; record its state on the new path by hand, set this entry to "
                                "delete or unreviewed, and re-run")
            continue
        target = owner_of[destination]
        if target == key:
            continue
        if (target, destination) in listing:
            notes.append(f"dropped {path} — {state} (now {destination} in #{numbers[target]} ({target}))")
        elif target in numbers:
            blockers.append(f"sync #{numbers[target]} ({target}) first: it does not list {destination} yet")
        else:
            blockers.append(f"create the {target} module issue first: {path} moved to {destination}")
    if blockers:
        raise LedgerError(f"#{number} would lose audit state: " + "; ".join(sorted(blockers)))
    body = replace_files(issue["body"], checklist(owned, states, revision))
    if len(body.encode("utf-8")) > BODY_LIMIT:
        raise LedgerError(f"#{number} body would exceed {BODY_LIMIT} bytes; split the module")
    for note in notes:
        print(note)
    if body == issue["body"] or body.rstrip("\n") == issue["body"].rstrip("\n"):
        print(f"#{number} ({key}) unchanged: {len(owned)} files")
        return 0
    # GitHub has no conditional issue update; re-read just before writing so a concurrent edit is
    # refused rather than overwritten (a remaining sub-second window is accepted).
    owner, name = tracking._repository(gh)
    if (tracking._issue(gh, f"{owner}/{name}", number).get("body") or "") != issue["body"]:
        raise LedgerError(f"#{number} changed while syncing; re-run")
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "body.md"
        path.write_text(body)
        tracking.edit_issue(gh, root, config, number, None, path)
    print(f"#{number} ({key}) synced at {revision[:12]}: {len(owned)} files")
    return 0


def create(gh: Gh, root: Path, config: dict, key: str, epic: int) -> int:
    revision = head_with_clean_index(root)
    local, owner_errors = ownership(root, revision)
    if key not in local["modules"]:
        raise LedgerError(f"no module {key!r}; see scripts/tron ownership --modules")
    if owner_errors:
        raise LedgerError(f"ownership has {len(owner_errors)} violation(s); fix them first (scripts/tron ownership)")
    existing = [issue for issue in module_issues(gh) if issue["module"] == key]
    if len(existing) > 1:
        raise LedgerError(f"{key} already has several module issues: " + ", ".join(f"#{i['number']}" for i in existing))
    if existing:
        number = existing[0]["number"]
        print(f"module issue #{number} for {key} exists")
        if existing[0]["area"] not in (None, epic):
            raise LedgerError(f"#{number} is already under #{existing[0]['area']}; move it explicitly with "
                              f"scripts/tron work issue parent {number} --epic {epic} --replace-parent")
        try:
            tracking.add_project_item(gh, root, config, number)  # repairs a create whose Project step failed
        except (GhError, tracking.TrackingError) as error:
            raise LedgerError(f"module issue #{number} exists but its Project membership is uncertain ({error}); "
                              "re-run the same command") from error
    else:
        module = local["modules"][key]
        body = (f"Parent: #{epic}. Module: `{key}` · layer {module['layer']} · manifest `{module['manifest']}`\n"
                "Target: as-is (the scoper decides). Locks: none yet (0.8/0.9). Risk class: unassigned.\n\n"
                + checklist(module["owned"], {}, revision) + "\n\n## Edges\n"
                "dependsOn and dynamicEdges: declared in the manifest by the scoper.\n\n"
                "## Slices\nSub-issues, ordered by blocked-by.\n")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "body.md"
            path.write_text(body)
            number = tracking.create_issue(gh, root, config, f"Module: {key}", path, "task", "kind:maintenance",
                                           area_labels(key), None, "P2", None, [LABEL])
    try:
        tracking.add_parent(gh, root, config, number, epic)
    except (GhError, tracking.TrackingError) as error:
        raise LedgerError(f"module issue #{number} exists but its parent link failed or is uncertain ({error}); "
                          "re-run the same command") from error
    return 0
