#!/usr/bin/env python3
"""Live long-running session and compaction regression harness for ROC-7."""

import argparse
import atexit
import datetime as dt
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rwo_n16_live_agent_harness as n16

ROOT = n16.ROOT
DEFAULT_SIM_UDID = "267F6468-09AE-471D-9157-29144173EB82"
TERMINAL_STOP_REASON = "end_turn"


def db_json(query, params=()):
    with sqlite3.connect(n16.DB_PATH, timeout=10) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, params)]


def db_scalar(query, params=()):
    rows = db_json(query, params)
    if not rows:
        return None
    return next(iter(rows[0].values()))


def invoke(ws, function_id, payload, request_id, idempotency_key, scopes, context=None, timeout=60):
    ctx = {
        "authorityScopes": scopes,
        "runtimeMetadata": {"scenario": "ROC-7", "harness": "long-running-compaction"},
    }
    if context:
        ctx.update(context)
    return n16.invoke(ws, function_id, payload, request_id, idempotency_key, ctx, timeout=timeout)


def child(response, expect_error=False):
    if not response.get("ok"):
        if expect_error:
            return None, response
        raise RuntimeError(response)
    result_child = response["result"]["child"]
    if result_child.get("error"):
        if expect_error:
            return None, result_child
        raise RuntimeError(result_child["error"])
    if expect_error:
        raise AssertionError(f"expected child error but got {result_child}")
    return result_child["value"], result_child


def latest_event_sequence(session_id):
    value = db_scalar(
        "SELECT coalesce(max(sequence), 0) FROM events WHERE session_id = ?",
        (session_id,),
    )
    return int(value or 0)


def wait_for_event_type_after(session_id, event_type, min_sequence, timeout_seconds=90):
    deadline = time.monotonic() + timeout_seconds
    latest = None
    while time.monotonic() < deadline:
        rows = db_json(
            """
            SELECT id, sequence, type, stop_reason, payload
            FROM events
            WHERE session_id = ? AND sequence > ?
            ORDER BY sequence
            """,
            (session_id, min_sequence),
        )
        for row in rows:
            if row["type"] == event_type:
                return row
        latest = rows[-1] if rows else latest
        time.sleep(0.5)
    raise TimeoutError(
        f"no {event_type} for {session_id} after sequence {min_sequence}; latest={latest}"
    )


