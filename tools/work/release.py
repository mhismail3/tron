"""`work release`: give up a stale claim on an open issue, preserving its work first (README.md, `release`)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Tuple

import claim as claims
import cleanup
import handoff
import land
import start
from gh import Gh

# Owner states the Gateway helper may return that admit a release. `absent` is
# release-only: nothing in the Gateway carries the owner id, and the work is
# preserved before the claim goes. Handoff and recover still need `settled`.
RELEASABLE = {"settled", "absent"}
# `release --stale` sweeps only claims with no claim-branch commit and no issue comment for this long.
STALE_HOURS = 72
# The Gateway's session id shape (packages/gateway/src/client/work-owner-status.ts). Among indeterminate
# owners a maintainer may force-release only one outside it (a legacy owner no Gateway knows); a
# Gateway-shaped indeterminate owner (a delegated session, an unsettled Home task, an unreadable Gateway)
# is never forced. A listed `idle` session with no Home task is the maintainer's to release (#1001).
_GATEWAY_SESSION = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


class ReleaseError(RuntimeError):
    pass


def _git(cwd: Path, *args: str, env: Optional[dict] = None, check: bool = True) -> str:
    completed = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                               env={**os.environ, **(env or {})})
    if check and completed.returncode:
        raise ReleaseError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout.strip()


def _claim_only(repo: Path, base_ref: str, head: str) -> Optional[str]:
    """Why the published claim branch carries work, or None when it is only claim/handoff commits."""
    commits = _git(repo, "rev-list", "--parents", head, "--not", base_ref).splitlines()
    if not commits:
        return f"it has no commit beyond {base_ref}"
    for line in commits:
        commit, *parents = line.split()
        if len(parents) != 1:
            return f"commit {commit[:12]} has {len(parents)} parents"
        if _git(repo, "rev-parse", f"{commit}^{{tree}}") != _git(repo, "rev-parse", f"{parents[0]}^{{tree}}"):
            return f"commit {commit[:12]} changes files; land, hand off or recover that work instead"
    return None


def _kept_ignored(path: Path, settings: cleanup.Settings) -> List[str]:
    """Ignored files that are not regenerable (progress notes, logs): preserved with the snapshot.

    A nested checkout with its own local data is refused rather than flattened into the snapshot.
    """
    regenerable = cleanup._regenerable(settings.regenerable)
    kept = []
    for entry in sorted(p for p in _git(path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z")
                        .split("\0") if p):
        if not regenerable.fullmatch(entry.rstrip("/")):
            if entry.endswith("/"):
                raise ReleaseError(f"{entry} is an ignored nested directory that is not regenerable; preserve it by hand")
            kept.append(entry)
        elif entry.endswith("/"):
            problem = cleanup._nested_checkout_problem(path / entry)
            if problem:
                raise ReleaseError(f"nested checkout {entry} holds {problem}; preserve it by hand")
    return kept


def _snapshot_tree(path: Path, settings: cleanup.Settings) -> str:
    """The worktree's whole state as a tree: tracked edits, untracked and non-regenerable ignored files.

    A private temporary index is used, so the worktree's own index and files are never touched.
    """
    with tempfile.TemporaryDirectory(prefix="tron-work-release-") as scratch:
        env = {"GIT_INDEX_FILE": str(Path(scratch) / "index")}
        _git(path, "read-tree", "HEAD", env=env)
        _git(path, "add", "-A", "--", ".", env=env)
        kept = _kept_ignored(path, settings)
        for start_index in range(0, len(kept), 500):
            _git(path, "add", "-f", "--", *kept[start_index:start_index + 500], env=env)
        return _git(path, "write-tree", env=env)


def _owner(repo: Path, number: int, head: str, force: bool) -> str:
    _, owner = handoff._claim_at(repo, head, number)
    if not owner:
        if force:
            return "unknown"
        raise ReleaseError(f"#{number}'s claim records no owner session; the owner is unknown, so the claim stays "
                           "(a maintainer may use --force-maintainer from a real terminal)")
    return owner


def _admit_owner(owner: str, force: bool = False) -> Tuple[str, str]:
    """Admit a settled or absent owner; with force, also an idle Gateway session or a legacy owner no Gateway knows.

    An idle session could be resumed at any moment, so its release needs the maintainer's typed
    confirmation; `run` re-reads this verdict right before the remote write, and a session that
    became live in between keeps its claim. Live owners are never released.
    """
    if force and owner == "unknown":
        return "unknown", "legacy claim without an owner session; maintainer confirmed"
    state, why = handoff.owner_status(owner)
    if state in RELEASABLE:
        return state, why
    if force and (state == "idle" or state == "indeterminate" and not _GATEWAY_SESSION.fullmatch(owner.lower())):
        return state, f"{why}; maintainer confirmed"
    hint = " (a maintainer may use --force-maintainer from a real terminal)" if state == "idle" and not force else ""
    raise ReleaseError(f"owner session {owner} is {state} ({why}); refusing release, claim left unchanged{hint}")


def _confirm(number: int, owner: str) -> None:
    if not sys.stdin.isatty():
        raise ReleaseError("--force-maintainer requires an interactive terminal; claim left unchanged")
    expected = f"RELEASE #{number} FROM {owner}"
    print(f"Type exactly: {expected}", flush=True)
    if input("> ").strip() != expected:
        raise ReleaseError("confirmation did not match; claim left unchanged")


def _write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(temporary, path)


def _comment(gh: Gh, number: int, manifest: dict, primary: Path, config: dict) -> None:
    marker = f"<!-- work:release branch={manifest['branch']} head={manifest['remoteHead']} -->"
    existing = gh.run("api", f"repos/{{owner}}/{{repo}}/issues/{number}/comments", "--paginate", "--jq", ".[].body")
    if marker in existing:
        return
    changed = manifest["changedPaths"]
    body = (f"{marker}\nReleased the stale claim on #{number}. The issue stays open and unclaimed.\n\n"
            f"- Previous owner: `{manifest['owner']}` ({manifest['ownerState']}: {manifest['ownerReason']})\n"
            f"- Released by: `{manifest['actor']}`\n- Reason: {manifest['reason']}\n"
            f"- Released claim branch: `{manifest['branch']}` at `{manifest['remoteHead']}`\n"
            f"- Preserved first: local head `{manifest['localHead']}`"
            + (f", worktree snapshot `{manifest['snapshot']}` ({changed} changed path{'s' if changed != 1 else ''})"
               if manifest["snapshot"] else "")
            + f", bundled in the releasing checkout's Git directory under `work/releases/{manifest['directory']}/`.\n")
    scrub = config.get("verify", {}).get("scrubCommand")
    if not isinstance(scrub, str) or not scrub.strip() or subprocess.run(
            ["bash", "-c", scrub], cwd=primary, input=body, capture_output=True, text=True).returncode:
        raise ReleaseError("release audit comment refused by the configured privacy guard")
    gh.run("issue", "comment", str(number), "--body-file", "-", stdin=body)


def _set_ready(gh: Gh, number: int, config: dict) -> None:
    rules = config["claim"]
    owner, name = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip().split("/")
    issue = start.load_issue(gh, owner, name, number, rules, config["project"]["title"])
    if issue["item"] is not None and issue["status"] in rules["claimedStatuses"]:
        start.set_status(gh, issue["item"], rules["readyStatus"])


def _remove_local(manifest: dict, settings: cleanup.Settings) -> str:
    branch, local_head = manifest["branch"], manifest["localHead"]
    path = Path(manifest["worktree"]) if manifest["worktree"] else None
    os.chdir(settings.primary)
    removed = "no worktree"
    if path and path.exists():
        unopened = cleanup._open_directories(path)
        if unopened:
            raise ReleaseError(f"claim released; worktree kept: {unopened}")
        # Forced only after the snapshot of this exact state was bundled and re-proven unchanged.
        _git(settings.primary, "worktree", "remove", "--force", str(path))
        removed = "worktree removed"
    if _git(settings.primary, "rev-parse", "-q", "--verify", f"refs/heads/{branch}", check=False) == local_head:
        _git(settings.primary, "update-ref", "-d", f"refs/heads/{branch}", local_head)
        removed += ", local branch deleted" + cleanup._drop_branch_settings(settings.primary, branch)
    return removed


def _finish(gh: Gh, number: int, manifest: dict, manifest_path: Path, settings: cleanup.Settings,
            config: dict, log: Path) -> int:
    _comment(gh, number, manifest, settings.primary, config)
    _set_ready(gh, number, config)
    local = _remove_local(manifest, settings)
    manifest["phase"] = "released"
    _write_json(manifest_path, manifest)
    with log.open("a") as stream:
        stream.write(json.dumps({"at": time.time_ns(), "event": "release", "issue": number,
                                 "branch": manifest["branch"], "remoteHead": manifest["remoteHead"],
                                 "localHead": manifest["localHead"], "snapshot": manifest["snapshot"],
                                 "owner": manifest["owner"], "ownerState": manifest["ownerState"],
                                 "actor": manifest["actor"], "directory": manifest["directory"]}) + "\n")
    print(f"released #{number}: {manifest['branch']} at {manifest['remoteHead'][:12]} "
          f"(owner {manifest['owner']} {manifest['ownerState']}); {local}; preserved in {manifest_path.parent}")
    return 0


def run(gh: Gh, cwd: Path, config: dict, number: int, reason: str, force: bool = False,
        absent_only: bool = False) -> int:
    if number < 1:
        raise ReleaseError("issue number must be positive")
    reason = reason.strip()
    if not reason or len(reason) > 500 or any(ord(char) < 32 for char in reason):
        raise ReleaseError("reason must be 1–500 printable characters")
    actor = handoff.claim_session(None)
    rules, section = config["claim"], config["cleanup"]
    primary = start.primary_checkout(cwd).resolve()
    settings = cleanup.Settings(
        primary=primary, root=(primary / rules["worktreeRoot"]).resolve(), remote=rules["remote"],
        base=rules["baseBranch"], regenerable=section["regenerableIgnored"], releases=section["releaseCommands"],
        started=Path(_git(cwd, "rev-parse", "--show-toplevel")).resolve())
    remote, base_ref = settings.remote, f"{settings.remote}/{settings.base}"
    common = Path(_git(primary, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    releases = common / "work" / "releases"
    releases.mkdir(parents=True, exist_ok=True)
    log = releases / "log.jsonl"

    matching = sorted((name, sha) for name, sha in claims._remote_heads(primary, remote).items()
                      if claims.claimed_issue(name) == number)
    if not matching:
        # Retry after the remote branch went: finish only an exact recorded release.
        for manifest_path in sorted(releases.glob(f"{number}-*/manifest.json")):
            manifest = json.loads(manifest_path.read_text())
            if manifest.get("issue") == number and manifest.get("phase") == "remote-released":
                print(f"resuming the release of #{number} recorded in {manifest_path.parent}")
                return _finish(gh, number, manifest, manifest_path, settings, config, log)
        raise ReleaseError(f"#{number} has no claim branch on {remote}; nothing to release")
    if len(matching) != 1:
        raise ReleaseError(f"expected exactly one claim branch for #{number}; found {len(matching)}")
    branch, remote_head = matching[0]
    if json.loads(gh.run("issue", "view", str(number), "--json", "state"))["state"] != "OPEN":
        raise ReleaseError(f"#{number} is not open; use `work cleanup` for a closed issue's claim")
    _git(primary, "fetch", "-q", remote, f"refs/heads/{branch}:refs/remotes/{remote}/{branch}",
         f"refs/heads/{settings.base}:refs/remotes/{base_ref}")
    if _git(primary, "rev-parse", f"refs/remotes/{remote}/{branch}") != remote_head:
        raise ReleaseError("remote claim moved while reading it; retry")
    why = _claim_only(primary, base_ref, remote_head)
    if why:
        raise ReleaseError(f"{branch} on {remote} is not claim-only: {why}")
    owner = _owner(primary, number, remote_head, force)
    owner_state, owner_reason = _admit_owner(owner, force)
    if absent_only and owner_state != "absent":
        raise ReleaseError(f"owner session {owner} is now {owner_state}; the stale sweep releases only absent owners")

    # The local side: a registered claim worktree, or only a local branch, or nothing.
    path = (settings.root / branch.split("/", 1)[1]).resolve()
    tree = next((t for t in cleanup.list_worktrees(primary) if t.path == path), None)
    if path.exists() and tree is None:
        raise ReleaseError(f"{path} exists but is not a registered worktree; inspect it by hand")
    if tree:
        handoff.claimed_worktree(primary, config, branch)
        if tree.locked is not None:
            raise ReleaseError(f"{path} is locked" + (f": {tree.locked}" if tree.locked else ""))
        operation = land.operation_in_progress(path)
        if operation:
            raise ReleaseError(f"a {operation} is in progress in {path}")
        busy = cleanup._process_blockers(path, settings)
        if busy:
            raise ReleaseError(f"{path}: " + "; ".join(busy))
    local_head = _git(primary, "rev-parse", "-q", "--verify", f"refs/heads/{branch}", check=False) or remote_head
    if force:
        _confirm(number, owner)

    # Preserve before any release step: local head, remote head and the worktree's exact state.
    snapshot, changed = "", 0
    if tree:
        snapshot_tree = _snapshot_tree(path, settings)
        head_tree = _git(path, "rev-parse", "HEAD^{tree}")
        changed = len(_git(path, "diff", "--name-only", head_tree, snapshot_tree).splitlines())
        snapshot = _git(path, "commit-tree", snapshot_tree, "-p", local_head,
                        "-m", f"work release snapshot of #{number}\n\nWork-Release-Issue: {number}\n")
    directory = f"{number}-{remote_head[:12]}"
    destination = releases / directory
    destination.mkdir(exist_ok=True)
    namespace = f"refs/work-release/{number}/{remote_head[:12]}"
    refs = {f"{namespace}/remote": remote_head, f"{namespace}/head": local_head}
    if snapshot:
        refs[f"{namespace}/worktree"] = snapshot
    for ref, sha in refs.items():
        _git(primary, "update-ref", ref, sha)  # keeps the objects reachable in this repository too
    bundle = destination / "claim.bundle"
    _git(primary, "bundle", "create", str(bundle), *refs, "--not", base_ref)
    _git(primary, "bundle", "verify", str(bundle))
    if snapshot:
        patch = subprocess.run(["git", "diff", "--binary", local_head, snapshot], cwd=primary, capture_output=True)
        if patch.returncode:
            raise ReleaseError("cannot write the worktree patch")
        (destination / "worktree.patch").write_bytes(patch.stdout)
    manifest = {"issue": number, "branch": branch, "remoteHead": remote_head, "localHead": local_head,
                "snapshot": snapshot, "changedPaths": changed, "worktree": str(path) if tree else "",
                "owner": owner, "ownerState": owner_state, "ownerReason": owner_reason, "actor": actor,
                "reason": reason, "directory": directory, "refs": sorted(refs), "phase": "preserved",
                "preservedAt": time.time_ns()}
    manifest_path = destination / "manifest.json"
    _write_json(manifest_path, manifest)
    print(f"preserved #{number}: {bundle}" + (f" (worktree snapshot {snapshot[:12]}, {changed} changed paths)" if snapshot else ""))

    if tree:
        for entry in settings.releases:
            failure = cleanup._release(path, entry)
            if failure:
                raise ReleaseError(f"release command {failure}; claim left unchanged, work preserved")
    # Everything slow is done: prove nothing changed since the snapshot, right before the remote write.
    if _admit_owner(owner, force)[0] != owner_state:
        raise ReleaseError("the owner's state changed while preserving; claim left unchanged, work preserved")
    if tree:
        if _git(path, "rev-parse", "HEAD") != local_head or _snapshot_tree(path, settings) != _git(path, "rev-parse", f"{snapshot}^{{tree}}"):
            raise ReleaseError("the worktree changed after it was preserved; claim left unchanged, retry to preserve again")
        busy = cleanup._process_blockers(path, settings)
        if busy:
            raise ReleaseError(f"{path}: " + "; ".join(busy))
    pushed = subprocess.run(["git", "push", "--porcelain", f"--force-with-lease=refs/heads/{branch}:{remote_head}",
                             remote, f":refs/heads/{branch}"], cwd=primary, capture_output=True, text=True)
    if pushed.returncode:
        raise ReleaseError(f"remote claim delete refused by its exact lease; inspect before retry: {pushed.stderr.strip()}")
    manifest["phase"] = "remote-released"
    _write_json(manifest_path, manifest)
    return _finish(gh, number, manifest, manifest_path, settings, config, log)


def _idle_hours(primary: Path, gh: Gh, number: int, branch: str, remote: str, now: datetime) -> Tuple[Optional[str], float]:
    """(issue state, hours since the newest claim-branch commit or issue comment)."""
    committed = int(_git(primary, "log", "-1", "--format=%ct", f"refs/remotes/{remote}/{branch}"))
    issue = json.loads(gh.run("issue", "view", str(number), "--json", "state,comments"))
    moments = [datetime.fromtimestamp(committed, timezone.utc)]
    moments += [datetime.fromisoformat(c["createdAt"].replace("Z", "+00:00")) for c in issue.get("comments") or []]
    return issue.get("state"), (now - max(moments)).total_seconds() / 3600


def sweep(gh: Gh, cwd: Path, config: dict, dry_run: bool) -> int:
    """Release every open-issue claim idle for more than STALE_HOURS whose owner is absent.

    Only `absent` qualifies: a settled Home task's claim passes to its successor through `start`
    (#929) and may be a maintainer's paused continuation, so the sweep leaves it. Each release is
    the ordinary audited `run` above (preservation, owner re-proof, exact lease); a refusal leaves
    that claim untouched and the sweep continues.
    """
    rules = config["claim"]
    remote = rules["remote"]
    primary = start.primary_checkout(cwd).resolve()
    heads = sorted((claims.claimed_issue(name), name) for name in claims._remote_heads(primary, remote)
                   if claims.claimed_issue(name) is not None)
    if heads:
        _git(primary, "fetch", "-q", remote, *(f"refs/heads/{b}:refs/remotes/{remote}/{b}" for _, b in heads))
    now = datetime.now(timezone.utc)
    released, kept = [], []
    for number, branch in heads:
        state, idle = _idle_hours(primary, gh, number, branch, remote, now)
        if state != "OPEN":
            continue  # a closed issue's claim is `work cleanup`'s
        if idle <= STALE_HOURS:
            continue
        label = f"#{number} {branch} idle {idle / 24:.1f}d"
        owner = handoff._claim_at(primary, f"refs/remotes/{remote}/{branch}", number)[1]
        state, why = handoff.owner_status(owner) if owner else ("unknown", "claim records no owner")
        if state != "absent":
            print(f"kept {label}: owner {owner} is {state} ({why})", flush=True)
            kept.append(number)
            continue
        if dry_run:
            print(f"would release {label}: owner {owner} is absent ({why})")
            continue
        print(f"releasing {label}", flush=True)
        try:
            run(gh, primary, config, number, f"stale claim: idle {idle / 24:.1f} days and its owner session is gone",
                absent_only=True)
            released.append(number)
        except ReleaseError as error:
            print(f"kept {label}: {error}", flush=True)
            kept.append(number)
    if dry_run:
        print(f"stale sweep (dry run): kept {len(kept)}")
    else:
        print(f"stale sweep: released {len(released)}" + (f" ({', '.join(f'#{n}' for n in released)})" if released else "")
              + f", kept {len(kept)}" + (f" ({', '.join(f'#{n}' for n in kept)})" if kept else ""))
    return 0
