#!/usr/bin/env python3
"""Generated documentation indexes (tools/docs/README.md)."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "ownership"))
import ownership  # noqa: E402  (the one module authority)

GATEWAY = "packages/gateway"
SERVICE = f"{GATEWAY}/src/transport/gateway-service.ts"
SCHEMA = f"{GATEWAY}/src/kernel/settings/settings-schema.ts"
SCHEMA_TYPES = f"{GATEWAY}/src/kernel/settings/tool-contract.ts"
SCHEMA_COMPOSITION = f"{GATEWAY}/src/main/settings-schema.ts"
BLOCK = re.compile(r"^<!-- tron docs ([^>]*?) -->\n(.*?)^<!-- /tron docs -->$", re.S | re.M)
OPENER = re.compile(r"^<!-- tron docs [^>]*-->", re.M)
FENCE = re.compile(r"^```.*?^```", re.S | re.M)
CELL = re.compile(r"(?<!\\)\|")
# Generators that load Gateway code, so need its installed dependencies, and whether a path is a source of
# theirs. With `check --base`, their blocks are regenerated only when a source or the block itself changed.
LOADED = {"settings": lambda path: path.startswith("tools/docs/") or path in (f"{GATEWAY}/package.json",
          f"{GATEWAY}/package-lock.json") or path.startswith(f"{GATEWAY}/src/")}

USAGE = """usage: scripts/tron docs modules [<path>] | signals | rpc | settings | check [--base <ref>] | update
Prints a generated Markdown index, or checks/rewrites the generated blocks in tracked Markdown
(tools/docs/README.md). Exit 0 current, 1 stale or failed, 2 usage."""


class DocsError(Exception):
    pass


def tracked(pattern: str) -> list[str]:
    try:
        listed = ownership.git("ls-files", "-z", "--", pattern)
    except ownership.GitError as error:
        raise DocsError(str(error)) from None
    return sorted(p.decode() for p in listed.split(b"\0") if p)


def read(path: str) -> str:
    try:
        return (ROOT / path).read_bytes().decode("utf-8")
    except OSError as error:
        raise DocsError(f"cannot read {path}: {error.strerror or error}") from None
    except UnicodeDecodeError:
        raise DocsError(f"cannot read {path}: not UTF-8") from None


def module_map() -> dict:
    try:
        result, errors = ownership.check()
    except ownership.GitError as error:
        raise DocsError(str(error)) from None
    if errors:
        print(f"docs: {len(errors)} ownership violation(s); see scripts/tron ownership", file=sys.stderr)
    return result["modules"]


def modules(under: str | None = None) -> str:
    prefix = under.strip("/") + "/" if under else ""
    rows = []
    for key, module in module_map().items():
        if not module["manifest"].startswith(prefix):
            continue
        folder = str(PurePosixPath(module["manifest"]).parent)
        readme = "README.md" if folder == "." else f"{folder}/README.md"
        rows.append(f"| `{key}` | {module['layer']} | {len(module['owned'])} | `{module['manifest']}` | "
                    f"{f'`{readme}`' if readme in module['owned'] else '—'} |")
    if not rows:
        raise DocsError(f"no module manifest under {under!r}")
    return "\n".join(["| Module | Layer | Files | Manifest | README |", "| --- | --- | --- | --- | --- |", *rows]) + "\n"


def cells(row: str) -> list[str]:
    return [cell.strip() for cell in CELL.split(row.strip().strip("|"))]


def signal_rows(text: str) -> list[tuple[tuple, list[str]]]:
    """(header cells, row cells) of the tables under a `## Signals` heading; the first cell names the signal."""
    lines = BLOCK.sub("", text).splitlines()
    rows, inside, fenced, header = [], False, False, ()
    for index, line in enumerate(lines):
        if line.startswith("```"):
            fenced = not fenced
        if fenced:
            continue
        if re.match(r"^#{1,2} ", line):
            inside = re.match(r"^## Signals\s*$", line) is not None
            continue
        if not inside or not line.startswith("|") or re.match(r"^\|[\s:|-]+\|?\s*$", line):
            continue
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if re.match(r"^\|[\s:|-]+\|?\s*$", following):
            header = tuple(cells(line))
            continue
        rows.append((header, cells(line)))
    return rows


def signals() -> str:
    """One table per distinct Signals header, rows sorted by signal, with the owning module appended."""
    tables: dict[tuple, list[list[str]]] = {}
    for key, module in module_map().items():
        for path in (p for p in module["owned"] if PurePosixPath(p).name == "README.md"):
            for header, row in signal_rows(read(path)):
                tables.setdefault(header, []).append([*row, f"[`{key}`]({path}#signals)"])
    if not tables:
        return "No module README has a `## Signals` table yet.\n"
    out = []
    for header, rows in sorted(tables.items()):
        out += ["" if out else None, f"| {' | '.join([*header, 'Module'])} |", f"|{' --- |' * (len(header) + 1)}"]
        out += [f"| {' | '.join(row)} |" for row in sorted(rows)]
    return "\n".join(line for line in out if line is not None) + "\n"


def rpc_methods() -> list[str]:
    """The case labels of `GatewayService.invoke`'s method switch: the one RPC registration."""
    lines = read(SERVICE).splitlines()
    start = next((i for i, line in enumerate(lines) if re.match(r"^\s+async invoke\(", line)), None)
    switch = next((i for i in range(start, len(lines)) if re.match(r"^\s+switch \(method\) \{", lines[i])), None) \
        if start is not None else None
    if switch is None:
        raise DocsError(f"{SERVICE}: no `invoke` method switch")
    indent = re.match(r"^\s*", lines[switch]).group(0)
    methods = []
    for line in lines[switch + 1:]:
        if line == f"{indent}}}":
            break
        label = re.match(rf'^{indent}  case "([^"]+)":', line)
        if label:
            methods.append(label.group(1))
    if not methods:
        raise DocsError(f"{SERVICE}: the `invoke` switch has no method cases")
    return methods


