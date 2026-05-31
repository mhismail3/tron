#!/usr/bin/env python3
"""Live agent harness for RWO-N15 queue/trigger/stream evidence."""

import argparse
import datetime as dt
import json
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rwo_n16_live_agent_harness as n16

ROOT = n16.ROOT
DB_PATH = n16.DB_PATH
HEALTH = n16.HEALTH
DEFAULT_SIM_UDID = "267F6468-09AE-471D-9157-29144173EB82"
HARNESS_PREFIX = "rwo-n15-agent-"
TERMINAL_QUEUE_STATUSES = ("completed", "cancelled", "dead_lettered")


def db_json(query, params=()):
    with sqlite3.connect(DB_PATH, timeout=10) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, params)]


def create_session(ws, stamp, model):
    response = n16.invoke(
        ws,
        "session::create",
        {
            "workingDirectory": str(ROOT),
            "model": model,
            "title": f"RWO-N15 queue trigger stream {stamp}",
            "useWorktree": False,
        },
        "create-rwo-n15",
        f"rwo-n15-session-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {"scenario": "RWO-N15", "harness": "agent-live"},
        },
        timeout=60,
    )
    value, child = n16.child_value(response)
    return value["sessionId"], child


def start_fixture(fixture):
    stdout = open(fixture["stdout"], "a", encoding="utf-8")
    cmd = [
        sys.executable,
        str(ROOT / "packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py"),
        "--session-id",
        fixture["sessionId"],
        "--worker-id",
        fixture["workerId"],
        "--function-id",
        fixture["functionId"],
        "--trigger-id",
        fixture["triggerId"],
        "--stream-topic",
        fixture["streamTopic"],
        "--log",
        fixture["log"],
        "--failure-mode",
        "none",
        "--heartbeat-interval-ms",
        "1000",
    ]
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=stdout, stderr=subprocess.STDOUT, text=True)
    return proc, stdout, cmd


def exact_prompt(fixture):
    stamp = fixture["stamp"]
    session_id = fixture["sessionId"]
    worker_args = {
        "subscriptionId": fixture["workerSubscriptionId"],
        "topic": fixture["streamTopic"],
        "sessionId": session_id,
        "afterCursor": 0,
        "visibility": "session",
    }
    queue_args = {
        "subscriptionId": fixture["queueSubscriptionId"],
        "topic": "queue.lifecycle",
        "sessionId": session_id,
        "afterCursor": 0,
        "visibility": "session",
    }
    dispatch_args = {
        "triggerId": fixture["triggerId"],
        "deliveryMode": "enqueue",
        "targetIdempotencyKey": f"rwo-n15-target-{stamp}",
        "payload": {
            "scenario": "RWO-N15",
            "message": "queued trigger stream evidence",
            "nonce": stamp,
        },
    }
    resource_args = {
        "kind": "evidence",
        "scope": "session",
        "sessionId": session_id,
        "resourceId": fixture["resourceId"],
        "payload": {
            "scenario": "RWO-N15",
            "sessionId": session_id,
            "workerId": fixture["workerId"],
            "functionId": fixture["functionId"],
            "triggerId": fixture["triggerId"],
            "streamTopic": fixture["streamTopic"],
            "receiptId": "<receiptId from trigger::dispatch>",
            "summary": f"RWO-N15 queue trigger stream evidence {stamp}",
        },
    }
    return f"""Use only execute. RWO-N15 live worker queue/trigger/stream test. Do not use shell, process, filesystem, web, browser, or non-execute tools.

Make exactly these target invocations through execute in order, then report every id and observed state.

1. execute target stream::subscribe, operation run, idempotencyKey rwo-n15-worker-sub-{stamp}, arguments {json.dumps(worker_args, separators=(",", ":"))}.
2. execute target stream::subscribe, operation run, idempotencyKey rwo-n15-queue-sub-{stamp}, arguments {json.dumps(queue_args, separators=(",", ":"))}.
3. execute target trigger::dispatch, operation run, idempotencyKey rwo-n15-trigger-dispatch-{stamp}, arguments {json.dumps(dispatch_args, separators=(",", ":"))}. Capture receiptId.
4. execute target queue::get, operation run, idempotencyKey rwo-n15-queue-get-{stamp}, arguments {{"receiptId":"<receiptId from step 3>"}}. If the status is not completed yet, call queue::get one more time with idempotencyKey rwo-n15-queue-get-retry-{stamp} and the same receiptId.
5. execute target stream::poll, operation run, idempotencyKey rwo-n15-worker-poll-{stamp}, arguments {{"subscriptionId":"{fixture["workerSubscriptionId"]}","afterCursor":0,"limit":25}}. Confirm a worker event has payload.result.rwoN15Fixture=true.
6. execute target stream::poll, operation run, idempotencyKey rwo-n15-queue-poll-{stamp}, arguments {{"subscriptionId":"{fixture["queueSubscriptionId"]}","afterCursor":0,"limit":50}}. Confirm queue.enqueue, queue.claim, and queue.complete for the same receipt.
7. execute target resource::create, operation run, idempotencyKey rwo-n15-resource-create-{stamp}, arguments {json.dumps(resource_args, separators=(",", ":"))}.
8. execute target worker::health, operation run, idempotencyKey rwo-n15-worker-health-{stamp}, arguments {{"workerId":"{fixture["workerId"]}"}}.
9. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n15-worker-unsubscribe-{stamp}, arguments {{"subscriptionId":"{fixture["workerSubscriptionId"]}"}}.
10. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n15-queue-unsubscribe-{stamp}, arguments {{"subscriptionId":"{fixture["queueSubscriptionId"]}"}}.

Final answer requirements: report each execute invocation id, child target invocation id if visible, trigger receiptId, queue final status and attempts, queue lifecycle evidence, worker stream evidence, evidence resource id/version if visible, worker health, and whether any approval was required. Do not invent missing ids; say not visible if an id is not visible."""


