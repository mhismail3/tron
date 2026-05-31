#!/usr/bin/env python3
"""Live multi-session harness for RWO-N17 isolation and ownership evidence."""

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
DEFAULT_SIM_UDID = "267F6468-09AE-471D-9157-29144173EB82"
TERMINAL_QUEUE_STATUSES = ("completed", "cancelled", "dead_lettered")
HARNESS_PREFIX = "rwo-n17-"
BENIGN_POST_TURN_FUNCTIONS = {
    "memory::auto_retain_fire",
    "notifications::mark_all_read",
    "prompt_library::history_record",
    "session::resume",
    "skills::refresh",
}


def db_json(query, params=()):
    with sqlite3.connect(n16.DB_PATH, timeout=10) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, params)]


def create_session(ws, stamp, model, role):
    response = n16.invoke(
        ws,
        "session::create",
        {
            "workingDirectory": str(ROOT),
            "model": model,
            "title": f"RWO-N17 {role} multi-session churn {stamp}",
            "useWorktree": False,
        },
        f"create-rwo-n17-{role}",
        f"rwo-n17-{role}-session-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {
                "scenario": "RWO-N17",
                "harness": "multi-session",
                "role": role,
            },
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
        "--endpoint",
        n16.worker_endpoint(),
        "--auth-path",
        n16.AUTH_PATH,
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


def visible_prompt(session_id, stamp, resource_id):
    resource_args = {
        "kind": "evidence",
        "scope": "session",
        "sessionId": session_id,
        "resourceId": resource_id,
        "payload": {
            "scenario": "RWO-N17",
            "role": "visible",
            "sessionId": session_id,
            "stamp": stamp,
            "summary": f"RWO-N17 simulator-visible session marker {stamp}",
        },
    }
    return f"""Use only execute. RWO-N17 visible session marker {stamp}.

1. execute target resource::create, operation run, idempotencyKey rwo-n17-visible-resource-{stamp}, arguments {json.dumps(resource_args, separators=(",", ":"))}.

Final answer requirements: say exactly "RWO-N17 visible terminal marker {stamp}" and include the evidence resource id {resource_id}. Do not call any other target."""


def background_prompt(fixture, stamp):
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
        "targetIdempotencyKey": f"rwo-n17-background-target-{stamp}",
        "payload": {
            "scenario": "RWO-N17",
            "role": "background",
            "message": "multi-session background worker isolation",
            "nonce": stamp,
        },
    }
    resource_args = {
        "kind": "evidence",
        "scope": "session",
        "sessionId": session_id,
        "resourceId": fixture["resourceId"],
        "payload": {
            "scenario": "RWO-N17",
            "role": "background",
            "sessionId": session_id,
            "workerId": fixture["workerId"],
            "functionId": fixture["functionId"],
            "triggerId": fixture["triggerId"],
            "streamTopic": fixture["streamTopic"],
            "receiptId": "<receiptId from trigger::dispatch>",
            "summary": f"RWO-N17 background queue/stream/resource evidence {stamp}",
        },
    }
    return f"""Use only execute. RWO-N17 background session churn {stamp}. Do not use shell, process, filesystem, web, browser, or non-execute tools.

1. execute target stream::subscribe, operation run, idempotencyKey rwo-n17-background-worker-sub-{stamp}, arguments {json.dumps(worker_args, separators=(",", ":"))}.
2. execute target stream::subscribe, operation run, idempotencyKey rwo-n17-background-queue-sub-{stamp}, arguments {json.dumps(queue_args, separators=(",", ":"))}.
3. execute target trigger::dispatch, operation run, idempotencyKey rwo-n17-background-dispatch-{stamp}, arguments {json.dumps(dispatch_args, separators=(",", ":"))}. Capture receiptId.
4. execute target queue::get, operation run, idempotencyKey rwo-n17-background-queue-get-{stamp}, arguments {{"receiptId":"<receiptId from step 3>"}}. If status is not completed, call queue::get one more time with idempotencyKey rwo-n17-background-queue-get-retry-{stamp}.
5. execute target stream::poll, operation run, idempotencyKey rwo-n17-background-worker-poll-{stamp}, arguments {{"subscriptionId":"{fixture["workerSubscriptionId"]}","afterCursor":0,"limit":25}}.
6. execute target stream::poll, operation run, idempotencyKey rwo-n17-background-queue-poll-{stamp}, arguments {{"subscriptionId":"{fixture["queueSubscriptionId"]}","afterCursor":0,"limit":50}}.
7. execute target resource::create, operation run, idempotencyKey rwo-n17-background-resource-{stamp}, arguments {json.dumps(resource_args, separators=(",", ":"))}.
8. execute target worker::health, operation run, idempotencyKey rwo-n17-background-worker-health-{stamp}, arguments {{"workerId":"{fixture["workerId"]}"}}.
9. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n17-background-worker-unsubscribe-{stamp}, arguments {{"subscriptionId":"{fixture["workerSubscriptionId"]}"}}.
10. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n17-background-queue-unsubscribe-{stamp}, arguments {{"subscriptionId":"{fixture["queueSubscriptionId"]}"}}.

Final answer requirements: report every execute invocation id and child id if visible, the receiptId, final queue status/attempts, queue.complete evidence, worker stream evidence, evidence resource id/version if visible, worker health, and whether any approval was required. Do not invent missing ids."""


