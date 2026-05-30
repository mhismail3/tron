#!/usr/bin/env python3
"""Live agent harness for RWO-N16B cancellation and dead-letter evidence."""

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
OLD_SIM_UDID = "267F6468-09AE-471D-9157-29144173EB82"


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
            "title": f"RWO-N16B queue cancellation and dead-letter {stamp}",
            "useWorktree": False,
        },
        "create-rwo-n16b",
        f"rwo-n16b-session-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {"scenario": "RWO-N16B", "harness": "agent-live"},
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
        fixture["failureMode"],
        "--heartbeat-interval-ms",
        "1000",
    ]
    if fixture.get("sleepBeforeResultMs"):
        cmd.extend(["--sleep-before-result-ms", str(fixture["sleepBeforeResultMs"])])
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=stdout, stderr=subprocess.STDOUT, text=True)
    return proc, stdout, cmd


def fixture_definitions(stamp):
    cancel_namespace = f"rwo_n16b_cancel_{stamp}"
    dead_namespace = f"rwo_n16b_dead_{stamp}"
    return {
        "cancel": {
            "kind": "cancel",
            "stamp": stamp,
            "workerId": f"rwo-n16b-cancel-worker-{stamp}",
            "functionId": f"{cancel_namespace}::queued_echo",
            "triggerId": f"manual:{cancel_namespace}.queued_echo",
            "streamTopic": f"{cancel_namespace}.worker.events",
            "failureMode": "none",
            "sleepBeforeResultMs": 10000,
            "workerSubscriptionId": f"rwo-n16b-cancel-worker-sub-{stamp}",
            "log": f"/tmp/rwo_n16b_cancel_worker_fixture_{stamp}.jsonl",
            "stdout": f"/tmp/rwo_n16b_cancel_worker_fixture_{stamp}.stdout.log",
        },
        "dead": {
            "kind": "dead",
            "stamp": stamp,
            "workerId": f"rwo-n16b-dead-worker-{stamp}",
            "functionId": f"{dead_namespace}::queued_echo",
            "triggerId": f"manual:{dead_namespace}.queued_echo",
            "streamTopic": f"{dead_namespace}.worker.events",
            "failureMode": "always-error",
            "sleepBeforeResultMs": 0,
            "workerSubscriptionId": f"rwo-n16b-dead-worker-sub-{stamp}",
            "log": f"/tmp/rwo_n16b_dead_worker_fixture_{stamp}.jsonl",
            "stdout": f"/tmp/rwo_n16b_dead_worker_fixture_{stamp}.stdout.log",
        },
    }


