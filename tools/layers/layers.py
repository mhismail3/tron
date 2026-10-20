#!/usr/bin/env python3
"""Gateway and iOS layer/reference checker with shrink-only baselines (tools/layers/README.md)."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
GATEWAY = "packages/gateway"
IOS = "packages/ios-app"
TARGETS = {"gateway": (GATEWAY, "gateway/", "Gateway"), "ios": (IOS, "ios-app/", "iOS")}
REASON = re.compile(r"^\s+(?:Imported|Referenced) via (?:\"[^\"]*\"|'[^']*'|\S+) from file '([^']+)'")


class LayersError(Exception):
    pass


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    done = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if check and done.returncode:
        raise LayersError(done.stderr.strip() or f"git {args[0]} failed")
    return done


def modules(prefix: str) -> tuple[dict, dict, set]:
    """One package's modules (layer, dependsOn), path owners and all tracked paths, from tools/ownership."""
    sys.path.insert(0, str(ROOT / "tools" / "ownership"))
    import ownership  # noqa: E402
    try:
        result, errors = ownership.check()
    except ownership.GitError as error:
        raise LayersError(f"ownership: {error}") from error
    if errors:
        raise LayersError(f"ownership has {len(errors)} violation(s); fix them first (scripts/tron ownership)")
    package = {key: module for key, module in result["modules"].items() if key.startswith(prefix)}
    owner = {path: key for key, module in package.items() for path in module["owned"]}
    return package, owner, set(result["tracked"])


def gateway_graph() -> set[tuple[str, str]]:
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
    """Violating module pairs keyed by rule; the file-edge counts are reported, never ratcheted."""
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
    """Ratcheted entries: a pair rule maps to 1 (present); `unindexed <module>` maps to its file count."""
    if text is None:
        return {}
    try:
        data = json.loads(text)
        pairs, gaps = data["violations"], data.get("unindexed", {})
        if not isinstance(pairs, list) or not all(isinstance(rule, str) and not rule.startswith("unindexed ")
                                                  for rule in pairs):
            raise ValueError("violations must list module-pair rules")
        if not isinstance(gaps, dict) or not all(isinstance(v, int) and v > 0 for v in gaps.values()):
            raise ValueError("unindexed must map modules to positive file counts")
    except (ValueError, KeyError, TypeError) as error:
        raise LayersError(f"{origin}: malformed baseline ({error})") from error
    return {**dict.fromkeys(pairs, 1), **{f"unindexed {key}": count for key, count in gaps.items()}}


def ratcheted(current: Counter) -> dict:
    """What the baseline bounds: the presence of each pair rule and the unindexed file count per module."""
    return {rule: count if rule.startswith("unindexed ") else 1 for rule, count in current.items()}


def ios_graph(package: dict, tracked: set) -> tuple[set, Counter, dict]:
    """Index-store edges plus the owned Swift files the stamped build did not index (coverage gaps)."""
    sys.path.insert(0, str(ROOT / "tools" / "layers"))
    import swift_index  # noqa: E402
    try:
        edges, indexed = swift_index.graph(ROOT, IOS, tracked)
    except swift_index.IndexError_ as error:
        raise LayersError(str(error)) from error
    if not indexed:
        raise LayersError("the stamped index store covers no iOS source file; run scripts/tron-ios-test build")
    gaps, examples = Counter(), {}
    for key, module in sorted(package.items()):
        missing = [path for path in module["owned"] if path.endswith(".swift") and path not in indexed]
        if missing:
            gaps[f"unindexed {key}"] = len(missing)
            examples[f"unindexed {key}"] = (missing[0], f"{len(missing)} file(s) not compiled by the test build")
    return edges, gaps, examples