def wait_end_turn_after(session_id, min_sequence, timeout_seconds=180):
    deadline = time.monotonic() + timeout_seconds
    latest = None
    while time.monotonic() < deadline:
        rows = db_json(
            """
            SELECT id, sequence, type, stop_reason, payload
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
            and n16.event_stop_reason(row) == TERMINAL_STOP_REASON
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


def wait_health_url(url, timeout=45):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                body = response.read().decode("utf-8")
            data = json.loads(body)
            if data.get("status") == "ok":
                return data
        except Exception as error:
            last_error = str(error)
        time.sleep(0.5)
    raise TimeoutError(f"server did not become healthy at {url}: {last_error}")


def spawn_existing_home_server(tron_home, port):
    binary = ROOT / "packages/agent/target/dev-server/tron"
    env = os.environ.copy()
    env["TRON_DATA_DIR"] = str(tron_home)
    env.pop("TRON_RELAY_URL", None)
    env.pop("TRON_RELAY_SECRET", None)
    env.pop("TRON_RELAY_ENVIRONMENT", None)
    proc = subprocess.Popen(
        [
            str(binary),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--quiet",
            "--log-level",
            "info",
        ],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    atexit.register(lambda: n16.stop_isolated_server(proc))
    health_url = f"http://127.0.0.1:{port}/health"
    try:
        health = wait_health_url(health_url)
    except Exception:
        n16.stop_isolated_server(proc)
        raise
    n16.configure_runtime(
        Path(tron_home) / "internal/database/tron.sqlite",
        Path(tron_home) / "profiles/auth.json",
        f"ws://127.0.0.1:{port}/engine",
        health_url,
    )
    return proc, health


def stop_server_gracefully(proc):
    if proc is None:
        return {"returncode": None, "output": ""}
    return n16.stop_isolated_server(proc)


def kill_server(proc):
    if proc is None or proc.poll() is not None:
        return {"returncode": proc.returncode if proc else None, "output": ""}
    proc.send_signal(signal.SIGKILL)
    output = proc.communicate(timeout=10)[0] or ""
    return {"returncode": proc.returncode, "output": output[-8000:]}


def create_session(ws, stamp, label, title, model="claude-sonnet-4-6"):
    value, _ = child(invoke(
        ws,
        "session::create",
        {
            "workingDirectory": str(ROOT),
            "model": model,
            "title": title,
            "source": "chat",
            "profile": "chat",
            "useWorktree": False,
        },
        f"roc7-{label}-session-create-{stamp}",
        f"roc7-{label}-session-create-{stamp}",
        ["session.write"],
    ))
    return value["sessionId"]


def append_event(ws, session_id, event_type, payload, stamp, label):
    value, _ = child(invoke(
        ws,
        "events::append",
        {
            "sessionId": session_id,
            "type": event_type,
            "payload": payload,
        },
        f"roc7-{label}-{event_type}-{stamp}",
        f"roc7-{label}-{event_type}-{stamp}",
        ["events.write", "events.read", "session.read"],
        {"sessionId": session_id},
    ))
    return value["event"]


def reconstruct_page(ws, session_id, stamp, label, limit, before_event_id=None):
    payload = {"sessionId": session_id, "limit": limit}
    if before_event_id:
        payload["beforeEventId"] = before_event_id
    value, _ = child(invoke(
        ws,
        "session::reconstruct",
        payload,
        f"roc7-reconstruct-{label}-{stamp}-{before_event_id or 'tail'}",
        f"roc7-reconstruct-{label}-{stamp}-{before_event_id or 'tail'}",
        ["session.read", "events.read"],
        {"sessionId": session_id},
    ))
    return value


def reconstruct_all(ws, session_id, stamp, label, page_size=15):
    pages = []
    page = reconstruct_page(ws, session_id, stamp, label, page_size)
    pages.insert(0, page["events"])
    oldest = page.get("oldestEventId")
    while page.get("hasMoreEvents"):
        page = reconstruct_page(ws, session_id, stamp, label, page_size, oldest)
        pages.insert(0, page["events"])
        oldest = page.get("oldestEventId")
        if not oldest and page.get("hasMoreEvents"):
            raise RuntimeError("reconstruction page reported hasMoreEvents without oldestEventId")
    events = [event for page_events in pages for event in page_events]
    return {"events": events, "pages": len(pages), "lastPage": page}


def list_user_visible_sessions(ws, stamp, label):
    value, _ = child(invoke(
        ws,
        "session::list",
        {},
        f"roc7-session-list-{label}-{stamp}",
        f"roc7-session-list-{label}-{stamp}",
        ["session.read"],
    ))
    return value.get("sessions", [])


def db_event_rows(session_id):
    return db_json(
        "SELECT id, sequence, type, payload FROM events WHERE session_id = ? ORDER BY sequence",
        (session_id,),
    )


def validate_reconstruct_matches_db(ws, session_id, stamp, label, validations, page_size=15):
    reconstructed = reconstruct_all(ws, session_id, stamp, label, page_size)
    db_rows = db_event_rows(session_id)
    reconstructed_pairs = [(event["id"], event["type"]) for event in reconstructed["events"]]
    db_pairs = [(row["id"], row["type"]) for row in db_rows]
    validations.append({
        "name": f"{label}_reconstruct_event_ids_match_db_truth",
        "ok": reconstructed_pairs == db_pairs,
        "dbEventCount": len(db_pairs),
        "reconstructedEventCount": len(reconstructed_pairs),
        "pages": reconstructed["pages"],
        "firstMismatch": first_mismatch(db_pairs, reconstructed_pairs),
    })
    validations.append({
        "name": f"{label}_pagination_exercised",
        "ok": reconstructed["pages"] > 1,
        "pages": reconstructed["pages"],
        "pageSize": page_size,
    })
    return reconstructed


def first_mismatch(expected, actual):
    for index, (left, right) in enumerate(zip(expected, actual)):
        if left != right:
            return {"index": index, "expected": left, "actual": right}
    if len(expected) != len(actual):
        return {"expectedLength": len(expected), "actualLength": len(actual)}
    return None


def seed_long_session(ws, stamp):
    session_id = create_session(
        ws,
        stamp,
        "long",
        f"ROC-7 long reconstruction truth {stamp}",
    )
    for index in range(1, 31):
        append_event(
            ws,
            session_id,
            "message.user",
            {"content": f"ROC-7 long user {stamp} #{index:02d}"},
            stamp,
            f"long-user-{index:02d}",
        )
        append_event(
            ws,
            session_id,
            "message.assistant",
            {
                "content": [{"type": "text", "text": f"ROC-7 long assistant {stamp} #{index:02d}"}],
                "turn": index,
                "tokenUsage": {"inputTokens": 10 + index, "outputTokens": 5},
            },
            stamp,
            f"long-assistant-{index:02d}",
        )
        append_event(
            ws,
            session_id,
            "stream.turn_end",
            {
                "turn": index,
                "durationMs": 1,
                "stopReason": "end_turn",
                "tokenUsage": {"inputTokens": 10 + index, "outputTokens": 5},
            },
            stamp,
            f"long-turn-end-{index:02d}",
        )
    return session_id


def seed_boundary_session(ws, stamp):
    session_id = create_session(
        ws,
        stamp,
        "boundary",
        f"ROC-7 boundary reconstruction truth {stamp}",
    )
    raw_marker = f"ROC7_RAW_PRE_COMPACTION_SHOULD_NOT_SURVIVE_CONTEXT_{stamp}"
    summary = f"ROC-7 committed boundary summary {stamp}"
    append_event(ws, session_id, "message.user", {"content": raw_marker}, stamp, "boundary-old-user")
    append_event(
        ws,
        session_id,
        "message.assistant",
        {"content": [{"type": "text", "text": "old assistant"}], "turn": 1},
        stamp,
        "boundary-old-assistant",
    )
    append_event(
        ws,
        session_id,
        "compact.boundary",
        {
            "originalTokens": 4096,
            "compactedTokens": 256,
            "compressionRatio": 0.0625,
            "reason": "threshold_exceeded",
            "summary": summary,
            "estimatedContextTokens": 256,
            "preservedTurns": 1,
            "summarizedTurns": 1,
            "preservedMessages": 2,
        },
        stamp,
        "boundary-commit",
    )
    append_event(
        ws,
        session_id,
        "message.user",
        {"content": f"ROC-7 post-boundary user {stamp}"},
        stamp,
        "boundary-new-user",
    )
    append_event(
        ws,
        session_id,
        "message.assistant",
        {"content": [{"type": "text", "text": f"ROC-7 post-boundary assistant {stamp}"}], "turn": 2},
        stamp,
        "boundary-new-assistant",
    )
    return session_id, raw_marker, summary


def context_snapshot(ws, session_id, stamp, label):
    value, _ = child(invoke(
        ws,
        "context::get_detailed_snapshot",
        {"sessionId": session_id},
        f"roc7-context-snapshot-{label}-{stamp}",
        f"roc7-context-snapshot-{label}-{stamp}",
        ["context.read", "session.read"],
        {"sessionId": session_id},
    ))
    return value


def snapshot_text(snapshot):
    return json.dumps(snapshot.get("messages", []), sort_keys=True)


def update_compaction_settings(ws, stamp):
    value, _ = child(invoke(
        ws,
        "settings::update",
        {
            "settings": {
                "context": {
                    "compactor": {
                        "triggerTokenThreshold": 0.0,
                        "preserveRecentCount": 1,
                    }
                }
            }
        },
        f"roc7-settings-update-{stamp}",
        f"roc7-settings-update-{stamp}",
        ["settings.write", "settings.read"],
        timeout=60,
    ))
    settings, _ = child(invoke(
        ws,
        "settings::get",
        {},
        f"roc7-settings-get-{stamp}",
        f"roc7-settings-get-{stamp}",
        ["settings.read"],
        timeout=60,
    ))
    return {"update": value, "settings": settings.get("settings", settings)}


def send_agent_prompt(ws, session_id, prompt, stamp, label, timeout=240):
    before = latest_event_sequence(session_id)
    value, child_record = child(invoke(
        ws,
        "agent::prompt",
        {"sessionId": session_id, "prompt": prompt, "source": "chat"},
        f"roc7-agent-prompt-{label}-{stamp}",
        f"roc7-agent-prompt-{label}-{stamp}",
        ["session.write", "session.read", "agent.read", "agent.write"],
        {"sessionId": session_id},
        timeout=60,
    ))
    terminal = wait_end_turn_after(session_id, before, timeout_seconds=timeout)
    return {"beforeSequence": before, "response": value, "child": child_record, "terminal": terminal}


def run_live_compaction(ws, stamp):
    session_id = create_session(
        ws,
        stamp,
        "live-compact",
        f"ROC-7 live compaction {stamp}",
    )
    large_payload = " ".join([f"roc7-first-block-{stamp}-{i:04d}" for i in range(900)])
    prompts = [
        (
            "first",
            f"Reply with exactly `ROC-7 first acknowledged {stamp}`. "
            f"Retain this long first-turn payload only as context: {large_payload}",
        ),
        (
            "second",
            f"Reply with exactly `ROC-7 second acknowledged {stamp}`.",
        ),
        (
            "third",
            f"Reply with exactly `ROC-7 third acknowledged after compaction {stamp}`.",
        ),
    ]
    results = []
    for label, prompt in prompts:
        results.append(send_agent_prompt(ws, session_id, prompt, stamp, label))
    compact_rows = db_json(
        """
        SELECT id, sequence, type, payload
        FROM events
        WHERE session_id = ? AND type LIKE 'compact.%'
        ORDER BY sequence
        """,
        (session_id,),
    )
    return {"sessionId": session_id, "prompts": results, "compactRows": compact_rows}


def run_mid_turn_restart(proc, server_info, stamp):
    ws, _ = n16.ws_hello(f"roc7-midturn-hello-{stamp}")
    session_id = create_session(
        ws,
        stamp,
        "midturn",
        f"ROC-7 restart mid-turn {stamp}",
    )
    before = latest_event_sequence(session_id)
    long_prompt = " ".join([f"roc7-midturn-{stamp}-{i:04d}" for i in range(1200)])
    response = invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": session_id,
            "prompt": (
                f"ROC-7 restart mid-turn {stamp}. Reply with a concise acknowledgement. "
                f"Context payload: {long_prompt}"
            ),
            "source": "chat",
        },
        f"roc7-agent-prompt-midturn-{stamp}",
        f"roc7-agent-prompt-midturn-{stamp}",
        ["session.write", "session.read", "agent.read", "agent.write"],
        {"sessionId": session_id},
        timeout=60,
    )
    child(response)
    turn_start = wait_for_event_type_after(session_id, "stream.turn_start", before, timeout_seconds=60)
    kill_result = kill_server(proc)
    ws.close()
    restarted_proc, health = spawn_existing_home_server(Path(server_info["tronHome"]), server_info["port"])
    ws_after, _ = n16.ws_hello(f"roc7-midturn-after-restart-{stamp}", session_id=session_id)
    reconstructed = reconstruct_page(ws_after, session_id, stamp, "midturn-after-restart", 50)
    ws_after.close()
    terminal_after_start = db_scalar(
        """
        SELECT count(*) FROM events
        WHERE session_id = ? AND sequence > ? AND type = 'stream.turn_end'
        """,
        (session_id, turn_start["sequence"]),
    )
    return {
        "sessionId": session_id,
        "turnStart": turn_start,
        "kill": kill_result,
        "restartHealth": health,
        "reconstructAfterRestart": {
            "eventCount": len(reconstructed["events"]),
            "isRunning": reconstructed["isRunning"],
            "agentPhase": reconstructed["agentPhase"],
            "lastSequence": reconstructed["lastSequence"],
        },
        "terminalEventsAfterKilledTurnStart": terminal_after_start,
        "process": restarted_proc,
    }


def collect_validation(ws, stamp, sessions, server_restart_snapshot=None, midturn=None):
    validations = []
    empty_draft_id = sessions["emptyDraft"]
    empty_draft_row = db_json(
        """
        SELECT source, profile, event_count, message_count, turn_count,
               total_input_tokens, total_output_tokens
        FROM sessions
        WHERE id = ?
        """,
        (empty_draft_id,),
    )
    visible_sessions = list_user_visible_sessions(ws, stamp, "empty-chat-draft")
    visible_ids = {session.get("sessionId") for session in visible_sessions if session.get("sessionId")}
    draft_reconstruct = reconstruct_page(ws, empty_draft_id, stamp, "empty-chat-draft", 5)
    validations.append({
        "name": "empty_chat_draft_is_not_user_visible",
        "ok": empty_draft_row
        and empty_draft_row[0]["source"] == "chat"
        and empty_draft_row[0]["profile"] == "chat"
        and empty_draft_row[0]["message_count"] == 0
        and empty_draft_row[0]["turn_count"] == 0
        and empty_draft_row[0]["event_count"] <= 1
        and empty_draft_id not in visible_ids,
        "draftRow": empty_draft_row[0] if empty_draft_row else None,
        "visibleSessionIds": sorted(visible_ids),
    })
    validations.append({
        "name": "empty_chat_draft_remains_directly_reconstructable",
        "ok": len(draft_reconstruct["events"]) == 1
        and draft_reconstruct["events"][0]["type"] == "session.start",
        "eventTypes": [event["type"] for event in draft_reconstruct["events"]],
    })
    validate_reconstruct_matches_db(ws, sessions["long"], stamp, "long", validations, page_size=17)

    boundary_snapshot = context_snapshot(ws, sessions["boundary"], stamp, "boundary")
    boundary_text = snapshot_text(boundary_snapshot)
    validations.append({
        "name": "boundary_context_reconstruction_uses_committed_summary",
        "ok": sessions["boundarySummary"] in boundary_text
        and sessions["boundaryRawMarker"] not in boundary_text,
        "summaryPresent": sessions["boundarySummary"] in boundary_text,
        "rawMarkerPresent": sessions["boundaryRawMarker"] in boundary_text,
    })
    validate_reconstruct_matches_db(ws, sessions["boundary"], stamp, "boundary", validations, page_size=3)

    live_compact_rows = sessions["liveCompaction"]["compactRows"]
    compact_types = [row["type"] for row in live_compact_rows]
    boundary_payloads = [
        json.loads(row["payload"] or "{}")
        for row in live_compact_rows
        if row["type"] == "compact.boundary"
    ]
    validations.append({
        "name": "live_compaction_committed_exactly_one_staging_and_boundary",
        "ok": compact_types == ["compact.summary_staging", "compact.boundary"],
        "compactTypes": compact_types,
    })
    validations.append({
        "name": "live_compaction_boundary_has_summary_and_no_compact_summary_event",
        "ok": len(boundary_payloads) == 1
        and bool(boundary_payloads[0].get("summary"))
        and "compact.summary" not in compact_types,
        "boundaryPayload": boundary_payloads[0] if boundary_payloads else None,
    })
    live_snapshot = context_snapshot(ws, sessions["liveCompaction"]["sessionId"], stamp, "live-compaction")
    live_text = snapshot_text(live_snapshot)
    raw_tail_marker = f"roc7-first-block-{stamp}-0899"
    validations.append({
        "name": "live_compaction_context_snapshot_uses_boundary_summary",
        "ok": "[Context from earlier in this conversation]" in live_text
        and raw_tail_marker not in live_text,
        "prefixPresent": "[Context from earlier in this conversation]" in live_text,
        "rawFirstPayloadTailPresent": raw_tail_marker in live_text,
    })
    validate_reconstruct_matches_db(
        ws,
        sessions["liveCompaction"]["sessionId"],
        stamp,
        "live-compaction",
        validations,
        page_size=10,
    )

    if server_restart_snapshot:
        restart_text = snapshot_text(server_restart_snapshot)
        validations.append({
            "name": "post_restart_context_still_uses_boundary_summary",
            "ok": "[Context from earlier in this conversation]" in restart_text
            and raw_tail_marker not in restart_text,
            "prefixPresent": "[Context from earlier in this conversation]" in restart_text,
            "rawFirstPayloadTailPresent": raw_tail_marker in restart_text,
        })

    if midturn:
        validations.append({
            "name": "mid_turn_restart_interrupted_before_terminal_event",
            "ok": midturn["terminalEventsAfterKilledTurnStart"] == 0,
            "terminalEventsAfterKilledTurnStart": midturn["terminalEventsAfterKilledTurnStart"],
        })
        validations.append({
            "name": "mid_turn_restart_reopens_idle_without_synthetic_running_state",
            "ok": midturn["reconstructAfterRestart"]["isRunning"] is False
            and midturn["reconstructAfterRestart"]["agentPhase"] == "idle",
            "reconstructAfterRestart": midturn["reconstructAfterRestart"],
        })
        validations.append({
            "name": "mid_turn_restart_did_not_emit_unexpected_compaction",
            "ok": db_scalar(
                "SELECT count(*) FROM events WHERE session_id = ? AND type LIKE 'compact.%'",
                (midturn["sessionId"],),
            )
            == 0,
        })

    validations.append({
        "name": "no_open_engine_queues_after_roc7",
        "ok": db_scalar(
            """
            SELECT count(*) FROM engine_queue_items
            WHERE status NOT IN ('completed', 'cancelled', 'dead_lettered')
            """,
        )
        == 0,
    })
    validations.append({
        "name": "no_unexpected_failed_roc7_invocations",
        "ok": db_scalar(
            """
            SELECT count(*) FROM engine_invocations
            WHERE idempotency_key LIKE 'roc7-%' AND succeeded = 0
            """,
        )
        == 0,
    })
    validations.append({
        "name": "no_error_or_fatal_logs",
        "ok": db_scalar(
            "SELECT count(*) FROM logs WHERE lower(level) IN ('error', 'fatal')",
        )
        == 0,
    })
    return validations


def run_matrix(args):
    stamp = args.stamp or dt.datetime.now(dt.UTC).strftime("%Y%m%d%H%M%S")
    if args.use_current_server:
        raise RuntimeError(
            "ROC-7 restart validation requires a disposable isolated server; omit --use-current-server"
        )
    server = n16.maybe_start_isolated_server(args, stamp, "roc7")
    server_mode = "current" if args.use_current_server else "isolated"
    proc = server.pop("process") if server else None
    midturn_result = None
    restarted_proc = None
    try:
        ws, hello = n16.ws_hello(f"roc7-hello-{stamp}")
        settings_result = update_compaction_settings(ws, stamp)
        empty_draft_session = create_session(
            ws,
            stamp,
            "empty-draft",
            f"ROC-7 empty chat draft {stamp}",
        )
        long_session = seed_long_session(ws, stamp)
        boundary_session, boundary_raw, boundary_summary = seed_boundary_session(ws, stamp)
        live_compaction = run_live_compaction(ws, stamp)
        pre_restart_snapshot = context_snapshot(ws, live_compaction["sessionId"], stamp, "pre-restart")
        ws.close()

        stop_result = stop_server_gracefully(proc)
        proc = None
        restarted_proc, restart_health = spawn_existing_home_server(
            Path(server["tronHome"]) if server else Path(os.environ["TRON_DATA_DIR"]),
            server["port"] if server else 9847,
        )
        ws_after, _ = n16.ws_hello(f"roc7-after-restart-{stamp}")
        post_restart_snapshot = context_snapshot(
            ws_after,
            live_compaction["sessionId"],
            stamp,
            "post-restart",
        )
        ws_after.close()

        midturn_result = run_mid_turn_restart(restarted_proc, server, stamp)
        restarted_proc = midturn_result.pop("process")
        ws_final, _ = n16.ws_hello(f"roc7-final-{stamp}")
        sessions = {
            "long": long_session,
            "emptyDraft": empty_draft_session,
            "boundary": boundary_session,
            "boundaryRawMarker": boundary_raw,
            "boundarySummary": boundary_summary,
            "liveCompaction": live_compaction,
        }
        validations = collect_validation(
            ws_final,
            stamp,
            sessions,
            server_restart_snapshot=post_restart_snapshot,
            midturn=midturn_result,
        )
        ws_final.close()

        screenshot = n16.simulator_evidence(
            args.sim_udid,
            live_compaction["sessionId"],
            f"/tmp/roc7_long_running_{stamp}_iphone.png",
            args.simulator_delay,
            args.open_session_in_simulator,
            boot=args.boot_simulator,
        )

        result = {
            "scenario": "ROC-7",
            "stamp": stamp,
            "serverMode": server_mode,
            "server": n16.public_server_info(server) if server else None,
            "hello": hello,
            "settings": settings_result,
            "sessions": {
                "long": long_session,
                "emptyDraft": empty_draft_session,
                "boundary": boundary_session,
                "liveCompaction": live_compaction["sessionId"],
                "midTurnRestart": midturn_result["sessionId"],
            },
            "liveCompaction": {
                "compactRows": live_compaction["compactRows"],
                "preRestartMessageCount": len(pre_restart_snapshot.get("messages", [])),
                "restart": {"stop": stop_result, "health": restart_health},
            },
            "midTurnRestart": midturn_result,
            "simulator": screenshot,
            "validations": validations,
            "validationFailures": [item for item in validations if not item["ok"]],
        }
        out = Path(f"/tmp/roc7_long_running_compaction_{stamp}.json")
        out.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
        result["outputPath"] = str(out)
        print(json.dumps(result, indent=2, sort_keys=True))
        if result["validationFailures"]:
            return 1
        return 0
    finally:
        if restarted_proc is not None:
            n16.stop_isolated_server(restarted_proc)
        if proc is not None:
            n16.stop_isolated_server(proc)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    n16.add_runtime_args(parser)
    parser.add_argument("--stamp", default=None)
    parser.add_argument("--sim-udid", default=DEFAULT_SIM_UDID)
    parser.add_argument("--simulator-delay", type=float, default=4.0)
    parser.add_argument("--open-session-in-simulator", action="store_true")
    parser.add_argument("--boot-simulator", action="store_true")
    return parser.parse_args()


def main():
    raise SystemExit(run_matrix(parse_args()))


if __name__ == "__main__":
    main()