def rpc() -> str:
    methods = rpc_methods()
    groups: dict[str, list[str]] = {}
    for method in sorted(set(methods)):
        groups.setdefault(method.split(".")[0], []).append(method)
    rows = [f"| `{name}` | {', '.join(f'`{m}`' for m in items)} |" for name, items in sorted(groups.items())]
    return "\n".join([f"{len(set(methods))} methods, registered in `{SERVICE}` (`GatewayService.invoke`).", "",
                      "| Namespace | Methods |", "| --- | --- |", *rows]) + "\n"


def schema() -> dict:
    node = subprocess.run([str(ROOT / "scripts" / "tron-node")], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, check=False)
    if node.returncode != 0:
        raise DocsError(f"no pinned Node: {node.stderr.strip()}")
    done = subprocess.run([node.stdout.strip(), "--experimental-transform-types", "--no-warnings",
                           str(Path(__file__).with_name("settings-keys.mjs")), str(ROOT / SCHEMA_COMPOSITION), str(ROOT / SCHEMA_TYPES)],
                          cwd=ROOT / GATEWAY, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    if done.returncode != 0:
        if not (ROOT / GATEWAY / "node_modules").is_dir():
            error = next((line for line in done.stderr.splitlines() if "Error" in line), "").strip()
            raise DocsError(f"loading {SCHEMA} needs the Gateway dependencies, and {GATEWAY}/node_modules is missing "
                            f"(install with: cd {GATEWAY} && ../../scripts/tron-node exec npm ci){': ' if error else ''}"
                            f"{error}")
        raise DocsError(f"loading {SCHEMA} failed:\n{done.stderr.strip()[-2000:]}")
    return json.loads(done.stdout)


def pair(value: object) -> str:
    if isinstance(value, dict):
        return ", ".join(f"{k} {value[k]}" for k in ("narrow", "widen") if k in value)
    return "—" if value is None else str(value)


def settings() -> str:
    data = schema()
    order = {layer: index for index, layer in enumerate(data["layers"])}

    def layers(names) -> str:
        return ", ".join(sorted(names, key=lambda name: order.get(name, len(order)))) or "none"

    rows = []
    for key in data["keys"]:
        home = layers(key["home"]["layers"]) if "home" in key else "as allowed"
        rows.append(f"| `{key['id']}` | {key.get('qualifier', '—')} | {key['group']} | {layers(key['layers'])} | {home} | "
                    f"{pair(key.get('timing'))} | {key.get('effect', '—')} | {pair(key.get('floor'))} |")
    subjects = [f"| `{s['id']}` | {s['group']} | {s['qualifier']} | {pair(s.get('floor'))} |" for s in data["subjects"]]
    return "\n".join([f"{len(rows)} keys, declared in `{SCHEMA}` (`KEYS`).", "",
                      "| Key | Qualifier | Group | Layers | Home layers | Timing | Effect | Floor |",
                      "| --- | --- | --- | --- | --- | --- | --- | --- |", *rows, "",
                      f"Record subjects (`RECORD_SUBJECTS`), changed per instance through the same path:", "",
                      "| Subject | Group | Qualifier | Floor |", "| --- | --- | --- | --- |", *subjects]) + "\n"


GENERATORS = {"modules": (modules, 1), "signals": (signals, 0), "rpc": (rpc, 0), "settings": (settings, 0)}


def usable(args: list[str]) -> bool:
    return bool(args) and args[0] in GENERATORS and len(args) - 1 <= GENERATORS[args[0]][1]


def generate(args: list[str]) -> str:
    if not usable(args):
        raise DocsError(f"unknown generator `tron docs {' '.join(args)}`")
    return GENERATORS[args[0]][0](*args[1:])


def unchanged_loaded(base: str) -> set[str]:
    """The LOADED generators none of whose sources changed between `base` and the working tree."""
    try:
        changed = ownership.git("diff", "--no-renames", "--name-only", "-z", base, "--").split(b"\0") \
            + ownership.git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    except ownership.GitError as error:
        raise DocsError(f"base {base}: {error}") from None
    paths = [p.decode("utf-8", "surrogateescape") for p in changed if p]
    return {name for name, source in LOADED.items() if not any(source(path) for path in paths)}


def base_bodies(base: str, path: str) -> dict:
    try:
        text = ownership.git("show", f"{base}:{path}").decode("utf-8")
    except (ownership.GitError, UnicodeDecodeError):
        return {}
    return {tuple(m.group(1).split()): m.group(2) for m in BLOCK.finditer(text)}


def blocks(write: bool, base: str | None = None) -> int:
    """Check (or rewrite) every `<!-- tron docs … -->` block in tracked Markdown."""
    outputs: dict[tuple, str] = {}
    problems, count, kept = [], 0, 0
    quiet = unchanged_loaded(base) if base else set()
    for path in tracked("*.md"):
        text = read(path)
        fences = [match.span() for match in FENCE.finditer(text)]

        def unfenced(matches) -> list:
            return [m for m in matches if not any(start <= m.start() < end for start, end in fences)]
        found = unfenced(BLOCK.finditer(text))
        if len(unfenced(OPENER.finditer(text))) != len(found):
            # An unclosed opener would match through the next block's end; never rewrite such a file.
            problems.append(f"{path}: a `<!-- tron docs … -->` block has no `<!-- /tron docs -->` end")
            continue
        updated = text
        named = {m.group(1).split()[0] for m in found if m.group(1).split()}
        before = base_bodies(base, path) if named & quiet else {}
        for match in reversed(found):
            count += 1
            args = tuple(match.group(1).split())
            if args[:1] and args[0] in quiet and before.get(args) == match.group(2):
                kept += 1  # its sources and its text are as at the base: regenerating cannot differ
                continue
            try:
                expected = outputs[args] if args in outputs else outputs.setdefault(args, generate(list(args)))
            except DocsError as error:
                problems.append(f"{path}: {error}")
                continue
            if match.group(2) != expected:
                if write:
                    updated = updated[:match.start(2)] + expected + updated[match.end(2):]
                    print(f"docs: updated `tron docs {' '.join(args)}` in {path}")
                else:
                    problems.append(f"{path}: `tron docs {' '.join(args)}` is stale; run scripts/tron docs update")
        if updated != text:
            (ROOT / path).write_bytes(updated.encode("utf-8"))
    for problem in problems:
        print(problem)
    state = f"{len(problems)} problem(s)" if problems else "current"
    print(f"docs: {count} generated block(s), {state}"
          + (f" ({kept} unchanged since {base} with unchanged sources, not regenerated)" if kept else ""))
    return 1 if problems else 0


def main(argv: list[str]) -> int:
    base = argv[2] if len(argv) == 3 and argv[:2] == ["check", "--base"] else None
    if not argv or argv[0] in ("-h", "--help") or (argv[0] in ("check", "update") and len(argv) > 1 and not base):
        print(USAGE, file=sys.stderr)
        return 0 if argv and argv[0] in ("-h", "--help") else 2
    try:
        if argv[0] in ("check", "update"):
            return blocks(write=argv[0] == "update", base=base)
        if not usable(argv):
            print(USAGE, file=sys.stderr)
            return 2
        sys.stdout.write(generate(argv))
        return 0
    except DocsError as error:
        print(f"docs: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
