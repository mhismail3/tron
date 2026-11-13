"""Plans and performs the offline runtime-layout address rewrites."""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import stat
import sys
import terminal_layout
from pathlib import Path
from runtime_rewrites import rewrite

MARKER = b"retired by layout 2; merge main\n"
ROOTS = {"gateway", "mac-terminal", "ios-builds"}
TERMINAL = {"complete", "completed", "failed", "partial", "stopped", "rejected"}


def enabled(registry):
    return "state/layout.json" in registry["paths"] and {"from": "gateway", "to": "state"} in registry["retired"]


def marker(path):
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size != len(MARKER):
            return False
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            return stream.read(len(MARKER) + 1) == MARKER
    except (FileNotFoundError, NotADirectoryError):
        return False


def prefixes(home, registry, reverse=False):
    pairs = [(os.path.join(home, row["from"]), os.path.join(home, row["to"])) for row in [*registry["retired"], *extra_moves({"home": home}, registry)]
             if not row["from"].startswith("~/") and not row["to"].startswith("~/") and "*" not in row["from"]]
    return sorted(((new, old) if reverse else (old, new) for old, new in pairs), key=lambda pair: -len(pair[0]))


def replace_prefix(value, pairs):
    for old, new in pairs:
        if value == old or value.startswith(old + "/"):
            return new + value[len(old):]
    return value


def encode_cwd(value):
    return "--" + re.sub(r"[/\\:]", "-", re.sub(r"^[/\\]", "", value)) + "--"


def extra_moves(report, registry):
    if not enabled(registry):
        return []
    home = report["home"]
    old = encode_cwd(os.path.join(home, "gateway/home/workspace"))
    new = encode_cwd(os.path.join(home, "state/home/workspace"))
    return [{"from": "agent/sessions/" + old, "to": "agent/sessions/" + new}]


def files(l, root, patterns):
    if l.observed(str(root)) is None:
        return
    count = 0
    pending = [(Path(root), tuple(tuple(pattern.split("/")) for pattern in patterns))]
    while pending:
        directory, remaining = pending.pop()
        fd = l.open_home(str(directory))
        try:
            with os.scandir(fd) as entries:
                children = sorted(entries, key=lambda item: item.name)
            for child in children:
                count += 1
                if count > 100000:
                    raise l.LayoutError("rewrite_file_budget_exceeded")
                matches = [pattern[1:] for pattern in remaining if fnmatch.fnmatchcase(child.name, pattern[0])]
                if not matches:
                    continue
                path = directory / child.name
                info = child.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    raise l.LayoutError("rewrite_symlink")
                if stat.S_ISDIR(info.st_mode):
                    if () in matches and path.name == "status.json":
                        yield path
                    if any(matches):
                        pending.append((path, tuple(pattern for pattern in matches if pattern)))
                elif stat.S_ISREG(info.st_mode):
                    if () in matches:
                        yield path
                else:
                    raise l.LayoutError("rewrite_unsafe_type")
        finally:
            os.close(fd)


def physical(l, home, old, new):
    info = l.observed(os.path.join(home, old))
    return Path(home) / (old if info is not None and stat.S_ISDIR(info.st_mode) else new)


def read_record(l, path, session=False):
    if l.linked_component(str(path), "/"):
        raise l.LayoutError("rewrite_symlink_component")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise l.LayoutError("rewrite_unowned_file")
        data = stream.readline(65537) if session else stream.read(16777217)
        if len(data) > (65536 if session else 16777216):
            raise l.LayoutError("rewrite_record_budget_exceeded")
    return data, info


