#!/usr/bin/env python3
"""Checks, audits and prunes Tron homes against the one path registry.

The registry is packages/gateway/src/foundation/tron-home-layout.json; the
policy is docs/tron-home.md. `check` reads tracked source only. `audit`,
`retention` and `prune --plan` only read a home; `prune --apply` deletes exactly
the reviewed plan; `migrate` is the only reader of retired locations.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = "packages/gateway/src/foundation/tron-home-layout.json"
FIELDS = {"owner", "writer", "life", "rebuild", "backup", "secret", "retention", "view"}
LIVES = {"durable", "cache", "scratch", "log", "lock"}
VIEWS = {"system", "config", "knowledge"}
SECRETS = {None, "private", "credential"}
EXTERNAL_OWNERS = ("pi-sdk", "pi-subagents", "extension")
DAY = 86_400


class LayoutError(Exception):
    pass


def load(root: Path = ROOT) -> dict:
    try:
        return json.loads((root / REGISTRY).read_text())
    except (OSError, ValueError) as error:
        raise LayoutError(f"{REGISTRY}: {error}") from error


def registered(paths: dict, relative: str) -> bool:
    """True when a registry entry, pattern or owning subtree covers `relative`."""
    parts = relative.split("/")
    for index in range(len(parts), 0, -1):
        prefix = "/".join(parts[:index])
        for key, entry in paths.items():
            if key == prefix or ("*" in key and fnmatch.fnmatchcase(prefix, key)):
                if index == len(parts) or entry.get("subtree"):
                    return True
    return False


def modules(root: Path) -> set[str]:
    """Module ids from the one ownership authority."""
    sys.path.insert(0, str(root / "tools/ownership"))
    import ownership  # noqa: E402
    return set(ownership.check()[0]["modules"])


def validate(registry: dict, root: Path) -> list[str]:
    problems, paths, known = [], registry.get("paths", {}), modules(root)
    for key, entry in paths.items():
        missing = FIELDS - entry.keys()
        if missing:
            problems.append(f"{key}: missing {', '.join(sorted(missing))}")
            continue
        if entry["life"] not in LIVES or entry["view"] not in VIEWS or entry["secret"] not in SECRETS:
            problems.append(f"{key}: life, view or secret is not one of the declared values")
        if not isinstance(entry["backup"], bool):
            problems.append(f"{key}: backup must be true or false")
        owner = entry["owner"]
        if not owner.startswith(EXTERNAL_OWNERS) and owner not in known:
            problems.append(f"{key}: owner {owner} is not a module (scripts/tron ownership --modules)")
        parent = key.rsplit("/", 1)[0]
        if "/" in key and parent not in paths:
            problems.append(f"{key}: parent {parent} is not registered")
    for move in registry.get("retired", []):
        if not registered(paths, move["to"]) or registered(paths, move["from"]):
            problems.append(f"retired {move['from']} -> {move['to']}: the destination must be registered and the source not")
    return problems


# A Tron-home-relative literal: `.tron/<a>/<b>`, `".tron", "<a>"`, `".tron" / "<a>"`,
# Swift `tronHome...appendingPathComponent("<a>"`, or `join(tronHome, "<a>", "<b>"`.
LITERALS = [
    re.compile(r"\.tron/([\w.-]+)(?:/([\w.*-]+))?"),
    re.compile(r"""["']\.tron["']\s*[,/]\s*["']([\w.-]+)["'](?:\s*[,/]\s*["']([\w.*-]+)["'])?"""),
    re.compile(r"""tronHome\b[^\n]*?appendingPathComponent\(\s*"([\w.-]+)\""""),
    re.compile(r"""\b(?:join|resolve)\(\s*[\w.]*(?:tronHome|tron_home|TRON_HOME)\b[^,()]*,\s*["']([\w.-]+)["'](?:\s*,\s*["']([\w.*-]+)["'])?"""),
]
SOURCE_ROOTS = ("packages/gateway/src", "packages/gateway/scripts", "packages/mac-app/Sources", "packages/mac-app/scripts", "scripts", "tools")
SOURCE_SUFFIXES = {".ts", ".mjs", ".js", ".py", ".swift", ".c", ".sh"}
TEST_NAME = re.compile(r"((^|/)test[-_][^/]*$|[.-]test\.|\.(integration|e2e|lock)\.|Tests?/|/tests/)")
# The registry module itself, and the tool that reads the registry, name paths by design.
EXEMPT = {"packages/gateway/src/foundation/tron-home-layout.ts", "tools/home-layout/home_layout.py"}


def tracked(root: Path) -> list[str]:
    output = subprocess.run(["git", "ls-files", "--", *SOURCE_ROOTS], cwd=root, check=True, capture_output=True, text=True).stdout
    return [path for path in output.splitlines()
            if not TEST_NAME.search(path) and path not in EXEMPT
            and (Path(path).suffix in SOURCE_SUFFIXES or (not Path(path).suffix and (root / path).is_file()))]


