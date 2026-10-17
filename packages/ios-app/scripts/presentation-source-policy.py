#!/usr/bin/env python3
"""Guard the native sheet implementation boundary, not arbitrary SwiftUI semantics.

System picker bindings still require behavioral lifecycle tests. App-owned
confirmations must use the shared Tron sheet, including interpreted alerts.
This lexical guard does not prove action admission or dismissal semantics.

It also keeps sheet content's state with its presentation (#1073): SwiftUI
rebuilds a presented sheet's content, with fresh `@State`, when the app returns
from the background, so a view constructed directly as managed-sheet content
(a `tronManagedSheet` closure, or a progressive settings link's destination)
declares `@PresentationState` instead. A `@State` that is genuinely view-local
says why on its line: `// view-local: <reason>`. The behavioral proof is
RealGatewayPairAndChatUITests.testForegroundAndReconnectKeepSheetsAndTheirContent.
"""
import pathlib
import re
import sys

OWNER = pathlib.PurePosixPath("State/PresentationActivityCoordinator.swift")
# The Swift app interpreter replays a displayed app's own `.sheet` modifier inside
# its managed runner sheet; that is the app's presentation, not a Tron surface.
INTERPRETED = pathlib.PurePosixPath("UI/SwiftApps/SwiftAppViews.swift")
# Mask comments/strings so documentation and string literals aren't controls.
NON_CODE = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
PRESENTATION = re.compile(r"\.\s*(sheet|fullScreenCover)\s*\(")
SYSTEM_CONFIRMATION = re.compile(r"\.\s*(?:alert|confirmationDialog|actionSheet)\s*\(|\b(?:Alert|ActionSheet|UIAlertController|UIAlertAction)\b")


def mask(text):
    return NON_CODE.sub(lambda match: "\n" * match.group().count("\n"), text)


def _balanced(code, start, opening, closing):
    """The text inside the bracket at `start`, or None if it never closes."""
    depth = 0
    for index in range(start, len(code)):
        if code[index] == opening:
            depth += 1
        elif code[index] == closing:
            depth -= 1
            if depth == 0:
                return start, index
    return None


def _trailing_closure(code, open_paren):
    span = _balanced(code, open_paren, "(", ")")
    if not span:
        return None
    index = span[1] + 1
    while index < len(code) and code[index] in " \t\n":
        index += 1
    if index >= len(code) or code[index] != "{":
        return None
    inner = _balanced(code, index, "{", "}")
    return code[inner[0] + 1:inner[1]] if inner else None


VIEW = re.compile(r"\bstruct\s+([A-Z]\w*)\s*(?:<[^>{]*>)?\s*:\s*[^{]*\bView\b[^{]*\{")
SHEET_CALL = re.compile(r"\.tronManagedSheet\s*\(|\b(?:TronProgressiveSheetLink|settingsLink)\s*\(")
DESTINATION = re.compile(r"\bdestination\s*:\s*\{")
CONSTRUCTED = re.compile(r"\b([A-Z]\w*)\s*[({]")
STATE = re.compile(r"@State\b")
VIEW_LOCAL = re.compile(r"//\s*view-local:\s*\S")


def sheet_state_violations(sources):
    """`sources` maps a relative path to its text."""
    code = {path: mask(text) for path, text in sources.items()}
    views = {}
    for path, text in code.items():
        for match in VIEW.finditer(text):
            views.setdefault(match.group(1), []).append((path, match.end() - 1))
    roots = set()
    for text in code.values():
        bodies = [_trailing_closure(text, match.end() - 1) for match in SHEET_CALL.finditer(text)]
        for match in DESTINATION.finditer(text):
            span = _balanced(text, match.end() - 1, "{", "}")
            bodies.append(text[span[0] + 1:span[1]] if span else None)
        for body in filter(None, bodies):
            roots.update(name for name in CONSTRUCTED.findall(body) if name in views)
    failures = []
    for name in sorted(roots):
        for path, brace in views[name]:
            span = _balanced(code[path], brace, "{", "}")
            if not span:
                continue
            lines = sources[path].split("\n")
            for match in STATE.finditer(code[path], span[0], span[1]):
                line = code[path].count("\n", 0, match.start()) + 1
                if not VIEW_LOCAL.search(lines[line - 1]):
                    failures.append(
                        f"{path}:{line}: @State in sheet content {name} is reset when SwiftUI rebuilds the "
                        "sheet; use @PresentationState or mark it `// view-local: <reason>`"
                    )
    return failures


def violations(relative_path, text):
    code = NON_CODE.sub(lambda match: "\n" * match.group().count("\n"), text)
    return [
        f"{relative_path}:{code.count(chr(10), 0, match.start()) + 1}: "
        f"raw {match.group(1)} must use the managed presentation owner"
        for match in PRESENTATION.finditer(code)
        if pathlib.PurePosixPath(relative_path) not in (OWNER, INTERPRETED)
    ] + [
        f"{relative_path}:{code.count(chr(10), 0, match.start()) + 1}: "
        "system confirmation must use the shared Tron confirmation sheet"
        for match in SYSTEM_CONFIRMATION.finditer(code)
    ]


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1])
    sources = {path.relative_to(root).as_posix(): path.read_text() for path in sorted(root.rglob("*.swift"))}
    failures = [failure for path, text in sources.items() for failure in violations(path, text)]
    failures += sheet_state_violations(sources)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
