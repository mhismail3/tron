#!/usr/bin/env python3
"""Guard the native sheet implementation boundary, not arbitrary SwiftUI semantics.

System picker/alert bindings still require behavioral lifecycle tests. This
lexical guard deliberately makes no claim to prove their binding equivalence.
"""
import pathlib
import re
import sys
import unittest

OWNER = pathlib.PurePosixPath("State/PresentationActivityCoordinator.swift")
# Mask comments/strings so documentation and string literals aren't controls.
NON_CODE = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
PRESENTATION = re.compile(r"\.\s*(sheet|fullScreenCover)\s*\(")


def violations(relative_path, text):
    code = NON_CODE.sub(lambda match: "\n" * match.group().count("\n"), text)
    return [
        f"{relative_path}:{code.count(chr(10), 0, match.start()) + 1}: "
        f"raw {match.group(1)} must use the managed presentation owner"
        for match in PRESENTATION.finditer(code)
        if pathlib.PurePosixPath(relative_path) != OWNER
    ]


class BoundaryTests(unittest.TestCase):
    def test_owner_and_literals_are_not_consumers(self):
        self.assertEqual(violations(str(OWNER), "view.sheet (item: $route) {}"), [])
        self.assertEqual(violations("UI/Test.swift", '// .sheet(x)\nlet x = ".sheet(x)"'), [])
        self.assertEqual(violations("UI/Test.swift", 'switch surface ?? .sheet { case .sheet: break }'), [])

    def test_relocation_cannot_hide_behind_total_count(self):
        # Even if a caller replaces a removed owner call, its path is forbidden.
        self.assertEqual(len(violations("UI/Test.swift", "view.sheet(item: $route) {}")), 1)

    def test_whitespace_and_alternate_native_presentation(self):
        for source in ["view.sheet (item: $route) {}", "view.\n sheet\n(item: $route) {}", "view.fullScreenCover(isPresented: $flag) {}"]:
            with self.subTest(source=source):
                self.assertEqual(len(violations("UI/Test.swift", source)), 1)


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        unittest.main(argv=[sys.argv[0]])
    else:
        root = pathlib.Path(sys.argv[1])
        failures = [failure for path in sorted(root.rglob("*.swift"))
                    for failure in violations(path.relative_to(root).as_posix(), path.read_text())]
        if failures:
            print("\n".join(failures), file=sys.stderr)
            sys.exit(1)