def exact_prompt(fixtures, session_id, stamp):
    cancel = fixtures["cancel"]
    dead = fixtures["dead"]
    queue_sub = f"rwo-n16b-queue-sub-{stamp}"
    resource_id = f"evidence:rwo-n16b-agent:{stamp}"
    cancel_worker_args = {
        "subscriptionId": cancel["workerSubscriptionId"],
        "topic": cancel["streamTopic"],
        "sessionId": session_id,
        "afterCursor": 0,
        "visibility": "session",
    }
    dead_worker_args = {
        "subscriptionId": dead["workerSubscriptionId"],
        "topic": dead["streamTopic"],
        "sessionId": session_id,
        "afterCursor": 0,
        "visibility": "session",
    }
    queue_args = {
        "subscriptionId": queue_sub,
        "topic": "queue.lifecycle",
        "sessionId": session_id,
        "afterCursor": 0,
        "visibility": "session",
    }
    cancel_dispatch = {
        "triggerId": cancel["triggerId"],
        "deliveryMode": "enqueue",
        "targetIdempotencyKey": f"rwo-n16b-cancel-target-{stamp}",
        "payload": {"message": "rwo-n16b cancel claimed item", "nonce": stamp},
    }
    dead_dispatch = {
        "triggerId": dead["triggerId"],
        "deliveryMode": "enqueue",
        "targetIdempotencyKey": f"rwo-n16b-dead-target-{stamp}",
        "payload": {"message": "rwo-n16b dead letter repeated failure", "nonce": stamp},
    }
    resource_args = {
        "kind": "evidence",
        "scope": "session",
        "sessionId": session_id,
        "resourceId": resource_id,
        "payload": {
            "summary": f"RWO-N16B cancellation and terminal dead-letter evidence {stamp}",
            "scenario": "RWO-N16B",
            "sessionId": session_id,
            "cancelWorkerId": cancel["workerId"],
            "deadLetterWorkerId": dead["workerId"],
            "cancelReceiptId": "<cancel receiptId from step 4>",
            "deadLetterReceiptId": "<dead-letter receiptId from step 8>",
            "expectedQueueTruth": [
                "queue.cancel for the cancellation receipt",
                "queue.dead_letter for the repeated failure receipt",
                "no queue.complete for the cancellation receipt",
            ],
        },
    }
    return f"""Use only execute. RWO-N16B queue cancellation and terminal dead-letter test. Do not use shell, process, filesystem, web, browser, or non-execute tools. Make exactly these target invocations through execute in order, then report every id and observed state.

The cancellation worker intentionally sleeps before returning a successful target result. Cancel its queued receipt while it is claimed; the engine must leave the receipt cancelled and must not later complete it. The dead-letter worker intentionally returns an error on every target invocation; the engine must retry until it records terminal dead-letter state.

1. execute target stream::subscribe, operation run, idempotencyKey rwo-n16b-cancel-worker-sub-{stamp}, arguments {json.dumps(cancel_worker_args, separators=(",", ":"))}.
2. execute target stream::subscribe, operation run, idempotencyKey rwo-n16b-dead-worker-sub-{stamp}, arguments {json.dumps(dead_worker_args, separators=(",", ":"))}.
3. execute target stream::subscribe, operation run, idempotencyKey rwo-n16b-queue-sub-{stamp}, arguments {json.dumps(queue_args, separators=(",", ":"))}.
4. execute target trigger::dispatch, operation run, idempotencyKey rwo-n16b-cancel-dispatch-{stamp}, arguments {json.dumps(cancel_dispatch, separators=(",", ":"))}. Capture the cancel receiptId.
5. execute target queue::get, operation run, idempotencyKey rwo-n16b-cancel-get-before-{stamp}, arguments {{"receiptId":"<cancel receiptId from step 4>"}}. If status is ready, call queue::get one more time with idempotencyKey rwo-n16b-cancel-get-before-retry-{stamp}.
6. execute target queue::cancel, operation run, idempotencyKey rwo-n16b-cancel-receipt-{stamp}, arguments {{"receiptId":"<cancel receiptId from step 4>"}}.
7. execute target queue::get, operation run, idempotencyKey rwo-n16b-cancel-get-after-{stamp}, arguments {{"receiptId":"<cancel receiptId from step 4>"}}.
8. execute target trigger::dispatch, operation run, idempotencyKey rwo-n16b-dead-dispatch-{stamp}, arguments {json.dumps(dead_dispatch, separators=(",", ":"))}. Capture the dead-letter receiptId.
9. execute target queue::get, operation run, idempotencyKey rwo-n16b-dead-get-1-{stamp}, arguments {{"receiptId":"<dead-letter receiptId from step 8>"}}.
10. execute target queue::get, operation run, idempotencyKey rwo-n16b-dead-get-2-{stamp}, arguments {{"receiptId":"<dead-letter receiptId from step 8>"}}.
11. execute target queue::get, operation run, idempotencyKey rwo-n16b-dead-get-3-{stamp}, arguments {{"receiptId":"<dead-letter receiptId from step 8>"}}.
12. execute target queue::get, operation run, idempotencyKey rwo-n16b-dead-get-4-{stamp}, arguments {{"receiptId":"<dead-letter receiptId from step 8>"}}.
13. execute target queue::get, operation run, idempotencyKey rwo-n16b-dead-get-5-{stamp}, arguments {{"receiptId":"<dead-letter receiptId from step 8>"}}.
14. execute target stream::poll, operation run, idempotencyKey rwo-n16b-queue-poll-{stamp}, arguments {{"subscriptionId":"{queue_sub}","afterCursor":0,"limit":100}}. Confirm queue.cancel for the cancellation receipt and queue.dead_letter for the repeated failure receipt.
15. execute target stream::poll, operation run, idempotencyKey rwo-n16b-cancel-worker-poll-{stamp}, arguments {{"subscriptionId":"{cancel["workerSubscriptionId"]}","afterCursor":0,"limit":25}}.
16. execute target resource::create, operation run, idempotencyKey rwo-n16b-resource-create-{stamp}, arguments {json.dumps(resource_args, separators=(",", ":"))}.
17. execute target worker::health, operation run, idempotencyKey rwo-n16b-cancel-worker-health-{stamp}, arguments {{"workerId":"{cancel["workerId"]}"}}.
18. execute target worker::health, operation run, idempotencyKey rwo-n16b-dead-worker-health-{stamp}, arguments {{"workerId":"{dead["workerId"]}"}}.
19. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n16b-cancel-worker-unsubscribe-{stamp}, arguments {{"subscriptionId":"{cancel["workerSubscriptionId"]}"}}.
20. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n16b-dead-worker-unsubscribe-{stamp}, arguments {{"subscriptionId":"{dead["workerSubscriptionId"]}"}}.
21. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n16b-queue-unsubscribe-{stamp}, arguments {{"subscriptionId":"{queue_sub}"}}.

Final answer requirements: report each execute invocation id, child target invocation id if visible, both receiptIds, cancellation final status/attempts/lease fields, terminal dead-letter final status/attempts/lease fields, queue.cancel and queue.dead_letter stream evidence, whether any queue.complete appeared for the cancellation receipt, evidence resourceRef/resourceId/versionId if visible, worker health for both workers, and whether any approval was required. Do not invent missing ids; say not visible if an id is not visible."""


