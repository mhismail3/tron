"""`work land --acceptance`: run a task's registered journeys and check their evidence.

The registry is one declarative mapping in the repository's `.github/work.json`:
each journey id names the journey its report must belong to, the command that
owns it, the report that command leaves in the evidence directory the run is
given, and the wall-clock bound it runs under (README.md, `land`).

Nothing here names a repository, a framework or a language. A journey is a shell
command; its report is JSON that names the journey it belongs to, its final
status, whether its evidence is complete, and the source state it was stamped
with. Tron's registry runs the real-UI journeys of `scripts/ios-gateway-e2e-test`,
which write the report named by packages/ios-app/docs/development.md.
"""
from __future__ import annotations

import hashlib
import json
import os
import signal
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Tuple


class AcceptanceError(RuntimeError):
    pass


# How long a journey that passed its bound is given to wind down after SIGINT
# before land stops and reports it. The harness stops its fixture and the lease
# holder releases the simulator lane while they run their own wind-down, so land
# never SIGKILLs a journey: a killed holder leaves the lane booted until another
# command's sweep reclaims it (AGENTS.md, process lifecycle and cleanup).
_WIND_DOWN_SECONDS = 120


def journeys(config: dict) -> Dict[str, dict]:
    """The registered journeys, id -> its declaration."""
    section = config.get("acceptance")
    registered = section.get("journeys") if isinstance(section, dict) else None
    if not isinstance(registered, dict) or not registered:
        raise AcceptanceError("this repository registers no acceptance journeys; "
                              "add acceptance.journeys to .github/work.json")
    evidence_env(config)
    return registered


def evidence_env(config: dict) -> str:
    """The environment variable that carries a journey's evidence directory."""
    section = config.get("acceptance")
    name = section.get("evidenceEnv") if isinstance(section, dict) else None
    if not isinstance(name, str) or not name:
        raise AcceptanceError("acceptance.evidenceEnv names the environment variable that carries a "
                              "journey's evidence directory")
    return name


def requested(config: dict, value: str) -> List[str]:
    """The journey ids an `--acceptance` value names, each one registered."""
    ids = [part.strip() for part in value.split(",")]
    if any(not part for part in ids):
        raise AcceptanceError("--acceptance takes one or more comma-separated journey ids")
    registered = journeys(config)
    unknown = [journey for journey in ids if journey not in registered]
    if unknown:
        raise AcceptanceError("unknown acceptance journey " + ", ".join(unknown) + "; registered: "
                              + ", ".join(sorted(registered)))
    return ids


def entry(config: dict, journey: str) -> dict:
    """One journey's declaration, with every field land needs to run and judge it."""
    declared = journeys(config)[journey]
    for name in ("journey", "command", "report"):
        value = declared.get(name)
        if not isinstance(value, str) or not value.strip():
            raise AcceptanceError(f"acceptance.journeys.{journey}.{name} must be a non-empty string")
    timeout = declared.get("timeoutSeconds")
    if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout <= 0:
        raise AcceptanceError(f"acceptance.journeys.{journey}.timeoutSeconds must be a positive whole "
                              "number of seconds")
    return declared


def evidence_directory(repo: Path, head: str) -> Path:
    """This worktree's evidence directory for one head, beside verify's receipts and logs."""
    return Path(_git(repo, "rev-parse", "--absolute-git-dir")) / "work" / "acceptance" / head


