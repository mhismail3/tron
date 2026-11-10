#!/usr/bin/env python3
"""Keep sheet loading on the one shared pulse (#890).

A whole-content load is `TronSheetLoadingState`, drawn once and centered by the
enclosing `TronPresentationSurface`; a partial load is `TronLoadingState`. Both
are the chat-opening pulse with a VoiceOver-only label. This lexical guard
rejects the ad-hoc alternatives that wrapped and drifted: indeterminate system
spinners and visible "Loading…" text placeholders, plus any second pulse host.
It cannot prove a placeholder is whole-content; the UI journey proves placement.
"""
import pathlib
import re
import sys
import unittest

HOST = "TronSheetLoadingHostModifier"
HOST_OWNERS = {"UI/Theme/TronPresentation.swift", "State/PresentationActivityCoordinator.swift",
               "App/TronMobileApp.swift"}
SPINNER_ALLOWED = {
    "UI/Chat/ArchivedSessionsSection.swift",
    "UI/Chat/ChatDisplayViews.swift",
    "UI/Chat/HomePinnedRow.swift",
    "UI/Chat/SessionShellView.swift",
    "UI/SwiftApps/SwiftAppDisplayCard.swift",
    "UI/SwiftApps/SwiftAppViews.swift",
}
TEXT_ALLOWED = {
    ("UI/Chat/ChatTranscriptEventViews.swift", "Preparing details…"),
}
COMMENTS = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/')
STRINGS = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
SPINNER = re.compile(r"\bProgressView\s*\((?!\s*value\s*:)")
LOADING_TEXT = re.compile(
    r'\bText\s*\(\s*"((?:Loading|Opening|Preparing|Waiting for|Connecting|Fetching|Inspecting|Calculating)[^"]*(?:…|\.\.\.))"'
)


def _line(code, offset):
    return code.count("\n", 0, offset) + 1


def violations(relative_path, text):
    path = pathlib.PurePosixPath(relative_path).as_posix()
    if not path.startswith(("UI/", "State/")) and path not in HOST_OWNERS:
        return []
    code = COMMENTS.sub(lambda m: "\n" * m.group().count("\n"), text)
    bare = STRINGS.sub(lambda m: '""' + "\n" * m.group().count("\n"), code)
    found = []
    if path not in SPINNER_ALLOWED:
        found += [f"{path}:{_line(bare, m.start())}: indeterminate ProgressView; use TronSheetLoadingState "
                  f"(whole sheet), TronLoadingState (section) or TronPulseLoadingIndicator (control)"
                  for m in SPINNER.finditer(bare)]
    found += [f"{path}:{_line(code, m.start())}: visible loading text \"{m.group(1)}\"; use the shared "
              f"pulse with a VoiceOver label" for m in LOADING_TEXT.finditer(code)
              if (path, m.group(1)) not in TEXT_ALLOWED]
    if path not in HOST_OWNERS:
        found += [f"{path}:{_line(bare, m.start())}: only presentation surfaces and the app root host the sheet pulse"
                  for m in re.finditer(rf"\b{HOST}\b", bare)]
    return found


class PolicyTests(unittest.TestCase):
    def test_rejects_ad_hoc_loading(self):
        for source in ['ProgressView()', 'ProgressView ("Completing setup…")', 'Text("Loading Home…")',
                       'Text( "Waiting for Home..." )', '.modifier(TronSheetLoadingHostModifier())']:
            with self.subTest(source=source):
                self.assertEqual(len(violations("UI/Settings/New.swift", source)), 1)

    def test_accepts_shared_and_determinate(self):
        for source in ['TronSheetLoadingState(label: "Loading Home…", accent: .tronEmerald)',
                       'TronLoadingState(label: "Loading…")', 'ProgressView(value: 3, total: 10)',
                       '// ProgressView()', 'let s = "ProgressView()"', 'Text("Loaded")']:
            with self.subTest(source=source):
                self.assertEqual(violations("UI/Settings/New.swift", source), [])

    def test_owners_and_allowlists_are_exact(self):
        self.assertEqual(violations("State/PresentationActivityCoordinator.swift", ".modifier(TronSheetLoadingHostModifier())"), [])
        self.assertEqual(violations("UI/Chat/HomePinnedRow.swift", "ProgressView()"), [])
        self.assertEqual(len(violations("UI/Chat/HomePinnedRow.swift", 'Text("Loading Home…")')), 1)
        self.assertEqual(violations("App/HostedFixture.swift", "ProgressView()"), [])


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
