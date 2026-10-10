"""Isolated checks for land's bug-summary contract (failure mode 79 in README.md).

The public CLI rejects malformed bug evidence before it writes or opens a pull request.
The fixture is LandFixture in test_land.py, which owns the fake `gh` and the shared template.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

import test_land
from test_land import BASE, BRANCH, NUMBER, SESSION, LandFixture, git


def setUpModule():
    # Each test_land_*.py module runs in its own process, so it builds the template itself.
    test_land.setUpModule()


class TypeSpecificPullBodyTests(LandFixture):
    """The public CLI must reject malformed bug evidence before writing or opening a PR."""

    BUG_SUMMARY = "## Repro\n\nThe regression is reproduced.\n\n## Cause\n\nThe cause is identified.\n\n## Fix\n\nThe fix is described.\n"

    def cli_land(self, summary: str, labels=None, summary_file=True, existing_body=None, merged=False):
        self.set_state(issues={str(NUMBER): {**self.issue(), "labels": labels or ["task"]}})
        config_path = self.repo / ".github" / "work.json"
        if not config_path.exists():
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config = json.loads(json.dumps(self.config))
            config["verify"]["checks"][0]["paths"].append(".github/**")
            config_path.write_text(json.dumps(config))
            git(self.repo, "add", ".github/work.json")
            git(self.repo, "commit", "-q", "-m", "fixture work configuration")
        if existing_body is not None:
            pull = {"number": 100, "headRefName": BRANCH, "title": "feat: Add the widget",
                    "base": BASE, "body": existing_body, "state": "MERGED" if merged else "OPEN",
                    "headRefOid": git(self.repo, "rev-parse", "HEAD"),
                    "mergeCommit": {"oid": git(self.repo, "rev-parse", "HEAD")} if merged else None}
            self.set_state(pulls=[pull])
        path = self.tmp / "cli-summary.md"
        path.write_text(summary)
        command = [sys.executable, str(Path(__file__).with_name("cli.py")), "land", "--session", SESSION]
        if summary_file:
            command += ["--summary-file", str(path)]
        result = subprocess.run(command, cwd=self.repo, env=os.environ.copy(), capture_output=True, text=True)
        return result

    def assert_rejected_without_publication(self, summary: str):
        before = len(self.calls())
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Repro", result.stderr)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def assert_existing_body_rejected_without_publication(self, summary: str, merged=False):
        body = chr(10).join(("Closes #7", "", "## Summary", "", summary,
                             "## Verification", "", "Generated.", ""))
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=body, merged=merged)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_missing_bug_sections_are_refused_before_any_publication(self):
        self.assert_rejected_without_publication("## Repro\n\nShown.\n\n## Cause\n\nKnown.\n")

    def test_empty_bug_section_is_refused_before_any_publication(self):
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\n   ")
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\n<!-- pending -->\n")

    def test_heading_depth_and_fenced_heading_text_do_not_count(self):
        self.assert_rejected_without_publication(
            "### Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(
            "```md\n## Repro\n```\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_reordered_bug_sections_are_refused(self):
        self.assert_rejected_without_publication(
            "## Cause\n\nKnown.\n\n## Repro\n\nShown.\n\n## Fix\n\nDone.\n")

    def test_verification_heading_cannot_be_confused_with_summary_content(self):
        self.assert_rejected_without_publication(
            self.BUG_SUMMARY + "\n## Verification\n\nThis would shadow generated evidence.\n")

    def test_sibling_heading_ends_a_required_section(self):
        self.assert_rejected_without_publication(
            "## Repro\n\n## Notes\n\nNotes are not reproduction evidence.\n\n"
            "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_empty_fenced_block_is_not_meaningful_content(self):
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n## Cause\n\n```text\n```\n\n## Fix\n\nDone.\n")

    def test_html_comments_cannot_supply_required_sections(self):
        self.assert_rejected_without_publication(
            "<!--\n## Repro\n\nShown.\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n-->\n")

    def test_commented_duplicate_heading_does_not_satisfy_or_duplicate_a_section(self):
        summary = ("## Repro\n\nThe behavior reproduces.\n<!-- ## Repro -->\n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_unclosed_fence_and_duplicate_summary_wrapper_are_refused(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n```md\nexample\n")
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n## Summary\n\nconflicting wrapper\n")

    def test_unclosed_html_comment_is_refused_before_generated_verification(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n<!-- unclosed comment")

    def test_fence_trailer_text_is_not_a_closing_delimiter(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n```md\n```not-a-closing-fence\n")

    def test_nonbreaking_space_is_not_a_fence_closer(self):
        summary = ("## Repro\n\n```text\nfailure\n```\u00a0\n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(summary)

    def test_ascii_space_fence_trailer_is_valid(self):
        summary = ("## Repro\n\n```text\nfailure\n``` \n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_ascii_tab_fence_trailer_is_valid(self):
        summary = ("## Repro\n\n```text\nfailure\n```" + "\t" + "\n\n"
                   "## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_unicode_line_separators_cannot_create_required_sections(self):
        summary = ("## Repro\u2028\u2028Failure.\u2028\u2028## Cause\u2028\u2028Known.\u2028\u2028"
                   "## Fix\u2028\u2028Done.\n")
        self.assert_rejected_without_publication(summary)

    def test_unicode_line_separators_are_rejected_when_adopting_open_pr(self):
        summary = ("## Repro\u2028\u2028Failure.\u2028\u2028## Cause\u2028\u2028Known.\u2028\u2028"
                   "## Fix\u2028\u2028Done.\n")
        self.assert_existing_body_rejected_without_publication(summary)

    def test_unicode_line_separators_are_rejected_on_merged_resume(self):
        summary = ("## Repro\u2028\u2028Failure.\u2028\u2028## Cause\u2028\u2028Known.\u2028\u2028"
                   "## Fix\u2028\u2028Done.\n")
        self.assert_existing_body_rejected_without_publication(summary, merged=True)

    def test_adjacent_hashes_are_not_atx_closing_sequences(self):
        summary = "## Repro###\n\nFailure.\n\n## Cause###\n\nKnown.\n\n## Fix###\n\nDone.\n"
        self.assert_rejected_without_publication(summary)

    def test_adjacent_hashes_are_rejected_when_adopting_open_pr(self):
        summary = "## Repro###\n\nFailure.\n\n## Cause###\n\nKnown.\n\n## Fix###\n\nDone.\n"
        self.assert_existing_body_rejected_without_publication(summary)

    def test_adjacent_hashes_are_rejected_on_merged_resume(self):
        summary = "## Repro###\n\nFailure.\n\n## Cause###\n\nKnown.\n\n## Fix###\n\nDone.\n"
        self.assert_existing_body_rejected_without_publication(summary, merged=True)

    def test_atx_closing_hashes_with_preceding_space_remain_valid(self):
        summary = ("## Repro ###\n\nFailure.\n\n## Cause ##\n\nKnown.\n\n"
                   "## Fix #\n\nDone.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_unclosed_preformatted_block_is_refused_before_generated_verification(self):
        self.assert_rejected_without_publication(self.BUG_SUMMARY + "\n<pre>\n")

    def test_closed_preformatted_block_allows_generated_verification(self):
        result = self.cli_land(self.BUG_SUMMARY + "\n<pre>\nLiteral evidence.\n</pre>\n",
                               labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_unclosed_preformatted_block_is_refused_in_adopted_body(self):
        body = ("Closes #7\n\n## Summary\n\n" + self.BUG_SUMMARY +
                "\n## Verification\n\nGenerated.\n\n<pre>\n")
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=body)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_preformatted_html_headings_cannot_supply_required_sections(self):
        summary = ("## Repro\n\nFailure.\n\n<pre>\n## Cause\n\nKnown.\n\n"
                   "## Fix\n\nDone.\n</pre>\n")
        self.assert_rejected_without_publication(summary)

    def test_preformatted_html_headings_are_rejected_when_adopting_open_pr(self):
        summary = ("## Repro\n\nFailure.\n\n<pre>\n## Cause\n\nKnown.\n\n"
                   "## Fix\n\nDone.\n</pre>\n")
        self.assert_existing_body_rejected_without_publication(summary)

    def test_preformatted_html_headings_are_rejected_on_merged_resume(self):
        summary = ("## Repro\n\nFailure.\n\n<pre>\n## Cause\n\nKnown.\n\n"
                   "## Fix\n\nDone.\n</pre>\n")
        self.assert_existing_body_rejected_without_publication(summary, merged=True)

    def test_four_space_and_tab_fence_markers_are_code_not_closers(self):
        self.assert_rejected_without_publication(
            "## Repro\n\n```text\nfailure\n    ```\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(
            "## Repro\n\n```text\nfailure\n\t```\n\n## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_four_space_or_tab_indented_headings_do_not_count(self):
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n    ## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")
        self.assert_rejected_without_publication(
            "## Repro\n\nShown.\n\n\t## Cause\n\nKnown.\n\n## Fix\n\nDone.\n")

    def test_one_to_three_space_headings_and_fences_are_valid(self):
        summary = (" ## Repro\n\n ```text\nfailure output\n ```\n\n"
                   "  ## Cause\n\n  ```text\nThe parser boundary was wrong.\n  ```\n\n"
                   "   ## Fix\n\n   ```text\nThe boundary was corrected.\n   ```\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_heading_shaped_code_output_counts_as_meaningful_evidence(self):
        summary = ("## Repro\n\n```text\n# Actual failing output\n```\n\n"
                   "## Cause\n\nThe cause is known.\n\n## Fix\n\nThe fix is applied.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_balanced_html_comment_keeps_generated_verification_visible(self):
        summary = ("<!-- evidence context\nnot a heading: ## Verification\n-->\n"
                   + self.BUG_SUMMARY)
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("## Verification", self.state()["pulls"][0]["body"])

    def test_nonempty_fenced_evidence_and_harmless_comments_are_valid(self):
        summary = ("<!-- issue evidence -->\n## Repro\n\n```text\nexpected failure\n```\n\n"
                   "## Cause\n\nThe parser lost the boundary.\n\n<!-- note -->\n## Fix\n\nRestore it.\n")
        result = self.cli_land(summary, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_valid_bug_summary_lands_through_cli_with_generated_verification(self):
        result = self.cli_land(self.BUG_SUMMARY, labels=["task", "kind:bug"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        body = self.state()["pulls"][0]["body"]
        for heading in ("## Repro", "## Cause", "## Fix", "## Verification"):
            self.assertIn(heading, body)

    def test_nonbug_summary_remains_unchanged_through_cli(self):
        result = self.cli_land("Adds the widget.\n", labels=["task", "kind:feature"])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Adds the widget.", self.state()["pulls"][0]["body"])

    def test_adopting_valid_bug_pr_ignores_verification_example_in_fenced_code(self):
        summary = (" ## Repro\n\n   ```text\nfailure\n   ```\n\n  ## Cause\n\nKnown.\n\n"
                   "   ## Fix\n\nDone.\n\n   ```md\n## Verification\n   ```\n")
        body = ("Closes #7\n\n## Summary\n\n" + summary
                + "\n## Verification\n\nGenerated.\n")
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False, existing_body=body)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("   ```md\n## Verification\n   ```", self.state()["pulls"][0]["body"])

    def test_adopting_open_bug_pr_with_confusing_verification_heading_is_refused(self):
        malformed_body = ("Closes #7\n\n## Summary\n\n" + self.BUG_SUMMARY
                          + "\n## Verification\n\nExisting check text.\n\n## Verification\n\nGenerated.\n")
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=malformed_body)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])
        self.assertEqual(self.remote_head(), self.claim_sha)

    def test_merged_bug_resume_validates_the_merged_body(self):
        malformed_body = "Closes #7\n\n## Summary\n\n## Repro\n\nShown.\n\n## Verification\n\nGenerated.\n"
        before = len(self.calls())
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=malformed_body, merged=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.writes(before), [])

    def test_merged_bug_resume_preserves_fenced_headings_and_maintainer_handoff(self):
        summary = (" ## Repro\n\n   ```text\n# Output\n   ```\n\n  ## Cause\n\nKnown.\n\n"
                   "   ## Fix\n\nDone.\n\n   ```md\n\n## Verification\n\n## Maintainer validation\n\n"
                   "Not the handoff.\n   ```\n")
        body = ("Refs #7\n\n## Summary\n\n" + summary + "\n## Verification\n\nGenerated receipt.\n"
                "\n## Maintainer validation\n\nIrreducible: physical device\n\nRun the stated check.\n")
        result = self.cli_land("", labels=["task", "kind:bug"], summary_file=False,
                               existing_body=body, merged=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.issue()["state"], "OPEN")
        self.assertEqual(self.issue()["status"], "Needs you")
        self.assertIn("Run the stated check.", self.issue()["comments"][-1])
        self.assertNotIn("Not the handoff.", self.issue()["comments"][-1])


if __name__ == "__main__":
    unittest.main()
