"""Isolated checks for stacked claims in land, steward and start (failure modes 75-78 in README.md).

The claim for issue 7 starts from the claim branch of issue 9, which itself lands into main.
The fixture is StackedFixture here, over LandFixture in test_land.py.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

import claim as claims
import land
import start
import test_land
from gh import Gh
from test_land import BASE, BRANCH, NUMBER, REMOTE, SESSION, LandFixture, git


def setUpModule():
    # Each test_land_*.py module runs in its own process, so it builds the template itself.
    test_land.setUpModule()


HELD_NUMBER = 9


HELD = "feat/9-hold-the-thing"


HELD_SESSION = "session-h"


class StackedFixture(LandFixture):
    """#7 (BRANCH) is claimed on HELD, #9's claim branch, which itself lands into main."""

    def setUp(self):
        super().setUp()
        self.held = self._clone("held")
        claims.create_claim(self.held, REMOTE, BASE, HELD, HELD_NUMBER, HELD_SESSION)
        git(self.held, "fetch", "-q", REMOTE)
        git(self.held, "checkout", "-q", "-b", HELD, "--track", f"{REMOTE}/{HELD}")
        self.commit(self.held, "lib/held.txt", "held\n")
        git(self.held, "push", "-q", REMOTE, f"HEAD:{HELD}")
        # Claim #7 again, this time on the held branch.
        git(self.repo, "push", "-q", REMOTE, f":refs/heads/{BRANCH}")
        git(self.repo, "checkout", "-q", "--detach")
        git(self.repo, "branch", "-q", "-D", BRANCH)
        self.claim_sha = claims.create_claim(self.repo, REMOTE, HELD, BRANCH, NUMBER, SESSION).sha
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "checkout", "-q", "-b", BRANCH, "--track", f"{REMOTE}/{BRANCH}")
        self.commit(self.repo, "app/a.txt", "two\n")
        self.add_issue(HELD_NUMBER, "[Task]: Hold the thing", status="Needs you")

    def add_issue(self, number: int, title: str, status: str = "Ready", state: str = "OPEN") -> None:
        issues = self.state()["issues"]
        issues[str(number)] = {"title": title, "state": state, "labels": ["task"], "status": status,
                               "inProject": True, "comments": []}
        self.set_state(issues=issues)

    def remote_file(self, branch: str, relative: str) -> str:
        git(self.repo, "fetch", "-q", REMOTE)
        shown = subprocess.run(["git", "show", f"{REMOTE}/{branch}:{relative}"], cwd=self.repo,
                               capture_output=True, text=True)
        return shown.stdout.strip() if shown.returncode == 0 else ""

    def receipt_checks(self, head: str) -> list:
        work = Path(git(self.repo, "rev-parse", "--absolute-git-dir")) / "work" / "receipts"
        return sorted(json.loads((work / f"{head}.json").read_text())["checks"])

    def close_issue(self, number: int) -> None:
        issues = self.state()["issues"]
        issues[str(number)]["state"] = "CLOSED"
        self.set_state(issues=issues)

    def reopen_issue(self, number: int) -> None:
        issues = self.state()["issues"]
        issues[str(number)]["state"] = "OPEN"
        self.set_state(issues=issues)

    def land_held(self) -> int:
        return land.land(Gh(self.held), self.held, self.config, HELD_SESSION, None, self.summary, None,
                         sleep=self.sleep, clock=self.clock)