def send_prompt(ws, fixture):
    prompt = exact_prompt(fixture)
    before_sequence = n16.db_scalar(
        "SELECT coalesce(max(sequence), -1) FROM events WHERE session_id = ?",
        (fixture["sessionId"],),
    )
    response = n16.invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": fixture["sessionId"],
            "prompt": prompt,
            "source": f"ios-simulator-rwo-n15-{fixture['stamp']}",
        },
        "prompt-rwo-n15",
        f"rwo-n15-agent-prompt-{fixture['stamp']}",
        {
            "sessionId": fixture["sessionId"],
            "authorityScopes": ["session.write", "session.read", "agent.read", "agent.write"],
            "runtimeMetadata": {"scenario": "RWO-N15", "harness": "agent-live"},
        },
        timeout=60,
    )
    value, child = n16.child_value(response)
    return prompt, before_sequence, value, child


def wait_catalog_unregistered(session_id, worker_id, function_id, trigger_id, timeout=30):
    expected = {
        worker_id: '"WorkerUnregistered"',
        function_id: '"FunctionUnregistered"',
        trigger_id: '"TriggerUnregistered"',
    }
    deadline = time.monotonic() + timeout
    latest_rows = []
    while time.monotonic() < deadline:
        rows = db_json(
            """
            SELECT after_revision, subject_id, kind_json, owner_worker_id, timestamp
            FROM engine_catalog_changes
            WHERE session_id = ? AND subject_id IN (?, ?, ?)
            ORDER BY after_revision
            """,
            (session_id, worker_id, function_id, trigger_id),
        )
        latest_rows = rows
        latest_by_subject = {}
        for row in rows:
            latest_by_subject[row["subject_id"]] = row["kind_json"]
        if all(latest_by_subject.get(subject_id) == kind for subject_id, kind in expected.items()):
            return rows
        time.sleep(0.25)
    raise TimeoutError(f"worker unregistration not visible; last={latest_rows}")


def stream_payload(row):
    try:
        return json.loads(row["payload_preview"] or "{}")
    except json.JSONDecodeError:
        return {}


