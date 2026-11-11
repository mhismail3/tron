#!/usr/bin/env python3
"""Refuse a code comment added since a base revision (charter: code carries no comments; tools/verify/README.md).

`python3 tools/verify/comments.py --base <rev>` reads each changed code file at HEAD, finds its comments
with a syntax-aware scanner (tokenize for Python; string-, template-, regex- and heredoc-aware lexers for
TypeScript/JavaScript, shell, Swift and CSS) and fails on every comment that starts on a line the diff adds.
Directives tools read stay allowed: shebangs, type/lint/test/coverage pragmas, shellcheck, Swift
`swift-tools-version` and `view-local:` (presentation-source-policy.py), and the tooling purpose line
tools/ownership/layout.py requires. Generated files, third_party/ and non-code files are not read."""
from __future__ import annotations

import argparse
import io
import re
import subprocess
import sys
import tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/ownership"))
import layout  # noqa: E402

GENERATED = re.compile(r"GENERATED.*Do not edit", re.I)
SKIPPED = ("packages/gateway/third_party/",)
DIRECTIVE = {
    "js": re.compile(r"^(@ts-(expect-error|ignore|nocheck|check)\b|(eslint|oxlint)-(disable|enable)|eslint \S+:|"
                     r"prettier-ignore|biome-ignore|@?vitest-environment |c8 ignore|istanbul ignore|v8 ignore|"
                     r"[#@] ?sourceMappingURL=|[#@]__PURE__|[#@]__NO_SIDE_EFFECTS__|@vite-ignore|<reference )"),
    "py": re.compile(r"^(type: |noqa\b|pragma: |pylint: |mypy: |pyright: |fmt: |isort: |-\*- .* -\*-|coding[:=])"),
    "sh": re.compile(r"^shellcheck (disable|enable|source|shell)="),
    "swift": re.compile(r"^(swift-tools-version|swiftlint:|view-local: \S)"),
}


def kind(path: str, text: str) -> str | None:
    if path.startswith(SKIPPED) or GENERATED.search(text[:600]):
        return None
    first = text.split("\n", 1)[0]
    for suffixes, name in (((".ts", ".mts", ".cts", ".mjs", ".cjs", ".js"), "js"), ((".py",), "py"), ((".sh",), "sh"),
                           ((".swift",), "swift"), ((".css",), "css")):
        if path.endswith(suffixes):
            return name
    if "." not in path.rsplit("/", 1)[-1] and first.startswith("#!"):
        return "py" if "python" in first else "sh" if "bash" in first or first.endswith("/sh") else None
    return None


REGEX_AFTER = set("([{,;:=!&|?+-*%<>~^") | {""}
REGEX_KEYWORDS = {"return", "typeof", "case", "in", "of", "new", "delete", "void", "throw", "instanceof", "yield", "await",
                  "else", "do", "extends"}


def js_spans(text: str) -> list[tuple[int, int]]:
    spans, i, n, last = [], 0, len(text), ""
    braces: list[str] = []
    if text.startswith("#!"):
        spans.append((0, line_end(text, 0)))
        i = line_end(text, 0)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif text.startswith("//", i):
            spans.append((i, line_end(text, i)))
            i = line_end(text, i)
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            spans.append((i, end))
            i = end
        elif c in "'\"":
            i += 1
            while i < n and text[i] != c:
                i += 2 if text[i] == "\\" else 1
            i, last = i + 1, "x"
        elif c == "`" or (c == "}" and braces and braces[-1] == "`"):
            if c == "}":
                braces.pop()
            i += 1
            while i < n and text[i] != "`" and not text.startswith("${", i):
                i += 2 if text[i] == "\\" else 1
            if text.startswith("${", i):
                braces.append("`")
                i, last = i + 2, "{"
            else:
                i, last = i + 1, "x"
        elif c in "+-" and text.startswith(c * 2, i):
            last = "x" if last == "x" else c
            i += 2
        elif c == "/" and (last in REGEX_AFTER or last in REGEX_KEYWORDS):
            i, klass = i + 1, False
            while i < n and (klass or text[i] != "/") and text[i] != "\n":
                klass = (klass and text[i] != "]") or (not klass and text[i] == "[")
                i += 2 if text[i] == "\\" else 1
            i += 1
            while i < n and (text[i].isalnum() or text[i] == "_"):
                i += 1
            last = "x"
        elif c.isalnum() or c in "_$#@":
            j = i
            while j < n and (text[j].isalnum() or text[j] in "_$#"):
                j += 1
            word = text[i:max(j, i + 1)]
            last = word if word in REGEX_KEYWORDS else "x"
            i = max(j, i + 1)
        else:
            if c == "{":
                braces.append("{")
            elif c == "}" and braces:
                braces.pop()
            last = ")" if c in ")]" else c
            i += 1
            if last == ")":
                last = "x"
    return spans