def run(config: dict, repo: Path, head: str, journey: str) -> dict:
    """Run one registered journey against `head` and return the evidence record for its report.

    The command receives the head's evidence directory in the environment
    variable the registry names, so every journey of this head shares one
    directory: a second run there reuses the fixture state and dependency
    install the first one paid for.
    """
    declared = entry(config, journey)
    command = declared["command"].replace("{journey}", declared["journey"])
    timeout = declared["timeoutSeconds"]
    evidence = evidence_directory(repo, head)
    env = dict(os.environ)
    env[evidence_env(config)] = str(evidence)
    path = evidence / declared["report"]
    # What sits at the declared report path now: a run that exits without
    # writing must never be judged on the report an earlier run left there.
    before = _report_state(path)
    print(f"journey:  {journey}: {command}", flush=True)
    process = subprocess.Popen(command, shell=True, cwd=repo, env=env)
    try:
        returncode = process.wait(timeout=timeout)
    except KeyboardInterrupt:
        # The journey shares this terminal's process group, so it already has
        # SIGINT and bounds its own wind-down. Waiting for it keeps the fixture
        # stop and the lane release; subprocess.run would SIGKILL it after a
        # quarter of a second and leave the simulator booted.
        process.wait()
        raise
    except subprocess.TimeoutExpired:
        code = _interrupt(journey, process, timeout)
        raise AcceptanceError(f"acceptance journey {journey} passed its {timeout}s bound and was "
                              f"interrupted (exit {code}); nothing was pushed, posted or merged") from None
    if returncode != 0:
        raise AcceptanceError(f"acceptance journey {journey} failed (exit {returncode}); "
                              "nothing was pushed, posted or merged")

    after = _report_state(path)
    if after is None:
        raise AcceptanceError(f"acceptance journey {journey} left no report at {path}")
    if after == before:
        raise AcceptanceError(f"acceptance journey {journey} left no new report at {path}; the file "
                              "there is the one an earlier run wrote")
    try:
        data = path.read_bytes()
    except OSError as error:
        raise AcceptanceError(f"acceptance journey {journey} left no report at {path}: {error}") from None
    try:
        report = json.loads(data)
    except ValueError as error:
        raise AcceptanceError(f"acceptance journey {journey} left an unreadable report at {path}: {error}") from None
    if not isinstance(report, dict):
        raise AcceptanceError(f"acceptance journey {journey} left a report that is not a JSON object at {path}")
    # The bytes land read are kept under the journey's own name: the run that
    # follows replaces the link this report path resolves through, and a refused
    # report has to stay inspectable too.
    kept = evidence / f"{journey}.report.json"
    kept.write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    check(journey, report, head, declared["journey"])
    print(f"journey:  {journey} passed in {report.get('journey_seconds', 0)}s; "
          f"report sha256 {digest[:16]}", flush=True)
    return record(journey, report, digest)


def check(journey: str, report: dict, head: str, expected: str) -> None:
    """Refuse a report that does not prove this journey ran to completion from exactly `head`."""
    named = report.get("journey")
    if named != expected:
        raise AcceptanceError(f"acceptance journey {journey}'s report is for {named!r}, "
                              f"not the registered journey {expected!r}")
    status = report.get("journey_status")
    if status != 0:
        raise AcceptanceError(f"acceptance journey {journey} reported status {status!r}; "
                              "nothing was pushed, posted or merged")
    if report.get("evidence_complete") is not True:
        raise AcceptanceError(f"acceptance journey {journey} did not leave complete evidence; "
                              "nothing was pushed, posted or merged")
    source = report.get("source")
    if not isinstance(source, dict):
        raise AcceptanceError(f"acceptance journey {journey}'s report names no source state")
    revision = source.get("revision")
    if revision != head:
        raise AcceptanceError(f"acceptance journey {journey} ran from {str(revision)[:12]}, "
                              f"not the head being landed ({head[:12]})")
    if source.get("dirty") is not False:
        raise AcceptanceError(f"acceptance journey {journey} ran from a dirty worktree, so its report "
                              "does not describe the head being landed")
    fingerprint = source.get("source_fingerprint")
    if not isinstance(fingerprint, str) or not fingerprint:
        raise AcceptanceError(f"acceptance journey {journey}'s report names no source fingerprint")


def record(journey: str, report: dict, digest: str) -> dict:
    """What the pull request cites about one passing journey."""
    source = report["source"]
    return {
        "journey": journey,
        "sha256": digest,
        "seconds": report.get("journey_seconds", 0),
        "artifacts": len(report.get("artifacts") or []),
        "revision": source["revision"],
        "fingerprint": source["source_fingerprint"],
    }


def _report_state(path: Path) -> Optional[Tuple[str, int, int]]:
    """The resolved path and file identity of a report path, or None when nothing is there."""
    try:
        resolved = path.resolve(strict=True)
        info = resolved.stat()
    except OSError:
        return None
    return (str(resolved), info.st_ino, info.st_mtime_ns)


def _interrupt(journey: str, process: "subprocess.Popen", timeout: int) -> int:
    """SIGINT a journey that passed its bound, wait for its own wind-down, and return its exit.

    SIGINT, never SIGKILL: the harness stops its fixture and the lease holder
    releases the simulator lane only while they run that wind-down.
    """
    process.send_signal(signal.SIGINT)
    try:
        return process.wait(timeout=_WIND_DOWN_SECONDS)
    except subprocess.TimeoutExpired:
        raise AcceptanceError(f"acceptance journey {journey} is still running {_WIND_DOWN_SECONDS}s after "
                              f"SIGINT (PID {process.pid}); it holds the simulator lane, so stop it and run "
                              "land again") from None


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if completed.returncode != 0:
        raise AcceptanceError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout.strip()
