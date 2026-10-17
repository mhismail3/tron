"""Claim mechanics: naming, eligibility, and the remote-branch claim (README.md, `start`)."""
from __future__ import annotations

import json
import re
import subprocess
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

ISSUE_TRAILER = "Work-Claim-Issue"
SESSION_TRAILER = "Work-Claim-Session"
BASE_TRAILER = "Work-Claim-Base"
AREAS_TRAILER = "Work-Claim-Areas"
_MAX_SLUG_WORDS = 5
# `<type>/<issue>-<slug>`; group 1 is the issue number.
_CLAIM_BRANCH = re.compile(r"^[a-z0-9._-]+/([0-9]+)-")


class ClaimError(RuntimeError):
    pass


# ------------------------------------------------------------------- naming


def slugify(title: str) -> str:
    # Issue forms prefix titles with "[Task]: "; that is not part of the outcome.
    title = re.sub(r"^\s*\[[^\]]*\]:?\s*", "", title)
    ascii_title = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode()
    words = re.findall(r"[a-z0-9]+", ascii_title.lower())
    return "-".join(words[:_MAX_SLUG_WORDS]) or "work"


def branch_name(branch_type: str, number: int, slug: str) -> str:
    return f"{branch_type}/{number}-{slug}"


def claimed_issue(branch: str) -> Optional[int]:
    """The issue a claim-style branch name is for, or None for any other branch."""
    match = _CLAIM_BRANCH.match(branch)
    return int(match.group(1)) if match else None


def branch_type(labels: List[str], rules: dict) -> str:
    for mapping in rules.get("branchTypes", []):
        if mapping["label"] in labels:
            return mapping["type"]
    return rules["defaultBranchType"]


# -------------------------------------------------------------- eligibility


def ineligibility(issue: dict, rules: dict) -> List[str]:
    """Reasons the issue cannot be claimed; empty when it can. Any open, unclaimed, non-epic issue may be claimed."""
    reasons: List[str] = []
    if issue["state"] != "OPEN":
        reasons.append("issue is closed")
    excluded = sorted(set(issue["labels"]) & set(rules["excludeLabels"]))
    if excluded:
        reasons.append("issue is labeled " + ", ".join(excluded) + "; claim one of its tasks instead")
    return reasons


def normalized_areas(values) -> tuple:
    """Literal repo-relative prefixes; absence means unknown, never disjoint."""
    if not isinstance(values, (list, tuple)) or len(values) > 16:
        raise ClaimError("areas must be at most 16 repo-relative path prefixes")
    areas = set()
    for value in values:
        if not isinstance(value, str) or not value or len(value) > 256:
            raise ClaimError("areas must be repo-relative path prefixes of 1–256 characters")
        value = value.rstrip("/")
        if value != "." and (not re.fullmatch(r"[A-Za-z0-9_.@+/-]+", value)
                             or any(part in ("", ".", "..") for part in value.split("/"))):
            raise ClaimError("areas must be literal repo-relative paths (no traversal, glob or absolute path)")
        areas.add(value)
    return tuple(sorted(areas))


def area_advice(areas: tuple, others: list, exclude: Optional[str] = None) -> dict:
    """Predictions guide Home, not admission: a claimed branch need not be running."""
    overlapping, unknown = [], []
    for other in others:
        if other.branch == exclude:
            continue
        row = {"issue": claimed_issue(other.branch), "branch": other.branch, "areas": list(other.areas)}
        if not areas or not other.areas:
            unknown.append(row)
            continue
        intersections = sorted({b if a == "." or b.startswith(a + "/") else a
                                for a in areas for b in other.areas
                                if a == b or a == "." or b == "." or a.startswith(b + "/") or b.startswith(a + "/")})
        if intersections:
            overlapping.append({**row, "intersections": intersections})
    return {"areas": list(areas), "overlapping": overlapping, "unknown": unknown}


def render_advice(advice: dict) -> str:
    lines = ["predicted areas: " + (", ".join(advice["areas"]) or "unknown")]
    for other in advice["overlapping"]:
        lines.append(f"  overlap #{other['issue']} ({other['branch']}): " + ", ".join(other["intersections"]))
    if advice["unknown"]:
        lines.append("  overlap unknown: " + ", ".join(f"#{other['issue']}" for other in advice["unknown"]))
    lines.append("  advisory only: retained claims are not proof of running work; confirm with Home before sequencing")
    return "\n".join(lines)


def claim_comment(session: str, branch: str, worktree: str, base: str, base_sha: str, areas: tuple = ()) -> str:
    # The repository may be public: only paths relative to the checkout's
    # parent directory are published.
    if worktree.startswith(("/", "~")) or re.match(r"^[A-Za-z]:", worktree):
        raise ClaimError(f"refusing to publish an absolute worktree path: {worktree}")
    return (
        f"<!-- work:claim session={session} branch={branch} -->\n"
        f"Claimed by session `{session}`.\n\n"
        f"- Branch: `{branch}`\n"
        f"- Worktree: `{worktree}`\n"
        f"- Base: `{base}` at `{base_sha}`\n"
        f"- Predicted areas: {', '.join('`' + area + '`' for area in areas) or 'unknown (do not assume disjoint)'}\n"
    )


# --------------------------------------------------------------- git claim


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if check and completed.returncode != 0:
        raise ClaimError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed


@dataclass
class Claim:
    branch: str
    sha: str
    session: Optional[str]  # None when the branch has no claim commit
    base: Optional[str] = None
    base_sha: Optional[str] = None
    areas: tuple = ()


