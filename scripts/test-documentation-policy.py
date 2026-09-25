#!/usr/bin/env python3
"""Exercise source-comment path checks without changing repository files."""

from __future__ import annotations

from pathlib import Path
import importlib.util
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "check_documentation_policy", ROOT / "scripts/check-documentation-policy.py"
)
assert SPEC is not None and SPEC.loader is not None
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class DocumentationPolicyTests(unittest.TestCase):
    def test_source_comments_ignore_quoted_examples(self) -> None:
        source = 'const example = "// `packages/missing.ts`"; // `packages/real.ts`\n'
        comments = policy.source_comments(source, ".ts")
        self.assertEqual(comments, [(1, " `packages/real.ts`")])

    def test_source_comments_ignore_multiline_strings(self) -> None:
        source = '\'\'\'\n# `packages/not-a-comment.ts`\n\'\'\'\n# `packages/real.ts`\n'
        self.assertEqual(
            policy.source_comments(source, ".py"),
            [(4, " `packages/real.ts`")],
        )

    def test_source_comments_support_block_and_hash_comments(self) -> None:
        self.assertEqual(
            policy.source_comments("/* `docs/missing.md` */\n", ".swift"),
            [(1, " `docs/missing.md` ")],
        )
        self.assertEqual(
            policy.source_comments('value = "# not a comment" # `scripts/tool.sh`\n', ".py"),
            [(1, " `scripts/tool.sh`")],
        )

    def test_repository_comment_path_uses_existing_validation(self) -> None:
        source = ROOT / "fixture.ts"
        with self.assertRaisesRegex(SystemExit, "missing repository path: packages/missing.ts"):
            policy.validate_repository_literal(
                "packages/missing.ts", source=source, line_number=1, files=set(),
            )
        with self.assertRaisesRegex(SystemExit, "missing repository path: packages/missing-directory"):
            policy.validate_repository_literal(
                "packages/missing-directory", source=source, line_number=1,
                files=set(), check_directories=True,
            )
        for literal in (
            "packages/<name>.ts", "packages/*.ts", "packages/build/generated.ts",
            "https://example.test/packages/no.ts",
        ):
            policy.validate_repository_literal(
                literal, source=source, line_number=1, files=set(),
            )


if __name__ == "__main__":
    unittest.main()
