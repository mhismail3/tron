#!/usr/bin/env python3
"""Bound one subprocess group while streaming and preserving complete evidence."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
from typing import NoReturn

TIMEOUT_EXIT = 124
INTERRUPTED_EXIT = 130


def atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def artifact_inventory(artifact: str | None) -> list[dict[str, object]]:
    if not artifact:
        return []
    root = Path(artifact)
    if not root.exists():
        return []
    if root.is_file():
        return [{"path": root.name, "bytes": root.stat().st_size}]
    values: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            values.append({"path": str(path.relative_to(root)), "bytes": path.stat().st_size})
        if len(values) == 200:
            break
    return values


def capture_evidence(evidence_dir: Path, process: subprocess.Popen[bytes], reason: str, artifact: str | None) -> None:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    atomic_json(
        evidence_dir / "timeout.json",
        {
            "schema": "tron.ios-process-timeout.v1",
            "reason": reason,
            "pid": process.pid,
            "process_group": process.pid,
            "artifact": artifact,
            "artifact_exists": bool(artifact and Path(artifact).exists()),
            "artifact_files": artifact_inventory(artifact),
            "captured_at_epoch_seconds": int(time.time()),
        },
    )
    snapshot_text = ""
    try:
        snapshot_text = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,pgid=,state=,etime=,command="],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=5,
        ).stdout
        (evidence_dir / "process-tree.txt").write_text(snapshot_text)
    except (OSError, subprocess.SubprocessError) as error:
        (evidence_dir / "process-tree.txt").write_text(f"ps capture failed: {error}\n")

    sample = Path("/usr/bin/sample")
    if sample.exists():
        candidates: list[tuple[int, str]] = []
        for line in snapshot_text.splitlines():
            fields = line.strip().split(None, 5)
            if len(fields) != 6 or not fields[0].isdigit():
                continue
            pid, pgid, command = int(fields[0]), fields[2], fields[5]
            if pgid == str(process.pid) or any(name in command for name in ("testmanagerd", "TronMobile", "xcodebuild")):
                label = "xcodebuild" if "xcodebuild" in command else "testmanagerd" if "testmanagerd" in command else "test-host"
                candidates.append((pid, label))
        for index, (pid, label) in enumerate(candidates[:4]):
            try:
                sampled = subprocess.run(
                    [str(sample), str(pid), "1", "1"],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=5,
                ).stdout
                (evidence_dir / f"sample-{index}-{label}.txt").write_bytes(sampled[-256_000:])
            except (OSError, subprocess.SubprocessError) as error:
                (evidence_dir / f"sample-{index}-{label}.txt").write_text(f"sample failed: {error}\n")


def process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return False


def terminate_group(process: subprocess.Popen[bytes], grace_seconds: float) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    deadline = time.monotonic() + grace_seconds
    while process_group_exists(process.pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    try:
        process.wait(timeout=max(grace_seconds, 1.0))
    except subprocess.TimeoutExpired:
        pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--overall-seconds", required=True, type=float)
    parser.add_argument("--no-output-seconds", required=True, type=float)
    parser.add_argument("--term-grace-seconds", type=float, default=10.0)
    parser.add_argument("--artifact")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.command[:1] == ["--"]:
        arguments.command = arguments.command[1:]
    if not arguments.command:
        parser.error("a command is required after --")
    if arguments.overall_seconds <= 0 or arguments.no_output_seconds <= 0 or arguments.term_grace_seconds <= 0:
        parser.error("deadlines and grace period must be positive")
    return arguments


def main() -> int:
    arguments = parse_args()
    arguments.log.parent.mkdir(parents=True, exist_ok=True)
    arguments.evidence_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    last_output = started
    interrupted_signal: int | None = None
    timed_out_reason: str | None = None

    with arguments.log.open("wb") as log:
        process = subprocess.Popen(
            arguments.command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            bufsize=0,
        )
        assert process.stdout is not None

        def forward_signal(signum: int, _frame: object) -> None:
            nonlocal interrupted_signal
            interrupted_signal = signum
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass

        previous_handlers = {
            signum: signal.signal(signum, forward_signal)
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        }
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            while True:
                now = time.monotonic()
                if interrupted_signal is not None:
                    terminate_group(process, arguments.term_grace_seconds)
                    return 128 + interrupted_signal
                if now - started >= arguments.overall_seconds:
                    timed_out_reason = "overall"
                elif now - last_output >= arguments.no_output_seconds:
                    timed_out_reason = "no-output"
                if timed_out_reason is not None:
                    capture_evidence(arguments.evidence_dir, process, timed_out_reason, arguments.artifact)
                    terminate_group(process, arguments.term_grace_seconds)
                    return TIMEOUT_EXIT

                ready = selector.select(timeout=0.1)
                for key, _ in ready:
                    chunk = os.read(key.fd, 64 * 1024)
                    if chunk:
                        last_output = time.monotonic()
                        log.write(chunk)
                        log.flush()
                        sys.stdout.buffer.write(chunk)
                        sys.stdout.buffer.flush()
                    else:
                        selector.unregister(key.fileobj)
                if process.poll() is not None and not selector.get_map():
                    return 128 + interrupted_signal if interrupted_signal is not None else process.returncode
        finally:
            terminate_group(process, arguments.term_grace_seconds)
            selector.close()
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
            atomic_json(
                arguments.evidence_dir / "process.json",
                {
                    "schema": "tron.ios-process.v1",
                    "command": arguments.command,
                    "exit_code": process.returncode,
                    "elapsed_seconds": round(time.monotonic() - started, 3),
                    "timeout_reason": timed_out_reason,
                    "artifact": arguments.artifact,
                    "artifact_exists": bool(arguments.artifact and Path(arguments.artifact).exists()),
                },
            )


if __name__ == "__main__":
    raise SystemExit(main())