@dataclass(frozen=True)
class ClaimCommit:
    session: str
    base: Optional[str] = None
    base_sha: Optional[str] = None
    areas: tuple = ()


@dataclass
class ClaimResult:
    won: bool
    sha: str
    base: str


def _remote_heads(repo: Path, remote: str) -> dict:
    output = _git(repo, "ls-remote", "--heads", remote).stdout
    heads = {}
    for line in output.splitlines():
        sha, ref = line.split("\t")
        heads[ref[len("refs/heads/"):]] = sha
    return heads


def claim_commit(repo: Path, head: str, number: int) -> Optional[ClaimCommit]:
    """Newest owner and creation base survive a plain push of the claim to main."""
    keys = ",".join(f"key={key}" for key in (ISSUE_TRAILER, SESSION_TRAILER, BASE_TRAILER, AREAS_TRAILER))
    log = _git(repo, "log", "--first-parent", f"--format=%P%x1f%(trailers:{keys},separator=%x00)%x1e",
               f"--grep=^{ISSUE_TRAILER}: {number}$", head).stdout
    session = None
    for record in log.split("\x1e"):
        parents, separator, trailers = record.strip().partition("\x1f")
        if not separator:
            continue
        fields = {}
        for trailer in trailers.split("\x00"):
            key, _, value = trailer.partition(":")
            if value.strip():
                fields.setdefault(key.strip(), value.strip())
        if fields.get(ISSUE_TRAILER) != str(number) or not fields.get(SESSION_TRAILER):
            continue
        session = session or fields[SESSION_TRAILER]
        # Handoff changes the owner, not the creation base. Its receipt remains
        # on the same first-parent chain; no second mutable copy is needed.
        if fields.get(BASE_TRAILER) and len(parents.split()) == 1:
            try:
                areas = normalized_areas(json.loads(fields.get(AREAS_TRAILER, "[]")))
            except (ValueError, ClaimError):
                areas = ()  # Damaged predictions cannot prove disjointness.
            return ClaimCommit(session, fields[BASE_TRAILER], parents.strip(), areas)
    return ClaimCommit(session) if session else None


def _read_claims(repo: Path, remote: str, default_base: str, heads: dict) -> List[Claim]:
    if not heads:
        return []
    refspecs = [f"+refs/heads/{b}:refs/remotes/{remote}/{b}" for b in heads]
    _git(repo, "fetch", "-q", "--no-tags", remote,
         f"+refs/heads/{default_base}:refs/remotes/{remote}/{default_base}", *refspecs)
    claims = []
    for b in sorted(heads):
        found = claim_commit(repo, f"{remote}/{b}", claimed_issue(b))
        # Branch names are navigation, not ownership. Ordinary checkpoints
        # must not impersonate another worker's claim (#1270).
        if found:
            claims.append(Claim(b, heads[b], found.session, found.base, found.base_sha, found.areas))
    return claims


def existing_claims(repo: Path, remote: str, default_base: str, number: int) -> List[Claim]:
    """Every remote branch for the issue, with its owner, sorted by name."""
    heads = {b: s for b, s in _remote_heads(repo, remote).items() if claimed_issue(b) == number}
    return _read_claims(repo, remote, default_base, heads)


def all_claims(repo: Path, remote: str, default_base: str) -> List[Claim]:
    """Every claim-style remote branch of every issue, with its owner, sorted by name."""
    heads = {b: s for b, s in _remote_heads(repo, remote).items() if claimed_issue(b) is not None}
    return _read_claims(repo, remote, default_base, heads)


def create_claim(repo: Path, remote: str, base: str, branch: str, number: int, session: str,
                 areas: tuple = ()) -> ClaimResult:
    """Claim `number` as `branch`, starting from the fetched tip of `base` and recording it."""
    _git(repo, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{base}:refs/remotes/{remote}/{base}")
    base_sha = _git(repo, "rev-parse", f"{remote}/{base}").stdout.strip()
    message = (
        f"chore: claim #{number}\n\n"
        f"{ISSUE_TRAILER}: {number}\n{SESSION_TRAILER}: {session}\n{BASE_TRAILER}: {base}\n"
        f"{AREAS_TRAILER}: {json.dumps(list(areas), separators=(',', ':'))}\n"
    )
    tree = _git(repo, "rev-parse", f"{base_sha}^{{tree}}").stdout.strip()
    sha = _git(repo, "commit-tree", tree, "-p", base_sha, "-m", message).stdout.strip()
    # Create-only: an empty expected value makes the remote reject the update
    # if the ref exists, even when it points at the same commit.
    pushed = _git(
        repo, "push", "--porcelain", f"--force-with-lease=refs/heads/{branch}:", remote,
        f"{sha}:refs/heads/{branch}", check=False,
    )
    return ClaimResult(won=pushed.returncode == 0, sha=sha, base=base_sha)


def resolve_race(repo: Path, remote: str, default_base: str, number: int, session: str) -> bool:
    """After claiming, keep the claim only if it is the issue's smallest branch name.

    Every claimant applies the same rule, so exactly one survives; a loser
    deletes only its own ref, and only at the commit it pushed.
    """
    claims = existing_claims(repo, remote, default_base, number)
    if not claims:
        raise ClaimError(f"no branch exists for #{number} after claiming")
    if claims[0].session == session:
        return True
    for claim in claims[1:]:
        if claim.session == session:
            _git(repo, "push", "-q", f"--force-with-lease=refs/heads/{claim.branch}:{claim.sha}",
                 remote, f":refs/heads/{claim.branch}", check=False)
    return False