class StackedLandTests(StackedFixture):
    # Failure mode 75: verify diffs against, land merges from, opens its pull
    # request into, merges into and reports the claim's own base, never main.
    def test_a_stacked_claim_verifies_against_and_lands_into_its_base(self):
        main_move = self.advance_base("lib/main-only.txt", "main\n")
        git(self.held, "pull", "-q", "--no-rebase", REMOTE, HELD)
        self.commit(self.held, "lib/later.txt", "later\n")
        git(self.held, "push", "-q", REMOTE, f"HEAD:{HELD}")
        self.assertEqual(self.land(), 0)
        [merge] = self.merges()
        head = merge[merge.index("--match-head-commit") + 1]
        pull = self.state()["pulls"][0]
        self.assertEqual((pull["base"], pull["state"]), (HELD, "MERGED"))
        self.assertIn(f"`{REMOTE}/{HELD}`", pull["body"])
        # Only #7's own change is in its diff: the held branch's paths need no check.
        self.assertEqual(self.receipt_checks(head), ["app", "policy"])
        self.assertNotEqual(subprocess.run(["git", "merge-base", "--is-ancestor", main_move, head],
                                           cwd=self.repo).returncode, 0, "main's move reached the stacked claim")
        self.assertEqual(self.remote_file(HELD, "app/a.txt"), "two")
        self.assertEqual(self.remote_file(HELD, "lib/later.txt"), "later")
        self.assertEqual(self.remote_file(BASE, "app/a.txt"), "one")
        # GitHub's "Closes #7" does not apply off the default branch; land closes it and names the base.
        issue = self.issue()
        self.assertEqual((issue["state"], issue["status"]), ("CLOSED", "Done"))
        self.assertTrue(issue["comments"][-1].startswith("Landed in #100 as"), issue["comments"][-1])
        self.assertIn(f"into `{HELD}`", issue["comments"][-1])
        self.assertEqual(self.remote_head(), "")

    # Failure mode 75: a land stopped after its merge into the base resumes.
    def test_a_stacked_land_stopped_after_its_merge_resumes(self):
        self.set_state(failIssue=["close"])
        with self.assertRaises(land.LandError):
            self.land()
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.set_state(failIssue=[])
        self.assertEqual(self.land(summary=False), 0)
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))
        self.assertEqual(len(self.merges()), 1)

    # Failure mode 77: a base is not landed while an open claim is stacked on it;
    # a stacked claim whose issue is closed no longer counts.
    def test_a_base_with_an_open_stacked_claim_does_not_land(self):
        with self.assertRaises(land.LandError) as raised:
            self.land_held()
        self.assertIn(f"#{NUMBER}", str(raised.exception))
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.merges(), [])
        issues = self.state()["issues"]
        issues[str(NUMBER)]["state"] = "CLOSED"
        self.set_state(issues=issues)
        self.assertEqual(self.land_held(), 0)
        self.assertEqual(self.state()["pulls"][-1]["base"], BASE)
        self.assertEqual(self.remote_file(BASE, "lib/held.txt"), "held")

    # Failure mode 77: a claim stacked while its base waits for checks stops the merge.
    def test_a_claim_stacked_during_the_wait_stops_the_merge(self):
        self.close_issue(NUMBER)
        self.set_state(pendingViews=1)

        def stacked_meanwhile(seconds: float) -> None:
            self.sleep(seconds)
            self.reopen_issue(NUMBER)

        with self.assertRaises(land.LandError) as raised:
            land.land(Gh(self.held), self.held, self.config, HELD_SESSION, None, self.summary, None,
                      sleep=stacked_meanwhile, clock=self.clock)
        self.assertIn(f"#{NUMBER}", str(raised.exception))
        self.assertEqual(self.merges(), [])
        self.assertNotEqual(self.remote_head(HELD), "")

    # Failure mode 77: a claim stacked after the merge keeps its base branch.
    def test_a_claim_stacked_after_the_merge_keeps_its_base_branch(self):
        self.close_issue(NUMBER)
        self.set_state(reopenOnMerge=[str(NUMBER)])
        self.assertEqual(self.land_held(), 0)
        self.assertEqual(self.state()["pulls"][-1]["state"], "MERGED")
        self.assertNotEqual(self.remote_head(HELD), "", "the base of an open claim was deleted")

    # Failure mode 78: a pull request retargeted during the wait is not merged.
    def test_a_pull_request_retargeted_during_the_wait_is_not_merged(self):
        self.set_state(pendingViews=1)

        def retargeted_meanwhile(seconds: float) -> None:
            self.sleep(seconds)
            pulls = self.state()["pulls"]
            pulls[0]["base"] = BASE
            self.set_state(pulls=pulls)

        with self.assertRaises(land.LandError) as raised:
            self.land(sleep=retargeted_meanwhile)
        self.assertIn(HELD, str(raised.exception))
        self.assertEqual(self.merges(), [])
        self.assertEqual(self.remote_file(BASE, "app/a.txt"), "one")

    # Failure mode 78: an open pull request into another base is never merged.
    def test_an_open_pull_request_into_another_base_is_refused(self):
        self.set_state(pulls=[{"number": 100, "headRefName": BRANCH, "title": "feat: Add the widget",
                               "body": "Closes #7\n", "base": BASE, "state": "OPEN", "headRefOid": None,
                               "mergeCommit": None}])
        with self.assertRaises(land.LandError) as raised:
            self.land()
        self.assertIn(HELD, str(raised.exception))
        self.assert_nothing_published()


