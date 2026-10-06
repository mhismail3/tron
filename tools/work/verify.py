"""`work verify`: diff -> check set -> run -> receipt -> evidence (README.md, `verify`)."""
from __future__ import annotations

import base64
import contextlib
import hashlib
import json
import os
import re
import shlex
import signal
import stat
import subprocess
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

    def matches(self, path: str) -> bool:
        return any(pattern.match(path) for pattern in self.patterns)


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
        names.add(name)
        checks.append(Check(name, raw["paths"], raw["command"], always, [glob_regex(g) for g in raw["paths"]]))
    return checks


def config_hash(config: dict) -> str:
    scope = {"remote": config["claim"]["remote"], "baseBranch": config["claim"]["baseBranch"],
             "verify": config["verify"]}
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


# ----------------------------------------------------------------- receipts


def _work_dir(repo: Path) -> Path:
    return Path(_git(repo, "rev-parse", "--absolute-git-dir").strip()) / "work"


def _prior_receipt(repo: Path, receipts: Path, head: str, digest: str) -> Optional[dict]:
    """The nearest passing receipt on an ancestor of head under the same configuration."""
    best: Optional[Tuple[int, dict]] = None
    for path in receipts.glob("*.json") if receipts.is_dir() else []:
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if (receipt.get("passed") is not True or receipt.get("configHash") != digest
                or not _is_ancestor(repo, receipt["head"], head)):
            continue
        distance = int(_git(repo, "rev-list", "--count", f"{receipt['head']}..{head}"))
        if best is None or distance < best[0]:
            best = (distance, receipt)
    return best[1] if best else None


def _run_check(root: Path, check: Check, prelude: str, command: str, log_path: Path) -> Tuple[int, float]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with log_path.open("w") as log:
        log.write(f"$ {command}\n")
        log.flush()
        process = subprocess.Popen(
            ["bash", "-c", f"set -eo pipefail\n{prelude}\n{command}"],
            cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            code = process.wait()
        except BaseException:
            # The check owns a process group; an interrupted verify leaves nothing running.
            # The group may already be gone; the interrupt stays the reported error.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
    return code, round(time.monotonic() - started, 1)


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


def verify(repo: Path, config: dict, evidence_manifest: Optional[Path] = None) -> dict:
    settings, claim = config["verify"], config["claim"]
    remote = claim["remote"]
    checks = load_checks(settings)
    root = Path(_git(repo, "rev-parse", "--show-toplevel").strip())
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
    prior = _prior_receipt(root, receipts, head, digest)
    since_prior = _changed(root, prior["head"], head) if prior else []

    results: Dict[str, dict] = {}
    for check in required:
        earlier = (prior or {}).get("checks", {}).get(check.name)
        if (earlier and earlier["exitCode"] == 0 and not check.always
                and not any(check.matches(path) for path in since_prior)):
            results[check.name] = {**earlier, "carriedFrom": earlier["carriedFrom"] or prior["head"]}
            print(f"  {check.name}: carried from {results[check.name]['carriedFrom'][:12]}")
            continue
        present = [str(root / p) for p in matched[check.name] if (root / p).exists()]
        command = (check.command.replace("{paths}", " ".join(shlex.quote(p) for p in present))
                   .replace("{merge_base}", merge_base))
        log_path = work / "logs" / head / f"{check.name}.log"
        print(f"  {check.name}: running", flush=True)
        code, seconds = _run_check(root, check, settings.get("prelude", ""), command, log_path)
        print(f"  {check.name}: {'pass' if code == 0 else f'FAIL (exit {code})'} in {seconds}s")
        results[check.name] = {"command": check.command, "exitCode": code, "seconds": seconds,
                               "log": str(log_path), "carriedFrom": None}

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


def _upload(gh: Gh, repository: str, path: str, content: bytes, message: str) -> None:
    api = f"repos/{repository}/contents/{path}"
    body = {"message": message, "content": base64.b64encode(content).decode()}
    try:
        body["sha"] = gh.rest("GET", api)["sha"]
    except GhError as error:
        if "HTTP 404" not in str(error):
            raise
    gh.rest("PUT", api, body)


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
