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
SCHEMA = f"{GATEWAY}/src/admin/settings-schema.ts"
SCHEMA_TYPES = f"{GATEWAY}/src/admin/settings-types.ts"
BLOCK = re.compile(r"^<!-- tron docs ([^>]*?) -->\n(.*?)^<!-- /tron docs -->$", re.S | re.M)
OPENER = re.compile(r"^<!-- tron docs [^>]*-->", re.M)
FENCE = re.compile(r"^```.*?^```", re.S | re.M)
CELL = re.compile(r"(?<!\\)\|")

USAGE = """usage: scripts/tron docs modules [<path>] | signals | rpc | settings | check | update
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
        return (ROOT / path).read_text()
    except OSError as error:
        raise DocsError(f"cannot read {path}: {error.strerror or error}") from None


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


def signal_names(text: str) -> list[str]:
    """First-column cells of the tables under a `## Signals` heading (header rows excluded)."""
    lines = BLOCK.sub("", text).splitlines()
    names, inside, fenced = [], False, False
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
            continue  # a header row
        names.append(cells(line)[0])
    return names


def signals() -> str:
    rows = []
    for key, module in module_map().items():
        for path in (p for p in module["owned"] if PurePosixPath(p).name == "README.md"):
            rows.extend((name, key, path) for name in signal_names(read(path)))
    if not rows:
        return "No module README has a `## Signals` table yet.\n"
    body = [f"| {name} | `{key}` | `{path}` |" for name, key, path in sorted(rows)]
    return "\n".join(["| Signal | Module | README |", "| --- | --- | --- |", *body]) + "\n"


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
                           str(Path(__file__).with_name("settings-keys.mjs")), str(ROOT / SCHEMA), str(ROOT / SCHEMA_TYPES)],
                          cwd=ROOT / GATEWAY, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    if done.returncode != 0:
        hint = "" if (ROOT / GATEWAY / "node_modules").is_dir() else \
            f"; {GATEWAY}/node_modules is missing (install with: cd {GATEWAY} && ../../scripts/tron-node exec npm ci)"
        raise DocsError(f"loading {SCHEMA} failed{hint}:\n{done.stderr.strip()[-2000:]}")
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
        rows.append(f"| `{key['id']}` | {key['group']} | {layers(key['layers'])} | {home} | "
                    f"{pair(key.get('timing'))} | {key.get('effect', '—')} | {pair(key.get('floor'))} |")
    subjects = [f"| `{s['id']}` | {s['group']} | {s['qualifier']} | {pair(s.get('floor'))} |" for s in data["subjects"]]
    return "\n".join([f"{len(rows)} keys, declared in `{SCHEMA}` (`KEYS`).", "",
                      "| Key | Group | Layers | Home layers | Timing | Effect | Floor |",
                      "| --- | --- | --- | --- | --- | --- | --- |", *rows, "",
                      f"Record subjects (`RECORD_SUBJECTS`), changed per instance through the same path:", "",
                      "| Subject | Group | Qualifier | Floor |", "| --- | --- | --- | --- |", *subjects]) + "\n"


GENERATORS = {"modules": (modules, 1), "signals": (signals, 0), "rpc": (rpc, 0), "settings": (settings, 0)}


def generate(args: list[str]) -> str:
    if not args or args[0] not in GENERATORS or len(args) - 1 > GENERATORS[args[0]][1]:
        raise DocsError(f"unknown generator `tron docs {' '.join(args)}`")
    return GENERATORS[args[0]][0](*args[1:])


def blocks(write: bool) -> int:
    """Check (or rewrite) every `<!-- tron docs … -->` block in tracked Markdown."""
    outputs: dict[tuple, str] = {}
    problems, count = [], 0
    for path in tracked("*.md"):
        text = read(path)
        fences = [match.span() for match in FENCE.finditer(text)]

        def unfenced(matches) -> list:
            return [m for m in matches if not any(start <= m.start() < end for start, end in fences)]
        found = unfenced(BLOCK.finditer(text))
        if len(unfenced(OPENER.finditer(text))) != len(found):
            problems.append(f"{path}: a `<!-- tron docs … -->` block has no `<!-- /tron docs -->` end")
        updated = text
        for match in reversed(found):
            count += 1
            args = tuple(match.group(1).split())
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
            (ROOT / path).write_text(updated)
    for problem in problems:
        print(problem)
    state = f"{len(problems)} problem(s)" if problems else "current"
    print(f"docs: {count} generated block(s), {state}")
    return 1 if problems else 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help") or (argv[0] in ("check", "update") and len(argv) > 1):
        print(USAGE, file=sys.stderr)
        return 0 if argv and argv[0] in ("-h", "--help") else 2
    try:
        if argv[0] in ("check", "update"):
            return blocks(write=argv[0] == "update")
        if argv[0] not in GENERATORS:
            print(USAGE, file=sys.stderr)
            return 2
        sys.stdout.write(generate(argv))
        return 0
    except DocsError as error:
        print(f"docs: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
