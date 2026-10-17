"""Landing without a queue (README.md#landing, #1190): the merge critical section, branch
receipts, and the post-merge check of main.

A branch is verified once, on its own tree, outside any repository-wide lock; a pass
records a receipt keyed by that exact tree. `work land` then merges it when Git merges
it cleanly onto the current base, holding `merge.lock` only around that check and the
squash merge. Everything merged since the last main that passed is checked afterwards
by one background runner, which coalesces merges into one run, bisects a failure to
the culprit merge, stops landing, reverts the culprit through a pull request (or flags
it when the revert does not apply) and tells its issue. Landing resumes when a check of
main passes again.

State lives in `<git common dir>/work/main/` (`state.json`, `events.jsonl`,
`check.log`, the runner's detached worktree) and receipts in
`<git common dir>/work/gate/receipts/`. The gate's content-addressed results keep
partial work: a check that crashes or is killed reruns only what did not pass.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import IO, Iterator, List, Optional
from urllib.parse import quote

import ledger

LOCKFILES = ("packages/gateway/package-lock.json",)


class MainlineError(RuntimeError):
    pass


def _git(root: Path, *args: str, check: bool = True) -> str:
    done = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if check and done.returncode:
        raise MainlineError(f"git {' '.join(args[:2])} failed: {done.stderr.strip()}")
    return done.stdout.strip()


def _directory(root: Path) -> Path:
    path = ledger.common_dir(root) / "work" / "main"
    path.mkdir(parents=True, exist_ok=True)
    return path


# ---------------------------------------------------------------- state


def state(root: Path) -> dict:
    with contextlib.suppress(OSError, ValueError):
        return json.loads((_directory(root) / "state.json").read_text())
    return {"lastPassed": None, "check": None, "stopped": None}


def _update(root: Path, **fields) -> dict:
    """Read-modify-write under `state.lock`; the file is replaced atomically."""
    directory = _directory(root)
    with (directory / "state.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = {**state(root), **fields, "updatedAt": ledger.now()}
        temporary = directory / f"state.{os.getpid()}.tmp"
        temporary.write_text(json.dumps(current, indent=2) + "\n")
        temporary.replace(directory / "state.json")
        return current


def _event(root: Path, event: str, **fields) -> None:
    with contextlib.suppress(OSError):
        ledger.append(_directory(root) / "events.jsonl", {**ledger.context(root), "event": event, **fields})


def stopped(root: Path) -> Optional[dict]:
    return state(root).get("stopped")


def stopped_message(stop: dict) -> str:
    if stop.get("predates"):
        return (f"landing is stopped: {stop['shard']} fails on main at {stop['failedAt'][:12]} and also on the last "
                f"main that passed ({stop['since'][:12]}), so no merge is blamed. Fix the check or its environment "
                "(work/main/check.log), then run scripts/tron gate main-check; a fix lands with --repair-main.")
    if not stop.get("culprit"):
        return (f"landing is stopped: the check of main failed at {stop['failedAt'][:12]} ({stop['shard']}) and is "
                "bisecting to the culprit merge. It resumes when a check of main passes (scripts/tron gate status).")
    revert = stop.get("revert") or {}
    if revert.get("state") == "merged":
        action = f"revert PR #{revert['pull']} merged; the reverted main is being checked"
    elif revert.get("pull"):
        action = (f"revert PR #{revert['pull']} could not merge ({revert.get('detail', 'flagged')}); merge it or "
                  "land a fix with --repair-main")
    else:
        action = f"the revert did not apply cleanly ({revert.get('detail', 'flagged')}); land a fix with --repair-main"
    return (f"landing is stopped: the check of main failed at {stop['failedAt'][:12]} ({stop['shard']}); "
            f"culprit {stop['culprit'][:12]} {stop.get('subject', '')!r}; {action}. "
            "It resumes when a check of main passes (scripts/tron gate status).")


def ensure_baseline(root: Path, base_tip: str) -> None:
    """The first landing under this flow trusts the base it merges onto: every earlier tip
    passed the merged-tree verification that landing used before (#1190)."""
    directory = _directory(root)
    with (directory / "state.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if state(root).get("lastPassed"):
            return
        current = {**state(root), "lastPassed": base_tip, "updatedAt": ledger.now()}
        temporary = directory / f"state.{os.getpid()}.tmp"
        temporary.write_text(json.dumps(current, indent=2) + "\n")
        temporary.replace(directory / "state.json")
    _event(root, "baseline", sha=base_tip)


# ---------------------------------------------------------------- merge critical section


@contextlib.contextmanager
def merge_lock(root: Path, branch: str, report: IO[str] = sys.stdout) -> Iterator[float]:
    """The only landing lock: held for the mergeability check and the squash merge (seconds)."""
    path = ledger.common_dir(root) / "work" / "land" / "merge.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    started = time.monotonic()
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = merge_holder(root) or {}
            print(f"land: waiting for the merge of {holder.get('branch', 'another landing')} to finish",
                  file=report, flush=True)
            fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        handle.truncate()
        json.dump({"branch": branch, "pid": os.getpid(), "since": ledger.now()}, handle)
        handle.flush()
        yield round(time.monotonic() - started, 1)
    finally:
        with contextlib.suppress(OSError, ValueError):
            handle.seek(0)
            handle.truncate()
            fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()


def merge_holder(root: Path) -> Optional[dict]:
    path = ledger.common_dir(root) / "work" / "land" / "merge.lock"
    if not path.exists():
        return None
    with path.open("a+") as probe:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            with contextlib.suppress(ValueError, OSError):
                return json.loads(path.read_text() or "{}")
            return {}
        fcntl.flock(probe, fcntl.LOCK_UN)
    return None


def merges_cleanly(root: Path, base_tip: str, head: str) -> List[str]:
    """Conflicting paths of merging `head` onto `base_tip` (empty when Git merges it cleanly)."""
    done = subprocess.run(["git", "merge-tree", "--write-tree", "--name-only", "--no-messages", base_tip, head],
                          cwd=root, capture_output=True, text=True)
    if done.returncode == 0:
        return []
    if done.returncode == 1:
        return done.stdout.splitlines()[1:] or ["(conflict)"]
    raise MainlineError(f"git merge-tree failed: {done.stderr.strip()}")


# ---------------------------------------------------------------- receipts


def lockfile_hash(root: Path, tree: str) -> dict:
    return {path: _git(root, "rev-parse", f"{tree}:{path}", check=False) or None for path in LOCKFILES}


def receipt_path(root: Path, tree: str) -> Path:
    return ledger.common_dir(root) / "work" / "gate" / "receipts" / f"{tree}.json"


def record_receipt(root: Path, tree: str, head: str, base: str, checks: List[dict]) -> dict:
    receipt = {"tree": tree, "head": head, "mergeBase": base, "lockfiles": lockfile_hash(root, tree),
               "checks": checks, "at": ledger.now()}
    path = receipt_path(root, tree)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def receipt(root: Path, tree: str) -> Optional[dict]:
    with contextlib.suppress(OSError, ValueError):
        return json.loads(receipt_path(root, tree).read_text())
    return None


# ---------------------------------------------------------------- post-merge check


def start_background(root: Path) -> None:
    """Start a runner detached; a runner already waiting covers this merge too."""
    log = _directory(root) / "check.log"
    gate = Path(__file__).resolve().parent / "gate.py"
    with log.open("a") as stream:
        subprocess.Popen([sys.executable, "-B", str(gate), "main-check"], cwd=root, stdin=subprocess.DEVNULL,
                         stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)


@contextlib.contextmanager
def _flock(path: Path, blocking: bool) -> Iterator[Optional[IO[str]]]:
    handle = path.open("a+")
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield None
            return
        yield handle
    finally:
        handle.close()


def _worktree(root: Path, config: dict) -> Path:
    path = _directory(root) / "worktree"
    if not (path / ".git").exists():
        subprocess.run(["git", "worktree", "prune"], cwd=root, capture_output=True)
        _git(root, "worktree", "add", "--detach", "-q", str(path), f"{config['claim']['remote']}/{config['claim']['baseBranch']}")
    return path


def _fetch(root: Path, config: dict) -> str:
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    _git(root, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{base}:refs/remotes/{remote}/{base}")
    return _git(root, "rev-parse", f"{remote}/{base}")


def _checkout(worktree: Path, sha: str) -> None:
    _git(worktree, "checkout", "-q", "--detach", "--force", sha)
    _git(worktree, "clean", "-q", "-fd")


def run(root: Path, config: dict, runner_fd: Optional[int] = None) -> int:
    """`gate main-check`: one runner at a time, plus at most one waiter that starts after it.

    The launcher (any worktree's code) takes the runner lock, checks out the current base
    tip in the runner's own worktree and re-executes that tip's gate code with the lock
    held, so the check runs main's code and catalog and survives the launcher's worktree
    being cleaned up."""
    if runner_fd is not None:
        return _loop(root, runner_fd)
    directory = _directory(root)
    with _flock(directory / "waiter.lock", blocking=False) as waiting:
        if waiting is None:
            print("main check: a runner is already waiting; it covers this merge", flush=True)
            return 0
        runner = (directory / "check.lock").open("a+")
        fcntl.flock(runner, fcntl.LOCK_EX)
    worktree = _worktree(root, config)
    _checkout(worktree, _fetch(root, config))
    os.set_inheritable(runner.fileno(), True)
    gate = worktree / "tools" / "work" / "gate.py"
    os.chdir(worktree)
    os.execv(sys.executable, [sys.executable, "-B", str(gate), "main-check", "--runner-fd", str(runner.fileno())])


def _loop(root: Path, runner_fd: int) -> int:
    # Every module the check needs is loaded before the worktree changes commits under it.
    import claim  # noqa: F401
    import gate
    import tracking  # noqa: F401
    from gh import Gh
    worktree = _directory(root) / "worktree"
    config = json.loads((worktree / ".github" / "work.json").read_text())
    try:
        return _check(root, worktree, config, gate, Gh)
    finally:
        os.close(runner_fd)


def _check(root: Path, worktree: Path, config: dict, gate, Gh) -> int:
    while True:
        tip = _fetch(root, config)
        last = state(root).get("lastPassed")
        if not last:
            ensure_baseline(root, tip)
            continue
        if subprocess.run(["git", "merge-base", "--is-ancestor", tip, last], cwd=root).returncode == 0:
            _update(root, check=None)
            print(f"main check: {tip[:12]} is covered by the last main that passed ({last[:12]})", flush=True)
            return 0
        commits = _git(root, "rev-list", "--first-parent", "--reverse", f"{last}..{tip}").splitlines()
        check = {"from": last, "to": tip, "merges": len(commits), "phase": "verify", "pid": os.getpid(),
                 "startedAt": ledger.now()}
        _update(root, check=check)
        _event(root, "check-start", **{k: v for k, v in check.items() if k != "phase"})
        print(f"main check: {last[:12]}..{tip[:12]} ({len(commits)} merges)", flush=True)
        _checkout(worktree, tip)
        catalog = gate.load_catalog()
        change = _change(gate, worktree, last, tip)
        ok = gate.execute(worktree, config, gate.plan(catalog, change), change)
        if ok:
            _update(root, lastPassed=tip, stopped=None, check=None, reverted=[])
            _event(root, "passed", sha=tip, merges=len(commits), **gate.LAST_RUN)
            print(f"main check: {tip[:12]} passed; landing is open", flush=True)
            continue
        failed = gate.FAILED_SHARD
        if failed is None:
            _update(root, check=None)
            _event(root, "error", detail="the check stopped without a failing shard")
            return 2
        # Landing stops at once: nothing merges onto a broken main while the culprit is found.
        _update(root, check={**check, "phase": "bisect", "shard": failed.name},
                stopped={"culprit": None, "shard": failed.name, "failedAt": tip, "since": last, "at": ledger.now()})
        print(f"main check: FAILED {failed.name} at {tip[:12]}; landing is stopped; bisecting "
              f"{len(commits)} merges", flush=True)
        if _fails_at_baseline(gate, worktree, config, catalog, last, failed):
            # It fails without any merge of the range: an environment or check bug, not a culprit.
            stop = {"culprit": None, "shard": failed.name, "failedAt": tip, "since": last, "at": ledger.now(),
                    "predates": True}
            _update(root, stopped=stop, check=None)
            _event(root, "stopped", **stop)
            print(f"main check: {failed.name} also fails on the last main that passed ({last[:12]}); no merge "
                  "is blamed or reverted. Fix the check or its environment, then rerun scripts/tron gate main-check",
                  flush=True)
            return 1
        culprit = _bisect(gate, root, worktree, config, catalog, last, commits, failed)
        subject = _git(root, "log", "-1", "--format=%s", culprit)
        stop = {"culprit": culprit, "subject": subject, "shard": failed.name, "failedAt": tip, "since": last,
                "at": ledger.now(), "revert": None}
        _update(root, stopped=stop, check={**check, "phase": "revert", "shard": failed.name})
        _event(root, "stopped", **stop)
        print(f"main check: culprit {culprit[:12]} {subject!r}", flush=True)
        gh = Gh(root)
        reverted = state(root).get("reverted") or []
        if culprit in reverted:
            # Its revert is already in the range, so bisect cannot name what still fails.
            stop["revert"] = {"state": "flagged", "detail": f"{failed.name} still fails after {culprit[:12]} was "
                              "reverted; another merge in the range breaks it"}
        else:
            stop["revert"] = _revert(root, worktree, config, gh, culprit, subject, tip, failed.name)
        if stop["revert"].get("state") == "merged":
            reverted = [*reverted, culprit]
        _update(root, stopped=stop, reverted=reverted)
        _notify(root, config, gh, stop)
        if stop["revert"].get("state") == "merged":
            continue  # The reverted tip is checked next; a pass reopens landing.
        _update(root, check=None)
        return 1


def _change(gate, worktree: Path, last: str, sha: str):
    tree = _git(worktree, "rev-parse", f"{sha}^{{tree}}")
    paths = [p for p in _git(worktree, "diff", "--name-only", "--no-renames", "-z", last, sha).split("\0") if p]
    return gate.Change(worktree, last, last, tree, paths, [])


def _fails_at_baseline(gate, worktree: Path, config: dict, catalog: dict, last: str, failed) -> bool:
    """Run the failing shard (and its prerequisites) on the last main that passed, here and
    now, ignoring recorded passes: a failure there is not caused by any merge since."""
    _checkout(worktree, last)
    change = _change(gate, worktree, last, last)
    prerequisites = []
    for name in failed.step.get("after", []):
        prerequisites += [shard for shard in gate._named(catalog, change, [], [name]) if shard not in prerequisites]
    print(f"main check: confirming {failed.name} passes on the last main that passed ({last[:12]})", flush=True)
    return not gate.execute(worktree, config, [*prerequisites, failed], change, force=True)


def _bisect(gate, root: Path, worktree: Path, config: dict, catalog: dict, last: str, commits: List[str],
            failed) -> str:
    """The first merge after `last` at which the failing shard fails (the tip is known to fail)."""
    low, high = 0, len(commits) - 1
    while low < high:
        middle = (low + high) // 2
        sha = commits[middle]
        _checkout(worktree, sha)
        change = _change(gate, worktree, last, sha)
        planned = gate.plan(catalog, change)
        same = [shard for shard in planned if shard.name == failed.name]
        print(f"main check: bisect {sha[:12]} ({middle + 1}/{len(commits)})", flush=True)
        # A shard the range up to this merge does not select cannot fail because of it.
        broken = bool(same) and not gate.execute(worktree, config, gate._named(catalog, change, planned, [failed.name]),
                                                 change)
        _event(root, "bisect", sha=sha, shard=failed.name, failed=broken)
        if broken:
            high = middle
        else:
            low = middle + 1
    return commits[high]


def _revert(root: Path, worktree: Path, config: dict, gh, culprit: str, subject: str, tip: str,
            shard: str) -> dict:
    """Revert the culprit on the failing tip through a pull request and merge it; never force."""
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    branch = f"revert/{culprit[:12]}"
    _checkout(worktree, tip)
    reverted = subprocess.run(["git", "revert", "--no-edit", culprit], cwd=worktree, capture_output=True, text=True)
    if reverted.returncode:
        subprocess.run(["git", "revert", "--abort"], cwd=worktree, capture_output=True)
        _event(root, "revert-flagged", culprit=culprit)
        return {"state": "flagged", "detail": "conflicts with later merges"}
    head = _git(worktree, "rev-parse", "HEAD")
    pull = None
    try:
        # The revert branch belongs to this check; a retry replaces what an earlier attempt left.
        _git(worktree, "push", "-q", "--force", remote, f"{head}:refs/heads/{branch}")
        repository = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()
        body = (f"The post-merge check of {base} failed at {tip[:12]} ({shard}) and bisected to {culprit[:12]}. "
                f"This reverts it so landing can resume (#1190, tools/work/README.md#landing).")
        _guard(root, config, f"Revert {subject}\n\n{body}")
        owner = repository.split("/", 1)[0]
        open_pulls = gh.rest("GET", f"repos/{repository}/pulls?state=open&per_page=100&head={quote(f'{owner}:{branch}', safe=':')}")
        pull = open_pulls[0] if open_pulls else gh.rest("POST", f"repos/{repository}/pulls", {
            "title": f"Revert \"{subject}\"", "head": branch, "base": base, "body": body})
        with merge_lock(root, branch):
            merged = gh.rest("PUT", f"repos/{repository}/pulls/{pull['number']}/merge", {
                "merge_method": "squash", "sha": head, "commit_title": f"Revert \"{subject}\" (#{pull['number']})",
                "commit_message": body})
        subprocess.run(["git", "push", "-q", remote, f":refs/heads/{branch}"], cwd=worktree, capture_output=True)
    except Exception as error:  # A failed write leaves landing stopped and says so.
        _event(root, "revert-failed", culprit=culprit, pull=(pull or {}).get("number"), detail=str(error)[:200])
        return {"state": "flagged", "pull": (pull or {}).get("number"),
                "detail": f"revert pull request failed: {str(error)[:120]}"}
    _event(root, "reverted", culprit=culprit, pull=pull["number"], sha=merged.get("sha"))
    print(f"main check: reverted {culprit[:12]} through #{pull['number']}", flush=True)
    return {"state": "merged", "pull": pull["number"], "sha": merged.get("sha")}


def _guard(root: Path, config: dict, text: str) -> None:
    command = config.get("verify", {}).get("scrubCommand")
    if not command or subprocess.run(["bash", "-c", command], cwd=root, input=text, capture_output=True,
                                     text=True).returncode:
        raise MainlineError("the privacy guard refused the revert text")


def _notify(root: Path, config: dict, gh, stop: dict) -> None:
    """Comment on and reopen the culprit's issue, so its worker and Home hear about it."""
    import claim
    import tempfile
    import tracking
    match = re.search(r"\(#(\d+)\)\s*$", stop["subject"])
    issue = None
    if match:
        with contextlib.suppress(Exception):
            repository = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()
            pull = gh.rest("GET", f"repos/{repository}/pulls/{match.group(1)}")
            issue = claim.claimed_issue(pull["head"]["ref"])
    revert = stop["revert"] or {}
    text = (f"The post-merge check of main failed at `{stop['failedAt'][:12]}` in `{stop['shard']}` and bisected "
            f"to this issue's merge `{stop['culprit'][:12]}`. "
            + (f"It was reverted by #{revert['pull']}; fix it on a branch and land it again."
               if revert.get("state") == "merged"
               else "The revert did not apply cleanly, so landing is stopped until a fix lands with "
                    "`scripts/tron work land --repair-main`.")
            + "\n\nDetails: `scripts/tron gate status` and `<git common dir>/work/main/check.log` (#1190).\n")
    _event(root, "notified", issue=issue, culprit=stop["culprit"])
    if issue is None:
        print("main check: the culprit names no claimed issue; see scripts/tron gate status", flush=True)
        return
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as body:
        body.write(text)
    try:
        tracking.reopen_issue(gh, root, config, issue, Path(body.name))
        print(f"main check: reopened #{issue} with the failure", flush=True)
    except Exception as error:
        print(f"main check: could not tell #{issue}: {str(error)[:160]}", flush=True)
    finally:
        os.unlink(body.name)


# ---------------------------------------------------------------- status


def status(root: Path, config: dict, as_json: bool = False) -> int:
    current = state(root)
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    tip = _git(root, "rev-parse", "--verify", "-q", f"{remote}/{base}", check=False)
    last = current.get("lastPassed")
    ahead = int(_git(root, "rev-list", "--count", f"{last}..{tip}", check=False) or 0) if last and tip else None
    check = current.get("check")
    if check and not _alive(int(check.get("pid") or 0)):
        check = {**check, "phase": "interrupted (rerun scripts/tron gate main-check; passes are reused)"}
    view = {"lastPassed": last, "mainTip": tip, "mergesAhead": ahead, "check": check,
            "stopped": current.get("stopped"), "merging": merge_holder(root),
            "lastStep": _last_step(_directory(root) / "check.log")}
    if as_json:
        print(json.dumps(view, indent=2))
        return 0
    print(f"last main that passed: {last[:12] if last else 'none yet'}"
          + (f" ({ahead} merges behind {remote}/{base} {tip[:12]})" if ahead else " (current)" if last else ""))
    if check:
        print(f"main check: {check['phase']} {check['from'][:12]}..{check['to'][:12]} ({check['merges']} merges)"
              f" since {check['startedAt']}" + (f"; {check['shard']}" if check.get("shard") else ""))
        if view["lastStep"]:
            print(f"  last step: {view['lastStep']}")
    elif ahead:
        print(f"main check: idle with {ahead} merge(s) unchecked; run scripts/tron gate main-check "
              "(work/main/check.log has the last runner's output)")
    else:
        print("main check: idle")
    print("landing: " + (stopped_message(view["stopped"]) if view["stopped"] else "open"))
    holder = view["merging"]
    print(f"merging now: {holder.get('branch')} since {holder.get('since')}" if holder else "merging now: none")
    return 0


def counts(root: Path) -> dict:
    """Bounded projection for `work status`: merges in flight (seconds each; nothing queues),
    whether landing is stopped, and the last main that passed."""
    holder = merge_holder(root)
    current = state(root)
    return {"running": None if holder == {} else int(holder is not None), "waiting": 0,
            "stopped": bool(current.get("stopped")), "lastPassed": (current.get("lastPassed") or "")[:12] or None,
            "checking": bool(current.get("check"))}


def _last_step(log: Path) -> Optional[str]:
    with contextlib.suppress(OSError):
        with log.open("rb") as stream:
            stream.seek(max(0, log.stat().st_size - 8192))
            lines = [line for line in stream.read().decode(errors="replace").splitlines()
                     if line.startswith(("gate: [", "main check:"))]
            return lines[-1][:160] if lines else None
    return None


def _alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def build_source(root: Path, config: dict, require_current: bool = False) -> dict:
    """Default main builds use its passed revision; explicit task branches keep HEAD.

    This is source admission, not a new pass ledger. Read the check owner's receipt
    strictly: absent or damaged evidence must never become permission to build main.
    Detached main revisions get the same protection; detached task revisions remain
    explicit development sources. Consumers still own build/source identity fences.
    """
    head = _git(root, "rev-parse", "HEAD")
    branch = _git(root, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    result = {"head": head, "revision": head, "warning": None}
    if branch and branch != base:
        return result

    def ancestor(a: str, b: str) -> bool:
        done = subprocess.run(["git", "merge-base", "--is-ancestor", a, b],
                              cwd=root, capture_output=True)
        if done.returncode not in (0, 1):
            raise MainlineError("cannot verify main build source: Git ancestry is unavailable")
        return done.returncode == 0

    try:
        main = _git(root, "rev-parse", "--verify", f"refs/remotes/{remote}/{base}^{{commit}}")
        on_main = ancestor(head, main)
        if not branch and not on_main:
            return result
        if not on_main:
            raise ValueError("local main diverges from its remote; use a task branch for development")
        path = ledger.common_dir(root) / "work" / "main" / "state.json"
        current = json.loads(path.read_text())
        last = current.get("lastPassed") if isinstance(current, dict) else None
        if not isinstance(last, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", last):
            raise ValueError("no valid last-passed commit")
        if _git(root, "cat-file", "-t", last) != "commit":
            raise ValueError("last-passed object is not a commit")
        if not ancestor(last, main):
            raise ValueError("the last-passed commit is not in remote main")
        if _git(root, "status", "--porcelain"):
            raise ValueError("main has uncommitted files; preserve them and use a task branch for development")
    except (OSError, ValueError, MainlineError) as error:
        raise MainlineError(f"cannot verify main build source: {error}; inspect scripts/tron gate status "
                            "and repair the main-check evidence before building") from error
    if last != head:
        message = (f"main source {head[:12]} is not the last main that passed ({last[:12]}); "
                   "inspect scripts/tron gate status; resume an interrupted check with "
                   "scripts/tron gate main-check, or use an explicit task branch for development")
        if require_current:
            raise MainlineError(message)
        result.update(revision=last, warning=message)
    return result