def send_prompt(ws, fixtures, session_id, stamp):
    prompt = exact_prompt(fixtures, session_id, stamp)
    before_sequence = n16.db_scalar(
        "SELECT coalesce(max(sequence), -1) FROM events WHERE session_id = ?",
        (session_id,),
    )
    response = n16.invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": session_id,
            "prompt": prompt,
            "source": f"ios-simulator-rwo-n16b-{stamp}",
        },
        "prompt-rwo-n16b",
        f"rwo-n16b-agent-prompt-{stamp}",
        {
            "sessionId": session_id,
            "authorityScopes": ["session.write", "session.read", "agent.read", "agent.write"],
            "runtimeMetadata": {"scenario": "RWO-N16B", "harness": "agent-live"},
        },
        timeout=60,
    )
    value, child = n16.child_value(response)
    return prompt, before_sequence, value, child


def stream_payload(row):
    try:
        return json.loads(row["payload_preview"] or "{}")
    except json.JSONDecodeError:
        return {}


def collect(fixtures, session_id, start_cursor, start_ts, resource_id):
    function_ids = [fixture["functionId"] for fixture in fixtures.values()]
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
          AND (session_id = ? OR topic IN ('queue.lifecycle', 'worker.lifecycle'))
        ORDER BY cursor
        """,
        (start_cursor, session_id),
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
        (session_id, resource_id),
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
        (session_id, resource_id),
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
    grants = db_json(
        """
        SELECT grant_id, parent_grant_id, subject_actor_id, subject_worker_id,
               subject_invocation_id, lifecycle, trace_id, created_at, updated_at
        FROM engine_grants
        WHERE trace_id IN (
            SELECT trace_id FROM engine_invocations WHERE session_id = ?
        )
           OR subject_invocation_id IN (
            SELECT invocation_id FROM engine_invocations WHERE session_id = ?
        )
        ORDER BY created_at
        """,
        (session_id, session_id),
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
    queue_by_function = {row["function_id"]: row for row in queues if row["function_id"] in function_ids}
    cancel_queue = queue_by_function.get(fixtures["cancel"]["functionId"])
    dead_queue = queue_by_function.get(fixtures["dead"]["functionId"])
    cancel_receipt = cancel_queue["receipt_id"] if cancel_queue else None
    dead_receipt = dead_queue["receipt_id"] if dead_queue else None
    payloads = [(row, stream_payload(row)) for row in streams]

    def queue_events(receipt, event_type):
        if not receipt:
            return []
        return [
            row
            for row, payload in payloads
            if payload.get("receiptId") == receipt and payload.get("type") == event_type
        ]

    failed = [row for row in invocations if row["succeeded"] == 0]
    dead_function = fixtures["dead"]["functionId"]
    expected_dead_failures = [row for row in failed if row["function_id"] == dead_function]
    unexpected_failures = [row for row in failed if row["function_id"] != dead_function]
    compact_events = [row for row in events if row["type"].startswith("compact.")]
    open_queues = [row for row in queues if row["status"] in ("ready", "leased")]
    active_harness_subscriptions = [
        row
        for row in subscriptions
        if row["active"] and row["subscription_id"].startswith("rwo-n16b-")
    ]
    active_client_subscriptions = [
        row
        for row in subscriptions
        if row["active"] and not row["subscription_id"].startswith("rwo-n16b-")
    ]
    active_leases = [row for row in leases if row["status"] == "active"]

    summary = {
        "cancelQueue": cancel_queue,
        "deadLetterQueue": dead_queue,
        "cancelEventCount": len(queue_events(cancel_receipt, "queue.cancel")),
        "cancelCompleteEventCount": len(queue_events(cancel_receipt, "queue.complete")),
        "deadLetterEventCount": len(queue_events(dead_receipt, "queue.dead_letter")),
        "deadFailEventCount": len(queue_events(dead_receipt, "queue.fail")),
        "failedInvocationCount": len(failed),
        "expectedDeadLetterFailureCount": len(expected_dead_failures),
        "unexpectedFailedInvocationCount": len(unexpected_failures),
        "unexpectedFailedInvocations": unexpected_failures,
        "approvalCount": len(approvals),
        "pendingApprovals": [row for row in approvals if row["status"] == "pending"],
        "compactEventCount": len(compact_events),
        "openQueueRows": open_queues,
        "activeHarnessSubscriptionCount": len(active_harness_subscriptions),
        "activeClientSubscriptionCount": len(active_client_subscriptions),
        "activeClientSubscriptions": active_client_subscriptions,
        "activeResourceLeaseCount": len(active_leases),
        "resourceId": resource_id,
    }
    summary["passed"] = (
        cancel_queue is not None
        and cancel_queue["status"] == "cancelled"
        and cancel_queue["lease_owner"] is None
        and cancel_queue["lease_expires_at"] is None
        and dead_queue is not None
        and dead_queue["status"] == "dead_lettered"
        and dead_queue["attempts"] >= 3
        and dead_queue["lease_owner"] is None
        and dead_queue["lease_expires_at"] is None
        and summary["cancelEventCount"] >= 1
        and summary["cancelCompleteEventCount"] == 0
        and summary["deadLetterEventCount"] >= 1
        and summary["expectedDeadLetterFailureCount"] >= 3
        and summary["unexpectedFailedInvocationCount"] == 0
        and summary["approvalCount"] == 0
        and summary["compactEventCount"] == 0
        and len(open_queues) == 0
        and len(active_harness_subscriptions) == 0
        and len(active_leases) == 0
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
        "grants": grants,
        "catalogChanges": catalog_changes,
        "logs": logs,
        "summary": summary,
    }


def run_harness(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    run_log = f"/tmp/rwo_n16b_agent_run_{stamp}.json"
    screenshot = f"/tmp/rwo_n16b_{stamp}_old_simulator.png"
    fixtures = fixture_definitions(stamp)
    resource_id = f"evidence:rwo-n16b-agent:{stamp}"
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "fixtures": fixtures,
        "resourceId": resource_id,
        "screenshot": screenshot,
        "serverHealthBefore": n16.run_cmd(["curl", "-fsS", HEALTH], timeout=10),
        "startCursor": n16.db_scalar("SELECT coalesce(max(cursor), 0) FROM engine_stream_events"),
        "startTimestamp": dt.datetime.now(dt.UTC).isoformat(),
    }
    ws = None
    processes = []
    error = None
    try:
        ws, hello = n16.ws_hello("rwo-n16b-hello")
        result["hello"] = hello
        session_id, create_child = create_session(ws, stamp, args.model)
        result["sessionId"] = session_id
        result["createChild"] = create_child
        for fixture in fixtures.values():
            fixture["sessionId"] = session_id
            proc, stdout, cmd = start_fixture(fixture)
            processes.append((proc, stdout))
            fixture["command"] = cmd
            result.setdefault("fixtureCommands", []).append(cmd)
        for fixture in fixtures.values():
            result.setdefault("registration", {})[fixture["kind"]] = n16.wait_registration(
                session_id,
                fixture["workerId"],
                fixture["functionId"],
                fixture["triggerId"],
                timeout=30,
            )
        prompt, before_sequence, prompt_value, prompt_child = send_prompt(
            ws,
            fixtures,
            session_id,
            stamp,
        )
        result["prompt"] = prompt
        result["beforeSequence"] = before_sequence
        result["promptValue"] = prompt_value
        result["promptChild"] = prompt_child
        result["terminalEvent"] = n16.wait_end_turn(session_id, args.timeout_seconds)
        time.sleep(args.post_terminal_worker_wait_seconds)
    except Exception as exc:
        error = repr(exc)
        result["error"] = error
    finally:
        for proc, stdout in processes:
            n16.stop_fixture(proc, stdout)
        if ws is not None:
            ws.close()
    if result.get("sessionId"):
        session_id = result["sessionId"]
        result["terminalGuard"] = n16.run_terminal_guard(
            session_id,
            min(args.timeout_seconds, 180),
        )
        result["simulatorBoot"] = n16.run_cmd(
            ["xcrun", "simctl", "boot", args.sim_udid],
            timeout=30,
        )
        result["simulatorBootstatus"] = n16.run_cmd(
            ["xcrun", "simctl", "bootstatus", args.sim_udid, "-b"],
            timeout=120,
        )
        result["simulatorOpen"] = n16.run_cmd(
            ["xcrun", "simctl", "openurl", args.sim_udid, f"tron://session/{session_id}"],
            timeout=30,
        )
        time.sleep(args.screenshot_delay_seconds)
        result["simulatorScreenshot"] = {
            "path": screenshot,
            "result": n16.run_cmd(
                ["xcrun", "simctl", "io", args.sim_udid, "screenshot", screenshot],
                timeout=30,
            ),
        }
        result["serverHealthAfter"] = n16.run_cmd(["curl", "-fsS", HEALTH], timeout=10)
        result["db"] = collect(
            fixtures,
            session_id,
            result["startCursor"],
            result["startTimestamp"],
            resource_id,
        )
    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    summary = {
        "runLog": run_log,
        "sessionId": result.get("sessionId"),
        "cancelFixtureLog": fixtures["cancel"]["log"],
        "deadFixtureLog": fixtures["dead"]["log"],
        "screenshot": screenshot,
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
    parser.add_argument("--model", default="claude-sonnet-4-20250514")
    parser.add_argument("--sim-udid", default=OLD_SIM_UDID)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--post-terminal-worker-wait-seconds", type=float, default=4.0)
    parser.add_argument("--screenshot-delay-seconds", type=float, default=2.0)
    return parser.parse_args(argv)


def main(argv):
    return run_harness(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
