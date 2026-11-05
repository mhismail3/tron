"""Purpose cards: what each module is for, who reaches it and which checks go red when it breaks.

`scripts/tron ownership` runs these checks with the layout rules (tools/ownership/README.md,
"Purpose cards"). A card is three manifest keys beside `owns`: `purpose`, `interfaces` (the
module's inbound contracts and the modules or outside parties that use them) and `uses` (the
outside contracts it depends on). Its guardians are its owned tests plus its `verify` commands.
References between modules are found in tracked file contents, so a card cannot omit a consumer,
keep a consumer that no longer names it, or name a path it does not own. Modules listed in
root.module.json `layout.uncarded` are exempt; that list only shrinks.
"""

from __future__ import annotations

import json
import re
from pathlib import PurePosixPath

KINDS = {"exec", "import", "read", "cli", "env", "wire", "fs", "launchd"}
INTERFACE_FIELDS = {"name", "kind", "consumers", "external"}
USE_FIELDS = {"name", "kind", "why"}
TEST_NAME = re.compile(r"(^test[-_].+\.(py|sh|js|mjs)$)|(\.test\.(ts|mjs|js)$)|(Tests?\.swift$)")
TOKEN = re.compile(r"[A-Za-z0-9_.$@{}/+-]+")
# `$ROOT/`, `${ROOT}/`, `$(dirname "$0")/`, `./` and `/` in front of a repo path.
LEAD = re.compile(r"^(\./|/|\$\{?[A-Za-z_]+\}?/|\$\([^)]*\)/|@/)+")
PY_JOIN = re.compile(r"\"\s*/\s*\"")
PY_IMPORT = re.compile(r"^\s*(?:from|import)\s+([A-Za-z_]\w*)", re.M)
MAX_BYTES = 2_000_000


def is_test(path: str) -> bool:
    return bool(TEST_NAME.search(path.rsplit("/", 1)[-1]))


def is_doc(path: str) -> bool:
    return path.endswith(".md")


def is_source(path: str) -> bool:
    """A file whose references count: prose and the manifests themselves do not."""
    return not is_doc(path) and not path.endswith(".module.json")


def directories(paths: list[str], owner: dict[str, str]) -> dict[str, str]:
    """Directories (two or more segments deep) whose every tracked file has the same owner."""
    seen: dict[str, set] = {}
    for path in paths:
        parts = path.split("/")
        for depth in range(2, len(parts)):
            seen.setdefault("/".join(parts[:depth]), set()).add(owner.get(path))
    return {folder: next(iter(owners)) for folder, owners in seen.items() if len(owners) == 1 and None not in owners}


def normal(path: str) -> str | None:
    parts: list[str] = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return "/".join(parts)


def references(paths: list[str], read, owner: dict[str, str]) -> dict[str, set[str]]:
    """For each tracked source file, the tracked files and single-owner directories its text names.

    A name counts when it resolves from the repository root, the file's package
    (`packages/<pkg>/`) or the file's own directory; a bare file name counts in its own
    directory when it is distinctive (has `-`, `_` or `.`), and a Python `import x` counts for
    `x.py` beside it. Matching is textual, so a reference in a comment counts too: it is
    still something a move must update.
    """
    targets = {path for path in paths if not is_doc(path)}
    folders = directories(paths, owner)
    by_dir: dict[str, dict[str, str]] = {}
    for path in targets:
        folder, _, name = path.rpartition("/")
        by_dir.setdefault(folder, {})[name] = path
    found: dict[str, set[str]] = {}
    for source in paths:
        if not is_source(source):
            continue
        try:
            blob = read(source)
        except OSError:
            continue
        if len(blob) > MAX_BYTES or b"\0" in blob[:8000]:
            continue
        text = blob.decode("utf-8", "replace")
        if source.endswith(".py"):
            text = PY_JOIN.sub("/", text)
        folder = source.rpartition("/")[0]
        parts = source.split("/")
        package = "/".join(parts[:2]) if parts[0] == "packages" and len(parts) > 2 else None
        siblings = by_dir.get(folder, {})
        hits: set[str] = set()
        for token in set(TOKEN.findall(text)):
            if "/" not in token:
                name = token.rstrip(".,;:")
                if ("-" in name or "_" in name or "." in name) and name in siblings:
                    hits.add(siblings[name])
                continue
            stripped = LEAD.sub("", token).rstrip(".,;:").rstrip("/")
            if not stripped:
                continue
            bases = [""] + ([package + "/"] if package else []) + ([folder + "/"] if folder else [])
            for base in reversed(bases):  # nearest first: own directory, package, root
                candidate = normal(base + stripped)
                if candidate and (candidate in targets or candidate in folders):
                    hits.add(candidate)
                    break
        if source.endswith(".py"):
            hits.update(siblings[f"{name}.py"] for name in PY_IMPORT.findall(text) if f"{name}.py" in siblings)
        hits.discard(source)
        if hits:
            found[source] = hits
    return found


