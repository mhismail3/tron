#!/usr/bin/env python3
"""Live agent/execute resource-truth and mutation-failure matrix for ROC-5."""

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rwo_n16_live_agent_harness as n16

ROOT = n16.ROOT
DB_PATH = n16.DB_PATH
HEALTH = n16.HEALTH
DEFAULT_SIM_UDID = "267F6468-09AE-471D-9157-29144173EB82"
TERMINAL_QUEUE_STATUSES = ("completed", "cancelled", "dead_lettered")


def db_json(query, params=()):
    with sqlite3.connect(DB_PATH, timeout=10) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, params)]


def db_scalar(query, params=()):
    rows = db_json(query, params)
    if not rows:
        return None
    return next(iter(rows[0].values()))


def latest_event_sequence(session_id):
    value = db_scalar(
        "SELECT coalesce(max(sequence), 0) FROM events WHERE session_id = ?",
        (session_id,),
    )
    return int(value or 0)


def wait_end_turn_after(session_id, min_sequence, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    latest = None
    while time.monotonic() < deadline:
        rows = db_json(
            """
            SELECT sequence, type, stop_reason, payload
            FROM events
            WHERE session_id = ? AND sequence > ?
            ORDER BY sequence
            """,
            (session_id, min_sequence),
        )
        terminal = [
            row
            for row in rows
            if row["type"] == "stream.turn_end"
            and n16.event_stop_reason(row) == n16.TERMINAL_STOP_REASON
        ]
        if terminal:
            last = terminal[-1]
            later_start = any(
                row["type"] == "stream.turn_start" and row["sequence"] > last["sequence"]
                for row in rows
            )
            if not later_start:
                return last
        latest = rows[-1] if rows else latest
        time.sleep(1)
    raise TimeoutError(
        f"no terminal end_turn for {session_id} after sequence {min_sequence}; latest={latest}"
    )


def sha256_hex(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def create_session(ws, stamp, model, workspace):
    response = n16.invoke(
        ws,
        "session::create",
        {
            "workingDirectory": workspace,
            "model": model,
            "title": f"ROC-5 resource truth matrix {stamp}",
            "useWorktree": False,
        },
        "create-roc5",
        f"roc5-session-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {"scenario": "ROC-5", "harness": "resource-truth"},
        },
        timeout=60,
    )
    value, child = n16.child_value(response)
    return value["sessionId"], child


def invoke_agent_prompt(ws, session_id, prompt, stamp, label):
    response = n16.invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": session_id,
            "prompt": prompt,
            "source": f"roc5-resource-truth-{label}-{stamp}",
        },
        f"prompt-roc5-{label}",
        f"roc5-agent-prompt-{label}-{stamp}",
        {
            "sessionId": session_id,
            "authorityScopes": ["session.write", "session.read", "agent.read", "agent.write"],
            "runtimeMetadata": {
                "scenario": "ROC-5",
                "harness": "resource-truth",
                "phase": label,
            },
        },
        timeout=60,
    )
    value, child = n16.child_value(response)
    return value, child


def valid_ui_surface(session_id, stamp):
    return {
        "surfaceId": f"roc5-surface-{stamp}",
        "title": "ROC-5 Surface",
        "purpose": "Validate stale generated UI action rejection",
        "catalog": {"id": "tron.ui.catalog.core.v1", "revision": 1},
        "layout": {
            "type": "Section",
            "props": {"title": "ROC-5"},
            "children": [
                {"type": "Heading", "props": {"text": "ROC-5"}},
                {"type": "Text", "props": {"text": "Resource truth matrix"}},
                {"type": "Button", "props": {"actionId": "submit-test"}},
            ],
        },
        "bindings": [],
        "actions": [
            {
                "actionId": "submit-test",
                "label": "Submit",
                "targetFunctionId": "resource::create",
                "inputSchema": {
                    "type": "object",
                    "required": ["message"],
                    "additionalProperties": False,
                    "properties": {"message": {"type": "string"}},
                },
                "payloadTemplate": {
                    "kind": "evidence",
                    "scope": "session",
                    "sessionId": session_id,
                    "resourceId": f"evidence:roc5:ui-action:{stamp}",
                    "payload": {
                        "summary": "${input.message}",
                        "sourceSurface": "${surface.resourceId}",
                    },
                },
                "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                "requiredGrant": "grant",
                "requiredRisk": "medium",
                "approvalPolicy": {"required": False},
                "targetRevision": 1,
                "expiresAt": "2100-01-01T00:00:00Z",
            }
        ],
        "redactionPolicy": {"mode": "redacted"},
        "expiresAt": "2100-01-01T00:00:00Z",
        "refreshPolicy": {"mode": "manual"},
    }