class StackedStewardTests(StackedFixture):
    def open_pull(self, base: str) -> str:
        git(self.repo, "push", "-q", REMOTE, f"HEAD:{BRANCH}")
        head = git(self.repo, "rev-parse", "HEAD")
        self.set_state(pulls=[{"number": 100, "headRefName": BRANCH, "title": "feat: Add the widget",
                               "body": "Closes #7\n", "base": base, "state": "OPEN", "headRefOid": None,
                               "mergeCommit": None}],
                       statuses={head: {"test/verify": "SUCCESS"}})
        return head

    def steward_land(self) -> int:
        clone = self._clone("steward")
        return land.steward(Gh(clone), clone, self.config, NUMBER)

    # Failure mode 75: the steward checks and merges against the claim's base.
    def test_a_stacked_pull_request_lands_into_its_base(self):
        self.open_pull(HELD)
        self.assertEqual(self.steward_land(), 0)
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.assertEqual(self.remote_file(HELD, "app/a.txt"), "two")
        self.assertEqual(self.remote_file(BASE, "app/a.txt"), "one")

    def test_steward_lands_valid_bug_body_with_fenced_evidence_and_handoff(self):
        self.open_pull(HELD)
        issues = self.state()["issues"]
        issues[str(NUMBER)]["labels"] = ["task", "kind:bug"]
        pulls = self.state()["pulls"]
        summary = (" ## Repro\n\n   ```text\nfailed case\n   ```\n\n  ## Cause\n\nCause.\n\n"
                   "   ## Fix\n\nFix.\n")
        pulls[0]["body"] = ("Refs #7\n\n## Summary\n\n" + summary
                             + "\n## Verification\n\nGenerated.\n\n## Maintainer validation\n\n"
                             "Irreducible: physical device\n\nRun the check.\n")
        self.set_state(issues=issues, pulls=pulls)
        self.assertEqual(self.steward_land(), 0)
        self.assertEqual(self.state()["pulls"][0]["state"], "MERGED")
        self.assertIn("Run the check.", self.issue()["comments"][-1])

    def test_steward_refuses_a_bug_pull_request_with_missing_evidence_sections(self):
        self.open_pull(HELD)
        issues = self.state()["issues"]
        issues[str(NUMBER)]["labels"] = ["task", "kind:bug"]
        pulls = self.state()["pulls"]
        pulls[0]["body"] = "Closes #7\n\n## Summary\n\n## Repro\n\nShown.\n\n## Verification\n\nGenerated.\n"
        self.set_state(issues=issues, pulls=pulls)
        with self.assertRaises(land.LandError) as raised:
            self.steward_land()
        self.assertIn("Cause", str(raised.exception))
        self.assertEqual(self.merges(), [])

    # Failure mode 78.
    def test_a_pull_request_into_another_base_is_refused(self):
        self.open_pull(BASE)
        with self.assertRaises(land.LandError) as raised:
            self.steward_land()
        self.assertIn(HELD, str(raised.exception))
        self.assertEqual(self.merges(), [])

    # Failure mode 77.
    def test_a_base_with_an_open_stacked_claim_is_not_landed(self):
        git(self.held, "push", "-q", REMOTE, f"HEAD:{HELD}")
        head = git(self.held, "rev-parse", "HEAD")
        self.set_state(pulls=[{"number": 100, "headRefName": HELD, "title": "feat: Hold the thing",
                               "body": "Closes #9\n", "base": BASE, "state": "OPEN", "headRefOid": None,
                               "mergeCommit": None}],
                       statuses={head: {"test/verify": "SUCCESS"}})
        clone = self._clone("steward")
        with self.assertRaises(land.LandError) as raised:
            land.steward(Gh(clone), clone, self.config, HELD_NUMBER)
        self.assertIn(f"#{NUMBER}", str(raised.exception))
        self.assertEqual(self.merges(), [])


class StackedStartTests(StackedFixture):
    def start(self, number: int, base=None) -> None:
        if not hasattr(self, "primary"):
            self.primary = self._clone("primary")
        start.run(Gh(self.primary), self.primary, self.config, number, SESSION, base)

    def claims_of(self, number: int) -> list:
        return claims.existing_claims(self.held, REMOTE, BASE, number)

    # Failure mode 75: start bases the claim on the fetched base tip and records it.
    def test_a_claim_starts_from_an_open_claim_branch_and_records_it(self):
        self.add_issue(8, "[Task]: Stack the next thing")
        self.start(8, base=HELD)
        [claim] = self.claims_of(8)
        self.assertEqual((claim.session, claim.base), (SESSION, HELD))
        held_tip = git(self.held, "rev-parse", "HEAD")
        self.assertEqual(git(self.held, "rev-parse", f"{claim.sha}^"), held_tip)
        self.assertIn(f"`{HELD}`", self.state()["issues"]["8"]["comments"][-1])

    # Failure mode 76: only the configured base or an open issue's claim branch is a base.
    def test_an_ineligible_base_is_refused_before_any_claim(self):
        self.add_issue(8, "[Task]: Stack the next thing")
        self.add_issue(10, "[Task]: Manual branch")
        self.add_issue(11, "[Task]: Finished", state="CLOSED")
        git(self.seed, "push", "-q", REMOTE, f"{REMOTE}/{BASE}:refs/heads/release")
        git(self.seed, "push", "-q", REMOTE, f"{REMOTE}/{BASE}:refs/heads/feat/10-manual")
        claims.create_claim(self.held, REMOTE, BASE, "feat/11-finished", 11, HELD_SESSION)
        for base in ("release", "feat/12-missing", "feat/10-manual", "feat/11-finished", "feat/8-itself"):
            with self.subTest(base=base):
                with self.assertRaises(claims.ClaimError):
                    self.start(8, base=base)
                self.assertEqual(self.claims_of(8), [])
        self.assertEqual(self.writes(), [])

    # Failure mode 76: a claim's base is fixed for its life.
    def test_a_resumed_claim_keeps_its_base(self):
        with self.assertRaises(claims.ClaimError):
            self.start(NUMBER, base=BASE)
        self.start(NUMBER)
        [claim] = self.claims_of(NUMBER)
        self.assertEqual(claim.base, HELD)


if __name__ == "__main__":
    unittest.main()