def owner_of(target: str, owner: dict[str, str], folders: dict[str, str]) -> str | None:
    return owner.get(target) or folders.get(target)


def covers(name: str, target: str) -> bool:
    return target == name or target.startswith(name + "/")


def word(name: str):
    return re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")


def module_edges(refs: dict[str, set[str]], owner: dict[str, str], folders: dict[str, str]) -> dict:
    """provider module -> consumer module -> {referenced target: [consumer files]}."""
    edges: dict[str, dict[str, dict[str, list[str]]]] = {}
    for source, targets in refs.items():
        for target in targets:
            provider = owner_of(target, owner, folders)
            if provider and provider != owner.get(source):
                edges.setdefault(provider, {}).setdefault(owner[source], {}).setdefault(target, []).append(source)
    return edges


def problems(modules: dict[str, dict], paths: list[str], read, uncarded: list[str]) -> list[str]:
    """Card violations. `modules` maps manifest path to {id, data, owned}."""
    out: list[str] = []
    ids = {module["id"]: manifest for manifest, module in modules.items()}
    owner = {path: module["id"] for module in modules.values() for path in module["owned"]}
    for entry in uncarded:
        if entry not in ids:
            out.append(f"layout: root.module.json layout.uncarded lists {entry!r}, which is not a module; remove it")
    exempt = set(uncarded)
    folders = directories(paths, owner)
    refs = references(paths, read, owner)
    edges = module_edges(refs, owner, folders)
    texts: dict[str, str] = {}

    def text(path: str) -> str:
        if path not in texts:
            try:
                blob = read(path)
            except OSError:
                blob = b""
            texts[path] = "" if b"\0" in blob[:8000] else blob.decode("utf-8", "replace")
        return texts[path]

    def module_problems(manifest: str, module: dict) -> list[str]:
        key, data, owned = module["id"], module["data"], module["owned"]
        out: list[str] = []
        where = f"{manifest}: card"
        if not (isinstance(data.get("purpose"), str) and data["purpose"].strip()):
            out.append(f"{where} needs a one-sentence \"purpose\" (what the module is for, who runs it)")
        tests = [path for path in owned if is_test(path)]
        if not tests and not data.get("verify"):
            out.append(f"{where} has no guardian: own a test that fails when the module breaks, or declare its "
                       "\"verify\" command")
        interfaces = data.get("interfaces")
        if not isinstance(interfaces, list) or not interfaces:
            out.append(f"{where} needs \"interfaces\": the names other modules or outside parties use to reach it; "
                       "a module nothing reaches is dead code to delete")
            interfaces = []
        declared: dict[str, set[str]] = {}
        named: list[str] = []
        for index, interface in enumerate(interfaces):
            label = f"{where} interfaces[{index}]"
            if not isinstance(interface, dict):
                out.append(f"{label} must be an object")
                continue
            for field in sorted(set(interface) - INTERFACE_FIELDS):
                out.append(f"{label} has unknown key {field!r}")
            name, kind = interface.get("name"), interface.get("kind")
            if not (isinstance(name, str) and name.strip()):
                out.append(f"{label} needs a non-empty \"name\"")
                continue
            label = f"{where} interface {name!r}"
            if kind not in KINDS:
                out.append(f"{label}: kind must be one of {', '.join(sorted(KINDS))}")
            consumers = interface.get("consumers", [])
            external = interface.get("external")
            if not isinstance(consumers, list) or not all(isinstance(c, str) for c in consumers) or len(set(consumers)) != len(consumers):
                out.append(f"{label}: consumers must be a list of distinct module ids")
                consumers = []
            if external is not None and not (isinstance(external, str) and external.strip()):
                out.append(f"{label}: external must name who outside the repository uses it")
            if not consumers and not external:
                out.append(f"{label}: list its \"consumers\" (module ids) or say who uses it in \"external\"")
            is_path = name in owner or name in folders
            if "/" in name and not is_path:
                users = sorted({source for module_edges in edges.values() for sources in module_edges.values()
                                for target, files in sources.items() if target == name for source in files})
                out.append(f"{label} is not a tracked path or directory" +
                           (f"; still named by {', '.join(users)}" if users else "") +
                           ": update the card to the path the module now owns, and its consumers with it")
                continue
            if is_path and owner_of(name, owner, folders) != key:
                out.append(f"{label} is owned by {owner_of(name, owner, folders)}, not this module")
                continue
            if not is_path and not any(word(name).search(text(path)) for path in owned):
                out.append(f"{label} does not occur in any file this module owns")
            named.append(name)
            for consumer in consumers:
                if consumer == key or consumer not in ids:
                    out.append(f"{label}: consumer {consumer!r} is not another module id")
                    continue
                declared.setdefault(consumer, set()).add(name)
                if is_path:
                    reached = edges.get(key, {}).get(consumer, {})
                    if not any(covers(name, target) for target in reached):
                        out.append(f"{label}: consumer {consumer} no longer names it; remove it from consumers or "
                                   "restore the reference")
                else:
                    pattern = word(name)
                    if not any(pattern.search(text(path)) for path in modules[ids[consumer]]["owned"] if is_source(path)):
                        out.append(f"{label}: consumer {consumer} does not name it in any source file")
        for consumer, reached in sorted(edges.get(key, {}).items()):
            for target, files in sorted(reached.items()):
                if is_doc(target):
                    continue
                if not any(covers(name, target) for name in declared.get(consumer, ())):
                    out.append(f"{where}: {consumer} uses {target} ({', '.join(sorted(files)[:3])}) but no interface "
                               f"lists it as a consumer; add {json.dumps({'name': target, 'consumers': [consumer]})} "
                               "with its kind, or remove the reference")
        reached_inside = {target for path in owned if not is_test(path) for target in refs.get(path, ())}
        for path in owned:
            if is_test(path) or not is_source(path) or path in reached_inside:
                continue
            if any(covers(name, path) for name in named):
                continue
            out.append(f"{where}: nothing outside its tests reaches {path}; delete it, or name it in \"interfaces\" "
                       "with who runs it")
        uses = data.get("uses", [])
        if not isinstance(uses, list):
            out.append(f"{where}: uses must be a list")
            uses = []
        for index, use in enumerate(uses):
            label = f"{where} uses[{index}]"
            if not isinstance(use, dict):
                out.append(f"{label} must be an object")
                continue
            for field in sorted(set(use) - USE_FIELDS):
                out.append(f"{label} has unknown key {field!r}")
            name = use.get("name")
            if use.get("kind") not in KINDS:
                out.append(f"{label}: kind must be one of {', '.join(sorted(KINDS))}")
            if not (isinstance(name, str) and name.strip()):
                out.append(f"{label} needs a non-empty \"name\"")
            elif not any(name in text(path) for path in owned):
                out.append(f"{label} {name!r} does not occur in any file this module owns")
        return out

    for manifest, module in sorted(modules.items()):
        key = module["id"]
        found = module_problems(manifest, module)
        if key not in exempt:
            out.extend(found)
        elif not found:
            out.append(f"layout: root.module.json layout.uncarded lists {key!r}, whose card is complete; remove it")
    return out