def file_sha(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    digest = hashlib.sha256()
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("rewrite_unsafe_type")
        for chunk in iter(lambda: stream.read(1048576), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_record(path, home, registry):
    return os.path.relpath(replace_prefix(str(path), prefixes(home, registry)), home)


def receipt(record):
    return {key: record[key] for key in ("kind", "before", "after", "source_sha256")}


def reserve_journal(l, report, registry, journal, layout, reverse):
    planned = {canonical_record(record["file"], report["home"], registry): receipt(record)
               for record, _ in rewrites(l, report, registry, reverse, layout)}
    if reverse and (layout["rewrites"].keys() | layout["inverse"].keys()) - planned.keys():
        raise l.LayoutError("rewrite_selection_changed")
    forward = layout["rewrites"] if reverse else {**layout["rewrites"], **planned}
    inverse = {**layout["inverse"], **planned} if reverse else {**forward, **layout["inverse"]}
    terminal = {phase: layout["terminal"].get(phase, {"enabled": True, "sha256": "0" * 64, "source": "canonical" if phase == "rollback" else "legacy"}) for phase in ("forward", "rollback")}
    projected = {**layout, "rewrites": forward, "inverse": inverse, "terminal": terminal}
    l.journal_bytes({**journal, "layouts": {**journal["layouts"], report["home"]: projected}})


def backup_root(report, layout, reverse=False):
    home = report["home"]
    tag = "debug" if Path(home).name == ".tron-dev" else "stable" if Path(home).name == ".tron" else hashlib.sha256(os.fsencode(home)).hexdigest()[:16]
    root = Path(report["user_home"]) / ".tron-maintenance/backups" / ("2026-11-12-2500-layout-v2-" + tag) / layout["id"] / ("rollback" if reverse else "forward")
    return root


def receipt_paths(report, layout, relative, record, reverse=False):
    before = backup_root(report, layout, reverse) / relative
    return before, before if record["before"] == record["after"] else Path(str(before) + ".layout-after")


def snapshots(l, record, paths):
    backup, after_backup = paths
    if file_sha(backup) != record["source_sha256"]:
        raise l.LayoutError("rewrite_backup_changed")
    before, _ = read_record(l, backup, record["kind"] == "session")
    after, _ = read_record(l, after_backup, record["kind"] == "session" and after_backup == backup)
    if hashlib.sha256(before).hexdigest() != record["before"] or hashlib.sha256(after).hexdigest() != record["after"]:
        raise l.LayoutError("rewrite_backup_changed")
    return before, after


def carried_status(l, path):
    info = os.lstat(path)
    if stat.S_ISDIR(info.st_mode):
        return {"type": "directory", "reason": "opaque-status-directory", "sha256": None}
    if info.st_size > 16777216:
        return {"type": "file", "reason": "opaque-oversized-status", "sha256": file_sha(path)}
    data, _ = read_record(l, path)
    try:
        value = json.loads(data)
        if not isinstance(value, dict) or not isinstance(value.get("state"), str):
            raise ValueError("status_shape")
        pending = [value]
        interrupted = False
        while pending:
            item = pending.pop()
            if not isinstance(item, dict):
                raise ValueError("status_shape")
            if item.get("state", item.get("status")) not in TERMINAL:
                interrupted = True
            for key in ("steps", "children"):
                children = item.get(key, [])
                if not isinstance(children, list):
                    raise ValueError("status_shape")
                pending.extend(children)
        if not interrupted:
            return None
        reason = "interrupted-at-migration"
    except (ValueError, UnicodeError, RecursionError):
        reason = "malformed-status"
    return {"type": "file", "reason": reason, "sha256": hashlib.sha256(data).hexdigest()}


def carried_records(l, report, registry):
    subagents = physical(l, report["home"], "internal/subagents", "state/subagents")
    patterns = ("async-subagent-runs/*/status.json", "nested-subagent-runs/*/*/status.json")
    result = []
    for path in files(l, subagents, patterns):
        record = carried_status(l, path)
        if record is not None:
            result.append({"path": canonical_record(path, report["home"], registry), **record})
    return sorted(result, key=lambda record: record["path"])


def rewrites(l, report, registry, reverse=False, layout=None):
    if not enabled(registry):
        return
    home = report["home"]
    pairs = prefixes(home, registry, reverse)
    state = physical(l, home, "gateway", "state")
    subagents = physical(l, home, "internal/subagents", "state/subagents")
    terminal = physical(l, home, "mac-terminal", "state/mac-terminal")
    selections = [(path, "session") for path in files(l, Path(home) / "agent/sessions", ("*.jsonl", "*/*.jsonl"))]
    selections += [(Path(home) / "agent/trust.json", "trust"), (state / "settings/observed.json", "observed")]
    selections += [(path, "upload") for path in files(l, state / "uploads", ("*/metadata.json",))]
    selections += [(path, "target") for path in files(l, state / "home/tasks", ("*.json",))]
    selections += [(path, "mission") for path in files(l, Path(home) / "agent/missions", ("*.json", "*.jsonl", "index/*.json", "projects/*/*.json",
                                                                                    "index/*/state.json", "projects/*/*/state.json"))]
    run_names = ("run-fanout-budget.json", "process-terminal-candidate.json", "status.json", "recovery-descriptor.json")
    patterns = ["async-cfg-*.json", *(f"{folder}/{name}" for folder in ("async-subagent-runs/*", "nested-subagent-runs/*/*") for name in run_names)]
    for folder in ("async-subagent-results", "async-subagent-results/nested/*"):
        patterns.extend(f"{folder}/{suffix}" for suffix in ("*.json", "result-index/runs/*.json", "result-index/sessions/*/*.json",
                                                           "result-index/tool-calls/*/*.json", "result-index/observers/*/*.json", "result-pending/*/*.json"))
    for path in files(l, subagents, patterns):
        if path.name == "run-fanout-budget.json":
            selections.append((path, "budget"))
        elif path.name == "process-terminal-candidate.json":
            selections.append((path, "candidate"))
        elif (path.name in {"status.json", "recovery-descriptor.json"} or re.fullmatch(r"async-cfg-.*\.json", path.name)
              or path.suffix == ".json" and path.is_relative_to(subagents / "async-subagent-results")):
            selections.append((path, "subagent_config" if re.fullmatch(r"async-cfg-.*\.json", path.name) else "subagent"))
    selections.append((terminal / "sshd_config", "terminal"))
    trust_digest = None
    for path, kind in selections:
        if l.observed(str(path)) is None:
            continue
        if kind == "subagent" and path.name == "status.json" and carried_status(l, path) is not None:
            continue
        data, info = read_record(l, path, kind == "session")
        text = data.decode("utf-8")
        key = canonical_record(path, home, registry)
        forward = layout["rewrites"].get(key) if layout else None
        phase = layout["inverse"] if reverse and layout else layout["rewrites"] if layout else {}
        saved = phase.get(key)
        before = after = None
        if reverse and forward:
            paths = receipt_paths(report, layout, key, forward)
            if layout["direction"] == "rollback-partial" and l.observed(str(paths[0])) is None:
                if file_sha(path) != forward["source_sha256"]:
                    raise l.LayoutError("rewrite_backup_changed")
                before = after = data
            else:
                before, after = snapshots(l, forward, paths)
        if kind != "terminal":
            parsed = [json.loads(line) for line in text.splitlines()] if kind == "mission" and path.suffix == ".jsonl" else json.loads(text)
            if kind != "mission" and not isinstance(parsed, dict):
                raise l.LayoutError("invalid_rewrite_document")
            if kind == "session" and parsed.get("type") != "session":
                raise l.LayoutError("invalid_session_header")
        if reverse and layout["direction"] == "rollback-partial" and forward is None:
            output = data
        elif reverse and forward and hashlib.sha256(data).hexdigest() == forward["before"]:
            output = data
        elif reverse and forward and hashlib.sha256(data).hexdigest() == forward["after"]:
            output = before
        else:
            if kind == "mission" and path.suffix == ".jsonl":
                old_lines = before.decode().splitlines(keepends=True) if before is not None else []
                new_lines = after.decode().splitlines(keepends=True) if after is not None else []
                changed = "".join(rewrite(line, kind, pairs, old_lines[index] if index < len(old_lines) else None, new_lines[index] if index < len(new_lines) else None) for index, line in enumerate(text.splitlines(keepends=True)))
            else:
                changed = rewrite(text, kind, pairs, before.decode() if before is not None else None, after.decode() if after is not None else None, trust_digest)
            output = changed.encode("utf-8")
        if kind == "trust":
            trust_digest = (saved["before"] if saved else hashlib.sha256(data).hexdigest(), hashlib.sha256(output).hexdigest())
        if output == data and forward is None and saved is None:
            if reverse or rewrite(text, kind, prefixes(home, registry, True)) == text:
                continue
        yield {"file": str(path), "kind": kind, "device": info.st_dev, "inode": info.st_ino,
               "before": hashlib.sha256(data).hexdigest(), "after": hashlib.sha256(output).hexdigest(),
               "source_sha256": file_sha(path)}, output


def plan(l, report, registry):
    if not enabled(registry):
        return
    report["carried_lifecycle_records"] = carried_records(l, report, registry)
    report["rewrites"] = [record for record, _ in rewrites(l, report, registry) if record["before"] != record["after"]]
    terminal_layout.plan(l, sys.modules[__name__], report, physical(l, report["home"], "mac-terminal", "state/mac-terminal"))
    settings = Path(report["home"]) / "agent/settings.json"
    if l.observed(str(settings)) is not None:
        data, _ = read_record(l, settings)
        value = json.loads(data)
        if not isinstance(value, dict) or not isinstance(value.get("setup", {}), dict):
            raise l.LayoutError("invalid_settings_document")
        if value.get("setup", {}).get("sessionDir") or value.get("sessionDir"):
            raise l.LayoutError("relocated_sessions_directory")
    for old, new in prefixes(report["home"], registry):
        if old.startswith(report["home"] + "/gateway") and not new.startswith(report["home"] + "/state"):
            continue
        if old != report["home"] + "/gateway" or not os.path.isdir(old):
            continue
        pending = [Path(old)]
        while pending:
            directory = pending.pop()
            fd = l.open_home(str(directory))
            try:
                with os.scandir(fd) as entries:
                    children = sorted(entries, key=lambda item: item.name)
                for child in children:
                    path = directory / child.name
                    relative = str(path.relative_to(report["home"]))
                    if any(row["from"] == relative or relative.startswith(row["from"] + "/") for row in registry["retired"] if row["to"].startswith("~/")):
                        continue
                    relocated = os.path.relpath(replace_prefix(str(path), prefixes(report["home"], registry)), report["home"])
                    key, classification = l.registration(registry["paths"], relocated)
                    if key is None:
                        raise l.LayoutError("unregistered_relocated_entry:" + relative)
                    if child.is_dir(follow_symlinks=False) and classification != "delegated" and not registry["paths"][key].get("subtree"):
                        pending.append(path)
            finally:
                os.close(fd)
    roots = [row for row in report["moves"] if row["from"] in ROOTS]
    stamp = Path(report["home"]) / "state/layout.json"
    if any(row["state"] == "done" for row in roots) and not any(row["state"] == "pending" for row in report["moves"]) and not stamp_valid(l, stamp):
        report["state"] = "applied_without_stamp"


def stamp_valid(l, stamp):
    if l.observed(str(stamp)) is None:
        return False
    data, _ = read_record(l, stamp)
    return json.loads(data) == {"version": 2}


def clone(l, source, destination):
    l.private_directory(destination.parent)
    if destination.exists():
        raise l.LayoutError("rewrite_backup_exists")
    library = l.ctypes.CDLL(None, use_errno=True)
    clonefile = library.clonefile
    clonefile.argtypes = [l.ctypes.c_char_p, l.ctypes.c_char_p, l.ctypes.c_int]
    clonefile.restype = l.ctypes.c_int
    if clonefile(os.fsencode(source), os.fsencode(destination), 0) != 0:
        raise OSError(l.ctypes.get_errno(), "clonefile")
    os.chmod(destination, 0o600)
    fd = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    l.fsync_directory(str(destination.parent))


def validate_journal(l, journal, registry, report):
    for home, layout in journal["layouts"].items():
        if (not isinstance(home, str) or not os.path.isabs(home) or os.path.abspath(home) != home
                or not isinstance(layout, dict) or layout.keys() != {"id", "direction", "rewrites", "inverse", "parents", "slots", "terminal", "carried_lifecycle_records"}
                or not isinstance(layout["id"], str) or re.fullmatch(r"[a-f0-9]{32}", layout["id"]) is None
                or layout["direction"] not in {"forward", "applied", "rollback", "rollback-partial"}
                or not isinstance(layout["rewrites"], dict) or not isinstance(layout["inverse"], dict) or not isinstance(layout["parents"], list)
                or not isinstance(layout["slots"], list)):
            raise l.LayoutError("invalid_layout_journal")
        expected = [*registry["retired"], *extra_moves({**report, "home": home}, registry)]
        if any(slot not in expected for slot in layout["slots"]):
            raise l.LayoutError("invalid_layout_journal")
        if any(not isinstance(parent, str) or not parent.startswith(home + "/") or os.path.abspath(parent) != parent for parent in layout["parents"]):
            raise l.LayoutError("invalid_layout_journal")
        carried = layout["carried_lifecycle_records"]
        if not isinstance(carried, list):
            raise l.LayoutError("invalid_layout_journal")
        for record in carried:
            if (not isinstance(record, dict) or record.keys() != {"path", "type", "reason", "sha256"}
                    or not isinstance(record["path"], str) or not l.relative_parts(record["path"])
                    or not record["path"].startswith("state/subagents/") or not record["path"].endswith("/status.json")
                    or record["type"] not in {"file", "directory"}
                    or record["reason"] not in {"interrupted-at-migration", "malformed-status", "opaque-status-directory", "opaque-oversized-status"}
                    or (record["sha256"] is not None if record["type"] == "directory" else not isinstance(record["sha256"], str) or re.fullmatch(r"[a-f0-9]{64}", record["sha256"]) is None)):
                raise l.LayoutError("invalid_layout_journal")
        terminal_layout.validate(l, layout["terminal"])
        for relative, record in [*layout["rewrites"].items(), *layout["inverse"].items()]:
            if (not l.relative_parts(relative) or not isinstance(record, dict)
                    or record.keys() != {"kind", "before", "after", "source_sha256"}
                    or record["kind"] not in {"session", "trust", "observed", "upload", "target", "mission", "subagent", "subagent_config", "terminal", "budget", "candidate"}
                    or any(not isinstance(record[key], str) or re.fullmatch(r"[a-f0-9]{64}", record[key]) is None for key in ("before", "after", "source_sha256"))):
                raise l.LayoutError("invalid_layout_journal")


def owned_slot(l, journal, report, row):
    if journal is None or row["from"].startswith("~/") or row["to"].startswith("~/"):
        return False
    layout = journal["layouts"].get(report["home"])
    pair = {"from": row["from"], "to": row["to"]}
    if layout is None or pair not in layout["slots"]:
        return False
    if layout["direction"] == "applied" and stamp_valid(l, Path(report["home"]) / "state/layout.json"):
        return True
    return row["destination"] in layout["parents"] and row["identity"] is not None and row["identity"]["type"] == "directory"


def mutable_claim(l, journal, row):
    layout = journal["layouts"].get(row["home"])
    if (layout is None or layout["direction"] not in {"forward", "applied"} or row["from"].startswith("~/") or row["to"].startswith("~/")
            or {"from": row["from"], "to": row["to"]} not in layout["slots"]
            or not stamp_valid(l, Path(row["home"]) / "state/layout.json")):
        return False
    before, after = l.observed(row["source"]), l.observed(row["destination"])
    if row["from"] in ROOTS and marker(row["source"]):
        before = None
    if before is not None or l.linked_component(row["source"], "/") or l.linked_component(row["destination"], "/"):
        raise l.LayoutError("move_identity_changed")
    if after is not None and l.metadata(after)["type"] != row["identity"]["type"]:
        raise l.LayoutError("move_identity_changed")
    return True


def adopt_current(l, journal, report):
    for row in list(journal["moves"]):
        if row["home"] == report["home"] and mutable_claim(l, journal, row):
            current = l.observed(row["destination"])
            if current is None:
                journal["moves"].remove(row)
            else:
                row["identity"] = l.metadata(current)


def prepare(l, report, registry, journal, journal_path, reverse, locks, guards):
    if not enabled(registry):
        return
    home = report["home"]
    layout = journal["layouts"].get(home)
    if layout is None:
        if reverse:
            raise l.LayoutError("no_layout_journal")
        if l.observed(os.path.join(home, "gateway/layout.json")) is not None:
            raise l.LayoutError("unowned_layout_stamp")
        parents = set()
        for row in report["moves"]:
            parent = Path(row["destination"]).parent
            while str(parent).startswith(home + "/") and l.observed(str(parent)) is None:
                parents.add(str(parent))
                parent = parent.parent
        layout = {"id": os.urandom(16).hex(), "direction": "forward", "rewrites": {}, "inverse": {}, "terminal": {}, "parents": sorted(parents),
                  "carried_lifecycle_records": report["carried_lifecycle_records"],
                  "slots": [{"from": row["from"], "to": row["to"]} for row in report["moves"] if not row["from"].startswith("~/") and not row["to"].startswith("~/")]}
        journal["layouts"][home] = layout
    if not reverse and layout["direction"] == "applied":
        for key, saved in layout["rewrites"].items():
            snapshots(l, saved, receipt_paths(report, layout, key, saved))
        terminal_layout.validate_backups(l, sys.modules[__name__], report, layout)
        return
    if reverse and layout["direction"] == "applied":
        for key, saved in layout["rewrites"].items():
            snapshots(l, saved, receipt_paths(report, layout, key, saved))
        terminal_layout.validate_backups(l, sys.modules[__name__], report, layout)
    if reverse and not layout["direction"].startswith("rollback"):
        layout["direction"] = "rollback" if stamp_valid(l, Path(home) / "state/layout.json") else "rollback-partial"
    if reverse:
        owned = {row["destination"] for row in journal["moves"]}
        for row in report["moves"]:
            if row["state"] == "done" and row["destination"] not in owned and {"from": row["from"], "to": row["to"]} in layout["slots"]:
                journal["moves"].append({**row, "home": home})
        order = {(row["from"], row["to"]): index for index, row in enumerate(report["moves"])}
        owned = iter(sorted((row for row in journal["moves"] if row["home"] == home), key=lambda row: order[row["from"], row["to"]]))
        journal["moves"] = [next(owned) if row["home"] == home else row for row in journal["moves"]]
    if not reverse and layout["direction"].startswith("rollback"):
        raise l.LayoutError("migration_direction_changed")
    reserve_journal(l, report, registry, journal, layout, reverse)
    l.write_journal(journal_path, journal)
    terminal_layout.lock(l, sys.modules[__name__], report, locks, guards)
    directory = Path(home) / "state" if reverse else physical(l, home, "gateway", "state")
    if not reverse or l.observed(str(directory)) is not None:
        l.private_directory(directory)
        stamp = directory / "layout.json"
        if l.observed(str(stamp)) is not None and json.loads(read_record(l, stamp)[0]) not in ({"version": 2}, {"version": 2, "migrating": True}):
            raise l.LayoutError("layout_stamp_changed")
        l.write_journal(stamp, {"version": 2, "migrating": True})
    phase = layout["inverse"] if reverse else layout["rewrites"]
    for record, output in rewrites(l, report, registry, reverse, layout):
        path = Path(record["file"])
        key = canonical_record(path, home, registry)
        saved = phase.get(key)
        if saved is not None:
            if record["before"] == saved["after"] and saved["before"] != saved["after"]:
                snapshots(l, saved, receipt_paths(report, layout, key, saved, reverse))
                continue
            if record["before"] != saved["before"] or record["after"] != saved["after"] or record["source_sha256"] != saved["source_sha256"]:
                raise l.LayoutError("rewrite_changed")
        else:
            saved = receipt(record)
            phase[key] = saved
            l.write_journal(journal_path, journal)
        destination, after_path = receipt_paths(report, layout, key, saved, reverse)
        if l.observed(str(destination)) is None:
            clone(l, path, destination)
        if file_sha(destination) != saved["source_sha256"]:
            raise l.LayoutError("rewrite_backup_changed")
        if l.observed(str(after_path)) is None:
            fd = os.open(after_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(output)
                stream.flush()
                os.fsync(stream.fileno())
            l.fsync_directory(str(after_path.parent))
        snapshots(l, saved, (destination, after_path))
    def fence():
        for guard in guards:
            guard()
    terminal_layout.retire(l, sys.modules[__name__], report, layout, journal, journal_path, reverse, fence)
    for record, output in rewrites(l, report, registry, reverse, layout):
        path = Path(record["file"])
        saved = phase.get(canonical_record(path, home, registry))
        if saved is None:
            raise l.LayoutError("rewrite_changed")
        if record["before"] == saved["after"] and saved["before"] != saved["after"]:
            continue
        if record["before"] != saved["before"] or record["after"] != saved["after"] or record["source_sha256"] != saved["source_sha256"]:
            raise l.LayoutError("rewrite_changed")
        if record["before"] == record["after"]:
            continue
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        temporary = path.with_name(path.name + ".layout-v2-partial")
        try:
            with os.fdopen(fd, "rb") as source:
                before = os.fstat(source.fileno())
                if (before.st_dev, before.st_ino) != (record["device"], record["inode"]):
                    raise l.LayoutError("rewrite_identity_changed")
                out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, stat.S_IMODE(before.st_mode))
                os.fchmod(out, stat.S_IMODE(before.st_mode))
                with os.fdopen(out, "wb") as target:
                    target.write(output)
                    if record["kind"] == "session":
                        source.readline(65537)
                        body = hashlib.sha256()
                        for chunk in iter(lambda: source.read(1048576), b""):
                            body.update(chunk)
                            target.write(chunk)
                    target.flush()
                    os.fsync(target.fileno())
                after = os.fstat(source.fileno())
                if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                    raise l.LayoutError("rewrite_changed")
                if record["kind"] == "session":
                    with temporary.open("rb") as verify:
                        verify.readline(65537)
                        digest = hashlib.sha256()
                        for chunk in iter(lambda: verify.read(1048576), b""):
                            digest.update(chunk)
                    if digest.digest() != body.digest():
                        raise l.LayoutError("session_body_changed")
                fence()
                os.replace(temporary, path)
                l.fsync_directory(str(path.parent))
        finally:
            if l.observed(str(temporary)) is not None:
                temporary.unlink()
        l.write_journal(journal_path, journal)


def before_move(l, row, reverse):
    if not reverse and row["from"] == "gateway":
        stamp = Path(row["source"]) / "layout.json"
        partial = {"version": 2, "migrating": True}
        if l.observed(str(stamp)) is None:
            l.write_journal(stamp, partial)
        elif json.loads(read_record(l, stamp)[0]) != partial:
            raise l.LayoutError("unowned_layout_stamp")
    if reverse and row["from"] == "gateway":
        stamp = Path(row["destination"]) / "layout.json"
        if l.observed(str(stamp)) is not None:
            if not stamp_valid(l, stamp) and json.loads(read_record(l, stamp)[0]) != {"version": 2, "migrating": True}:
                raise l.LayoutError("layout_stamp_changed")
            stamp.unlink()
            l.fsync_directory(str(stamp.parent))
    if reverse and row["from"] in ROOTS and marker(row["source"]):
        os.unlink(row["source"])
        l.fsync_directory(os.path.dirname(row["source"]))


def after_move(l, row, reverse):
    if reverse and row["from"] == "gateway":
        stamp = Path(row["source"]) / "layout.json"
        if l.observed(str(stamp)) is not None:
            if json.loads(read_record(l, stamp)[0]) not in ({"version": 2}, {"version": 2, "migrating": True}):
                raise l.LayoutError("layout_stamp_changed")
            stamp.unlink()
            l.fsync_directory(str(stamp.parent))
    if not reverse and row["from"] in ROOTS and not marker(row["source"]):
        fd = os.open(row["source"], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(MARKER)
            stream.flush()
            os.fsync(stream.fileno())
        l.fsync_directory(os.path.dirname(row["source"]))


def finish(l, report, registry, journal, journal_path, reverse):
    if not enabled(registry):
        return
    home = report["home"]
    stamp = Path(home) / "state/layout.json"
    if reverse or journal["layouts"][home]["direction"] != "applied":
        terminal_layout.finish(l, sys.modules[__name__], report, journal["layouts"][home], reverse)
    if not reverse:
        l.private_directory(stamp.parent)
        journal["layouts"][home]["direction"] = "applied"
        l.write_journal(journal_path, journal)
        l.write_journal(stamp, {"version": 2})
        return
    else:
        for parent in sorted(journal["layouts"][home]["parents"], key=lambda path: -len(path)):
            try:
                os.rmdir(parent)
            except (FileNotFoundError, OSError):
                pass
        del journal["layouts"][home]
    l.write_journal(journal_path, journal)