def prompt_phase_one(ids):
    surface_json = json.dumps(valid_ui_surface(ids["sessionId"], ids["stamp"]), separators=(",", ":"))
    return f"""Use only execute. ROC-5 resource truth and mutation failure matrix {ids["stamp"]}. Do not use shell, process, filesystem, web, browser, or non-execute tools except for the exact execute calls below.

Important: several calls below are intentionally invalid. Make them exactly as written, do not repair them, and continue after expected failures.

1. execute target resource::create, operation run, idempotencyKey roc5-cas-create-{ids["stamp"]}, arguments {{"kind":"evidence","scope":"session","sessionId":"{ids["sessionId"]}","resourceId":"{ids["casResource"]}","payload":{{"summary":"ROC-5 CAS baseline {ids["stamp"]}","body":"v1"}}}}.
2. From step 1 capture resource.currentVersionId as CAS_V1. execute target resource::update, operation run, idempotencyKey roc5-cas-update-{ids["stamp"]}, arguments {{"resourceId":"{ids["casResource"]}","expectedCurrentVersionId":"<CAS_V1>","payload":{{"summary":"ROC-5 CAS update {ids["stamp"]}","body":"v2"}}}}.
3. Intentionally stale: execute target resource::update, operation run, idempotencyKey roc5-cas-stale-{ids["stamp"]}, arguments {{"resourceId":"{ids["casResource"]}","expectedCurrentVersionId":"<CAS_V1>","payload":{{"summary":"ROC-5 stale update {ids["stamp"]}","body":"stale"}}}}.
4. Intentionally missing payload: execute target resource::update, operation run, idempotencyKey roc5-missing-payload-{ids["stamp"]}, arguments {{"resourceId":"{ids["casResource"]}"}}.
5. Intentionally wrong declared hash: execute target materialized_file::update, operation run, idempotencyKey roc5-declared-hash-{ids["stamp"]}, arguments {{"resourceId":"{ids["declaredHashResource"]}","path":"{ids["declaredHashPath"]}","content":"declared hash mismatch","contentHash":"not-the-real-hash","scope":"session","sessionId":"{ids["sessionId"]}"}}.
6. Create hash-verify fixture: execute target materialized_file::update, operation run, idempotencyKey roc5-damaged-create-{ids["stamp"]}, arguments {{"resourceId":"{ids["damagedResource"]}","path":"{ids["damagedPath"]}","content":"untampered","contentHash":"{sha256_hex("untampered")}","scope":"session","sessionId":"{ids["sessionId"]}"}}.
7. Create discard fixture: execute target materialized_file::update, operation run, idempotencyKey roc5-discarded-create-{ids["stamp"]}, arguments {{"resourceId":"{ids["discardedResource"]}","path":"{ids["discardedPath"]}","content":"discard me","scope":"session","sessionId":"{ids["sessionId"]}"}}.
8. From step 7 capture resource.currentVersionId as DISCARD_V1. execute target materialized_file::discard, operation run, idempotencyKey roc5-discard-{ids["stamp"]}, arguments {{"resourceId":"{ids["discardedResource"]}","expectedCurrentVersionId":"<DISCARD_V1>"}}.
9. Intentionally read discarded resource: execute target materialized_file::read, operation run, idempotencyKey roc5-discarded-read-{ids["stamp"]}, arguments {{"resourceId":"{ids["discardedResource"]}"}}.
10. Inspect discarded resource: execute target materialized_file::inspect, operation run, idempotencyKey roc5-discarded-inspect-{ids["stamp"]}, arguments {{"resourceId":"{ids["discardedResource"]}"}}.
11. Create generated UI surface: execute target ui::create_surface, operation run, idempotencyKey roc5-ui-create-{ids["stamp"]}, arguments {{"resourceId":"{ids["uiSurfaceId"]}","surface":{surface_json}}}.
12. Intentionally stale generated UI submit: execute target ui::submit_action, operation run, idempotencyKey roc5-ui-stale-{ids["stamp"]}, arguments {{"surfaceResourceId":"{ids["uiSurfaceId"]}","surfaceVersionId":"wrong-version","actionId":"submit-test","userInput":{{"message":"ROC-5 stale UI should not create {ids["stamp"]}"}},"idempotencyKey":"roc5-ui-stale-action-{ids["stamp"]}"}}.
13. Intentionally duplicate process materialization target: execute target process::run, operation run, idempotencyKey roc5-process-collision-{ids["stamp"]}, arguments {{"command":"printf one > one.txt && printf two > two.txt","executionMode":"sandbox_materialized","expectedOutputs":[{{"path":"one.txt","targetPath":"collision.txt"}},{{"path":"two.txt","targetPath":"./collision.txt"}}],"retainOutput":true}}.

Final answer requirements: report the result of each numbered step, including which ones failed as expected. Do not retry failed steps with corrected inputs."""