def card(key: str, modules: dict[str, dict], paths: list[str], read) -> dict:
    """One module's card plus the references found in the tree: who names its files (dependents)
    and whose files it names (dependencies), whether or not a card declares them yet."""
    by_id = {module["id"]: module for module in modules.values()}
    module = by_id[key]
    data = module["data"]
    owner = {path: other["id"] for other in modules.values() for path in other["owned"]}
    folders = directories(paths, owner)
    edges = module_edges(references(paths, read, owner), owner, folders)
    outbound = [{"provider": other, "name": interface.get("name"), "kind": interface.get("kind")}
                for other, candidate in sorted(by_id.items()) if other != key
                for interface in candidate["data"].get("interfaces", []) or []
                if isinstance(interface, dict) and key in (interface.get("consumers") or [])]
    dependents = {consumer: sorted(f"{target} <- {', '.join(sorted(files))}" for target, files in targets.items())
                  for consumer, targets in sorted(edges.get(key, {}).items())}
    dependencies = {provider: sorted({target for target in consumers[key]})
                    for provider, consumers in sorted(edges.items()) if key in consumers}
    return {"id": key, "manifest": next(m for m, v in modules.items() if v is module), "purpose": data.get("purpose", ""),
            "interfaces": data.get("interfaces", []), "declaredOutbound": outbound, "uses": data.get("uses", []),
            "dependsOn": data.get("dependsOn", []), "dynamicEdges": data.get("dynamicEdges", []),
            "foundDependents": dependents, "foundDependencies": dependencies,
            "guardians": sorted(path for path in module["owned"] if is_test(path)) + list(data.get("verify", []))}
