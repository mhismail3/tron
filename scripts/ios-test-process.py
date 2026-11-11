#!/usr/bin/env python3
"""Bound one subprocess group while streaming and preserving complete evidence."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import plistlib
import re
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import threading
import uuid
from typing import NoReturn

TIMEOUT_EXIT = 124
INTERRUPTED_EXIT = 130
PROCESS_TREE_MAX_BYTES = 64 * 1024


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
    except (OSError, subprocess.SubprocessError) as error:
        (evidence_dir / "process-tree.txt").write_text(f"ps capture failed: {error}\n")
        return

    owned_lines: list[str] = []
    candidates: list[tuple[int, str]] = []
    for line in snapshot_text.splitlines():
        fields = line.strip().split(None, 5)
        if len(fields) != 6 or not fields[0].isdigit() or fields[2] != str(process.pid):
            continue
        owned_lines.append(line)
        pid, command = int(fields[0]), fields[5]
        label = "xcodebuild" if "xcodebuild" in command else "testmanagerd" if "testmanagerd" in command else "test-host"
        candidates.append((pid, label))
    (evidence_dir / "process-tree.txt").write_bytes(
        ("\n".join(owned_lines) + "\n").encode()[:PROCESS_TREE_MAX_BYTES]
    )

    sample = Path("/usr/bin/sample")
    if sample.exists():
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


def bounded_command(command: list[str], seconds: float = 3, limit: int = 256_000, truncate: bool = False) -> bytes:
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        selector = selectors.DefaultSelector()
        assert child.stdout is not None and child.stderr is not None
        selector.register(child.stdout, selectors.EVENT_READ)
        selector.register(child.stderr, selectors.EVENT_READ)
        output = bytearray()
        errors = bytearray()
        deadline = time.monotonic() + seconds
        try:
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(command, seconds, output=bytes(output[:limit]))
                for key, _ in selector.select(timeout=0.05):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        (output if key.fileobj is child.stdout else errors).extend(chunk)
                        if len(output) + len(errors) > limit:
                            if truncate:
                                return bytes(output[:limit])
                            raise ValueError(f"{command[0]} exceeded {limit} bytes")
            child.wait(timeout=max(0.01, deadline - time.monotonic()))
            if child.returncode:
                raise ValueError(f"{command[0]} exited {child.returncode}")
            return bytes(output)
        finally:
            selector.close()
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
    finally:
        if child.stdout:
            child.stdout.close()
        if child.stderr:
            child.stderr.close()


def bounded_json(path: Path) -> dict:
    with path.open("rb") as source:
        data = source.read(256_001)
    if len(data) > 256_000:
        raise ValueError("hosted snapshot exceeds 256000 bytes")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("hosted snapshot is not an object")
    return value


def executable_path(pid: int) -> str:
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    buffer = ctypes.create_string_buffer(4096)
    size = library.proc_pidpath(pid, buffer, len(buffer))
    return os.fsdecode(buffer.value) if size > 0 else ""


def process_birth(pid: int) -> dict[str, int]:
    class BSDInfo(ctypes.Structure):
        _fields_ = [("ids", ctypes.c_uint32 * 12), ("names", ctypes.c_char * 48),
                    ("counts", ctypes.c_uint32 * 6), ("seconds", ctypes.c_uint64),
                    ("microseconds", ctypes.c_uint64)]

    info = BSDInfo()
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    size = library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size != ctypes.sizeof(info) or info.ids[3] != pid or info.seconds == 0:
        raise ValueError("live process birth identity unavailable")
    return {"seconds": info.seconds, "microseconds": info.microseconds}


def capture_app_process(evidence_dir: Path, pid: int, executable: str, directory: Path, run) -> dict[str, object]:
    receipt: dict[str, object] = {"schema": "tron.ios-xctest-idle-app.v1", "pid": pid,
                                 "executable": executable, "signal": "not-sent"}
    birth = process_birth(pid)
    receipt["process_birth"] = birth
    try:
        if executable_path(pid) != executable:
            raise ValueError("owned app executable changed before readiness")
        ready = bounded_json(directory / "ready.json")
        if ready.get("pid") != pid or not isinstance(ready.get("launch"), str):
            raise ValueError("hosted signal readiness does not match live app")
        if ready.get("process_birth") != birth:
            raise ValueError("hosted signal readiness belongs to another process incarnation")
        receipt["launch"] = ready["launch"]
        request = uuid.uuid4().hex
        receipt["request"] = request
        atomic_json(directory / "request.json", {"pid": pid, "launch": ready["launch"], "request": request})
        if executable_path(pid) != executable or process_birth(pid) != birth:
            raise ValueError("owned app incarnation changed before signal")
        os.kill(pid, signal.SIGUSR2)
        receipt["signal"] = "sent"
        snapshot_deadline = time.monotonic() + 2
        receipt["snapshot"] = "not-received-within-2s"
        while time.monotonic() < snapshot_deadline:
            try:
                snapshot = bounded_json(directory / "snapshot.json")
                if (snapshot.get("pid"), snapshot.get("launch"), snapshot.get("request")) == (pid, ready["launch"], request):
                    atomic_json(evidence_dir / "app-animation-state.json", snapshot)
                    receipt["snapshot"] = "received"
                    break
            except (OSError, ValueError):
                pass
            time.sleep(0.05)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        receipt["error"] = f"{type(error).__name__}: {error}"
    finally:
        try:
            if executable_path(pid) == executable and process_birth(pid) == birth:
                sample = run(["/usr/bin/sample", str(pid), "1", "1"], seconds=10, truncate=True)
                (evidence_dir / "app-main-thread.sample.txt").write_bytes(sample)
                receipt["sample"] = "captured"
                receipt["sample_limit_reached"] = len(sample) == 256_000
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            receipt["sample_error"] = f"{type(error).__name__}: {error}"
            if isinstance(error, subprocess.TimeoutExpired) and error.output:
                (evidence_dir / "app-main-thread.sample.txt").write_bytes(error.output[:256_000])
                receipt["sample"] = "partial"
        atomic_json(evidence_dir / "app-capture.json", receipt)
    return receipt


def capture_idle_app(evidence_dir: Path, simulator: str) -> None:
    receipt: dict[str, object] = {"schema": "tron.ios-xctest-idle-app.v1", "simulator": simulator, "signal": "not-sent"}
    deadline = time.monotonic() + 15

    def run(command: list[str], seconds: float = 3, limit: int = 256_000, truncate: bool = False) -> bytes:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("idle capture exceeded 15s budget")
        return bounded_command(command, seconds=min(seconds, remaining), limit=limit, truncate=truncate)

    try:
        def container(kind: str) -> Path:
            return Path(os.fsdecode(run([
                "xcrun", "simctl", "get_app_container", simulator, "com.tron.mobile.testhost", kind,
            ])).strip()).resolve(strict=True)

        app = container("app")
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        name = info["CFBundleExecutable"]
        if not isinstance(name, str) or Path(name).name != name:
            raise ValueError("invalid CFBundleExecutable")
        executable = str((app / name).resolve(strict=True))
        pids = run(["/bin/ps", "-axo", "pid="], limit=64 * 1024).split()
        matches = []
        for candidate in pids:
            if time.monotonic() >= deadline:
                raise TimeoutError("app identity scan exceeded capture budget")
            if candidate.isdigit() and executable_path(int(candidate)) == executable:
                matches.append(int(candidate))
        if len(matches) != 1:
            raise ValueError(f"expected one exact owned app executable, found {len(matches)}")
        pid = matches[0]
        receipt.update(pid=pid, executable=executable)
        directory = container("data") / "Library/Caches/tron-xctest-idle"
        captured = capture_app_process(evidence_dir, pid, executable, directory, run)
        captured["simulator"] = simulator
        atomic_json(evidence_dir / "app-capture.json", captured)
        return
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        receipt["error"] = f"{type(error).__name__}: {error}"
        atomic_json(evidence_dir / "app-capture.json", receipt)


class XCTestIdleCapture:
    def __init__(self, directory: Path, simulator: str | None):
        self.directory = directory
        self.simulator = simulator
        self.pending = b""
        self.phase: tuple[float, float, int] | None = None
        self.phase_index = 0
        self.capture: dict[str, object] | None = None
        self.worker: threading.Thread | None = None

    def consume(self, chunk: bytes) -> None:
        if not self.simulator:
            return
        self.pending = (self.pending + chunk)[-128_000:]
        while b"\n" in self.pending:
            line, self.pending = self.pending.split(b"\n", 1)
            progress = re.match(rb"\s*t =\s*([0-9]+(?:\.[0-9]+)?)s\s+(.*)", line)
            if not progress:
                if line.startswith((b"Test Case ", b"Test Suite ")):
                    self.phase = None
                continue
            elapsed, message = float(progress[1]), progress[2]
            if b"App animations complete notification not received" in message and self.phase:
                if self.capture is None:
                    self.start_capture(actual_warning=True)
                if self.capture and self.capture["idle_phase"] == self.phase[2]:
                    self.capture["actual_animation_warning_observed"] = True
                    self.capture["xctest_wait_seconds_at_warning"] = round(elapsed - self.phase[1], 3)
                    self.save()
            if b"Wait for com.tron.mobile.testhost to idle" in message:
                self.phase_index += 1
                self.phase = (time.monotonic(), elapsed, self.phase_index)
            else:
                self.phase = None

    def save(self) -> None:
        assert self.capture is not None
        try:
            atomic_json(self.directory / "xctest-idle.json", self.capture)
        except OSError:
            pass

    def tick(self) -> None:
        if not self.simulator or self.capture is not None or not self.phase:
            return
        if time.monotonic() - self.phase[0] >= 15:
            self.start_capture()

    def start_capture(self, actual_warning: bool = False) -> None:
        assert self.phase is not None and self.simulator is not None
        self.capture = {
            "schema": "tron.ios-xctest-idle.v1",
            "classification": "xctest-animation-warning" if actual_warning else "provisional-prolonged-xctest-idle",
            "xctest_elapsed_seconds": self.phase[1],
            "no_xctest_progress_seconds": round(time.monotonic() - self.phase[0], 3),
            "idle_phase": self.phase[2],
            "actual_animation_warning_observed": actual_warning,
        }
        self.save()
        self.worker = threading.Thread(target=capture_idle_app, args=(self.directory, self.simulator), daemon=True)
        try:
            self.worker.start()
        except RuntimeError as error:
            self.capture["capture_error"] = str(error)
            self.worker = None
            self.save()

    def finish(self) -> None:
        if self.worker:
            self.worker.join(timeout=20)


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
    parser.add_argument("--idle-simulator")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.idle_simulator and not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", arguments.idle_simulator):
        parser.error("--idle-simulator requires an exact simulator UUID")
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
    idle = XCTestIdleCapture(arguments.evidence_dir, arguments.idle_simulator)
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
            except (ProcessLookupError, PermissionError):
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

                idle.tick()
                ready = selector.select(timeout=0.1)
                for key, _ in ready:
                    chunk = os.read(key.fd, 64 * 1024)
                    if chunk:
                        last_output = time.monotonic()
                        idle.consume(chunk)
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
            idle.finish()
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
                    "idle_simulator": arguments.idle_simulator,
                    "artifact": arguments.artifact,
                    "artifact_exists": bool(arguments.artifact and Path(arguments.artifact).exists()),
                },
            )


if __name__ == "__main__":
    raise SystemExit(main())
