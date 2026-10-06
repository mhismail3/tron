"""`work land --acceptance`: run a task's registered journeys and check their evidence.

The registry is one declarative mapping in the repository's `.github/work.json`:
each journey id names the command that owns it and the report that command
leaves in the evidence directory the run is given (README.md, `land`).

Nothing here names a repository, a framework or a language. A journey is a shell
command; its report is JSON that states the journey's final status, whether its
evidence is complete, and the source state it was stamped with. Tron's registry
runs the real-UI journeys of `scripts/ios-gateway-e2e-test`, which write the
report named by packages/ios-app/docs/development.md.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Dict, List


class AcceptanceError(RuntimeError):
    pass


def journeys(config: dict) -> Dict[str, dict]:
    """The registered journeys, id -> its command and its report path."""
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
    entry = journeys(config)[journey]
    command, relative = entry["command"], entry["report"]
    evidence = evidence_directory(repo, head)
    env = dict(os.environ)
    env[evidence_env(config)] = str(evidence)
    print(f"journey:  {journey}: {command}", flush=True)
    completed = subprocess.run(command, shell=True, cwd=repo, env=env)
    if completed.returncode != 0:
        raise AcceptanceError(f"acceptance journey {journey} failed (exit {completed.returncode}); "
                              "nothing was pushed, posted or merged")

    path = evidence / relative
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
    check(journey, report, head)
    print(f"journey:  {journey} passed in {report.get('journey_seconds', 0)}s; "
          f"report sha256 {digest[:16]}", flush=True)
    return record(journey, report, digest)


def check(journey: str, report: dict, head: str) -> None:
    """Refuse a report that does not prove this journey ran to completion from exactly `head`."""
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


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if completed.returncode != 0:
        raise AcceptanceError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout.strip()
