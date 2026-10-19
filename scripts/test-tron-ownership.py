#!/usr/bin/env python3
"""CLI tests for `scripts/tron ownership` (tools/ownership/README.md).

Each case copies the real `scripts/tron` and `tools/ownership/ownership.py` into a
disposable Git repository with an isolated HOME and Git configuration, writes
fixture manifests and files, and runs the command as a worker would:

1. A valid layout (whole-directory, lowest-common-directory explicit list, a
   split directory, SwiftPM and nested-package manifests) exits 0 and lists
   every module with its derived id and owned-path count.
2. Coverage: unowned, doubly owned (across manifests and within one), stale
   owns entries and a manifest not owning itself are each reported; exit 1.
3. Schema: unknown or duplicate keys, malformed fields, path escapes, bad
   names, duplicate ids and dangling references are each reported.
4. Placement: a manifest inside an XcodeGen folder reference or inside a
   SwiftPM package's sources is refused.
5. Discovery is Git-tracked only: untracked manifests and build output are
   ignored; `<rev>` reads one commit; bad usage or revisions exit 2.

The last run's output is kept in `test-results/ownership-cli/` for review.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "test-results" / "ownership-cli"
TOOL_FILES = ("scripts/tron", "tools/ownership/ownership.py")
TOOLING = {"layer": "L5", "owns": ["scripts/tron", "tools/ownership/**", "tooling.module.json"]}


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        home = base / "home"
        home.mkdir()
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        self.git("init", "-q", "-b", "main")
        for relative in TOOL_FILES:
            target = self.path / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        self.manifest("tooling.module.json", TOOLING)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout.strip()

    def write(self, relative: str, content: str = "x\n") -> None:
        target = self.path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def manifest(self, relative: str, data: object) -> None:
        self.write(relative, data if isinstance(data, str) else json.dumps(data))

    def track(self) -> None:
        self.git("add", "-A")

    def run(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run([str(self.path / "scripts/tron"), "ownership", *args], cwd=self.path,
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, check=False)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (ARTIFACTS / "last-run.txt").write_text(f"$ scripts/tron ownership {' '.join(args)}\n"
                                                f"exit {result.returncode}\n{result.stdout}{result.stderr}")
        return result


class OwnershipCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-ownership-")
        self.repo = Repo(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def violations(self, *args: str) -> list[str]:
        self.repo.track()
        result = self.repo.run(*args)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        return result.stdout.splitlines()[:-1]

    def assertReported(self, expected: list[str], *args: str) -> None:
        self.assertEqual(self.violations(*args), sorted(expected))


class ValidLayoutTests(OwnershipCase):
    def test_valid_layout_owns_every_path_once_and_lists_modules(self) -> None:
        r = self.repo
        for path in ("packages/gw/src/home/a.ts", "packages/gw/src/home/deep/b.ts", "packages/gw/src/sessions/run.ts",
                     "packages/gw/src/sessions/run.test.ts", "packages/gw/src/sessions/catalog.ts",
                     "packages/gw/src/sessions/fixtures/x.json", "packages/gw/src/.hidden",
                     "packages/ios/Kit/Package.swift", "packages/ios/Kit/Sources/Kit/K.swift", "README.md"):
            r.write(path)
        r.manifest("packages/gw/src/home/home.module.json", {"layer": "L3", "owns": ["**"]})
        r.manifest("packages/gw/src/sessions/run.module.json",
                   {"layer": "L2", "owns": ["run*.ts", "fixtures/**", "run.module.json"],
                    "dependsOn": ["gw/catalog"], "riskClass": ["kernel"], "verify": ["scripts/tron test gateway"],
                    "exceptions": [{"path": "run.ts", "budget": "lines", "reason": "god object", "exit": "Phase 2"}],
                    "dynamicEdges": [{"to": "gw/home", "kind": "registration", "via": "packages/gw/src/home/a.ts",
                                      "why": "registered at startup"}], "capabilities": ["runs.prompt"]})
        r.manifest("packages/gw/src/sessions/catalog.module.json",
                   {"layer": "L2", "owns": ["catalog.ts", "catalog.module.json"]})
        # Lowest common directory: one file two levels down plus its own manifest.
        r.manifest("packages/gw/gateway.module.json", {"layer": "L5", "owns": ["src/.hidden", "gateway.module.json"]})
        r.manifest("packages/ios/Kit/kit.module.json", {"layer": "L3", "owns": ["**"]})
        r.manifest("root.module.json", {"layer": "L5", "owns": ["README.md", "root.module.json"]})
        r.track()
        result = r.run("--modules")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = {line.split("\t")[0]: line.split("\t")[1:] for line in result.stdout.splitlines()[:-1]}
        self.assertEqual(rows, {
            "gw/catalog": ["L2", "2", "packages/gw/src/sessions/catalog.module.json"],
            "gw/gateway": ["L5", "2", "packages/gw/gateway.module.json"],
            "gw/home": ["L3", "3", "packages/gw/src/home/home.module.json"],
            "gw/run": ["L2", "4", "packages/gw/src/sessions/run.module.json"],
            "ios/kit": ["L3", "3", "packages/ios/Kit/kit.module.json"],
            "repo/root": ["L5", "2", "root.module.json"],
            "repo/tooling": ["L5", "3", "tooling.module.json"],
        })
        self.assertEqual(result.stdout.splitlines()[-1],
                         "ownership: 7 modules, 19 tracked paths, every path owned exactly once")


class CoverageTests(OwnershipCase):
    def test_unowned_double_stale_and_self_ownership_are_reported(self) -> None:
        r = self.repo
        for path in ("a/one.ts", "a/two.ts", "a/sub/three.ts", "b/four.ts"):
            r.write(path)
        r.manifest("a/a.module.json", {"layer": "L3", "owns": ["*.ts", "one.ts", "gone.ts", "a.module.json"]})
        r.manifest("other.module.json", {"layer": "L3", "owns": ["a/sub/**", "a/*.module.json", "other.module.json"]})
        self.assertReported([
            'a/a.module.json: owns entry "gone.ts" matches no tracked path',
            'owned more than once: a/a.module.json (a/a.module.json "a.module.json"; other.module.json "a/*.module.json")',
            'owned more than once: a/one.ts (a/a.module.json "*.ts"; a/a.module.json "one.ts")',
            "unowned: b/four.ts",
        ])

    def test_manifest_owned_only_by_another_module_is_reported(self) -> None:
        self.repo.manifest("a/a.module.json", {"layer": "L3", "owns": ["x.ts"]})
        self.repo.write("a/x.ts")
        self.repo.manifest("root.module.json", {"layer": "L5", "owns": ["a/a.module.json", "root.module.json"]})
        self.assertReported(["a/a.module.json: must own itself, not be owned by root.module.json"])

    def test_star_stays_in_one_segment_and_double_star_spans_zero_or_more(self) -> None:
        r = self.repo
        for path in ("d/x.ts", "d/e/y.ts", "d/e/f/z.ts", "d/q1.md"):
            r.write(path)
        r.manifest("d/d.module.json", {"layer": "L3", "owns": ["*.ts", "**/f/*.ts", "**/q?.md", "d.module.json"]})
        self.assertReported(["unowned: d/e/y.ts"])


class SchemaTests(OwnershipCase):
    def test_malformed_manifests_and_fields_are_reported(self) -> None:
        r = self.repo
        r.write("m/f.ts")
        r.manifest("m/keys.module.json", '{"layer": "L3", "layer": "L2", "owns": ["f.ts"]}')
        r.manifest("m/broken.module.json", "{not json")
        r.manifest("m/list.module.json", "[]")
        r.manifest("m/fields.module.json", {"layer": "L9", "owns": [], "owner": "me"})
        r.manifest("m/Bad_Name.module.json", {"layer": "L3", "owns": ["**"]})
        r.manifest("m/escape.module.json", {"layer": "L3", "owns": ["../f.ts", "/abs", "a**b", "[ab].ts", "x/./y",
                                                                      "f.ts", "f.ts"]})
        r.manifest("m/missing.module.json", {"owns": ["missing.module.json"]})
        self.assertReported([
            "m/Bad_Name.module.json: name must be <lowercase-kebab-name>.module.json",
            "m/broken.module.json: invalid JSON: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)",
            "m/escape.module.json: owns entry \"../f.ts\" has an empty, '.' or '..' segment (no escapes)",
            "m/escape.module.json: owns entry \"/abs\" must be relative, without a leading or trailing '/'",
            "m/escape.module.json: owns entry \"[ab].ts\" may use only '*', '?' and whole-segment '**' as wildcards",
            "m/escape.module.json: owns entry \"a**b\" uses '**' inside a segment; '**' must be a whole segment",
            "m/escape.module.json: owns entry \"x/./y\" has an empty, '.' or '..' segment (no escapes)",
            'm/escape.module.json: owns repeats "f.ts"',
            "m/fields.module.json: layer must be one of L0..L5",
            "m/fields.module.json: owns must not be empty",
            "m/fields.module.json: unknown key 'owner'",
            "m/keys.module.json: invalid JSON: duplicate key 'layer'",
            "m/list.module.json: must be a JSON object",
            "m/missing.module.json: missing required key 'layer'",
            # Nothing valid claims the remaining files.
            "unowned: m/Bad_Name.module.json", "unowned: m/broken.module.json",
            "unowned: m/fields.module.json", "unowned: m/keys.module.json", "unowned: m/list.module.json",
            "unowned: m/escape.module.json",
        ])

    def test_wrong_value_types_are_reported_without_crashing(self) -> None:
        self.repo.manifest("t/t.module.json", {
            "layer": ["L3"], "owns": ["**", 3], "dependsOn": "repo/tooling", "riskClass": [["kernel"]],
            "dynamicEdges": [{"to": ["repo/tooling"], "kind": {"k": 1}, "via": ["x"], "why": 1}],
            "exceptions": [{"path": 5, "budget": ["lines"], "reason": "r", "exit": "e"}],
        })
        m = "t/t.module.json: "
        self.assertReported([
            m + "dependsOn must be a list",
            m + "dynamicEdges kind must be one of fs-read, generated, registration, spawn, wire",
            m + "dynamicEdges to ['repo/tooling'] is not another module id",
            m + "dynamicEdges via ['x'] is not a tracked repo-relative path",
            m + "dynamicEdges why must be a non-empty string",
            m + "exceptions budget must be lines or doc",
            m + "exceptions path 5 is not a file this module owns",
            m + "layer must be one of L0..L5",
            m + "owns entry 3 must be a non-empty string",
            m + "riskClass ['kernel'] must be one of contracts, ios-ui, kernel, lifecycle, mac-installer, persistence, security",
        ])

    def test_duplicate_ids_and_dangling_references_are_reported(self) -> None:
        r = self.repo
        r.manifest("packages/p/a/x.module.json", {"layer": "L3", "owns": ["**"]})
        r.manifest("packages/p/b/x.module.json", {"layer": "L3", "owns": ["**"]})
        r.write("packages/p/c/f.ts")
        r.manifest("packages/p/c/c.module.json", {
            "layer": "L3", "owns": ["**"],
            "dependsOn": ["p/c", "p/nope", "p/x", "p/x", 7],
            "dynamicEdges": [{"to": "p/gone", "kind": "magic", "via": "nowhere.ts", "why": " ", "extra": 1},
                             {"to": "p/x"}, "edge"],
            "capabilities": [""], "verify": ["npm test"], "riskClass": ["scary"],
            "exceptions": [{"path": "missing.ts", "budget": "words", "reason": "r", "exit": ""}, {"path": "f.ts"}],
        })
        m = "packages/p/c/c.module.json: "
        self.assertReported([
            "duplicate module id p/x: packages/p/a/x.module.json, packages/p/b/x.module.json",
            m + "capabilities entries must be non-empty strings",
            m + "dependsOn 'p/c' is not another module id",
            m + "dependsOn 'p/nope' is not another module id",
            m + 'dependsOn repeats "p/x"',
            m + "dependsOn entries must be non-empty strings",
            m + "dynamicEdges entries must be objects",
            m + "dynamicEdges entry has unknown key 'extra'",
            m + "dynamicEdges entry is missing 'kind'",
            m + "dynamicEdges entry is missing 'why'",
            m + "dynamicEdges kind must be one of fs-read, generated, registration, spawn, wire",
            m + "dynamicEdges to 'p/gone' is not another module id",
            m + "dynamicEdges via 'nowhere.ts' is not a tracked repo-relative path",
            m + "dynamicEdges why must be a non-empty string",
            m + "exceptions budget must be lines or doc",
            m + "exceptions entries need exactly path, budget, reason and exit",
            m + "exceptions path 'missing.ts' is not a file this module owns",
            m + "exceptions reason and exit must be non-empty strings",
            m + "riskClass 'scary' must be one of contracts, ios-ui, kernel, lifecycle, mac-installer, persistence, security",
            m + "verify 'npm test' must be a 'scripts/tron …' command",
        ])


class PlacementTests(OwnershipCase):
    def test_folder_reference_and_swiftpm_sources_cannot_hold_manifests(self) -> None:
        r = self.repo
        r.write("packages/ios/project.yml", "targets:\n  App:\n    sources:\n      - path: Sources\n"
                "      - path: Sources/Fonts\n        type: folder\n        buildPhase: resources\n"
                "      - path: ../../tools/preview\n        type: folder\n"
                "      - path: \"Sources/Sound Kit\"\n        type: folder\n")
        r.write("packages/ios/Sources/Fonts/a.ttf")
        r.write("tools/preview/P.swift")
        r.write("packages/ios/Sources/Sound Kit/a.caf")
        r.manifest("packages/ios/Sources/Sound Kit/sounds.module.json", {"layer": "L4", "owns": ["**"]})
        r.manifest("packages/ios/Sources/Fonts/fonts.module.json", {"layer": "L4", "owns": ["**"]})
        r.manifest("tools/preview/preview.module.json", {"layer": "L5", "owns": ["**"]})
        r.manifest("packages/ios/ios.module.json", {"layer": "L5", "owns": ["project.yml", "ios.module.json"]})
        r.write("packages/ios/Kit/Package.swift")
        r.write("packages/ios/Kit/Sources/Kit/K.swift")
        r.manifest("packages/ios/Kit/Sources/Kit/kit.module.json", {"layer": "L3", "owns": ["**"]})
        r.manifest("packages/ios/Kit/package.module.json", {"layer": "L3", "owns": ["Package.swift",
                                                                                   "package.module.json"]})
        self.assertReported([
            "packages/ios/Kit/Sources/Kit/kit.module.json: inside SwiftPM package packages/ios/Kit; "
            "place it beside Package.swift",
            "packages/ios/Sources/Fonts/fonts.module.json: inside XcodeGen folder reference packages/ios/Sources/Fonts, "
            "which copies it into the bundle",
            "packages/ios/Sources/Sound Kit/sounds.module.json: inside XcodeGen folder reference "
            "packages/ios/Sources/Sound Kit, which copies it into the bundle",
            "tools/preview/preview.module.json: inside XcodeGen folder reference tools/preview, "
            "which copies it into the bundle",
        ])


class DiscoveryTests(OwnershipCase):
    def test_only_tracked_paths_count_and_a_revision_reads_its_commit(self) -> None:
        r = self.repo
        r.write("src/a.ts")
        r.manifest("src/src.module.json", {"layer": "L3", "owns": ["**"]})
        r.track()
        r.git("commit", "-q", "-m", "clean")
        sha = r.git("rev-parse", "HEAD")
        # Untracked build output and an untracked manifest are invisible.
        r.write("build/DerivedData/x.json")
        r.manifest("build/stray.module.json", {"bogus": True})
        self.assertEqual(r.run().returncode, 0)
        # The working tree's manifest content counts without a commit; the commit keeps its own.
        r.manifest("src/src.module.json", {"layer": "L3", "owns": ["nothing.ts"]})
        self.assertIn('src/src.module.json: owns entry "nothing.ts" matches no tracked path', r.run().stdout)
        committed = r.run(sha)
        self.assertEqual(committed.returncode, 0, committed.stdout)
        self.assertIn("2 modules, 5 tracked paths, every path owned exactly once", committed.stdout)

    def test_indexed_manifest_missing_from_disk_is_reported_not_raised(self) -> None:
        self.repo.manifest("gone/gone.module.json", {"layer": "L3", "owns": ["**"]})
        self.repo.track()
        (self.repo.path / "gone/gone.module.json").unlink()  # still in the index
        result = self.repo.run()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:-1], ["gone/gone.module.json: unreadable: No such file or directory",
                                                          "unowned: gone/gone.module.json"])

    def test_bad_usage_and_unknown_revision_exit_2(self) -> None:
        self.repo.track()
        self.assertEqual(self.repo.run("--json").returncode, 2)
        self.assertEqual(self.repo.run("a", "b").returncode, 2)
        missing = self.repo.run("no-such-rev")
        self.assertEqual(missing.returncode, 2)
        self.assertTrue(missing.stderr.startswith("ownership: "))


if __name__ == "__main__":
    unittest.main(verbosity=2)
