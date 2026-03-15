#!/usr/bin/env python3
"""Tron server benchmark — measures WebSocket RPC latencies.

Boots a fresh server with a temp database, connects via WebSocket,
and measures round-trip times for key RPC operations.

Scenarios:
  ping             system.ping round-trip (WebSocket + dispatch)
  session_create   Create + delete sessions (SQLite write path)
  session_list     List sessions (SQLite read path)
  all              Run all scenarios (default)
  gate             Stable subset for regression gating

Usage:
  python3 bench.py [options]
  python3 bench.py --baseline baselines/macos-aarch64.json --enforce-gates
"""

import argparse
import asyncio
import json
import math
import os
import platform
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request

try:
    import websockets
except ImportError:
    print("Installing websockets...", file=sys.stderr)
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "websockets", "-q"],
        stdout=subprocess.DEVNULL,
    )
    import websockets


# ── Server lifecycle ─────────────────────────────────────────────────────────

BENCH_PORT = 19847  # high port unlikely to conflict


def find_binary():
    """Find the tron release binary."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    workspace = os.path.join(script_dir, "..", "..", "packages", "agent")
    binary = os.path.join(workspace, "target", "release", "tron")
    if not os.path.isfile(binary):
        print(f"Release binary not found: {binary}", file=sys.stderr)
        print("Build it first: cd packages/agent && cargo build --release", file=sys.stderr)
        sys.exit(1)
    return binary


def boot_server(binary, db_path, port, home_dir=None):
    """Start the tron server as a subprocess. Returns the process."""
    env = os.environ.copy()
    env["RUST_LOG"] = "warn"
    if home_dir:
        env["HOME"] = home_dir
    proc = subprocess.Popen(
        [binary, "--port", str(port), "--db-path", db_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    return proc


def wait_for_server(port, timeout=15):
    """Poll the health endpoint until the server is ready."""
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            resp = urllib.request.urlopen(url, timeout=1)
            if resp.status == 200:
                return True
        except Exception:
            pass
        time.sleep(0.1)
    return False


def kill_server(proc):
    """Gracefully stop the server."""
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


# ── WebSocket helpers ────────────────────────────────────────────────────────

async def ws_connect(port):
    """Connect to the server WebSocket and consume the connection.established message."""
    ws = await websockets.connect(f"ws://127.0.0.1:{port}/ws")
    # Read and discard the connection.established message
    msg = await asyncio.wait_for(ws.recv(), timeout=5)
    data = json.loads(msg)
    assert data.get("type") == "connection.established", f"unexpected: {data}"
    return ws


async def rpc_call(ws, call_id, method, params=None):
    """Send an RPC call and wait for the matching response."""
    req = {"id": f"r{call_id}", "method": method}
    if params is not None:
        req["params"] = params
    await ws.send(json.dumps(req))

    while True:
        msg = await asyncio.wait_for(ws.recv(), timeout=10)
        data = json.loads(msg)
        if data.get("id") == f"r{call_id}":
            return data


# ── Scenarios ────────────────────────────────────────────────────────────────

async def scenario_ping(ws, iterations):
    """Measure system.ping round-trip latency."""
    latencies = []
    for i in range(iterations):
        start = time.perf_counter()
        resp = await rpc_call(ws, i, "system.ping")
        elapsed_ms = (time.perf_counter() - start) * 1000
        assert resp.get("success") is True, f"ping failed: {resp}"
        latencies.append(elapsed_ms)
    return {"name": "ping", "iterations": iterations, "latency_ms": summarize(latencies)}


async def scenario_session_create(ws, iterations):
    """Measure session.create + session.delete round-trip latency."""
    latencies = []
    for i in range(iterations):
        start = time.perf_counter()
        resp = await rpc_call(
            ws,
            10000 + i,
            "session.create",
            {"workingDirectory": f"/tmp/bench-{i}", "model": "claude-sonnet-4-6"},
        )
        elapsed_ms = (time.perf_counter() - start) * 1000
        assert resp.get("success") is True, f"session.create failed: {resp}"
        session_id = resp["result"]["sessionId"]

        # Clean up
        await rpc_call(ws, 20000 + i, "session.delete", {"sessionId": session_id})
        latencies.append(elapsed_ms)
    return {
        "name": "session_create",
        "iterations": iterations,
        "latency_ms": summarize(latencies),
    }


async def scenario_session_list(ws, iterations):
    """Measure session.list round-trip latency."""
    latencies = []
    for i in range(iterations):
        start = time.perf_counter()
        resp = await rpc_call(ws, 30000 + i, "session.list")
        elapsed_ms = (time.perf_counter() - start) * 1000
        assert resp.get("success") is True, f"session.list failed: {resp}"
        latencies.append(elapsed_ms)
    return {
        "name": "session_list",
        "iterations": iterations,
        "latency_ms": summarize(latencies),
    }


SCENARIOS = {
    "ping": scenario_ping,
    "session_create": scenario_session_create,
    "session_list": scenario_session_list,
}

GATE_SCENARIOS = ["ping", "session_create", "session_list"]


def resolve_scenario_names(name):
    if name == "all":
        return list(SCENARIOS.keys())
    if name == "gate":
        return GATE_SCENARIOS
    if name in SCENARIOS:
        return [name]
    print(f"Unknown scenario: {name}", file=sys.stderr)
    sys.exit(1)


# ── Stats ────────────────────────────────────────────────────────────────────

def summarize(latencies):
    if not latencies:
        return {"p50": 0, "p95": 0, "mean": 0, "min": 0, "max": 0}
    s = sorted(latencies)
    n = len(s)
    return {
        "p50": s[int(n * 0.50)],
        "p95": s[min(int(n * 0.95), n - 1)],
        "mean": sum(s) / n,
        "min": s[0],
        "max": s[-1],
    }


def current_environment():
    os_name = platform.system().lower()
    if os_name == "darwin":
        os_name = "macos"
    arch = platform.machine().lower()
    if arch == "arm64":
        arch = "aarch64"
    return {"os": os_name, "arch": arch, "cpu_count": os.cpu_count() or 1}


# ── Gate comparison ──────────────────────────────────────────────────────────

def compare_reports(baseline, current, thresholds):
    """Compare current results against a baseline. Returns (passed, summary)."""
    if baseline["environment"] != current["environment"]:
        return False, "environment mismatch"
    if baseline["config"] != current["config"]:
        return False, "config mismatch"

    baseline_by_name = {s["name"]: s for s in baseline["scenarios"]}
    failures = []
    worst_p95 = 0.0
    worst_mean = 0.0

    for sc in current["scenarios"]:
        base = baseline_by_name.get(sc["name"])
        if base is None:
            continue
        p95_reg = regression_pct(base["latency_ms"]["p95"], sc["latency_ms"]["p95"])
        mean_reg = regression_pct(base["latency_ms"]["mean"], sc["latency_ms"]["mean"])
        worst_p95 = max(worst_p95, p95_reg)
        worst_mean = max(worst_mean, mean_reg)

        if p95_reg > thresholds["p95"] or mean_reg > thresholds["mean"]:
            failures.append(
                f"  {sc['name']}: p95 +{p95_reg:.1f}% (limit {thresholds['p95']}%), "
                f"mean +{mean_reg:.1f}% (limit {thresholds['mean']}%)"
            )

    summary = f"worst p95 regression {worst_p95:.1f}%, worst mean regression {worst_mean:.1f}%"
    if failures:
        summary += "\nfailed scenarios:\n" + "\n".join(failures)
        return False, summary
    return True, summary


def regression_pct(baseline_val, current_val):
    if baseline_val <= 0:
        return 0.0
    floor = max(baseline_val, 5.0)  # ignore sub-5ms noise
    return max(0.0, (current_val - baseline_val) / floor * 100)


# ── Main ─────────────────────────────────────────────────────────────────────

async def run_benchmarks(port, scenario_names, iterations):
    ws = await ws_connect(port)
    results = []
    for name in scenario_names:
        fn = SCENARIOS[name]
        result = await fn(ws, iterations)
        results.append(result)
        print(
            f"  {result['name']:20s}  "
            f"p50={result['latency_ms']['p50']:8.3f}ms  "
            f"p95={result['latency_ms']['p95']:8.3f}ms  "
            f"mean={result['latency_ms']['mean']:8.3f}ms",
            file=sys.stderr,
        )
    await ws.close()
    return results


def main():
    parser = argparse.ArgumentParser(description="Tron server benchmark")
    parser.add_argument("--scenario", default="all", help="Scenario to run (default: all)")
    parser.add_argument("--iterations", type=int, default=100, help="Iterations per scenario")
    parser.add_argument("--output", help="Write JSON report to file")
    parser.add_argument("--baseline", help="Baseline JSON for comparison")
    parser.add_argument("--enforce-gates", action="store_true", help="Fail on regression")
    parser.add_argument(
        "--max-p95-regression-pct", type=float, default=15.0, help="P95 regression limit"
    )
    parser.add_argument(
        "--max-mean-regression-pct", type=float, default=35.0, help="Mean regression limit"
    )
    parser.add_argument("--port", type=int, default=BENCH_PORT, help="Server port")
    parser.add_argument("--external", action="store_true", help="Connect to existing server")
    args = parser.parse_args()

    scenario_names = resolve_scenario_names(args.scenario)
    binary = None
    proc = None
    tmpdir = None

    try:
        if not args.external:
            binary = find_binary()
            # DB path policy restricts to $HOME/.tron/database/tron.db.
            # Use a temp HOME to isolate from production data.
            tmpdir = tempfile.mkdtemp(prefix="tron-bench-")
            fake_home = tmpdir
            db_dir = os.path.join(fake_home, ".tron", "database")
            os.makedirs(db_dir, exist_ok=True)
            db_path = os.path.join(db_dir, "tron.db")

            print(f"Booting server on port {args.port}...", file=sys.stderr)
            proc = boot_server(binary, db_path, args.port, home_dir=fake_home)

            if not wait_for_server(args.port):
                stderr_out = ""
                if proc.poll() is not None:
                    stderr_out = proc.stderr.read().decode() if proc.stderr else ""
                print(f"Server failed to start within 15s\n{stderr_out}", file=sys.stderr)
                sys.exit(1)
            print("Server ready.", file=sys.stderr)

        print(f"Running {len(scenario_names)} scenarios ({args.iterations} iterations each)...", file=sys.stderr)
        results = asyncio.run(run_benchmarks(args.port, scenario_names, args.iterations))

        report = {
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "environment": current_environment(),
            "config": {
                "requested_scenario": args.scenario,
                "iterations": args.iterations,
            },
            "scenarios": results,
        }

        encoded = json.dumps(report, indent=2)

        if args.output:
            os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
            with open(args.output, "w") as f:
                f.write(encoded)
            print(f"Report: {args.output}", file=sys.stderr)
        else:
            print(encoded)

        if args.baseline:
            with open(args.baseline) as f:
                baseline = json.load(f)
            thresholds = {
                "p95": args.max_p95_regression_pct,
                "mean": args.max_mean_regression_pct,
            }
            passed, summary = compare_reports(baseline, report, thresholds)
            print(f"\nGate: {'PASSED' if passed else 'FAILED'} — {summary}", file=sys.stderr)
            if args.enforce_gates and not passed:
                sys.exit(1)

    finally:
        if proc is not None:
            kill_server(proc)
        if tmpdir is not None:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
