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
    r"(?<![\w.])((?:scripts|packages|config|\.agents|\.github)/[A-Za-z0-9_./-]+)"
)
REPOSITORY_PREFIXES = ("scripts/", "packages/", "config/", ".agents/", ".github/")


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
    candidate: str, *, source: Path, line_number: int, files: set[str]
) -> None:
    candidate = candidate.split()[0].rstrip(".,;:)")
    if not candidate.startswith(REPOSITORY_PREFIXES):
        return
    if any(marker in candidate for marker in ("<", ">", "*", "[", "]", "{", "}", "=")):
        return
    if candidate.endswith("/"):
        return
    # Generated directories such as packages/gateway/dist and build evidence
    # roots are valid documentation subjects but absent in clean checkouts.
    # Validate command paths and file-like literals against source inventory.
    if not (candidate.startswith("scripts/") or Path(candidate).suffix):
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

    print(f"documentation policy passed ({len(paths)} authored files)")


if __name__ == "__main__":
    main()
