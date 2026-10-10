"""Claim mechanics: naming, eligibility, and the remote-branch claim (README.md, `start`)."""
from __future__ import annotations

import re
import subprocess
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

ISSUE_TRAILER = "Work-Claim-Issue"
SESSION_TRAILER = "Work-Claim-Session"
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
    if issue["open_blockers"]:
        reasons.append("blocked by open issue(s): " + ", ".join(f"#{n}" for n in issue["open_blockers"]))
    return reasons


def is_active(state: str, labels: List[str], status: Optional[str], rules: dict) -> bool:
    """Whether an issue counts toward the soft cap; `start` and the dashboard both count with this."""
    return (state == "OPEN" and status in rules["activeStatuses"]
            and not set(labels) & set(rules["excludeLabels"]))


def claim_comment(session: str, branch: str, worktree: str, base: str, base_sha: str) -> str:
    # The repository may be public: only paths relative to the checkout's
    # parent directory are published.
    if worktree.startswith(("/", "~")) or re.match(r"^[A-Za-z]:", worktree):
        raise ClaimError(f"refusing to publish an absolute worktree path: {worktree}")
    return (
        f"<!-- work:claim session={session} branch={branch} -->\n"
        f"Claimed by session `{session}`.\n\n"
        f"- Branch: `{branch}`\n"
        f"- Worktree: `{worktree}`\n"
        f"- Base: `{base}` at `{base_sha[:12]}`\n"
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


@dataclass(frozen=True)
class ClaimCommit:
    session: str


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


def claim_commit(repo: Path, range_base: str, head: str, number: int) -> Optional[ClaimCommit]:
    """The claim commit of `number` in `range_base..head`, if any."""
    # Branch-only commits, oldest first; the first carrying this issue's
    # trailer is the claim. Merges from the base branch add only base commits.
    keys = ",".join(f"key={key}" for key in (ISSUE_TRAILER, SESSION_TRAILER))
    log = _git(repo, "log", "--reverse", f"--format=%(trailers:{keys},separator=%x00)%x1e",
               f"{range_base}..{head}").stdout
    for record in log.split("\x1e"):
        fields = {}
        for trailer in record.strip().split("\x00"):
            key, _, value = trailer.partition(":")
            if value.strip():
                fields.setdefault(key.strip(), value.strip())
        if fields.get(ISSUE_TRAILER) == str(number) and fields.get(SESSION_TRAILER):
            return ClaimCommit(fields[SESSION_TRAILER])
    return None


def _read_claims(repo: Path, remote: str, default_base: str, heads: dict) -> List[Claim]:
    if not heads:
        return []
    refspecs = [f"+refs/heads/{b}:refs/remotes/{remote}/{b}" for b in heads]
    _git(repo, "fetch", "-q", "--no-tags", remote,
         f"+refs/heads/{default_base}:refs/remotes/{remote}/{default_base}", *refspecs)
    claims = []
    for b in sorted(heads):
        found = claim_commit(repo, f"{remote}/{default_base}", f"{remote}/{b}", claimed_issue(b))
        claims.append(Claim(b, heads[b], found.session if found else None))
    return claims


def existing_claims(repo: Path, remote: str, default_base: str, number: int) -> List[Claim]:
    """Every remote branch for the issue, with its owner, sorted by name."""
    heads = {b: s for b, s in _remote_heads(repo, remote).items() if claimed_issue(b) == number}
    return _read_claims(repo, remote, default_base, heads)


def all_claims(repo: Path, remote: str, default_base: str) -> List[Claim]:
    """Every claim-style remote branch of every issue, with its owner, sorted by name."""
    heads = {b: s for b, s in _remote_heads(repo, remote).items() if claimed_issue(b) is not None}
    return _read_claims(repo, remote, default_base, heads)


def create_claim(repo: Path, remote: str, base: str, branch: str, number: int, session: str) -> ClaimResult:
    """Claim `number` as `branch`, starting from the fetched tip of `base` and recording it."""
    _git(repo, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{base}:refs/remotes/{remote}/{base}")
    base_sha = _git(repo, "rev-parse", f"{remote}/{base}").stdout.strip()
    message = (
        f"chore: claim #{number}\n\n"
        f"{ISSUE_TRAILER}: {number}\n{SESSION_TRAILER}: {session}\n"
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
