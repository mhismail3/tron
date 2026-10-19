#!/usr/bin/env python3
"""Gateway layer/reference checker with a shrink-only baseline (tools/layers/README.md)."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
GATEWAY = "packages/gateway"
BASELINE = f"{GATEWAY}/layer-baseline.json"
REASON = re.compile(r"^\s+(?:Imported|Referenced) via (?:\"[^\"]*\"|'[^']*'|\S+) from file '([^']+)'")


class LayersError(Exception):
    pass


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    done = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if check and done.returncode:
        raise LayersError(done.stderr.strip() or f"git {args[0]} failed")
    return done


def modules() -> tuple[dict, dict]:
    """Gateway modules (layer, dependsOn) and path owners from the one ownership authority."""
    sys.path.insert(0, str(ROOT / "tools" / "ownership"))
    import ownership  # noqa: E402
    try:
        result, errors = ownership.check()
    except ownership.GitError as error:
        raise LayersError(f"ownership: {error}") from error
    if errors:
        raise LayersError(f"ownership has {len(errors)} violation(s); fix them first (scripts/tron ownership)")
    gateway = {key: module for key, module in result["modules"].items() if key.startswith("gateway/")}
    owner = {path: key for key, module in gateway.items() for path in module["owned"]}
    return gateway, owner


def import_graph() -> set[tuple[str, str]]:
    """File edges of the Gateway production program, as resolved by the pinned TypeScript compiler.

    `--explainFiles` names every reason a file is in the program: static, type-only,
    side-effect, re-export and dynamic imports. Type errors do not stop it.
    """
    tsc = ROOT / GATEWAY / "node_modules" / "typescript" / "bin" / "tsc"
    node = ROOT / "scripts" / "tron-node"
    if not tsc.is_file():
        raise LayersError(f"missing {tsc.relative_to(ROOT)}; install Gateway dependencies (npm ci in {GATEWAY})")
    done = subprocess.run([str(node), "exec", "node", str(tsc), "-p", "tsconfig.json", "--noEmit",
                           "--explainFiles", "--pretty", "false"],
                          cwd=ROOT / GATEWAY, capture_output=True, text=True)
    edges, current, files = set(), None, 0
    for line in done.stdout.splitlines():
        if not line.startswith((" ", "\t")):
            # A file header is a bare path; diagnostics carry "(line,col): error".
            current = None if re.search(r"\(\d+,\d+\): error ", line) or not line.strip() else line.strip()
            files += current is not None and current.startswith("src/")
            continue
        match = REASON.match(line)
        if match and current and current.startswith("src/") and match.group(1).startswith("src/"):
            edges.add((f"{GATEWAY}/{match.group(1)}", f"{GATEWAY}/{current}"))
    if not files:
        detail = (done.stderr or done.stdout).strip().splitlines()[-1:] or ["no output"]
        raise LayersError(f"could not read the Gateway import graph from tsc --explainFiles ({detail[0]})")
    return edges


def evaluate(gateway: dict, owner: dict, edges: set) -> tuple[Counter, dict]:
    """Violations keyed by rule and module pair, counted in file edges."""
    pairs: dict[tuple[str, str], list] = defaultdict(list)
    for importer, imported in sorted(edges):
        source, target = owner.get(importer), owner.get(imported)
        if source is None or target is None:
            raise LayersError(f"unowned program file in edge {importer} -> {imported}")
        if source != target:
            pairs[(source, target)].append((importer, imported))
    violations: Counter = Counter()
    examples = {}
    for (source, target), found in pairs.items():
        rules = []
        if int(gateway[target]["layer"][1]) > int(gateway[source]["layer"][1]):
            rules.append(f"upward {source} ({gateway[source]['layer']}) -> {target} ({gateway[target]['layer']})")
        if target not in gateway[source]["dependsOn"]:
            rules.append(f"undeclared {source} -> {target}")
        if (target, source) in pairs and source < target:
            rules.append(f"two-way {source} <-> {target}")
        for rule in rules:
            violations[rule] = len(found) if not rule.startswith("two-way") else 1
            examples[rule] = found[0]
    return violations, {"pairs": len(pairs), "fileEdges": len(edges), "examples": examples}


def load_baseline(text: str | None, origin: str) -> dict:
    if text is None:
        return {}
    try:
        data = json.loads(text)
        counts = data["violations"]
        if not isinstance(counts, dict) or not all(isinstance(v, int) and v > 0 for v in counts.values()):
            raise ValueError("violations must map rules to positive edge counts")
    except (ValueError, KeyError, TypeError) as error:
        raise LayersError(f"{origin}: malformed baseline ({error})") from error
    return counts


def write_baseline(counts: dict) -> None:
    text = json.dumps({"comment": "Shrink-only: scripts/tron layers --update removes fixed entries; "
                                  "new violations are never added (tools/layers/README.md).",
                       "violations": dict(sorted(counts.items()))}, indent=2) + "\n"
    (ROOT / BASELINE).write_text(text)


def main(argv: list[str]) -> int:
    args, base, update = list(argv), "origin/main", False
    try:
        if "--update" in args:
            args.remove("--update")
            update = True
        if "--base" in args:
            at = args.index("--base")
            base = args[at + 1]
            del args[at:at + 2]
        if args:
            raise IndexError
    except IndexError:
        print("usage: scripts/tron layers [--update] [--base <ref>]", file=sys.stderr)
        return 2
    try:
        gateway, owner = modules()
        current, stats = evaluate(gateway, owner, import_graph())
        path = ROOT / BASELINE
        baseline = load_baseline(path.read_text() if path.exists() else None, BASELINE)
        problems = []
        new = sorted(rule for rule in current if rule not in baseline)
        grew = sorted(rule for rule in current if rule in baseline and current[rule] > baseline[rule])
        fixed = sorted(rule for rule in baseline if current.get(rule, 0) < baseline[rule])
        if update:
            if path.exists() and (new or grew):
                raise LayersError("--update only removes fixed entries; new or grown violations cannot be baselined: "
                                  + "; ".join(new + grew))
            write_baseline({rule: (count if not path.exists() else min(count, baseline[rule]))
                            for rule, count in current.items()})
            print(f"layers: baseline {'written' if not baseline else 'tightened'}: {len(current)} entries")
            baseline, new, grew, fixed = dict(current), [], [], []
        for rule in new:
            source, target = stats["examples"][rule]
            problems.append(f"new violation: {rule} [{current[rule]} edge(s), e.g. {source} -> {target}]")
        for rule in grew:
            problems.append(f"grew: {rule} [{baseline[rule]} -> {current[rule]} edge(s)]")
        for rule in fixed:
            problems.append(f"improved, tighten the baseline (scripts/tron layers --update): {rule} "
                            f"[{baseline[rule]} -> {current.get(rule, 0)}]")
        # The committed base revision's baseline bounds this one: an entry can only leave or shrink.
        if git("rev-parse", "--verify", "--quiet", f"{base}^{{commit}}", check=False).returncode == 0:
            shown = git("show", f"{base}:{BASELINE}", check=False)
            if shown.returncode == 0:
                bound = load_baseline(shown.stdout, f"{base}:{BASELINE}")
                for rule, count in sorted(baseline.items()):
                    if count > bound.get(rule, 0):
                        problems.append(f"baseline grew against {base}: {rule} [{bound.get(rule, 0)} -> {count}]")
            else:
                print(f"layers: {base} has no {BASELINE}; growth against the base not checked")
        else:
            print(f"layers: base {base} not found; growth against the base not checked")
    except LayersError as error:
        print(f"layers: {error}", file=sys.stderr)
        return 2
    for line in problems:
        print(line)
    kinds = Counter(rule.split(" ", 1)[0] for rule in current)
    print(f"layers: {len(gateway)} Gateway modules, {stats['pairs']} module pairs from {stats['fileEdges']} file "
          f"edges; current {kinds['upward']} upward, {kinds['undeclared']} undeclared, {kinds['two-way']} two-way; "
          + (f"{len(problems)} problem(s)" if problems else "no violation beyond the baseline"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