def check(root: Path = ROOT) -> list[str]:
    registry = load(root)
    problems = validate(registry, root)
    paths = registry["paths"]
    gateway_literal = LITERALS[3]
    for path in tracked(root):
        try:
            text = (root / path).read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if path.startswith("packages/gateway/src/") and gateway_literal.search(line):
                problems.append(f"{path}:{number}: resolve Tron-home paths with tronHomePath(), not a literal join")
                continue
            for pattern in LITERALS:
                for match in pattern.finditer(line):
                    segments = [segment for segment in match.groups() if segment and not re.search(r"[*$]|^\.tron", segment)]
                    relative = "/".join(segments)
                    if relative and not registered(paths, relative):
                        problems.append(f"{path}:{number}: {relative} is not in {REGISTRY}")
    return problems


def walk(home: Path, paths: dict) -> tuple[list[str], list[str]]:
    """Registered on-disk entries (descending only into non-subtree directories) and unregistered ones."""
    found, unknown, pending = [], [], [""]
    while pending:
        base = pending.pop()
        directory = home / base if base else home
        for entry in sorted(os.scandir(directory), key=lambda item: item.name):
            relative = f"{base}/{entry.name}" if base else entry.name
            if not registered(paths, relative):
                unknown.append(relative)
                continue
            found.append(relative)
            covered = registered(paths, f"{relative}/-")
            if entry.is_dir(follow_symlinks=False) and not covered:
                pending.append(relative)
    return found, sorted(unknown)


def usage(path: Path) -> tuple[int, int, float]:
    """Bytes, files and newest mtime of a path, never following symlinks."""
    if path.is_symlink() or path.is_file():
        info = path.lstat()
        return info.st_blocks * 512, 1, info.st_mtime
    total, files, newest = 0, 0, path.lstat().st_mtime
    for directory, names, children in os.walk(path):
        for name in names + children:
            try:
                info = os.lstat(os.path.join(directory, name))
            except FileNotFoundError:
                continue
            total += info.st_blocks * 512
            files += name in children
            newest = max(newest, info.st_mtime)
    return total, files, newest


def human(size: int) -> str:
    for unit in ("B", "K", "M", "G"):
        if size < 1024 or unit == "G":
            return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024
    return str(size)


def pinned_subagents(root: Path, home: Path) -> set[str]:
    """pi-subagents versions any installed or retained payload, or this checkout, pins."""
    pins = {json.loads((root / "packages/gateway/pi-subagents-pin.json").read_text())["version"]}
    for pin in (home / "gateway/payloads").glob("*/versions/*/app/pi-subagents-pin.json"):
        try:
            pins.add(json.loads(pin.read_text())["version"])
        except (OSError, ValueError, KeyError):
            pins.add("*")  # an unreadable pin keeps every version
    return pins


def candidates(home: Path, paths: dict, files_days: int | None, now: float) -> list[dict]:
    rows = [{"path": relative, "reason": "not in the registry"} for relative in walk(home, paths)[1]]
    pins = pinned_subagents(ROOT, home)
    installs = home / "internal/pi-subagents"
    if installs.is_dir() and "*" not in pins:
        for entry in sorted(installs.iterdir()):
            if entry.name not in pins:
                rows.append({"path": f"internal/pi-subagents/{entry.name}", "reason": "pi-subagents install no payload pins"})
                cache = home / "internal/pi-subagents-transform-cache" / entry.name
                if cache.exists():
                    rows.append({"path": str(cache.relative_to(home)), "reason": "transform cache of an unpinned install"})
    if files_days is not None and (home / "workspace/files").is_dir():
        for entry in sorted((home / "workspace/files").iterdir()):
            relative = f"workspace/files/{entry.name}"
            if paths.get(relative):
                continue  # a registered file such as the Profile is never a document candidate
            if now - usage(entry)[2] > files_days * DAY:
                rows.append({"path": relative, "reason": f"workspace document untouched for {files_days} days"})
    for row in rows:
        size, files, newest = usage(home / row["path"])
        row.update(bytes=size, files=files, newest=int(newest))
    return rows


def plan_digest(plan: dict) -> str:
    body = json.dumps({key: plan[key] for key in ("home", "candidates")}, sort_keys=True)
    return hashlib.sha256(body.encode()).hexdigest()


def runtime_lock(home: Path) -> bool:
    return (home / "agent/.tron-gateway-runtime.lock.lock").exists()


# Migration: the only reader of `retired` sources. It needs a stopped Gateway,
# copies every source into a backup first, journals each step, and is
# idempotent, resumable and reversible (`--rollback`).
JOURNAL = "gateway/layout-migration/journal.json"


