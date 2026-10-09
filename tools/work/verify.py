"""`work verify`: diff -> check set -> run -> receipt -> evidence (README.md, `verify`)."""
from __future__ import annotations

import base64
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shlex
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Pattern, Tuple

import claim as claims
from gh import Gh, GhError

_CHECK_NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_BRANCH_ISSUE = re.compile(r"^[^/]+/(\d+)-")
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_EXCERPT_LINE_LIMIT = 240
# Exported only to heavy checks: the CPU share of one host-wide heavy slot.
_CPU_SHARE_VARIABLE = "VERIFY_CPU_SHARE"


class VerifyError(RuntimeError):
    pass


# ------------------------------------------------------------ configuration


def glob_regex(glob: str) -> Pattern:
    """`*` stays within one path segment, `**` crosses segments, `?` is one character."""
    out, index = "", 0
    while index < len(glob):
        if glob.startswith("**/", index):
            out, index = out + "(?:.*/)?", index + 3
        elif glob.startswith("**", index):
            out, index = out + ".*", index + 2
        else:
            char = glob[index]
            out += "[^/]*" if char == "*" else "[^/]" if char == "?" else re.escape(char)
            index += 1
    return re.compile(out + r"\Z")


@dataclass
class Check:
    name: str
    paths: List[str]
    command: str
    always: bool
    patterns: List[Pattern]
    exclusive_group: Optional[str]
    exclusive_patterns: Optional[List[Pattern]]
    heavy: bool

    def matches(self, path: str) -> bool:
        return any(pattern.match(path) for pattern in self.patterns)

    def group_for(self, paths: List[str]) -> Optional[str]:
        if self.exclusive_patterns is None:
            return self.exclusive_group
        return self.exclusive_group if any(pattern.match(path) for pattern in self.exclusive_patterns
                                           for path in paths) else None


def load_checks(settings: dict) -> List[Check]:
    checks, names = [], set()
    for raw in settings["checks"]:
        name = raw.get("name", "")
        if not _CHECK_NAME.match(name) or name in names:
            raise VerifyError(f"verify check name {name!r} is invalid or repeated")
        if not isinstance(raw.get("command"), str) or not isinstance(raw.get("paths"), list):
            raise VerifyError(f"verify check {name} needs a command and a paths list")
        always = raw.get("always", False) is True
        if not raw["paths"] and not always:
            raise VerifyError(f"verify check {name} has no paths and is not always-run")
        group = raw.get("exclusiveGroup")
        if "exclusiveGroup" in raw and (not isinstance(group, str) or not _CHECK_NAME.fullmatch(group)):
            raise VerifyError(f"verify check {name} needs a valid exclusiveGroup name")
        exclusive_paths = raw.get("exclusivePaths")
        if "exclusivePaths" in raw and (group is None or not isinstance(exclusive_paths, list)
                or not exclusive_paths or any(not isinstance(path, str) or not path for path in exclusive_paths)):
            raise VerifyError(f"verify check {name} needs nonempty exclusivePaths and an exclusiveGroup")
        if "heavy" in raw and type(raw["heavy"]) is not bool:
            raise VerifyError(f"verify check {name} needs a boolean heavy flag")
        names.add(name)
        checks.append(Check(name, raw["paths"], raw["command"], always,
                            [glob_regex(g) for g in raw["paths"]], group,
                            [glob_regex(g) for g in exclusive_paths] if exclusive_paths is not None else None,
                            raw.get("heavy", False)))
    return checks


def heavy_slot_count(settings: dict) -> int:
    """Heavy checks that may run at once on this host; the default is one slot per eight CPUs."""
    if "heavySlots" not in settings:
        return max(1, (os.cpu_count() or 1) // 8)
    slots = settings["heavySlots"]
    if type(slots) is not int or slots < 1:
        raise VerifyError("verify.heavySlots must be a positive integer")
    return slots


def config_hash(config: dict) -> str:
    settings = config["verify"]
    # Heavy admission and its pool size choose how checks share the host, not what
    # they prove, so changing them must not invalidate receipts (like --jobs).
    verify_scope = {key: value for key, value in settings.items() if key != "heavySlots"}
    verify_scope["checks"] = [{key: value for key, value in check.items() if key != "heavy"}
                              for check in settings["checks"]]
    scope = {"remote": config["claim"]["remote"], "baseBranch": config["claim"]["baseBranch"],
             "verify": verify_scope}
    return hashlib.sha256(json.dumps(scope, sort_keys=True).encode()).hexdigest()


# ---------------------------------------------------------------------- git


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if completed.returncode != 0:
        raise VerifyError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout


def _is_ancestor(repo: Path, ancestor: str, head: str) -> bool:
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, head], cwd=repo,
                          capture_output=True).returncode == 0


