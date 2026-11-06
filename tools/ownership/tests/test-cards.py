#!/usr/bin/env python3
"""CLI tests for purpose cards in `scripts/tron ownership` (tools/ownership/README.md, "Purpose cards").

Each case copies the real `scripts/tron` and `tools/ownership/*.py` into a disposable Git
repository with two tool modules, `repo/tool` (carded) and `repo/caller`, and runs the command
as a worker would. Every refusal names the file and the fix:

1. A complete card passes: purpose, an owned test, and an interface listing each module whose
   files name the tool.
2. A card without purpose, guardian or interfaces is refused, and so is a new module that is
   not carded (only `layout.uncarded` exempts one, and that list only shrinks).
3. A new reference from another module to the tool is refused until the card lists that
   consumer; a consumer that stopped naming it must be dropped.
4. A tool moved without updating its callers is refused with the files that still name the
   old path; a moved card whose callers were not updated is refused per consumer.
5. A file nothing outside its tests reaches is refused as dead.
6. `--card <path>` prints the module's card with the dependents found in the tree.
7. An unowned file that names a carded tool is reported as unowned, not as a crash.

The last run's output is kept in `test-results/cards-cli/`.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "test-results" / "cards-cli"
TOOL = "#!/usr/bin/env bash\n# Fixture tool that callers run by path.\necho tool\n"
CALLER = "#!/usr/bin/env bash\n# Fixture caller that runs the tool.\n\"$ROOT/tools/tool/tool.sh\"\n"
TEST = "#!/usr/bin/env bash\n# Proves the tool prints its name.\n[[ $(bash tools/tool/tool.sh) == tool ]]\n"


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
        (self.path / "tools/ownership").mkdir(parents=True)
        (self.path / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/tron", self.path / "scripts/tron")
        for tool in (ROOT / "tools/ownership").glob("*.py"):
            shutil.copy2(tool, self.path / "tools/ownership" / tool.name)
        self.layout = {"root": [".gitignore", "root.module.json", "scripts", "tools"], "scriptsTop": ["scripts/tron", "scripts/tooling.module.json"],
                       "frozen": ["scripts/tron"], "uncarded": ["repo/caller", "repo/root", "repo/tooling"]}
        self.write(".gitignore", "test-results/\n")
        self.write("scripts/tooling.module.json", json.dumps({"layer": "L5", "owns": ["tron", "tooling.module.json"]}))
        self.write("tools/ownership/ownership.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        self.layout["uncarded"].append("repo/ownership")
        self.layout["uncarded"].sort()
        self.write("tools/tool/tool.sh", TOOL, mode=0o755)
        self.write("tools/tool/tests/test-tool.sh", TEST)
        self.card = {"layer": "L5", "purpose": "Prints its name for callers.", "owns": ["**"],
                     "interfaces": [{"name": "tools/tool/tool.sh", "kind": "exec", "consumers": ["repo/caller"]}]}
        self.save_card()
        self.write("tools/caller/caller.sh", CALLER, mode=0o755)
        self.write("tools/caller/caller.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        self.save_root()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def save_card(self) -> None:
        self.write("tools/tool/tool.module.json", json.dumps(self.card, indent=2))

    def save_root(self) -> None:
        self.write("root.module.json", json.dumps({"layer": "L5", "owns": ["root.module.json", ".gitignore"],
                                                   "layout": self.layout}, indent=2))

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, content: str = "x\n", mode: int | None = None) -> None:
        target = self.path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        if mode is not None:
            target.chmod(mode)

    def run(self, *args: str) -> subprocess.CompletedProcess:
        self.git("add", "-A")
        result = subprocess.run([str(self.path / "scripts/tron"), "ownership", *args], cwd=self.path,
                                env=self.env, capture_output=True, text=True, check=False)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron ownership {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        return result


class CardCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-cards-")
        self.repo = Repo(Path(self.temp.name).resolve())

    def tearDown(self) -> None:
        self.temp.cleanup()

    def clean(self) -> None:
        result = self.repo.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def refused(self, *fragments: str) -> str:
        result = self.repo.run()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for fragment in fragments:
            self.assertIn(fragment, result.stdout)
        return result.stdout


class CardTests(CardCase):
    def test_complete_card_passes(self) -> None:
        self.clean()

    def test_card_needs_purpose_guardian_and_interfaces(self) -> None:
        r = self.repo
        (r.path / "tools/tool/tests/test-tool.sh").unlink()
        r.card = {"layer": "L5", "owns": ["**"]}
        r.save_card()
        self.refused('tools/tool/tool.module.json: card needs a one-sentence "purpose"',
                     "tools/tool/tool.module.json: card has no guardian",
                     'tools/tool/tool.module.json: card needs "interfaces"')

    def test_a_new_module_is_carded_from_birth_and_the_exemption_list_only_shrinks(self) -> None:
        r = self.repo
        r.write("tools/extra/extra.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        r.write("tools/extra/extra.sh", "#!/usr/bin/env bash\n# An uncarded newcomer.\n", mode=0o755)
        self.refused('tools/extra/extra.module.json: card needs a one-sentence "purpose"')
        r.layout["uncarded"].append("repo/extra")
        r.save_root()
        self.refused("layout: root.module.json layout.uncarded gained 'repo/extra' since origin/main; these lists only "
                     "shrink: card the module instead")

    def test_a_complete_card_cannot_stay_exempt(self) -> None:
        r = self.repo
        r.layout["uncarded"].append("repo/tool")
        r.layout["uncarded"].sort()
        r.save_root()
        r.git("add", "-A")
        r.git("commit", "-q", "-m", "exempt")
        r.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.refused("layout: root.module.json layout.uncarded lists 'repo/tool', whose card is complete; remove it")

    def test_an_undeclared_consumer_is_refused_with_its_file(self) -> None:
        r = self.repo
        r.write("scripts/tron", (r.path / "scripts/tron").read_text() + "# tools/tool/tool.sh\n")
        self.refused("tools/tool/tool.module.json: card: repo/tooling uses tools/tool/tool.sh (scripts/tron) but no "
                     'interface lists it as a consumer; add {"name": "tools/tool/tool.sh", "consumers": ["repo/tooling"]}')

    def test_a_consumer_that_stopped_naming_the_tool_must_be_dropped(self) -> None:
        r = self.repo
        r.write("tools/caller/caller.sh", "#!/usr/bin/env bash\n# Fixture caller that no longer runs the tool.\n",
                mode=0o755)
        self.refused("tools/tool/tool.module.json: card interface 'tools/tool/tool.sh': consumer repo/caller no longer "
                     "names it; remove it from consumers or restore the reference")

    def test_a_move_without_its_callers_names_every_file_still_using_the_old_path(self) -> None:
        r = self.repo
        (r.path / "tools/tool/bin").mkdir()
        r.git("mv", "tools/tool/tool.sh", "tools/tool/bin/tool.sh")
        self.refused("tools/tool/tool.module.json: card interface 'tools/tool/tool.sh' is not a tracked path or "
                     "directory; still named by tools/caller/caller.sh")
        r.card["interfaces"][0]["name"] = "tools/tool/bin/tool.sh"
        r.save_card()
        self.refused("tools/tool/tool.module.json: card interface 'tools/tool/bin/tool.sh': consumer repo/caller no "
                     "longer names it")
        r.write("tools/caller/caller.sh", CALLER.replace("tool/tool.sh", "tool/bin/tool.sh"), mode=0o755)
        r.write("tools/tool/tests/test-tool.sh", TEST.replace("tool/tool.sh", "tool/bin/tool.sh"))
        self.clean()

    def test_a_file_nothing_reaches_is_dead(self) -> None:
        r = self.repo
        r.write("tools/tool/helper.sh", "#!/usr/bin/env bash\n# A helper nobody calls.\n", mode=0o755)
        self.refused("tools/tool/tool.module.json: card: nothing outside its tests reaches tools/tool/helper.sh; "
                     "delete it, or name it in \"interfaces\" with who runs it")
        r.write("tools/tool/tool.sh", TOOL + "source \"$(dirname \"$0\")/helper.sh\"\n", mode=0o755)
        self.clean()

    def test_an_unowned_file_naming_a_tool_is_reported_as_unowned(self) -> None:
        r = self.repo
        r.write("notes/run.sh", "#!/usr/bin/env bash\n# Runs the tool.\nbash tools/tool/tool.sh\n")
        result = r.run()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("unowned: notes/run.sh", result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_card_prints_dependents_found_in_the_tree(self) -> None:
        result = self.repo.run("--card", "tools/tool/tool.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        card = json.loads(result.stdout)
        self.assertEqual(card["id"], "repo/tool")
        self.assertEqual(card["foundDependents"], {"repo/caller": ["tools/tool/tool.sh <- tools/caller/caller.sh"]})
        self.assertEqual(card["guardians"], ["tools/tool/tests/test-tool.sh"])
        caller = json.loads(self.repo.run("--card", "repo/caller").stdout)
        self.assertEqual(caller["declaredOutbound"], [{"provider": "repo/tool", "name": "tools/tool/tool.sh", "kind": "exec"}])
        self.assertEqual(caller["foundDependencies"], {"repo/tool": ["tools/tool/tool.sh"]})


if __name__ == "__main__":
    unittest.main(verbosity=2)