def migrate(home: Path, registry: dict, rollback: bool) -> list[str]:
    if runtime_lock(home):
        raise LayoutError(f"a Gateway holds {home}/agent; stop Tron before migrating")
    journal_path = home / JOURNAL
    backup = journal_path.parent / "backup"
    journal = json.loads(journal_path.read_text()) if journal_path.exists() else {"version": 1, "moves": {}}
    log = []
    for move in registry["retired"]:
        source, destination = home / move["from"], home / move["to"]
        state = journal["moves"].get(move["from"])
        if rollback:
            if state != "moved" and not (state == "copied" and destination.exists()):
                continue
            if source.exists():
                raise LayoutError(f"cannot roll back {move['to']}: {move['from']} exists again")
            source.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.replace(destination, source)
            journal["moves"][move["from"]] = "rolled-back"
            log.append(f"restored {move['from']}")
        else:
            if state == "moved" and not source.exists():
                continue
            if not source.exists():
                log.append(f"absent {move['from']}")
                continue
            if destination.exists():
                raise LayoutError(f"{move['to']} and {move['from']} both exist; resolve by hand")
            copy = backup / move["from"]
            if not copy.exists():
                copy.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                (shutil.copytree if source.is_dir() else shutil.copy2)(source, copy)
            journal["moves"][move["from"]] = "copied"
            write_journal(journal_path, journal)
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.replace(source, destination)
            journal["moves"][move["from"]] = "moved"
            log.append(f"moved {move['from']} -> {move['to']}")
        write_journal(journal_path, journal)
        prune_empty(source.parent, home)
    return log


def write_journal(path: Path, journal: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(journal, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def prune_empty(directory: Path, home: Path) -> None:
    """Remove a migration source's now-empty parents, never a registered root."""
    while directory != home and directory.is_dir() and not any(directory.iterdir()):
        directory.rmdir()
        directory = directory.parent


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron home-layout", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="registry is valid and tracked source names only registered Tron-home paths")
    for name, text in (("audit", "on-disk entries the registry does not list"), ("retention", "size, age and retention rule of every entry")):
        sub = commands.add_parser(name, help=text)
        sub.add_argument("--home", required=True, type=Path)
    prune = commands.add_parser("prune", help="plan, or apply a reviewed plan, deleting dead and expired entries")
    prune.add_argument("--home", type=Path)
    prune.add_argument("--files-older-than", type=int, metavar="DAYS")
    prune.add_argument("--plan", type=Path, metavar="OUT", help="write the plan here")
    prune.add_argument("--apply", type=Path, metavar="PLAN")
    prune.add_argument("--confirm", metavar="SHA256", help="the digest `--plan` printed")
    move = commands.add_parser("migrate", help="move retired locations to their registered place (Gateway stopped)")
    move.add_argument("--home", required=True, type=Path)
    move.add_argument("--rollback", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            problems = check()
            for problem in problems:
                print(problem)
            print(f"home-layout check: {len(problems)} problem(s), {len(load()['paths'])} registered paths")
            return 1 if problems else 0
        registry = load()
        home = (args.home or Path()).expanduser().resolve()
        if args.command == "audit":
            found, unknown = walk(home, registry["paths"])
            for relative in unknown:
                print(f"unregistered {relative}")
            print(f"home-layout audit {home}: {len(found)} registered, {len(unknown)} unregistered")
            return 1 if unknown else 0
        if args.command == "retention":
            now = time.time()
            for relative in walk(home, registry["paths"])[0]:
                key = next(key for key in sorted(registry["paths"], key=len, reverse=True)
                           if key == relative or ("*" in key and fnmatch.fnmatchcase(relative, key)))
                entry = registry["paths"][key]
                if entry["retention"] == "per child":
                    continue
                size, files, newest = usage(home / relative)
                flag = "NO-RULE" if entry["retention"] is None else entry["life"]
                print(f"{human(size):>7} {files:>8} {int((now - newest) / DAY):>4}d {flag:<8} {relative}  [{entry['retention'] or 'no retention rule'}]")
            return 0
        if args.command == "prune":
            if args.apply:
                plan = json.loads(args.apply.read_text())
                if args.confirm != plan_digest(plan):
                    raise LayoutError("--confirm must be the plan's digest")
                target = Path(plan["home"])
                for row in plan["candidates"]:
                    path = target / row["path"]
                    if not path.exists() and not path.is_symlink():
                        continue
                    size, files, newest = usage(path)
                    if (files, int(newest)) != (row["files"], row["newest"]):
                        raise LayoutError(f"{row['path']} changed since the plan; plan again")
                    shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
                    print(f"deleted {row['path']} ({human(row['bytes'])})")
                return 0
            if not args.home or not args.plan:
                raise LayoutError("prune needs --home and --plan OUT, or --apply PLAN --confirm SHA256")
            plan = {"version": 1, "home": str(home), "candidates": candidates(home, registry["paths"], args.files_older_than, time.time())}
            args.plan.parent.mkdir(parents=True, exist_ok=True)
            args.plan.write_text(json.dumps(plan, indent=2) + "\n")
            for row in plan["candidates"]:
                print(f"{human(row['bytes']):>7} {row['path']}  ({row['reason']})")
            total = sum(row["bytes"] for row in plan["candidates"])
            print(f"plan {args.plan}: {len(plan['candidates'])} candidate(s), {human(total)}; digest {plan_digest(plan)}")
            print(f"apply (maintainer): scripts/tron home-layout prune --apply {args.plan} --confirm {plan_digest(plan)}")
            return 0
        for line in migrate(home, registry, args.rollback):
            print(line)
        print(f"home-layout {'rollback' if args.rollback else 'migrate'} {home}: done")
        return 0
    except LayoutError as error:
        print(f"home-layout: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