def _changed(repo: Path, start: str, end: str) -> List[str]:
    # No rename detection: a rename must count as both of its paths.
    output = _git(repo, "diff", "--name-only", "--no-renames", "-z", start, end)
    return [path for path in output.split("\0") if path]


def _dirty(repo: Path) -> List[str]:
    return _git(repo, "status", "--porcelain", "--untracked-files=all").splitlines()


@dataclass
class HeavyPool:
    """Host-wide heavy-check slots: one flock'd file per slot in the shared git common dir.

    Every worktree of a repository shares that directory, so the bound holds across
    verify invocations and sessions. flock is per open file description and is released
    when its descriptor closes or its process exits, so a slot cannot outlive the check
    that holds it. Descriptors are not inheritable, so no check child can keep one.
    """
    directory: Path
    size: int

    def acquire(self) -> Optional[int]:
        """A descriptor holding one free slot, or None while every slot is held."""
        for index in range(self.size):
            descriptor = os.open(self.directory / f"{index}.lock", os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(descriptor)
                continue
            except OSError:
                os.close(descriptor)
                raise
            return descriptor
        return None


def _heavy_pool(repo: Path, settings: dict) -> HeavyPool:
    common = Path(_git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
    directory = common / "work" / "slots"
    directory.mkdir(parents=True, exist_ok=True)
    return HeavyPool(directory, heavy_slot_count(settings))


# ----------------------------------------------------------------- receipts


def _work_dir(repo: Path) -> Path:
    return Path(_git(repo, "rev-parse", "--absolute-git-dir").strip()) / "work"


def _prior_receipts(repo: Path, receipts: Path, head: str, digest: str) -> List[dict]:
    """Receipts on head or an ancestor under the same configuration, nearest first.

    Carry-over is decided per check, so a receipt that failed overall still
    proves every check that passed in it.
    """
    found: List[Tuple[int, dict]] = []
    for path in receipts.glob("*.json") if receipts.is_dir() else []:
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if receipt.get("configHash") != digest or not _is_ancestor(repo, receipt["head"], head):
            continue
        found.append((int(_git(repo, "rev-list", "--count", f"{receipt['head']}..{head}")), receipt))
    return [receipt for _, receipt in sorted(found, key=lambda item: item[0])]


def _physical_memory() -> int:
    """Physical RAM, not a competing snapshot of native simulator admission."""
    try:
        if sys.platform == "darwin":
            result = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.memsize"], capture_output=True, text=True)
            return int(result.stdout) if result.returncode == 0 else 0
        return os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError):
        return 0


def worker_count(jobs: Optional[int]) -> int:
    if jobs is not None:
        if type(jobs) is not int or jobs < 1:
            raise VerifyError("verify --jobs must be a positive integer")
        return jobs
    # A check can itself fan out to bounded test/build workers. Native tooling
    # remains the authority for live-memory admission and simulator leases.
    return max(1, min(4, os.cpu_count() or 1, _physical_memory() // (8 * 1024 ** 3)))


@contextlib.contextmanager
def _run_check(root: Path, prelude: str, command: str, log_path: Path, environment: Dict[str, str]):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with log_path.open("w") as log:
        log.write(f"$ {command}\n")
        log.flush()
        process = subprocess.Popen(
            ["bash", "-c", f"set -eo pipefail\n{prelude}\n{command}"],
            cwd=root, env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            yield process, started
        finally:
            # Settlement and abort retire the same process-group owner, including
            # descendants left behind by a check whose leader already exited.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)


@dataclass
class RunningCheck:
    check: Check
    process: subprocess.Popen
    started: float
    owner: contextlib.ExitStack
    group: Optional[str]


def _run_checks(root: Path, pending: list, prelude: str, jobs: int, environment: Dict[str, str],
                pool: HeavyPool, cpu_share: int) -> Dict[str, dict]:
    results: Dict[str, dict] = {}
    running: List[RunningCheck] = []
    # Heavy checks refused a slot, with the time of the first refusal: their wait counts in check time.
    queued: Dict[str, float] = {}
    # The invocation owns every started check. No threads or background queue
    # can outlive it; all exits unwind these exact process-group owners.
    with contextlib.ExitStack() as invocation:
        # SIGINT already unwinds Python frames. Termination/hangup must do the
        # same before restoring the caller's handlers and leaving this scope.
        def terminate(signum, _frame):
            raise SystemExit(128 + signum)

        for signum in (signal.SIGTERM, signal.SIGHUP):
            invocation.callback(signal.signal, signum, signal.getsignal(signum))
            signal.signal(signum, terminate)
        while pending or running:
            for task in pending[:]:
                if len(running) >= jobs:
                    break
                check, command, log_path, group = task
                if group and any(item.group == group for item in running):
                    continue
                descriptor = None
                if check.heavy:
                    descriptor = pool.acquire()
                    if descriptor is None:
                        # Only heavy checks wait here; independent checks keep launching.
                        if check.name not in queued:
                            queued[check.name] = time.monotonic()
                            print(f"  {check.name}: waiting for a heavy slot", flush=True)
                        continue
                owner = invocation.enter_context(contextlib.ExitStack())
                if descriptor is not None:
                    # Registered before the process group, so it is released only after the group is retired.
                    owner.callback(os.close, descriptor)
                    check_environment = {**environment, _CPU_SHARE_VARIABLE: str(cpu_share)}
                else:
                    check_environment = environment
                print(f"  {check.name}: running", flush=True)
                process, started = owner.enter_context(
                    _run_check(root, prelude, command, log_path, check_environment))
                started = queued.pop(check.name, started)
                running.append(RunningCheck(check, process, started, owner, group))
                pending.remove(task)
            for item in running[:]:
                code = item.process.poll()
                if code is None:
                    continue
                seconds = round(time.monotonic() - item.started, 1)
                results[item.check.name] = {"command": item.check.command, "exitCode": code,
                                            "seconds": seconds, "carriedFrom": None}
                item.owner.close()
                running.remove(item)
            if running:
                time.sleep(0.05)
    return results


# Media is explicit opt-in: format checks cannot establish that screen contents
# are safe. Operators review captures before supplying a head-bound manifest.
_MEDIA_COUNT = 10
_MEDIA_BYTES = 10 * 1024 * 1024
_MEDIA_TOTAL = 25 * 1024 * 1024
_MEDIA_NAME = re.compile(r"^[0-9a-f]{64}\.(png|jpg|mp4|mov)$")


@contextlib.contextmanager
def _parent_fd(path: Path, create: bool = False):
    """No-follow directory walk, including parents, rather than a check/open race."""
    path = path.absolute()
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            if create:
                with contextlib.suppress(FileExistsError):
                    os.mkdir(part, 0o700, dir_fd=fd)
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


def _read_regular(path: Path, bound: int) -> bytes:
    try:
        with _parent_fd(path) as parent:
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            with os.fdopen(fd, "rb") as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= bound:
                    raise VerifyError("evidence must be a nonempty bounded regular file")
                content = source.read(bound + 1)
                if not 0 < len(content) <= bound:
                    raise VerifyError("evidence exceeds its byte bound")
                return content
    except OSError as error:
        raise VerifyError(f"cannot read evidence file (missing, symlink or inaccessible): {path}") from error


def _media_extension(content: bytes, suffix: str) -> str:
    if suffix == ".png" and content.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if suffix in (".jpg", ".jpeg") and content.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if suffix in (".mp4", ".mov") and len(content) >= 12 and content[4:8] == b"ftyp":
        return suffix[1:]
    raise VerifyError("evidence format must match PNG, JPEG, MP4 or MOV media; never supply credentials")


def _snapshot_media(work: Path, head: str, manifest: Path) -> list:
    try:
        value = json.loads(_read_regular(manifest, 64 * 1024))
    except (ValueError, UnicodeError) as error:
        raise VerifyError("invalid evidence manifest JSON") from error
    if not isinstance(value, dict) or set(value) != {"head", "artifacts"} or value["head"] != head:
        raise VerifyError("evidence manifest must name the exact full head; recapture for this commit")
    items = value["artifacts"]
    if not isinstance(items, list) or not 1 <= len(items) <= _MEDIA_COUNT:
        raise VerifyError("evidence manifest needs 1–10 artifacts")
    captured, total = [], 0
    for item in items:
        relative = item.get("path") if isinstance(item, dict) and set(item) == {"path"} else None
        if (not isinstance(relative, str) or not relative or "\\" in relative or "\x00" in relative
                or Path(relative).is_absolute() or any(p in ("", ".", "..") for p in relative.split("/"))):
            raise VerifyError("evidence paths must stay beneath the manifest directory")
        source = manifest.parent / relative
        content = _read_regular(source, _MEDIA_BYTES)
        extension = _media_extension(content, source.suffix.lower())
        total += len(content)
        if total > _MEDIA_TOTAL:
            raise VerifyError("evidence exceeds the 25 MiB total byte bound")
        digest = hashlib.sha256(content).hexdigest()
        entry = {"name": f"{digest}.{extension}", "sha256": digest, "bytes": len(content)}
        if any(existing[0]["name"] == entry["name"] for existing in captured):
            raise VerifyError("evidence manifest repeats the same media")
        captured.append((entry, content))
    directory = work / "media" / head
    for entry, content in captured:
        target = directory / entry["name"]
        try:
            with _parent_fd(target, create=True) as parent:
                fd = os.open(target.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=parent)
                with os.fdopen(fd, "wb") as output:
                    output.write(content)
        except FileExistsError:
            if _read_regular(target, _MEDIA_BYTES) != content:
                raise VerifyError("existing evidence snapshot is corrupt; remove it and recapture")
        except OSError as error:
            raise VerifyError("cannot write evidence snapshot") from error
    return [entry for entry, _ in captured]


def _media_content(work: Path, receipt: dict) -> list:
    contents, total = [], 0
    artifacts = receipt.get("artifacts", [])
    if not isinstance(artifacts, list) or len(artifacts) > _MEDIA_COUNT:
        raise VerifyError("invalid receipt media count")
    for entry in artifacts:
        if not isinstance(entry, dict) or not _MEDIA_NAME.fullmatch(entry.get("name", "")):
            raise VerifyError("invalid receipt media name")
        content = _read_regular(work / "media" / receipt["head"] / entry["name"], _MEDIA_BYTES)
        digest = hashlib.sha256(content).hexdigest()
        if (len(content) != entry.get("bytes") or digest != entry.get("sha256")
                or not entry["name"].startswith(digest + ".")):
            raise VerifyError("evidence snapshot changed since verification; recapture")
        _media_extension(content, Path(entry["name"]).suffix)
        total += len(content)
        if total > _MEDIA_TOTAL:
            raise VerifyError("receipt media exceeds total byte bound")
        contents.append((entry, content))
    return contents


def _receipt_media(repo: Path, work: Path, head: str, manifest: Optional[Path]) -> list:
    if manifest is not None:
        return _snapshot_media(work, head, manifest)
    # Unlike check carry-over, media is never evidence for a different commit.
    # Use the nearest receipt regardless of check/config success to avoid silently
    # losing explicitly supplied evidence during reverify or land's base merge.
    candidates = []
    for path in (work / "receipts").glob("*.json"):
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if _is_ancestor(repo, receipt["head"], head):
            distance = int(_git(repo, "rev-list", "--count", f"{receipt['head']}..{head}"))
            candidates.append((distance, receipt))
    if not candidates:
        return []
    receipt = min(candidates, key=lambda item: item[0])[1]
    if receipt.get("artifacts") and receipt["head"] != head:
        raise VerifyError("head changed since media capture; recapture and supply --evidence-manifest")
    _media_content(work, receipt)
    return receipt.get("artifacts", [])


def media_links(receipt: dict, evidence_link: str) -> list:
    return [f"- [UI evidence {index}]({evidence_link}/media/{entry['name']}) (private)"
            for index, entry in enumerate(receipt.get("artifacts", []), 1)]


def branch_base(root: Path, config: dict) -> str:
    """The base the current branch is compared with: its claim's recorded base, else the configured one."""
    rules = config["claim"]
    branch = subprocess.run(["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=root,
                            capture_output=True, text=True).stdout.strip()
    number = claims.claimed_issue(branch) if branch else None
    if number is None:
        return rules["baseBranch"]
    try:
        return claims.claim_base(root, rules["remote"], rules["baseBranch"], "HEAD", number)
    except claims.ClaimError as error:
        raise VerifyError(str(error)) from None


def _check_environment() -> Dict[str, str]:
    """The inherited environment every check runs with: live-home paths dropped
    (the policy lists them), selectors refused. Checks never see the caller's
    live-home pointers, so a Stable agent shell can run them."""
    policy = Path(__file__).resolve().parents[2] / "packages" / "gateway" / "src" / "tron-home-environment-policy.mjs"
    try:
        result = subprocess.run(["node", str(policy)], capture_output=True, text=True)
    except OSError as error:
        raise VerifyError(f"cannot run Tron-home environment preflight: {error}") from error
    if result.returncode != 0:
        message = result.stderr.strip() or "inherited environment resolves into a live Tron home"
        raise VerifyError(message)
    dropped = set(result.stdout.split())
    # Only heavy checks receive the CPU share; an inherited value must not reach the others.
    return {name: value for name, value in os.environ.items()
            if name not in dropped and name != _CPU_SHARE_VARIABLE}


def verify(repo: Path, config: dict, evidence_manifest: Optional[Path] = None,
           jobs: Optional[int] = None) -> dict:
    check_environment = _check_environment()
    workers = worker_count(jobs)
    settings, claim = config["verify"], config["claim"]
    remote = claim["remote"]
    checks = load_checks(settings)
    root = Path(_git(repo, "rev-parse", "--show-toplevel").strip())
    pool = _heavy_pool(root, settings)
    cpu_share = max(1, (os.cpu_count() or 1) // pool.size)
    dirty = _dirty(root)
    if dirty:
        raise VerifyError("commit or remove local changes first; the receipt binds to a commit:\n  "
                          + "\n  ".join(dirty[:20]))
    head = _git(root, "rev-parse", "HEAD").strip()
    base = branch_base(root, config)
    _git(root, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{base}:refs/remotes/{remote}/{base}")
    base_tip = _git(root, "rev-parse", f"{remote}/{base}").strip()
    merge_base = _git(root, "merge-base", base_tip, head).strip()
    changed = _changed(root, merge_base, head)

    unmapped = [path for path in changed if not any(check.matches(path) for check in checks)]
    if unmapped:
        raise VerifyError("no verify check covers these changed paths; add them to verify.checks:\n  "
                          + "\n  ".join(unmapped))
    matched: Dict[str, List[str]] = {c.name: [p for p in changed if c.matches(p)] for c in checks}
    required = [c for c in checks if c.always or matched[c.name]]

    digest = config_hash(config)
    work = _work_dir(root)
    receipts = work / "receipts"
    artifacts = _receipt_media(root, work, head, evidence_manifest)
    priors = _prior_receipts(root, receipts, head, digest)
    since: Dict[str, List[str]] = {}

    results: Dict[str, dict] = {}
    pending = []
    for check in required:
        # The nearest receipt in which this check passed, not only a passing receipt.
        prior = next((r for r in priors if r.get("checks", {}).get(check.name, {}).get("exitCode") == 0), None)
        if prior is not None and not check.always:
            if prior["head"] not in since:
                since[prior["head"]] = _changed(root, prior["head"], head)
            if not any(check.matches(path) for path in since[prior["head"]]):
                earlier = prior["checks"][check.name]
                results[check.name] = {**earlier, "carriedFrom": earlier["carriedFrom"] or prior["head"]}
                continue
        present = [str(root / p) for p in matched[check.name] if (root / p).exists()]
        command = (check.command.replace("{paths}", " ".join(shlex.quote(p) for p in present))
                   .replace("{merge_base}", merge_base))
        log_path = work / "logs" / head / f"{check.name}.log"
        pending.append((check, command, log_path, check.group_for(matched[check.name])))

    executed = _run_checks(root, pending, settings.get("prelude", ""), workers, check_environment, pool, cpu_share)
    for check in required:
        if check.name in executed:
            results[check.name] = {**executed[check.name],
                                   "log": str(work / "logs" / head / f"{check.name}.log")}
        entry = results[check.name]
        if entry["carriedFrom"]:
            print(f"  {check.name}: carried from {entry['carriedFrom'][:12]}", flush=True)
        else:
            code, seconds = entry["exitCode"], entry["seconds"]
            print(f"  {check.name}: {'pass' if code == 0 else f'FAIL (exit {code})'} in {seconds}s", flush=True)
    # Completion order is deliberately not receipt/report order.
    results = {check.name: results[check.name] for check in required}

    if _git(root, "rev-parse", "HEAD").strip() != head or _dirty(root):
        raise VerifyError("the head or the worktree changed while checks ran; no receipt written")
    receipt = {
        "head": head,
        "base": {"ref": f"{remote}/{base}", "sha": base_tip},
        "mergeBase": merge_base,
        "configHash": digest,
        "changedPaths": changed,
        "required": [c.name for c in required],
        "checks": results,
        "artifacts": artifacts,
        "passed": all(results[c.name]["exitCode"] == 0 for c in required),
        "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    receipts.mkdir(parents=True, exist_ok=True)
    staged = receipts / f".{head}.json.tmp"
    staged.write_text(json.dumps(receipt, indent=2) + "\n")
    staged.replace(receipts / f"{head}.json")
    return receipt


def receipt_path(repo: Path, head: str) -> Path:
    return _work_dir(repo) / "receipts" / f"{head}.json"


# ----------------------------------------------------------------- evidence


def _redact(text: str, root: Path) -> str:
    text = _ANSI.sub("", text).replace(str(root), "<repo>")
    home = os.environ.get("HOME")
    return text.replace(home, "~") if home else text


def _excerpt(log: str, lines: int, root: Path) -> str:
    try:
        tail = Path(log).read_text(errors="replace").splitlines()[-lines:]
    except OSError:
        return "(log unavailable)"
    clipped = [line if len(line) <= _EXCERPT_LINE_LIMIT else line[:_EXCERPT_LINE_LIMIT] + "…" for line in tail]
    return _redact("\n".join(clipped), root).replace("```", "'''")


def _cell(text: str) -> str:
    return text.replace("\n", " ").replace("|", "\\|")


def comment_body(receipt: dict, settings: dict, root: Path, evidence_link: str) -> str:
    checks = receipt["checks"]
    passed = sum(1 for name in receipt["required"] if checks[name]["exitCode"] == 0)
    verdict = "passed" if receipt["passed"] else "FAILED"
    lines = [
        f"<!-- work:verify head={receipt['head']} -->",
        f"**Verify {verdict}** for `{receipt['head']}`: {passed}/{len(receipt['required'])} required checks passed.",
        "",
        f"- Base: `{receipt['base']['ref']}` at `{receipt['base']['sha'][:12]}`, "
        f"merge-base `{receipt['mergeBase'][:12]}`",
        f"- Changed paths: {len(receipt['changedPaths'])}",
        f"- Verify configuration: `{receipt['configHash'][:12]}`",
        f"- Full logs and receipt: [evidence]({evidence_link}) (private)",
        "",
        "| Check | Result | Wall time | Carried from | Command |",
        "| --- | --- | --- | --- | --- |",
    ]
    for name in receipt["required"]:
        entry = checks[name]
        result = "pass" if entry["exitCode"] == 0 else f"FAIL ({entry['exitCode']})"
        carried = f"`{entry['carriedFrom'][:12]}`" if entry["carriedFrom"] else ""
        lines.append(f"| {name} | {result} | {entry['seconds']}s | {carried} | `{_cell(entry['command'])}` |")
    for name in receipt["required"]:
        entry = checks[name]
        if entry["exitCode"] != 0:
            lines += ["", f"<details><summary>{name}: last {settings['excerptLines']} log lines</summary>", "",
                      "```", _excerpt(entry["log"], settings["excerptLines"], root), "```", "", "</details>"]
    lines += ["", *media_links(receipt, evidence_link)] if receipt.get("artifacts") else []
    return "\n".join(lines) + "\n"


def scrub(root: Path, command: str, text: str) -> None:
    completed = subprocess.run(["bash", "-c", command], cwd=root, input=text, capture_output=True, text=True)
    if completed.returncode != 0:
        detail = (completed.stdout + completed.stderr).strip()
        raise VerifyError(f"the scrub command refused the evidence text; nothing was posted\n{detail}")


_UPLOAD_CONFLICTS = 5


def _upload(gh: Gh, repository: str, path: str, content: bytes, message: str) -> None:
    api = f"repos/{repository}/contents/{path}"
    # Each PUT is a commit on the evidence branch: a compare-and-swap on its head.
    # Concurrent lands lose it with HTTP 409; that is re-read and re-applied, not
    # a failure. Every other error, and a bounded run of conflicts, still raises.
    for attempt in range(_UPLOAD_CONFLICTS):
        body = {"message": message, "content": base64.b64encode(content).decode()}
        try:
            body["sha"] = gh.rest("GET", api)["sha"]
        except GhError as error:
            if "HTTP 404" not in str(error):
                raise
        try:
            gh.rest("PUT", api, body)
            return
        except GhError as error:
            if "HTTP 409" not in str(error) or attempt == _UPLOAD_CONFLICTS - 1:
                raise


def open_pull(gh: Gh, branch: str) -> Optional[dict]:
    """The open pull request from `branch` in this repository, if any."""
    pulls = json.loads(gh.run("pr", "list", "--head", branch, "--state", "open",
                              "--json", "number,title,body,url,isCrossRepository,baseRefName"))
    # Claim branch names are public; a fork can open a pull request with the same head name.
    own = sorted((p for p in pulls if not p["isCrossRepository"]), key=lambda p: p["number"])
    return own[0] if own else None


def post(gh: Gh, repo: Path, config: dict, receipt: dict) -> str:
    """Publish the receipt for the current head: evidence first, then the final status."""
    settings, claim = config["verify"], config["claim"]
    root = Path(_git(repo, "rev-parse", "--show-toplevel").strip())
    head = receipt["head"]
    if head != _git(root, "rev-parse", "HEAD").strip():
        raise VerifyError("receipt does not describe the current head")
    branch = subprocess.run(["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=root,
                            capture_output=True, text=True).stdout.strip()
    if not branch:
        raise VerifyError("posting needs a branch; HEAD is detached")
    remote_line = _git(root, "ls-remote", claim["remote"], f"refs/heads/{branch}").split()
    if not remote_line or remote_line[0] != head:
        raise VerifyError(f"{claim['remote']}/{branch} is not at {head[:12]}; push the head first")

    repository = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()
    status_api = f"repos/{repository}/statuses/{head}"
    context = settings["statusContext"]

    def set_status(state: str, description: str, url: Optional[str] = None) -> None:
        body = {"state": state, "context": context, "description": description[:140]}
        if url:
            body["target_url"] = url
        gh.rest("POST", status_api, body)

    # Pending replaces any earlier status on this head before a lookup can fail.
    set_status("pending", "posting verify evidence")
    try:
        pull = open_pull(gh, branch)
        issue_match = _BRANCH_ISSUE.match(branch)
        if pull is None and not issue_match:
            raise VerifyError(f"no open pull request for {branch} and no issue number in the branch name")
        target = pull["number"] if pull is not None else int(issue_match.group(1))
        evidence_issue = int(issue_match.group(1)) if issue_match else target
        evidence_repository = repository + settings["evidenceRepositorySuffix"]
        evidence_dir = f"{evidence_issue}/{head}"
        # Full logs and the receipt are unscrubbed and hold local paths.
        if (gh.rest("GET", f"repos/{evidence_repository}") or {}).get("private") is not True:
            raise VerifyError(f"evidence repository {evidence_repository} is not private; nothing was uploaded")
        # Relative to the issue or pull request page, so no owner is written.
        link = f"../../{evidence_repository.split('/', 1)[1]}/tree/HEAD/{evidence_dir}"
        body = comment_body(receipt, settings, root, link)
        scrub(root, settings["scrubCommand"], body)
        media = _media_content(_work_dir(root), receipt)
        message = f"verify evidence for {head[:12]}"
        for entry, content in media:
            _upload(gh, evidence_repository, f"{evidence_dir}/media/{entry['name']}", content, message)
        for name in receipt["required"]:
            entry = receipt["checks"][name]
            try:
                content = Path(entry["log"]).read_bytes()
            except OSError:
                content = b"(log unavailable locally)\n"
            _upload(gh, evidence_repository, f"{evidence_dir}/{name}.log", content, message)
        _upload(gh, evidence_repository, f"{evidence_dir}/receipt.json",
                (json.dumps(receipt, indent=2) + "\n").encode(), message)
        comment = gh.rest("POST", f"repos/{repository}/issues/{target}/comments", {"body": body})
        url = comment["html_url"]
        passed = sum(1 for n in receipt["required"] if receipt["checks"][n]["exitCode"] == 0)
        carried = sum(1 for n in receipt["required"] if receipt["checks"][n]["carriedFrom"])
        summary = f"{passed}/{len(receipt['required'])} required checks passed ({carried} carried)"
        set_status("success" if receipt["passed"] else "failure", summary, url)
        return url
    except BaseException:
        try:
            set_status("failure", "verify evidence was not posted")
        except Exception:  # the original error is the one to report
            pass
        raise