def collect(fixture, start_cursor, start_ts):
    session_id = fixture["sessionId"]
    invocations = db_json(
        """
        SELECT invocation_id, function_id, worker_id, parent_invocation_id, trace_id,
               session_id, idempotency_key, replayed_from, succeeded,
               produced_resource_refs_json, substr(result_json, 1, 6000) AS result_preview,
               substr(error_json, 1, 3000) AS error_preview, timestamp
        FROM engine_invocations
        WHERE session_id = ?
        ORDER BY timestamp
        """,
        (session_id,),
    )
    queues = db_json(
        """
        SELECT receipt_id, queue, function_id, status, attempts, lease_owner,
               lease_expires_at, trace_id, parent_invocation_id, trigger_id,
               idempotency_key, created_at, updated_at
        FROM engine_queue_items
        WHERE session_id = ?
        ORDER BY created_at
        """,
        (session_id,),
    )
    streams = db_json(
        """
        SELECT cursor, topic, visibility, session_id, producer, trace_id,
               parent_invocation_id, created_at, substr(payload_json, 1, 4000) AS payload_preview
        FROM engine_stream_events
        WHERE cursor > ?
          AND (session_id = ? OR topic IN (?, 'queue.lifecycle', 'worker.lifecycle'))
        ORDER BY cursor
        """,
        (start_cursor, session_id, fixture["streamTopic"]),
    )
    events = db_json(
        """
        SELECT sequence, type, timestamp, model, provider_type, stop_reason,
               model_primitive_name, invocation_id, substr(payload, 1, 4000) AS payload_preview
        FROM events
        WHERE session_id = ?
        ORDER BY sequence
        """,
        (session_id,),
    )
    approvals = db_json(
        """
        SELECT approval_id, function_id, status, trace_id, parent_invocation_id,
               idempotency_key, decision_actor_id, decided_at, created_at, updated_at
        FROM engine_approvals
        WHERE session_id = ?
        ORDER BY created_at
        """,
        (session_id,),
    )
    resources = db_json(
        """
        SELECT resource_id, kind, scope_kind, scope_value, lifecycle,
               current_version_id, created_by_invocation_id, trace_id, created_at, updated_at
        FROM engine_resources
        WHERE scope_value = ? OR resource_id = ?
        ORDER BY created_at
        """,
        (session_id, fixture["resourceId"]),
    )
    versions = db_json(
        """
        SELECT version_id, resource_id, parent_version_id, content_hash,
               version_state, created_by_invocation_id, trace_id, created_at,
               substr(payload_json, 1, 3000) AS payload_preview
        FROM engine_resource_versions
        WHERE resource_id IN (
            SELECT resource_id
            FROM engine_resources
            WHERE scope_value = ? OR resource_id = ?
        )
        ORDER BY created_at
        """,
        (session_id, fixture["resourceId"]),
    )
    leases = db_json(
        """
        SELECT lease_id, resource_id, holder_invocation_id, function_id, status,
               acquired_at, expires_at, released_at
        FROM engine_resource_leases
        WHERE holder_invocation_id IN (
            SELECT invocation_id FROM engine_invocations WHERE session_id = ?
        )
        ORDER BY acquired_at
        """,
        (session_id,),
    )
    subscriptions = db_json(
        """
        SELECT subscription_id, topic, cursor, visibility, session_id, workspace_id,
               active, created_at
        FROM engine_stream_subscriptions
        WHERE session_id = ?
        ORDER BY created_at
        """,
        (session_id,),
    )
    catalog_changes = db_json(
        """
        SELECT after_revision, subject_kind_json, subject_id, owner_worker_id,
               kind_json, session_id, workspace_id, timestamp
        FROM engine_catalog_changes
        WHERE session_id = ?
        ORDER BY after_revision
        """,
        (session_id,),
    )
    logs = db_json(
        """
        SELECT timestamp, level, component, message, session_id, trace_id,
               substr(data, 1, 2500) AS data_preview, error_message
        FROM logs
        WHERE timestamp >= ?
          AND (session_id = ?
               OR trace_id IN (SELECT trace_id FROM engine_invocations WHERE session_id = ?))
        ORDER BY timestamp
        """,
        (start_ts, session_id, session_id),
    )

    target_queues = [row for row in queues if row["function_id"] == fixture["functionId"]]
    target_queue = target_queues[0] if target_queues else None
    receipt_id = target_queue["receipt_id"] if target_queue else None
    payloads = [(row, stream_payload(row)) for row in streams]

    def queue_events(event_type):
        if not receipt_id:
            return []
        return [
            row
            for row, payload in payloads
            if payload.get("receiptId") == receipt_id and payload.get("type") == event_type
        ]

    latest_catalog = {}
    for row in catalog_changes:
        latest_catalog[row["subject_id"]] = row["kind_json"]
    failed = [row for row in invocations if row["succeeded"] == 0]
    compact_events = [row for row in events if row["type"].startswith("compact.")]
    open_queues = [row for row in queues if row["status"] not in TERMINAL_QUEUE_STATUSES]
    active_harness_subscriptions = [
        row
        for row in subscriptions
        if row["active"] and row["subscription_id"].startswith(HARNESS_PREFIX)
    ]
    active_leases = [row for row in leases if row["status"] == "active"]
    error_logs = [
        row for row in logs if str(row["level"]).lower() in {"error", "fatal"}
    ]
    worker_events = [row for row in streams if row["topic"] == fixture["streamTopic"]]
    resource_ids = {row["resource_id"] for row in resources}
    summary = {
        "targetQueue": target_queue,
        "queueEnqueueEventCount": len(queue_events("queue.enqueue")),
        "queueClaimEventCount": len(queue_events("queue.claim")),
        "queueCompleteEventCount": len(queue_events("queue.complete")),
        "workerEventCount": len(worker_events),
        "resourcePresent": fixture["resourceId"] in resource_ids,
        "workerUnregistered": latest_catalog.get(fixture["workerId"]) == '"WorkerUnregistered"',
        "functionUnregistered": latest_catalog.get(fixture["functionId"]) == '"FunctionUnregistered"',
        "triggerUnregistered": latest_catalog.get(fixture["triggerId"]) == '"TriggerUnregistered"',
        "failedInvocationCount": len(failed),
        "failedInvocations": failed,
        "approvalCount": len(approvals),
        "pendingApprovals": [row for row in approvals if row["status"] == "pending"],
        "compactEventCount": len(compact_events),
        "openQueueRows": open_queues,
        "activeHarnessSubscriptionCount": len(active_harness_subscriptions),
        "activeResourceLeaseCount": len(active_leases),
        "errorLogCount": len(error_logs),
        "resourceId": fixture["resourceId"],
    }
    summary["passed"] = (
        target_queue is not None
        and target_queue["status"] == "completed"
        and target_queue["attempts"] == 0
        and target_queue["lease_owner"] is None
        and target_queue["lease_expires_at"] is None
        and summary["queueEnqueueEventCount"] >= 1
        and summary["queueClaimEventCount"] >= 1
        and summary["queueCompleteEventCount"] >= 1
        and summary["workerEventCount"] >= 1
        and summary["resourcePresent"]
        and summary["workerUnregistered"]
        and summary["functionUnregistered"]
        and summary["triggerUnregistered"]
        and summary["failedInvocationCount"] == 0
        and summary["approvalCount"] == 0
        and summary["compactEventCount"] == 0
        and len(open_queues) == 0
        and len(active_harness_subscriptions) == 0
        and len(active_leases) == 0
        and summary["errorLogCount"] == 0
    )
    return {
        "invocations": invocations,
        "queues": queues,
        "streams": streams,
        "events": events,
        "approvals": approvals,
        "resources": resources,
        "resourceVersions": versions,
        "resourceLeases": leases,
        "streamSubscriptions": subscriptions,
        "catalogChanges": catalog_changes,
        "logs": logs,
        "summary": summary,
    }