def prompt_phase_two(ids):
    return f"""Use only execute. ROC-5 hash verification follow-up {ids["stamp"]}. The harness has tampered the canonical bytes for {ids["damagedResource"]}; do not repair the file.

1. execute target materialized_file::hash_verify, operation run, idempotencyKey roc5-damaged-verify-{ids["stamp"]}, arguments {{"resourceId":"{ids["damagedResource"]}"}}.

Final answer requirements: say exactly "ROC-5 resource truth matrix {ids["stamp"]} complete" and report whether hash_verify marked the resource damaged."""


def wait_for_file(path, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.25)
    return False


def resource_row(resource_id):
    rows = db_json(
        """
        SELECT resource_id, kind, lifecycle, current_version_id, scope_kind, scope_value
        FROM engine_resources
        WHERE resource_id = ?
        """,
        (resource_id,),
    )
    return rows[0] if rows else None


def version_count(resource_id):
    return db_scalar(
        "SELECT count(*) FROM engine_resource_versions WHERE resource_id = ?",
        (resource_id,),
    )


def invocation_by_key(session_id, key):
    rows = db_json(
        """
        SELECT invocation_id, function_id, parent_invocation_id, succeeded,
               substr(result_json, 1, 3000) AS result_preview,
               substr(error_json, 1, 3000) AS error_preview
        FROM engine_invocations
        WHERE session_id = ? AND idempotency_key = ?
        ORDER BY timestamp DESC
        """,
        (session_id, key),
    )
    if rows:
        return rows[0]
    rows = db_json(
        """
        SELECT invocation_id, function_id, parent_invocation_id, succeeded,
               substr(result_json, 1, 3000) AS result_preview,
               substr(error_json, 1, 3000) AS error_preview
        FROM engine_invocations
        WHERE session_id = ?
          AND function_id = 'capability::execute'
          AND result_json LIKE ?
        ORDER BY timestamp DESC
        """,
        (session_id, f"%{key}%"),
    )
    return rows[0] if rows else None


def first_version_id(resource_id):
    rows = db_json(
        """
        SELECT version_id
        FROM engine_resource_versions
        WHERE resource_id = ?
        ORDER BY created_at
        LIMIT 1
        """,
        (resource_id,),
    )
    return rows[0]["version_id"] if rows else None