def py_spans(text: str) -> list[tuple[int, int]]:
    starts = [0]
    for line in text.split("\n"):
        starts.append(starts[-1] + len(line) + 1)
    return [(starts[token.start[0] - 1] + token.start[1], starts[token.start[0] - 1] + token.start[1] + len(token.string))
            for token in tokenize.generate_tokens(io.StringIO(text).readline) if token.type == tokenize.COMMENT]


def line_end(text: str, index: int) -> int:
    end = text.find("\n", index)
    return len(text) if end < 0 else end


def sh_spans(text: str) -> list[tuple[int, int]]:
    spans, stack, heredocs, i, n = [], [], [], 0, len(text)
    while i < n:
        c, top = text[i], stack[-1] if stack else ""
        if top in ("'",):
            stack.pop() if c == "'" else None
            i += 1
        elif top == "$'":
            i += 2 if c == "\\" else 1
            if c == "'":
                stack.pop()
        elif c == "\\":
            i += 2
        elif top == '"':
            if c == '"':
                stack.pop()
            elif text.startswith("$(", i) and not text.startswith("$((", i):
                stack.append("(")
                i += 1
            elif c == "`":
                stack.append("`")
            i += 1
        elif top == "`" and c == "`":
            stack.pop()
            i += 1
        elif c == "\n":
            i += 1
            for word, tabs in heredocs:
                while i < n:
                    end = line_end(text, i)
                    line, i = text[i:end], end + 1
                    if (line.lstrip("\t") if tabs else line) == word:
                        break
            heredocs = []
        elif c in "'\"`":
            stack.append("$'" if c == "'" and i and text[i - 1] == "$" else c)
            i += 1
        elif text.startswith("$((", i):
            stack.append("((")
            i += 3
        elif text.startswith("$(", i) or text.startswith("${", i):
            stack.append("(" if text[i + 1] == "(" else "{")
            i += 2
        elif c == "(" and top in ("(", "(("):
            stack.append("(")
            i += 1
        elif c == ")" and top in ("(", "(("):
            if top == "((" and text.startswith("))", i):
                i += 1
            stack.pop()
            i += 1
        elif c == "}" and top == "{":
            stack.pop()
            i += 1
        elif top == "{":
            i += 1
        elif text.startswith("<<<", i):
            i += 3
        elif text.startswith("<<", i) and \
                (match := re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", text[i:])):
            heredocs.append((match.group(3), match.group(1) == "-"))
            i += match.end()
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            spans.append((i, line_end(text, i)))
            i = line_end(text, i)
        else:
            i += 1
    return spans


SWIFT_STRING = re.compile(r'(#*)("""|")')
SWIFT_REGEX = re.compile(r"(#+)/")


def swift_spans(text: str) -> list[tuple[int, int]]:
    spans, i, n = [], 0, len(text)
    modes: list[tuple[str, int]] = []
    while i < n:
        mode, hashes = modes[-1] if modes else ("code", 0)
        if mode in ("string", "multiline"):
            closer = ('"""' if mode == "multiline" else '"') + "#" * hashes
            if text.startswith("\\" + "#" * hashes + "(", i):
                modes.append(("code", -1))
                i += 2 + hashes
            elif text[i] == "\\" and not hashes:
                i += 2
            elif text.startswith(closer, i):
                modes.pop()
                i += len(closer)
            else:
                i += 1
            continue
        if text.startswith("//", i):
            spans.append((i, line_end(text, i)))
            i = line_end(text, i)
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += 1 if text.startswith("/*", j) else -1 if text.startswith("*/", j) else 0
                j += 2 if text.startswith(("/*", "*/"), j) else 1
            spans.append((i, j))
            i = j
        elif match := SWIFT_STRING.match(text, i):
            modes.append(("multiline" if match.group(2) == '"""' else "string", len(match.group(1))))
            i = match.end()
        elif match := SWIFT_REGEX.match(text, i):
            end = text.find("/" + match.group(1), match.end())
            i = n if end < 0 else end + 1 + len(match.group(1))
        elif text[i] == "(" and modes and hashes == -1:
            modes.append(("code", -1))
            i += 1
        elif text[i] == ")" and modes and hashes == -1:
            modes.pop()
            i += 1
        else:
            i += 1
    return spans


def css_spans(text: str) -> list[tuple[int, int]]:
    spans, i, quote = [], 0, ""
    while i < len(text):
        if quote:
            if text[i] == "\\":
                i += 2
                continue
            quote = "" if text[i] == quote else quote
            i += 1
        elif text[i] in "'\"":
            quote, i = text[i], i + 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = len(text) if end < 0 else end + 2
            spans.append((i, end))
            i = end
        else:
            i += 1
    return spans


def allowed(kind_: str, text: str, start: int, end: int, purpose: str) -> bool:
    body = text[start:end]
    if start == 0 and body.startswith("#!"):
        return True
    inner = re.sub(r"^(//+|/\*+|#)\s*|\s*\*+/$", "", body).strip()
    if purpose and "\n" not in body and inner.startswith(purpose) and at_head(kind_, text, start):
        return True
    return kind_ in DIRECTIVE and bool(DIRECTIVE[kind_].search(inner))


def at_head(kind_: str, text: str, start: int) -> bool:
    for line in text[:start].split("\n")[:-1]:
        stripped = line.strip()
        inner = re.sub(r"^(//+|/\*+|#)\s*|\s*\*+/$", "", stripped).strip()
        if stripped and not stripped.startswith("#!") and not (kind_ in DIRECTIVE and DIRECTIVE[kind_].search(inner)):
            return False
    return True


def new_purpose(base: str, path: str, mode: str, text: str) -> str:
    if not layout.is_tooling(path, mode):
        return ""
    purpose = layout.purpose(text.encode())
    before = subprocess.run(["git", "show", f"{base}:{path}"], cwd=ROOT, capture_output=True).stdout
    old = layout.purpose(before) if before else ""
    return purpose if not old or old == purpose or old not in text else ""


def added_lines(base: str, path: str) -> set[int]:
    diff = subprocess.run(["git", "diff", "-U0", "--no-color", "--no-ext-diff", f"{base}..HEAD", "--", path], cwd=ROOT,
                          capture_output=True, text=True, check=True).stdout
    lines = set()
    for match in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", diff, re.M):
        first, count = int(match.group(1)), int(match.group(2) or 1)
        lines.update(range(first, first + count))
    return lines


def check(base: str) -> list[str]:
    changed = subprocess.run(["git", "diff", "--name-only", "--diff-filter=AMR", "-z", f"{base}..HEAD"], cwd=ROOT,
                             capture_output=True, text=True, check=True).stdout.split("\0")
    modes = {line.split("\t", 1)[1]: line.split()[0] for line in subprocess.run(
        ["git", "ls-files", "-s"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()}
    files = {}
    for path in filter(None, changed):
        try:
            text = subprocess.run(["git", "show", f"HEAD:{path}"], cwd=ROOT, capture_output=True, check=True).stdout.decode()
        except (subprocess.CalledProcessError, UnicodeDecodeError):
            continue
        if found := kind(path, text):
            files[path] = (found, text)
    scanners = {"js": js_spans, "py": py_spans, "sh": sh_spans, "swift": swift_spans, "css": css_spans}
    problems = []
    for path, (found, text) in sorted(files.items()):
        added = added_lines(base, path)
        purpose = new_purpose(base, path, modes.get(path, ""), text)
        for start, end in scanners[found](text):
            line = text.count("\n", 0, start) + 1
            if line in added and not allowed(found, text, start, end, purpose):
                problems.append(f"{path}:{line}: new comment `{text[start:end].splitlines()[0][:80]}`")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--base", required=True)
    problems = check(parser.parse_args().base)
    for problem in problems:
        print(problem)
    if problems:
        print(f"comments: {len(problems)} new comment(s); code carries no comments (AGENTS.md): put the rationale in "
              "the commit message or the owning module's doc, and keep only directives a tool reads")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
