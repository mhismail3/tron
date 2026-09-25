#!/usr/bin/env python3
"""Check durable repository-documentation navigation and path contracts."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
EXCLUDED_PARTS = {"build", "dist", "node_modules", "DerivedData", ".build"}
MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
BACKTICK = re.compile(r"`([^`]+)`")
FENCED_PATH = re.compile(
    r"(?<![\w.])((?:scripts|packages|docs|config|\.agents|\.github)/[A-Za-z0-9_./-]+)"
)
REPOSITORY_PREFIXES = (
    "packages/", "scripts/", "docs/", "config/", ".agents/", ".github/",
)
SOURCE_SUFFIXES = {
    ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs",
    ".c", ".h", ".swift", ".py", ".sh",
}


def fail(message: str) -> None:
    raise SystemExit(f"documentation policy: {message}")


def repository_files() -> set[str]:
    listed = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "--cached", "--others", "--exclude-standard"],
        text=True,
    ).splitlines()
    return {relative for relative in listed if (ROOT / relative).is_file()}


def markdown_paths(files: set[str]) -> list[Path]:
    return [
        ROOT / relative
        for relative in sorted(files)
        if relative.endswith((".md", ".mdx"))
        and not EXCLUDED_PARTS.intersection(Path(relative).parts)
    ]


def source_comments(source: str, suffix: str) -> list[tuple[int, str]]:
    """Return comment text without treating quoted path examples as comments."""
    hash_comments = suffix in {".py", ".sh"}
    comments: list[tuple[int, str]] = []
    block = False
    multiline_quote = ""
    for line_number, line in enumerate(source.splitlines(), 1):
        pieces: list[str] = []
        quote = multiline_quote
        escaped = False
        index = 0
        while index < len(line):
            pair = line[index:index + 2]
            char = line[index]
            if block:
                if pair == "*/":
                    block = False
                    index += 2
                else:
                    pieces.append(char)
                    index += 1
            elif quote:
                if len(quote) == 3 and line.startswith(quote, index):
                    quote = ""
                    index += 3
                elif len(quote) == 1 and escaped:
                    escaped = False
                    index += 1
                elif len(quote) == 1 and char == "\\":
                    escaped = True
                    index += 1
                elif len(quote) == 1 and char == quote:
                    quote = ""
                    index += 1
                else:
                    index += 1
            elif char in {'"', "'", "`"}:
                quote = char * 3 if line.startswith(char * 3, index) else char
                index += len(quote)
            elif pair == "/*" and not hash_comments:
                block = True
                index += 2
            elif pair == "//" and not hash_comments:
                pieces.append(line[index + 2:])
                break
            elif char == "#" and hash_comments:
                pieces.append(line[index + 1:])
                break
            else:
                index += 1
        multiline_quote = quote if len(quote) == 3 else ""
        if pieces:
            comments.append((line_number, "".join(pieces)))
    return comments


def heading_anchors(source: str) -> set[str]:
    anchors: set[str] = set()
    counts: dict[str, int] = {}
    for line in source.splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*$", line)
        if not match:
            continue
        value = re.sub(r"<[^>]+>", "", match.group(1)).strip().lower()
        value = re.sub(r"[^\w\- ]", "", value)
        value = re.sub(r"\s+", "-", value)
        count = counts.get(value, 0)
        counts[value] = count + 1
        anchors.add(value if count == 0 else f"{value}-{count}")
    return anchors


def validate_repository_literal(
    candidate: str, *, source: Path, line_number: int, files: set[str],
    check_directories: bool = False,
) -> None:
    candidate = candidate.split()[0].rstrip(".,;:)")
    if not candidate.startswith(REPOSITORY_PREFIXES):
        return
    if any(marker in candidate for marker in ("<", ">", "*", "[", "]", "{", "}", "=")):
        return
    if EXCLUDED_PARTS.intersection(Path(candidate).parts):
        return
    if candidate.endswith("/"):
        return
    # Generated directories such as packages/gateway/dist and build evidence
    # roots are valid documentation subjects but absent in clean checkouts.
    # Validate command paths and file-like literals against source inventory.
    if not (candidate.startswith("scripts/") or Path(candidate).suffix):
        if not check_directories:
            return
        if any(relative.startswith(f"{candidate.rstrip('/')}/") for relative in files):
            return
    # Markdown links often repeat a docs/ path relative to their owning doc.
    if source.suffix in {".md", ".mdx"} and candidate.startswith("docs/"):
        package_index = source.relative_to(ROOT).parts[:1] == ("packages",)
        if (source.parent / candidate).exists():
            return
        if package_index and (ROOT / Path(*source.relative_to(ROOT).parts[:2]) / candidate).exists():
            return
    if candidate not in files:
        relative_source = source.relative_to(ROOT)
        fail(f"{relative_source}:{line_number}: missing repository path: {candidate}")


def main() -> None:
    files = repository_files()
    paths = markdown_paths(files)
    sources = {path: path.read_text() for path in paths}
    readme_lines = len(sources[ROOT / "README.md"].splitlines())
    if readme_lines > 250:
        fail(f"README.md has {readme_lines} lines; maximum is 250")

    anchors = {path: heading_anchors(source) for path, source in sources.items()}
    for path, source in sources.items():
        relative_source = path.relative_to(ROOT)
        in_fence = False
        for line_number, line in enumerate(source.splitlines(), 1):
            if line.lstrip().startswith(("```", "~~~")):
                in_fence = not in_fence
                continue
            for destination in MARKDOWN_LINK.findall(line):
                target = destination.split()[0].strip("<>")
                if re.match(r"^[A-Za-z][\w+.-]*:", target):
                    continue
                file_part, separator, anchor = target.partition("#")
                if not file_part:
                    target_path = path
                else:
                    target_path = (path.parent / file_part).resolve()
                    try:
                        target_path.relative_to(ROOT)
                    except ValueError:
                        fail(f"{relative_source}:{line_number}: link escapes repository: {target}")
                if not target_path.exists():
                    fail(f"{relative_source}:{line_number}: missing link target: {target}")
                if separator and anchor and target_path in anchors and anchor.lower() not in anchors[target_path]:
                    fail(f"{relative_source}:{line_number}: missing heading anchor: {target}")

            for literal in BACKTICK.findall(line):
                validate_repository_literal(
                    literal, source=path, line_number=line_number, files=files
                )
            if in_fence:
                for candidate in FENCED_PATH.findall(line):
                    validate_repository_literal(
                        candidate, source=path, line_number=line_number, files=files
                    )

    tracked = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files"], text=True
    ).splitlines()
    for relative in sorted(tracked):
        source_path = Path(relative)
        if source_path.suffix not in SOURCE_SUFFIXES:
            continue
        if EXCLUDED_PARTS.intersection(source_path.parts):
            continue
        path = ROOT / source_path
        if not path.is_file():
            continue
        source_text = path.read_text()
        if not any(f"`{prefix}" in source_text for prefix in REPOSITORY_PREFIXES):
            continue
        for line_number, comment in source_comments(source_text, source_path.suffix):
            for literal in BACKTICK.findall(comment):
                validate_repository_literal(
                    literal, source=path, line_number=line_number, files=files,
                    check_directories=True,
                )

    print(f"documentation policy passed ({len(paths)} authored files)")


if __name__ == "__main__":
    main()