def repair_prompt_for_key(ids, key):
    stamp = ids["stamp"]
    prompts = {
        f"roc5-missing-payload-{stamp}": f"""Use only execute. ROC-5 missed negative attempt {stamp}.

Make exactly one execute call and do not repair the intentionally incomplete arguments:
execute target resource::update, operation run, idempotencyKey roc5-missing-payload-{stamp}, arguments {{"resourceId":"{ids["casResource"]}"}}.

Final answer requirements: report whether execute returned needs_input or failed. Do not run any other tool call.""",
        f"roc5-declared-hash-{stamp}": f"""Use only execute. ROC-5 missed declared-hash negative attempt {stamp}.

Make exactly one execute call and do not repair the intentionally wrong hash:
execute target materialized_file::update, operation run, idempotencyKey roc5-declared-hash-{stamp}, arguments {{"resourceId":"{ids["declaredHashResource"]}","path":"{ids["declaredHashPath"]}","content":"declared hash mismatch","contentHash":"not-the-real-hash","scope":"session","sessionId":"{ids["sessionId"]}"}}.

Final answer requirements: report that the hash mismatch failed before creating the resource. Do not run any other tool call.""",
        f"roc5-discarded-read-{stamp}": f"""Use only execute. ROC-5 missed discarded-read negative attempt {stamp}.

Make exactly one execute call:
execute target materialized_file::read, operation run, idempotencyKey roc5-discarded-read-{stamp}, arguments {{"resourceId":"{ids["discardedResource"]}"}}.

Final answer requirements: report that discarded resources are not readable. Do not run any other tool call.""",
        f"roc5-ui-stale-{stamp}": f"""Use only execute. ROC-5 missed stale generated UI submit attempt {stamp}.

Make exactly one execute call and do not repair the intentionally stale surfaceVersionId:
execute target ui::submit_action, operation run, idempotencyKey roc5-ui-stale-{stamp}, arguments {{"surfaceResourceId":"{ids["uiSurfaceId"]}","surfaceVersionId":"wrong-version","actionId":"submit-test","userInput":{{"message":"ROC-5 stale UI should not create {stamp}"}},"idempotencyKey":"roc5-ui-stale-action-{stamp}"}}.

Final answer requirements: report that the stale submit failed before the target action. Do not run any other tool call.""",
        f"roc5-process-collision-{stamp}": f"""Use only execute. ROC-5 missed process output-collision negative attempt {stamp}.

Make exactly one execute call and do not change the duplicate materialization target paths:
execute target process::run, operation run, idempotencyKey roc5-process-collision-{stamp}, arguments {{"command":"printf one > one.txt && printf two > two.txt","executionMode":"sandbox_materialized","expectedOutputs":[{{"path":"one.txt","targetPath":"collision.txt"}},{{"path":"two.txt","targetPath":"./collision.txt"}}],"retainOutput":true}}.

Final answer requirements: report that the duplicate materialization target was rejected before spawn/approval. Do not run any other tool call.""",
    }
    cas_stale_key = f"roc5-cas-stale-{stamp}"
    if key == cas_stale_key:
        cas_v1 = first_version_id(ids["casResource"])
        if not cas_v1:
            return None
        return f"""Use only execute. ROC-5 missed CAS stale negative attempt {stamp}.

Make exactly one execute call and do not repair the intentionally stale version:
execute target resource::update, operation run, idempotencyKey roc5-cas-stale-{stamp}, arguments {{"resourceId":"{ids["casResource"]}","expectedCurrentVersionId":"{cas_v1}","payload":{{"summary":"ROC-5 stale update {stamp}","body":"stale"}}}}.

Final answer requirements: report that the stale CAS write failed before mutation. Do not run any other tool call."""
    return prompts.get(key)


def expected_failure_keys(ids):
    return [
        f"roc5-cas-stale-{ids['stamp']}",
        f"roc5-missing-payload-{ids['stamp']}",
        f"roc5-declared-hash-{ids['stamp']}",
        f"roc5-discarded-read-{ids['stamp']}",
        f"roc5-ui-stale-{ids['stamp']}",
        f"roc5-process-collision-{ids['stamp']}",
    ]


def repair_missing_expected_attempts(ws, session_id, ids, start_ts, timeout_seconds):
    repairs = []
    for attempt in range(2):
        summary = collect(session_id, start_ts, ids)["summary"]
        missing = summary["missingExpectedFailureKeys"]
        if not missing:
            break
        for key in missing:
            prompt = repair_prompt_for_key(ids, key)
            if prompt is None:
                repairs.append({"attempt": attempt + 1, "key": key, "skipped": "missing prerequisite"})
                continue
            label = f"repair-{key.removeprefix('roc5-').removesuffix('-' + ids['stamp'])}-{attempt + 1}"
            before_sequence = latest_event_sequence(session_id)
            value, child = invoke_agent_prompt(
                ws,
                session_id,
                prompt,
                ids["stamp"],
                label,
            )
            terminal = wait_end_turn_after(session_id, before_sequence, timeout_seconds)
            repairs.append(
                {
                    "attempt": attempt + 1,
                    "key": key,
                    "prompt": prompt,
                    "value": value,
                    "child": child,
                    "terminal": terminal,
                }
            )
    return repairs