def write_baseline(entries: dict, baseline: str) -> None:
    data = {"comment": "Shrink-only: scripts/tron layers --update removes fixed entries; "
                       "new violations are never added (tools/layers/README.md).",
            "violations": sorted(rule for rule in entries if not rule.startswith("unindexed "))}
    gaps = {rule.split(" ", 1)[1]: count for rule, count in sorted(entries.items()) if rule.startswith("unindexed ")}
    if gaps:
        data["unindexed"] = gaps
    (ROOT / baseline).write_text(json.dumps(data, indent=2) + "\n")


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
        target = args.pop(0) if args else "gateway"
        if args or target not in TARGETS:
            raise IndexError
    except IndexError:
        print("usage: scripts/tron layers [gateway|ios] [--update] [--base <ref>]", file=sys.stderr)
        return 2
    directory, prefix, label = TARGETS[target]
    baseline_path = f"{directory}/layer-baseline.json"
    command = f"scripts/tron layers {target}"
    try:
        # Fail closed: the base revision's baseline bounds this one, so the base must exist.
        if git("rev-parse", "--verify", "--quiet", f"{base}^{{commit}}", check=False).returncode:
            raise LayersError(f"base {base} not found; pass --base <ref> with the revision this work starts from")
        shown = git("show", f"{base}:{baseline_path}", check=False)
        bound = load_baseline(shown.stdout, f"{base}:{baseline_path}") if shown.returncode == 0 else None
        package, owner, tracked = modules(prefix)
        if target == "gateway":
            counts, stats = evaluate(package, owner, gateway_graph())
        else:
            edges, gaps, gap_examples = ios_graph(package, tracked)
            counts, stats = evaluate(package, owner, edges)
            counts.update(gaps)
            stats["examples"].update(gap_examples)
        current = ratcheted(counts)
        path = ROOT / baseline_path
        if update and not path.exists() and bound is not None:
            raise LayersError(f"{baseline_path} is missing but {base} has one; restore it "
                              f"(git checkout {base} -- {baseline_path}) instead of rebuilding it")
        baseline = load_baseline(path.read_text() if path.exists() else None, baseline_path)
        problems = []
        new = sorted(rule for rule in current if rule not in baseline)
        grew = sorted(rule for rule in current if rule in baseline and current[rule] > baseline[rule])
        fixed = sorted(rule for rule in baseline if current.get(rule, 0) < baseline[rule])
        if update:
            if path.exists() and (new or grew):
                raise LayersError("--update only removes fixed entries; new or grown violations cannot be baselined: "
                                  + "; ".join(new + grew))
            write_baseline({rule: (count if not path.exists() else min(count, baseline[rule]))
                            for rule, count in current.items()}, baseline_path)
            print(f"layers: baseline {'written' if not baseline else 'tightened'}: {len(current)} entries")
            baseline, new, grew, fixed = dict(current), [], [], []
        for rule in new:
            source, target_file = stats["examples"][rule]
            problems.append(f"new violation: {rule} [{counts[rule]} edge(s), e.g. {source} -> {target_file}]")
        for rule in grew:  # only unindexed counts can grow; a pair's file edges are not ratcheted
            problems.append(f"grew: {rule} [{baseline[rule]} -> {current[rule]} file(s)]")
        for rule in fixed:
            problems.append(f"improved, tighten the baseline ({command} --update): {rule} "
                            f"[{baseline[rule]} -> {current.get(rule, 0)}]")
        # The committed base revision's baseline bounds this one: an entry can only leave or shrink.
        if bound is None:
            print(f"layers: {base} has no {baseline_path}; this change introduces it")
        else:
            for rule, count in sorted(baseline.items()):
                if count > bound.get(rule, 0):
                    problems.append(f"baseline grew against {base}: {rule} [{bound.get(rule, 0)} -> {count}]")
    except LayersError as error:
        print(f"layers: {error}", file=sys.stderr)
        return 2
    for line in problems:
        print(line)
    kinds = Counter(rule.split(" ", 1)[0] for rule in counts)
    gaps = sum(count for rule, count in counts.items() if rule.startswith("unindexed "))
    print(f"layers: {len(package)} {label} modules, {stats['pairs']} module pairs from {stats['fileEdges']} file "
          f"edges; current {kinds['upward']} upward, {kinds['undeclared']} undeclared, {kinds['two-way']} two-way"
          + (f", {gaps} unindexed Swift file(s) in {kinds['unindexed']} module(s)" if target == "ios" else "")
          + "; " + (f"{len(problems)} problem(s)" if problems else "no violation beyond the baseline"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