def run_harness(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    namespace = f"rwo_n15_agent_{stamp}"
    run_log = f"/tmp/rwo_n15_agent_run_{stamp}.json"
    fixture = {
        "stamp": stamp,
        "workerId": f"rwo-n15-agent-worker-{stamp}",
        "functionId": f"{namespace}::queued_echo",
        "triggerId": f"manual:{namespace}.queued_echo",
        "streamTopic": f"{namespace}.worker.events",
        "workerSubscriptionId": f"rwo-n15-agent-worker-sub-{stamp}",
        "queueSubscriptionId": f"rwo-n15-agent-queue-sub-{stamp}",
        "resourceId": f"evidence:rwo-n15-agent:{stamp}",
        "log": f"/tmp/rwo_n15_agent_worker_fixture_{stamp}.jsonl",
        "stdout": f"/tmp/rwo_n15_agent_worker_fixture_{stamp}.stdout.log",
        "screenshot": f"/tmp/rwo_n15_{stamp}_iphone.png",
        "sessionId": None,
    }
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "fixture": fixture,
        "serverHealthBefore": n16.run_cmd(["curl", "-fsS", HEALTH], timeout=10),
        "startCursor": n16.db_scalar("SELECT coalesce(max(cursor), 0) FROM engine_stream_events"),
        "startTimestamp": dt.datetime.now(dt.UTC).isoformat(),
    }
    ws = None
    fixture_proc = None
    fixture_stdout = None
    error = None
    try:
        ws, hello = n16.ws_hello("rwo-n15-hello")
        result["hello"] = hello
        session_id, create_child = create_session(ws, stamp, args.model)
        fixture["sessionId"] = session_id
        result["sessionId"] = session_id
        result["createChild"] = create_child
        fixture_proc, fixture_stdout, fixture_cmd = start_fixture(fixture)
        result["fixtureCommand"] = fixture_cmd
        result["registration"] = n16.wait_registration(
            session_id,
            fixture["workerId"],
            fixture["functionId"],
            fixture["triggerId"],
            timeout=30,
        )
        prompt, before_sequence, prompt_value, prompt_child = send_prompt(ws, fixture)
        result["prompt"] = prompt
        result["prePromptSequence"] = before_sequence
        result["promptValue"] = prompt_value
        result["promptChild"] = prompt_child
        result["terminalEvent"] = n16.wait_end_turn(session_id, args.timeout_seconds)
    except Exception as exc:
        error = repr(exc)
        result["error"] = error
    finally:
        n16.stop_fixture(fixture_proc, fixture_stdout)
        if fixture.get("sessionId"):
            try:
                result["unregistration"] = wait_catalog_unregistered(
                    fixture["sessionId"],
                    fixture["workerId"],
                    fixture["functionId"],
                    fixture["triggerId"],
                    timeout=30,
                )
            except Exception as exc:
                result["unregistrationError"] = repr(exc)
        if ws is not None:
            ws.close()

    if fixture.get("sessionId"):
        session_id = fixture["sessionId"]
        result["terminalGuard"] = n16.run_terminal_guard(
            session_id,
            min(args.timeout_seconds, 180),
        )
        result["simulatorOpen"] = n16.run_cmd(
            ["xcrun", "simctl", "openurl", args.sim_udid, f"tron://session/{session_id}"],
            timeout=30,
        )
        time.sleep(args.screenshot_delay_seconds)
        result["simulatorScreenshot"] = {
            "path": fixture["screenshot"],
            "result": n16.run_cmd(
                ["xcrun", "simctl", "io", args.sim_udid, "screenshot", fixture["screenshot"]],
                timeout=30,
            ),
        }
        result["serverHealthAfter"] = n16.run_cmd(["curl", "-fsS", HEALTH], timeout=10)
        result["db"] = collect(fixture, result["startCursor"], result["startTimestamp"])

    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    summary = {
        "runLog": run_log,
        "sessionId": result.get("sessionId"),
        "fixtureLog": fixture["log"],
        "screenshot": fixture["screenshot"],
        "terminalGuard": result.get("terminalGuard"),
        "dbSummary": result.get("db", {}).get("summary"),
        "error": error,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    if error:
        return 3
    guard = result.get("terminalGuard") or {}
    if guard.get("returncode") != 0:
        return 2
    if not result.get("db", {}).get("summary", {}).get("passed"):
        return 1
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="claude-sonnet-4-6")
    parser.add_argument("--sim-udid", default=DEFAULT_SIM_UDID)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--screenshot-delay-seconds", type=float, default=2.0)
    return parser.parse_args(argv)


def main(argv):
    return run_harness(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
