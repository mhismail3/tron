"""Isolated checks for claim failure modes 6-11 in README.md.

Git behavior is exercised against a real local bare remote, not mocks.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from claim import (
    ClaimError,
    claim_comment,
    create_claim,
    existing_claims,
    ineligibility,
    resolve_race,
    slugify,
)

REMOTE = "origin"
BASE = "main"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class RemoteFixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.remote = root / "remote.git"
        git(root, "init", "--bare", "-b", BASE, str(self.remote))
        seed = root / "seed"
        git(root, "clone", "-q", str(self.remote), str(seed))
        self._identity(seed)
        git(seed, "commit", "-q", "--allow-empty", "-m", "base")
        git(seed, "push", "-q", REMOTE, f"HEAD:{BASE}")
        self.seed = seed
        self.a = self._agent(root / "a")
        self.b = self._agent(root / "b")

    def tearDown(self):
        self._tmp.cleanup()

    def _identity(self, repo: Path) -> None:
        git(repo, "config", "user.name", "Agent")
        git(repo, "config", "user.email", "agent@example.invalid")

    def _agent(self, path: Path) -> Path:
        git(path.parent, "clone", "-q", str(self.remote), str(path))
        self._identity(path)
        return path

    def advance_remote(self) -> str:
        git(self.seed, "commit", "-q", "--allow-empty", "-m", "moved")
        git(self.seed, "push", "-q", REMOTE, f"HEAD:{BASE}")
        return git(self.seed, "rev-parse", "HEAD")


class ClaimRaceTests(RemoteFixture):
    # Failure mode 6: same branch name, both agents saw it absent.
    def test_create_only_push_admits_one_claimant(self):
        results = [
            create_claim(self.a, REMOTE, BASE, "fix/5-crash", 5, "session-a"),
            create_claim(self.b, REMOTE, BASE, "fix/5-crash", 5, "session-b"),
        ]
        self.assertEqual(sorted(r.won for r in results), [False, True])
        claims = existing_claims(self.a, REMOTE, BASE, 5)
        self.assertEqual([c.session for c in claims], ["session-a"])

    # Failure mode 6: the title changed between reads, so the names differ.
    def test_different_names_resolve_to_one_owner(self):
        create_claim(self.a, REMOTE, BASE, "fix/5-crash-on-launch", 5, "session-a")
        create_claim(self.b, REMOTE, BASE, "fix/5-crash", 5, "session-b")
        winners = [resolve_race(repo, REMOTE, BASE, 5, session)
                   for repo, session in ((self.a, "session-a"), (self.b, "session-b"))]
        self.assertEqual(sum(1 for w in winners if w), 1)
        remaining = existing_claims(self.a, REMOTE, BASE, 5)
        self.assertEqual([(c.branch, c.session) for c in remaining], [("fix/5-crash", "session-b")])

    def test_claims_are_scoped_to_their_issue_number(self):
        create_claim(self.a, REMOTE, BASE, "feat/50-other", 50, "session-a")
        self.assertEqual(existing_claims(self.b, REMOTE, BASE, 5), [])


class ClaimBaseTests(RemoteFixture):
    # Failure mode 7: agent b's local main is stale; the claim must still
    # start at the remote tip.
    def test_claim_parent_is_fetched_remote_tip(self):
        tip = self.advance_remote()
        self.assertNotEqual(git(self.b, "rev-parse", BASE), tip)
        result = create_claim(self.b, REMOTE, BASE, "feat/7-thing", 7, "session-b")
        self.assertTrue(result.won)
        self.assertEqual(git(self.b, "rev-parse", f"{result.sha}^"), tip)
        self.assertEqual(result.base, tip)


class ClaimOwnerTests(RemoteFixture):
    # Failure mode 8: owners are read from the trailers, even after the base
    # branch moved and was merged into the claim branch.
    def test_owner_survives_updates_from_base(self):
        create_claim(self.a, REMOTE, BASE, "feat/8-thing", 8, "session-a")
        self.advance_remote()
        git(self.a, "fetch", "-q", REMOTE)
        git(self.a, "checkout", "-q", "-b", "feat/8-thing", f"{REMOTE}/feat/8-thing")
        git(self.a, "commit", "-q", "--allow-empty", "-m", "work")
        git(self.a, "merge", "-q", "--no-edit", f"{REMOTE}/{BASE}")
        git(self.a, "push", "-q", REMOTE, "HEAD:feat/8-thing")
        claims = existing_claims(self.b, REMOTE, BASE, 8)
        self.assertEqual([(c.branch, c.session) for c in claims], [("feat/8-thing", "session-a")])

    def test_branch_without_claim_commit_has_unknown_owner(self):
        git(self.seed, "push", "-q", REMOTE, f"HEAD:refs/heads/feat/9-manual")
        claims = existing_claims(self.a, REMOTE, BASE, 9)
        self.assertEqual([(c.branch, c.session) for c in claims], [("feat/9-manual", None)])


def issue(**overrides):
    base = {
        "state": "OPEN",
        "labels": ["task"],
        "status": "Ready",
        "open_blockers": [],
    }
    base.update(overrides)
    return base


class EligibilityTests(unittest.TestCase):
    RULES = {"readyStatus": "Ready", "excludeLabels": ["epic"]}

    # Failure mode 9.
    def test_ready_open_unblocked_task_is_eligible(self):
        self.assertEqual(ineligibility(issue(), self.RULES), [])

    def test_each_ineligible_state_is_refused(self):
        cases = {
            "closed": issue(state="CLOSED"),
            "epic": issue(labels=["epic"]),
            "proposed": issue(status="Proposed"),
            "in progress": issue(status="In progress"),
            "not in project": issue(status=None),
            "open blocker": issue(open_blockers=[12]),
        }
        for name, case in cases.items():
            with self.subTest(name):
                self.assertNotEqual(ineligibility(case, self.RULES), [])


class NamingTests(unittest.TestCase):
    # Failure mode 10: arbitrary titles give valid, bounded, path-safe slugs.
    def test_slugs_are_safe(self):
        for title in ["[Bug]: ../../etc/passwd crash!!", "Émoji 🚀 support", "   ", "a..b @{x} ~^:?*[\\ lock.lock"]:
            slug = slugify(title)
            with self.subTest(title):
                self.assertRegex(slug, r"^[a-z0-9]+(-[a-z0-9]+)*$")
                self.assertLessEqual(len(slug.split("-")), 5)
                subprocess.run(["git", "check-ref-format", f"refs/heads/fix/1-{slug}"], check=True)

    def test_form_prefix_is_dropped(self):
        self.assertEqual(slugify("[Task]: Lease the physical iPhone"), "lease-the-physical-iphone")


class CommentTests(unittest.TestCase):
    # Failure mode 11: the public comment never carries an absolute path.
    def test_absolute_worktree_path_is_refused(self):
        with self.assertRaises(ClaimError):
            claim_comment("s", "fix/1-x", "/private/tmp/wt", "abc")
        body = claim_comment("s", "fix/1-x", "tron-worktrees/1-x", "abc")
        self.assertIn("tron-worktrees/1-x", body)
        self.assertNotIn("/private", body)


if __name__ == "__main__":
    unittest.main()
