#!/usr/bin/env python3
"""Exercise the real policy command in disposable repositories, without a runtime."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class AgentPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="tron-agent-policy-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        # Copy the actual guidance so the positive case detects catalog drift.
        # Mutations below provide independent known-bad policy inputs.
        shutil.copytree(ROOT / ".agents", self.root / ".agents")
        for relative in (
            "AGENTS.md",
            "scripts/check-agent-policy.sh",
            "scripts/personal-info-guard.sh",
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        subprocess.run(
            ["git", "init", "--quiet", str(self.root)],
            check=True, capture_output=True, timeout=10,
        )
        self.skill = self.root / ".agents/skills/tron-code-health/SKILL.md"

    def check_policy(self, error: str | None = None) -> None:
        result = subprocess.run(
            ["bash", str(self.root / "scripts/check-agent-policy.sh")],
            cwd=self.root, capture_output=True, text=True, timeout=15,
        )
        output = result.stdout + result.stderr
        if error is None:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn(error, output)

    def test_current_guidance_passes(self) -> None:
        self.check_policy()

    def test_catalog_entry_requires_a_skill_file(self) -> None:
        self.skill.unlink()
        self.check_policy("skill catalog mismatch")

    def test_skill_requires_a_catalog_entry(self) -> None:
        path = self.root / ".agents/README.md"
        path.write_text("\n".join(
            line for line in path.read_text().splitlines()
            if "skills/tron-code-health/SKILL.md" not in line
        ) + "\n")
        self.check_policy("skill catalog mismatch")

    def test_catalog_is_the_inventory_not_a_second_list(self) -> None:
        destination = self.root / ".agents/skills/tron-policy-fixture/SKILL.md"
        destination.parent.mkdir()
        destination.write_text(
            "---\nname: tron-policy-fixture\n"
            "description: Exercise catalog-driven policy in a disposable fixture.\n"
            "---\n\n# Fixture\nNo duplicated engineering safety prose.\n"
        )
        catalog = self.root / ".agents/README.md"
        catalog.write_text(catalog.read_text() +
                           "\n[Fixture](skills/tron-policy-fixture/SKILL.md)\n")
        self.check_policy()

    def test_name_must_match_directory(self) -> None:
        self.skill.write_text(self.skill.read_text().replace(
            "name: tron-code-health", "name: different-name", 1,
        ))
        self.check_policy("name does not match directory")

    def test_description_is_required(self) -> None:
        self.skill.write_text("\n".join(
            line for line in self.skill.read_text().splitlines()
            if not line.startswith("description:")
        ) + "\n")
        self.check_policy("frontmatter must contain only name and description")

    def test_duplicate_frontmatter_field_is_rejected(self) -> None:
        self.skill.write_text(self.skill.read_text().replace(
            "name: tron-code-health",
            "name: tron-code-health\nname: tron-code-health", 1,
        ))
        self.check_policy("duplicate frontmatter field")

    def test_harness_skill_copies_are_rejected(self) -> None:
        for harness in (".pi", ".claude", ".codex"):
            with self.subTest(harness=harness):
                directory = self.root / harness / "skills"
                directory.mkdir(parents=True)
                shutil.copyfile(self.skill, directory / "copy.md")
                self.check_policy("project skills must live under .agents/skills")
                shutil.rmtree(directory)

    def test_retired_ios_guidance_is_rejected_before_commit(self) -> None:
        (self.root / "unsafe.md").write_text("Use the Tron Fast scheme.\n")
        self.check_policy("stale iOS build guidance")

    def test_ios_release_guard_is_required(self) -> None:
        path = self.root / ".agents/skills/tron-ios/SKILL.md"
        path.write_text(path.read_text().replace(
            "Never install Release or DevicePerformance", "Install anything",
        ))
        self.check_policy("release install stop rule")

    def test_shared_work_suspension_guard_is_required(self) -> None:
        path = self.root / "AGENTS.md"
        path.write_text(path.read_text().replace("SIGSTOP", "a signal"))
        self.check_policy("Gateway work-suspension stop rule")


if __name__ == "__main__":
    unittest.main()