def send_prompt(ws, session_id, prompt, stamp, role):
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
            "source": f"ios-simulator-rwo-n17-{role}-{stamp}",
        },
        f"prompt-rwo-n17-{role}",
        f"rwo-n17-{role}-agent-prompt-{stamp}",
        {
            "sessionId": session_id,
            "authorityScopes": ["session.write", "session.read", "agent.read", "agent.write"],
            "runtimeMetadata": {
                "scenario": "RWO-N17",
                "harness": "multi-session",
                "role": role,
            },
        },
        timeout=60,
    )
    value, child = n16.child_value(response)
    return before_sequence, value, child


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


def run_terminal_guard(session_id, timeout_seconds):
    return n16.run_terminal_guard(session_id, timeout_seconds)


def safe_run_cmd(argv, timeout=60):
    try:
        return n16.run_cmd(argv, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        return {
            "argv": argv,
            "returncode": -1,
            "started": None,
            "finished": dt.datetime.now(dt.UTC).isoformat(),
            "output": f"timed out after {error.timeout} seconds",
        }


def open_simulator_session(sim_udid, session_id, screenshot, delay_seconds, open_session):
    if not open_session:
        return {
            "openSessionInSimulator": False,
            "skipped": True,
            "reason": "default harness path does not deep-link newly-created sessions into the visible simulator",
            "screenshot": {"path": screenshot, "skipped": True},
        }
    result = {
        "openSessionInSimulator": True,
        "boot": safe_run_cmd(["xcrun", "simctl", "boot", sim_udid], timeout=30),
        "bootstatus": safe_run_cmd(["xcrun", "simctl", "bootstatus", sim_udid, "-b"], timeout=120),
        "open": safe_run_cmd(
            ["xcrun", "simctl", "openurl", sim_udid, f"tron://session/{session_id}"],
            timeout=30,
        ),
    }
    time.sleep(delay_seconds)
    result["screenshot"] = {
        "path": screenshot,
        "result": safe_run_cmd(
            ["xcrun", "simctl", "io", sim_udid, "screenshot", screenshot],
            timeout=30,
        ),
    }
    return result


def simulator_result_ok(result):
    if result.get("skipped"):
        return True
    return (
        result.get("open", {}).get("returncode") == 0
        and result.get("screenshot", {}).get("result", {}).get("returncode") == 0
    )


def stream_payload(row):
    try:
        return json.loads(row["payload_preview"] or "{}")
    except json.JSONDecodeError:
        return {}


def collect_session(session_id, start_cursor, start_ts, identifiers):
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
          AND (session_id = ? OR payload_json LIKE ?)
        ORDER BY cursor
        """,
        (start_cursor, session_id, f"%{session_id}%"),
    )
    events = db_json(
        """
        SELECT sequence, type, timestamp, model, provider_type, stop_reason,
               model_primitive_name, invocation_id, substr(payload, 1, 5000) AS payload_preview
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
        WHERE scope_value = ?
        ORDER BY created_at
        """,
        (session_id,),
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
            WHERE scope_value = ?
        )
        ORDER BY created_at
        """,
        (session_id,),
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
    compensation = db_json(
        """
        SELECT compensation_id, invocation_id, function_id, trace_id,
               parent_invocation_id, status, succeeded, created_at,
               substr(error_json, 1, 2500) AS error_preview
        FROM engine_compensation_records
        WHERE trace_id IN (
            SELECT trace_id FROM engine_invocations WHERE session_id = ?
        )
           OR invocation_id IN (
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
    failed = [row for row in invocations if row["succeeded"] == 0]
    compact_events = [row for row in events if row["type"].startswith("compact.")]
    error_logs = [
        row for row in logs if str(row["level"]).lower() in {"error", "fatal"}
    ]
    open_queues = [row for row in queues if row["status"] not in TERMINAL_QUEUE_STATUSES]
    active_harness_subscriptions = [
        row for row in subscriptions if row["active"] and row["subscription_id"].startswith(HARNESS_PREFIX)
    ]
    active_client_subscriptions = [
        row for row in subscriptions if row["active"] and not row["subscription_id"].startswith(HARNESS_PREFIX)
    ]
    active_leases = [row for row in leases if row["status"] == "active"]
    prompt_queue_drains = [
        row for row in invocations if row["function_id"] == "agent::prompt_queue_drain"
    ]
    post_turn_effects = [
        row for row in invocations if row["function_id"] in BENIGN_POST_TURN_FUNCTIONS
    ]
    message_user = [row for row in events if row["type"] == "message.user"]
    message_assistant = [row for row in events if row["type"] == "message.assistant"]
    text = json.dumps(
        {
            "invocations": invocations,
            "queues": queues,
            "streams": streams,
            "events": events,
            "approvals": approvals,
            "resources": resources,
            "versions": versions,
            "leases": leases,
            "subscriptions": subscriptions,
            "grants": grants,
            "compensation": compensation,
            "catalogChanges": catalog_changes,
            "logs": logs,
        },
        sort_keys=True,
    )
    contains = {
        name: identifier in text
        for name, identifier in identifiers.items()
        if identifier
    }
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
        "compensation": compensation,
        "catalogChanges": catalog_changes,
        "logs": logs,
        "summary": {
            "failedInvocationCount": len(failed),
            "failedInvocations": failed,
            "approvalCount": len(approvals),
            "pendingApprovals": [row for row in approvals if row["status"] == "pending"],
            "compactEventCount": len(compact_events),
            "errorLogCount": len(error_logs),
            "openQueueRows": open_queues,
            "activeHarnessSubscriptionCount": len(active_harness_subscriptions),
            "activeClientSubscriptionCount": len(active_client_subscriptions),
            "activeClientSubscriptions": active_client_subscriptions,
            "activeResourceLeaseCount": len(active_leases),
            "activeGrantCount": len([row for row in grants if row["lifecycle"] == "active"]),
            "compensationCount": len(compensation),
            "promptQueueDrainCount": len(prompt_queue_drains),
            "postTurnEffectCount": len(post_turn_effects),
            "messageUserCount": len(message_user),
            "messageAssistantCount": len(message_assistant),
            "containsIdentifiers": contains,
        },
    }


def collect_cross_leakage(visible, background, identifiers):
    visible_text = json.dumps(visible, sort_keys=True)
    background_text = json.dumps(background, sort_keys=True)
    visible_contains_background = {
        name: identifier in visible_text
        for name, identifier in identifiers["background"].items()
        if identifier
    }
    background_contains_visible = {
        name: identifier in background_text
        for name, identifier in identifiers["visible"].items()
        if identifier
    }
    return {
        "visibleContainsBackground": visible_contains_background,
        "backgroundContainsVisible": background_contains_visible,
        "visibleLeakCount": sum(1 for leaked in visible_contains_background.values() if leaked),
        "backgroundLeakCount": sum(1 for leaked in background_contains_visible.values() if leaked),
    }


def catalog_latest(catalog_changes):
    latest = {}
    for row in catalog_changes:
        latest[row["subject_id"]] = row["kind_json"]
    return latest


def classify_visible(visible, visible_resource_id):
    summary = visible["summary"]
    resource_ids = {row["resource_id"] for row in visible["resources"]}
    return {
        "resourcePresent": visible_resource_id in resource_ids,
        "noFailures": summary["failedInvocationCount"] == 0,
        "noApprovals": summary["approvalCount"] == 0,
        "noCompactEvents": summary["compactEventCount"] == 0,
        "noErrorLogs": summary["errorLogCount"] == 0,
        "noOpenQueues": len(summary["openQueueRows"]) == 0,
        "noActiveLeases": summary["activeResourceLeaseCount"] == 0,
        "hasPromptQueueDrain": summary["promptQueueDrainCount"] >= 1,
        "hasPostTurnEffect": summary["postTurnEffectCount"] >= 1,
        "hasUserAndAssistantMessages": (
            summary["messageUserCount"] >= 1 and summary["messageAssistantCount"] >= 1
        ),
    }


def classify_background(background, fixture):
    summary = background["summary"]
    target_queues = [
        row for row in background["queues"] if row["function_id"] == fixture["functionId"]
    ]
    target_queue = target_queues[0] if target_queues else None
    receipt_id = target_queue["receipt_id"] if target_queue else None
    payloads = [(row, stream_payload(row)) for row in background["streams"]]
    queue_complete_events = [
        row
        for row, payload in payloads
        if payload.get("receiptId") == receipt_id and payload.get("type") == "queue.complete"
    ]
    worker_events = [
        row for row in background["streams"] if row["topic"] == fixture["streamTopic"]
    ]
    resource_ids = {row["resource_id"] for row in background["resources"]}
    latest_catalog = catalog_latest(background["catalogChanges"])
    return {
        "targetQueue": target_queue,
        "queueCompleted": (
            target_queue is not None
            and target_queue["status"] == "completed"
            and target_queue["attempts"] == 0
            and target_queue["lease_owner"] is None
            and target_queue["lease_expires_at"] is None
        ),
        "queueCompleteEventCount": len(queue_complete_events),
        "workerEventCount": len(worker_events),
        "resourcePresent": fixture["resourceId"] in resource_ids,
        "workerUnregistered": latest_catalog.get(fixture["workerId"]) == '"WorkerUnregistered"',
        "functionUnregistered": latest_catalog.get(fixture["functionId"]) == '"FunctionUnregistered"',
        "triggerUnregistered": latest_catalog.get(fixture["triggerId"]) == '"TriggerUnregistered"',
        "noFailures": summary["failedInvocationCount"] == 0,
        "noApprovals": summary["approvalCount"] == 0,
        "noCompactEvents": summary["compactEventCount"] == 0,
        "noErrorLogs": summary["errorLogCount"] == 0,
        "noOpenQueues": len(summary["openQueueRows"]) == 0,
        "noActiveHarnessSubscriptions": summary["activeHarnessSubscriptionCount"] == 0,
        "noActiveLeases": summary["activeResourceLeaseCount"] == 0,
        "hasPromptQueueDrain": summary["promptQueueDrainCount"] >= 1,
        "hasPostTurnEffect": summary["postTurnEffectCount"] >= 1,
        "hasUserAndAssistantMessages": (
            summary["messageUserCount"] >= 1 and summary["messageAssistantCount"] >= 1
        ),
    }


def all_true(mapping):
    return all(bool(value) for value in mapping.values())


def run_harness(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    namespace = f"rwo_n17_background_{stamp}"
    run_log = f"/tmp/rwo_n17_multi_session_run_{stamp}.json"
    isolated_server = n16.maybe_start_isolated_server(args, stamp, "rwo-n17")
    visible_resource_id = f"evidence:rwo-n17-visible:{stamp}"
    fixture = {
        "stamp": stamp,
        "workerId": f"rwo-n17-background-worker-{stamp}",
        "functionId": f"{namespace}::queued_echo",
        "triggerId": f"manual:{namespace}.queued_echo",
        "streamTopic": f"{namespace}.worker.events",
        "workerSubscriptionId": f"rwo-n17-background-worker-sub-{stamp}",
        "queueSubscriptionId": f"rwo-n17-background-queue-sub-{stamp}",
        "resourceId": f"evidence:rwo-n17-background:{stamp}",
        "log": f"/tmp/rwo_n17_background_worker_fixture_{stamp}.jsonl",
        "stdout": f"/tmp/rwo_n17_background_worker_fixture_{stamp}.stdout.log",
        "sessionId": None,
    }
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "fixture": fixture,
        "visibleResourceId": visible_resource_id,
        "visibleScreenshotBefore": f"/tmp/rwo_n17_visible_before_{stamp}.png",
        "backgroundScreenshot": f"/tmp/rwo_n17_background_{stamp}.png",
        "visibleScreenshotAfter": f"/tmp/rwo_n17_visible_after_{stamp}.png",
        "serverMode": "current_user" if args.use_current_server else "isolated",
        "isolatedServer": n16.public_server_info(isolated_server),
        "serverHealthBefore": n16.run_cmd(["curl", "-fsS", n16.HEALTH], timeout=10),
        "startCursor": n16.db_scalar("SELECT coalesce(max(cursor), 0) FROM engine_stream_events"),
        "startTimestamp": dt.datetime.now(dt.UTC).isoformat(),
    }
    ws = None
    fixture_proc = None
    fixture_stdout = None
    error = None
    try:
        ws, hello = n16.ws_hello("rwo-n17-hello")
        result["hello"] = hello

        visible_session_id, visible_create_child = create_session(ws, stamp, args.model, "visible")
        result["visibleSessionId"] = visible_session_id
        result["visibleCreateChild"] = visible_create_child
        visible = visible_prompt(visible_session_id, stamp, visible_resource_id)
        result["visiblePrompt"] = visible
        before_sequence, prompt_value, prompt_child = send_prompt(
            ws,
            visible_session_id,
            visible,
            stamp,
            "visible",
        )
        result["visibleBeforeSequence"] = before_sequence
        result["visiblePromptValue"] = prompt_value
        result["visiblePromptChild"] = prompt_child
        result["visibleTerminalEvent"] = n16.wait_end_turn(
            visible_session_id,
            args.timeout_seconds,
        )
        result["visibleTerminalGuardBefore"] = run_terminal_guard(
            visible_session_id,
            min(args.timeout_seconds, 180),
        )
        result["visibleSimulatorBefore"] = open_simulator_session(
            args.sim_udid,
            visible_session_id,
            result["visibleScreenshotBefore"],
            args.screenshot_delay_seconds,
            args.open_session_in_simulator,
        )
        time.sleep(args.visible_hold_seconds)

        background_session_id, background_create_child = create_session(
            ws,
            stamp,
            args.model,
            "background",
        )
        fixture["sessionId"] = background_session_id
        result["backgroundSessionId"] = background_session_id
        result["backgroundCreateChild"] = background_create_child
        fixture_proc, fixture_stdout, fixture_cmd = start_fixture(fixture)
        result["fixtureCommand"] = fixture_cmd
        result["registration"] = n16.wait_registration(
            background_session_id,
            fixture["workerId"],
            fixture["functionId"],
            fixture["triggerId"],
            timeout=30,
        )
        background = background_prompt(fixture, stamp)
        result["backgroundPrompt"] = background
        before_sequence, prompt_value, prompt_child = send_prompt(
            ws,
            background_session_id,
            background,
            stamp,
            "background",
        )
        result["backgroundBeforeSequence"] = before_sequence
        result["backgroundPromptValue"] = prompt_value
        result["backgroundPromptChild"] = prompt_child
        result["backgroundTerminalEvent"] = n16.wait_end_turn(
            background_session_id,
            args.timeout_seconds,
        )
        result["backgroundTerminalGuard"] = run_terminal_guard(
            background_session_id,
            min(args.timeout_seconds, 180),
        )
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

    visible_session_id = result.get("visibleSessionId")
    background_session_id = result.get("backgroundSessionId")
    if visible_session_id:
        result["visibleTerminalGuardAfter"] = run_terminal_guard(
            visible_session_id,
            min(args.timeout_seconds, 180),
        )
    if background_session_id:
        result["backgroundSimulator"] = open_simulator_session(
            args.sim_udid,
            background_session_id,
            result["backgroundScreenshot"],
            args.screenshot_delay_seconds,
            args.open_session_in_simulator,
        )
        result["serverHealthAfterBackgroundOpen"] = n16.run_cmd(["curl", "-fsS", n16.HEALTH], timeout=10)
    if visible_session_id:
        result["visibleSimulatorAfter"] = open_simulator_session(
            args.sim_udid,
            visible_session_id,
            result["visibleScreenshotAfter"],
            args.screenshot_delay_seconds,
            args.open_session_in_simulator,
        )
        result["serverHealthAfter"] = n16.run_cmd(["curl", "-fsS", n16.HEALTH], timeout=10)

    if visible_session_id and background_session_id:
        identifiers = {
            "visible": {
                "sessionId": visible_session_id,
                "resourceId": visible_resource_id,
            },
            "background": {
                "sessionId": background_session_id,
                "workerId": fixture["workerId"],
                "functionId": fixture["functionId"],
                "triggerId": fixture["triggerId"],
                "streamTopic": fixture["streamTopic"],
                "resourceId": fixture["resourceId"],
            },
        }
        visible_db = collect_session(
            visible_session_id,
            result["startCursor"],
            result["startTimestamp"],
            identifiers["background"],
        )
        background_db = collect_session(
            background_session_id,
            result["startCursor"],
            result["startTimestamp"],
            identifiers["visible"],
        )
        visible_classification = classify_visible(visible_db, visible_resource_id)
        background_classification = classify_background(background_db, fixture)
        cross_leakage = collect_cross_leakage(visible_db, background_db, identifiers)
        simulator_ok = (
            simulator_result_ok(result.get("visibleSimulatorBefore", {}))
            and simulator_result_ok(result.get("backgroundSimulator", {}))
            and simulator_result_ok(result.get("visibleSimulatorAfter", {}))
        )
        guards_ok = (
            result.get("visibleTerminalGuardBefore", {}).get("returncode") == 0
            and result.get("visibleTerminalGuardAfter", {}).get("returncode") == 0
            and result.get("backgroundTerminalGuard", {}).get("returncode") == 0
        )
        no_leakage = (
            cross_leakage["visibleLeakCount"] == 0
            and cross_leakage["backgroundLeakCount"] == 0
        )
        result["db"] = {
            "visible": visible_db,
            "background": background_db,
            "visibleClassification": visible_classification,
            "backgroundClassification": background_classification,
            "crossLeakage": cross_leakage,
            "summary": {
                "passed": (
                    guards_ok
                    and simulator_ok
                    and no_leakage
                    and all_true(visible_classification)
                    and all_true(background_classification)
                ),
                "guardsOk": guards_ok,
                "simulatorOk": simulator_ok,
                "noCrossLeakage": no_leakage,
                "visibleSessionId": visible_session_id,
                "backgroundSessionId": background_session_id,
                "visibleResourceId": visible_resource_id,
                "backgroundResourceId": fixture["resourceId"],
            },
        }

    if isolated_server is not None:
        result["isolatedServerStop"] = n16.stop_isolated_server(isolated_server["process"])

    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)

    summary = {
        "runLog": run_log,
        "visibleSessionId": result.get("visibleSessionId"),
        "backgroundSessionId": result.get("backgroundSessionId"),
        "fixtureLog": fixture["log"],
        "visibleScreenshotBefore": result["visibleScreenshotBefore"],
        "backgroundScreenshot": result["backgroundScreenshot"],
        "visibleScreenshotAfter": result["visibleScreenshotAfter"],
        "terminalGuards": {
            "visibleBefore": result.get("visibleTerminalGuardBefore"),
            "visibleAfter": result.get("visibleTerminalGuardAfter"),
            "background": result.get("backgroundTerminalGuard"),
        },
        "dbSummary": result.get("db", {}).get("summary"),
        "visibleClassification": result.get("db", {}).get("visibleClassification"),
        "backgroundClassification": result.get("db", {}).get("backgroundClassification"),
        "crossLeakage": result.get("db", {}).get("crossLeakage"),
        "error": error,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    if error:
        return 3
    if not result.get("db", {}).get("summary", {}).get("passed"):
        return 1
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="claude-sonnet-4-6")
    parser.add_argument("--sim-udid", default=DEFAULT_SIM_UDID)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--visible-hold-seconds", type=float, default=2.0)
    parser.add_argument("--screenshot-delay-seconds", type=float, default=6.0)
    parser.add_argument(
        "--open-session-in-simulator",
        action="store_true",
        help="Deep-link newly-created sessions into the visible Simulator and capture screenshots. Leave unset for backend-only harness runs.",
    )
    n16.add_runtime_args(parser)
    return parser.parse_args(argv)


def main(argv):
    return run_harness(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