def collect(session_id, start_ts, ids):
    resource_ids = [
        ids["casResource"],
        ids["declaredHashResource"],
        ids["damagedResource"],
        ids["discardedResource"],
        ids["uiSurfaceId"],
        f"evidence:roc5:ui-action:{ids['stamp']}",
    ]
    invocations = db_json(
        """
        SELECT invocation_id, function_id, worker_id, parent_invocation_id, trace_id,
               session_id, idempotency_key, replayed_from, succeeded,
               produced_resource_refs_json, substr(result_json, 1, 6000) AS result_preview,
               substr(error_json, 1, 4000) AS error_preview, timestamp
        FROM engine_invocations
        WHERE session_id = ? AND timestamp >= ?
        ORDER BY timestamp
        """,
        (session_id, start_ts),
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
    queues = db_json(
        """
        SELECT receipt_id, function_id, status, attempts, lease_owner, lease_expires_at
        FROM engine_queue_items
        WHERE session_id = ?
        ORDER BY created_at
        """,
        (session_id,),
    )
    resources = db_json(
        f"""
        SELECT resource_id, kind, lifecycle, current_version_id, scope_kind, scope_value
        FROM engine_resources
        WHERE resource_id IN ({','.join('?' for _ in resource_ids)})
        ORDER BY resource_id
        """,
        tuple(resource_ids),
    )
    versions = db_json(
        f"""
        SELECT resource_id, version_id, version_state, created_by_invocation_id,
               substr(payload_json, 1, 3000) AS payload_preview
        FROM engine_resource_versions
        WHERE resource_id IN ({','.join('?' for _ in resource_ids)})
        ORDER BY resource_id, created_at
        """,
        tuple(resource_ids),
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
    active_leases = [row for row in leases if row["status"] == "active"]
    expected_keys = expected_failure_keys(ids)
    keyed = {key: invocation_by_key(session_id, key) for key in expected_keys}
    stale_ui = keyed[f"roc5-ui-stale-{ids['stamp']}"]
    stale_ui_child_count = 0
    if stale_ui:
        stale_ui_child_count = db_scalar(
            """
            SELECT count(*)
            FROM engine_invocations
            WHERE parent_invocation_id = ? AND function_id = 'resource::create'
            """,
            (stale_ui["invocation_id"],),
        )
    return {
        "invocations": invocations,
        "events": events,
        "approvals": approvals,
        "queues": queues,
        "resources": resources,
        "resourceVersions": versions,
        "resourceLeases": leases,
        "logs": logs,
        "summary": {
            "failedInvocationCount": len(failed),
            "expectedFailureKeys": keyed,
            "missingExpectedFailureKeys": [
                key for key, row in keyed.items() if row is None
            ],
            "unexpectedFailedInvocations": [
                row
                for row in failed
                if row["idempotency_key"] not in expected_keys
            ],
            "approvalCount": len(approvals),
            "pendingApprovals": [row for row in approvals if row["status"] == "pending"],
            "compactEventCount": len(compact_events),
            "openQueueRows": open_queues,
            "activeResourceLeaseCount": len(active_leases),
            "errorLogCount": len(error_logs),
            "casVersionCount": version_count(ids["casResource"]),
            "declaredHashResourceRow": resource_row(ids["declaredHashResource"]),
            "damagedResourceRow": resource_row(ids["damagedResource"]),
            "discardedResourceRow": resource_row(ids["discardedResource"]),
            "staleUiTargetChildCount": stale_ui_child_count,
            "processCollisionTargetExists": os.path.exists(
                os.path.join(ids["workspace"], "collision.txt")
            ),
        },
    }


def run_harness(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    workspace = tempfile.mkdtemp(prefix=f"roc5-workspace-{stamp}-")
    run_log = f"/tmp/roc5_resource_truth_matrix_{stamp}.json"
    screenshot = f"/tmp/roc5-resource-truth-iphone-{stamp}.png"
    ids = {
        "stamp": stamp,
        "workspace": workspace,
        "casResource": f"evidence:roc5:cas:{stamp}",
        "declaredHashResource": f"materialized_file:roc5:declared-hash:{stamp}",
        "declaredHashPath": os.path.join(workspace, "declared-hash.txt"),
        "damagedResource": f"materialized_file:roc5:damaged:{stamp}",
        "damagedPath": os.path.join(workspace, "damaged.txt"),
        "discardedResource": f"materialized_file:roc5:discarded:{stamp}",
        "discardedPath": os.path.join(workspace, "discarded.txt"),
        "uiSurfaceId": f"ui-surface-roc5-{stamp}",
    }
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "workspace": workspace,
        "screenshot": screenshot,
        "ids": ids,
        "serverHealthBefore": n16.run_cmd(["curl", "-fsS", HEALTH], timeout=10),
        "startTimestamp": dt.datetime.now(dt.UTC).isoformat(),
    }
    ws = None
    try:
        ws, hello = n16.ws_hello("roc5-hello")
        result["hello"] = hello
        session_id, create_child = create_session(ws, stamp, args.model, workspace)
        ids["sessionId"] = session_id
        result["sessionId"] = session_id
        result["createChild"] = create_child
        phase_one = prompt_phase_one(ids)
        result["phaseOnePrompt"] = phase_one
        phase_one_before_sequence = latest_event_sequence(session_id)
        phase_one_value, phase_one_child = invoke_agent_prompt(
            ws,
            session_id,
            phase_one,
            stamp,
            "phase-one",
        )
        result["phaseOneValue"] = phase_one_value
        result["phaseOneChild"] = phase_one_child
        result["phaseOneTerminal"] = wait_end_turn_after(
            session_id,
            phase_one_before_sequence,
            args.timeout_seconds,
        )
        result["repairPrompts"] = repair_missing_expected_attempts(
            ws,
            session_id,
            ids,
            result["startTimestamp"],
            args.timeout_seconds,
        )

        if not wait_for_file(ids["damagedPath"], timeout=30):
            raise RuntimeError(f"damaged fixture file was not created: {ids['damagedPath']}")
        with open(ids["damagedPath"], "w", encoding="utf-8") as handle:
            handle.write("tampered")

        phase_two = prompt_phase_two(ids)
        result["phaseTwoPrompt"] = phase_two
        phase_two_before_sequence = latest_event_sequence(session_id)
        phase_two_value, phase_two_child = invoke_agent_prompt(
            ws,
            session_id,
            phase_two,
            stamp,
            "phase-two",
        )
        result["phaseTwoValue"] = phase_two_value
        result["phaseTwoChild"] = phase_two_child
        result["phaseTwoTerminal"] = wait_end_turn_after(
            session_id,
            phase_two_before_sequence,
            args.timeout_seconds,
        )
    finally:
        if ws is not None:
            ws.close()

    result["terminalGuard"] = n16.run_terminal_guard(
        result["sessionId"],
        min(args.timeout_seconds, 180),
    )
    result["simulatorEvidence"] = n16.simulator_evidence(
        args.sim_udid,
        result["sessionId"],
        screenshot,
        args.screenshot_delay_seconds,
        args.open_session_in_simulator,
    )
    result["serverHealthAfter"] = n16.run_cmd(["curl", "-fsS", HEALTH], timeout=10)
    result["db"] = collect(result["sessionId"], result["startTimestamp"], ids)
    summary = result["db"]["summary"]
    damaged = summary["damagedResourceRow"] or {}
    discarded = summary["discardedResourceRow"] or {}
    result["validation"] = {
        "casVersionCountStable": summary["casVersionCount"] == 2,
        "declaredHashCreatedNoResource": summary["declaredHashResourceRow"] is None,
        "damagedLifecycle": damaged.get("lifecycle") == "damaged",
        "discardedLifecycle": discarded.get("lifecycle") == "discarded",
        "staleUiCreatedNoChild": summary["staleUiTargetChildCount"] == 0,
        "processCollisionCreatedNoTarget": not summary["processCollisionTargetExists"],
        "expectedFailureKeysPresent": not summary["missingExpectedFailureKeys"],
        "expectedFailuresOnly": not summary["unexpectedFailedInvocations"],
        "noApprovals": summary["approvalCount"] == 0,
        "noCompactEvents": summary["compactEventCount"] == 0,
        "noOpenQueues": len(summary["openQueueRows"]) == 0,
        "noActiveLeases": summary["activeResourceLeaseCount"] == 0,
        "noErrorLogs": summary["errorLogCount"] == 0,
        "terminalGuardOk": result["terminalGuard"]["returncode"] == 0,
        "simulatorOk": (
            True
            if not args.open_session_in_simulator
            else (
                result["simulatorEvidence"]["open"]["returncode"] == 0
                and result["simulatorEvidence"]["screenshot"]["result"]["returncode"] == 0
            )
        ),
    }
    result["validation"]["passed"] = all(result["validation"].values())
    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    printed = {
        "runLog": run_log,
        "sessionId": result["sessionId"],
        "workspace": workspace,
        "screenshot": screenshot,
        "validation": result["validation"],
        "dbSummary": summary,
    }
    print(json.dumps(printed, indent=2, sort_keys=True))
    if args.cleanup_workspace and result["validation"]["passed"]:
        shutil.rmtree(workspace, ignore_errors=True)
    return 0 if result["validation"]["passed"] else 1


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="claude-sonnet-4-6")
    parser.add_argument("--sim-udid", default=DEFAULT_SIM_UDID)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--screenshot-delay-seconds", type=float, default=3.0)
    parser.add_argument(
        "--open-session-in-simulator",
        action="store_true",
        help="Deep-link the newly-created session into the visible Simulator and capture a screenshot. Leave unset for non-UI backend runs.",
    )
    parser.add_argument("--cleanup-workspace", action="store_true")
    return parser.parse_args(argv)


def main(argv):
    return run_harness(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
