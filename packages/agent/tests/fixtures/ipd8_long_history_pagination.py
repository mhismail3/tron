#!/usr/bin/env python3
"""Seed an IPD-8 long-history session through canonical engine APIs."""

import argparse
import datetime as dt
import json
import sqlite3
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rwo_n16_live_agent_harness as harness

ROOT = harness.ROOT
DEFAULT_OUTPUT = Path("/tmp/tron-psg-evidence/ipd8-long-history-pagination.json")


def wait_health(url, timeout_seconds=30):
    deadline = time.monotonic() + timeout_seconds
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


def child_value(response):
    if not response.get("ok"):
        raise RuntimeError(response)
    child = response["result"]["child"]
    if child.get("error"):
        raise RuntimeError(child["error"])
    return child["value"], child


def invoke(ws, function_id, payload, request_id, idempotency_key, scopes, session_id=None):
    context = {
        "authorityScopes": scopes,
        "runtimeMetadata": {"scenario": "IPD-8", "harness": "long-history-pagination"},
    }
    if session_id:
        context["sessionId"] = session_id
    return harness.invoke(
        ws,
        function_id,
        payload,
        request_id,
        idempotency_key,
        context,
        timeout=60,
    )


def create_session(ws, stamp, model, title):
    value, child = child_value(
        invoke(
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
            f"ipd8-pagination-create-{stamp}",
            f"ipd8-pagination-create-{stamp}",
            ["session.write"],
        )
    )
    return value["sessionId"], child


def append_event(ws, session_id, event_type, payload, stamp, index):
    value, child = child_value(
        invoke(
            ws,
            "events::append",
            {
                "sessionId": session_id,
                "type": event_type,
                "payload": payload,
            },
            f"ipd8-pagination-append-{index:03d}-{stamp}",
            f"ipd8-pagination-append-{index:03d}-{stamp}",
            ["events.write", "events.read", "session.read"],
            session_id=session_id,
        )
    )
    return value["event"], child


def reconstruct(ws, session_id, stamp, limit, before_event_id=None):
    payload = {"sessionId": session_id, "limit": limit}
    if before_event_id:
        payload["beforeEventId"] = before_event_id
    value, child = child_value(
        invoke(
            ws,
            "session::reconstruct",
            payload,
            f"ipd8-pagination-reconstruct-{stamp}-{before_event_id or 'tail'}",
            f"ipd8-pagination-reconstruct-{stamp}-{before_event_id or 'tail'}",
            ["session.read", "events.read"],
            session_id=session_id,
        )
    )
    return value, child


def db_rows(query, params=()):
    with sqlite3.connect(harness.DB_PATH, timeout=10) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, params)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pairs", type=int, default=120)
    parser.add_argument("--model", default="gemma4:e4b")
    parser.add_argument("--title-prefix", default="IPD-8 long history pagination")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    if args.pairs < 51:
        raise SystemExit("--pairs must be at least 51 so the 100-message initial window has older history")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%d%H%M%S")
    title = f"{args.title_prefix} {stamp}"
    health = wait_health(harness.HEALTH)
    ws, hello = harness.ws_hello(f"ipd8-pagination-hello-{stamp}")
    created_children = []

    try:
        session_id, create_child = create_session(ws, stamp, args.model, title)
        created_children.append(create_child.get("id"))

        append_count = 0
        for turn in range(1, args.pairs + 1):
            user_event, child = append_event(
                ws,
                session_id,
                "message.user",
                {
                    "content": f"IPD-8 pagination user {turn:03d}",
                    "turn": turn,
                },
                stamp,
                append_count,
            )
            created_children.append(child.get("id"))
            append_count += 1

            assistant_event, child = append_event(
                ws,
                session_id,
                "message.assistant",
                {
                    "content": [
                        {
                            "type": "text",
                            "text": f"IPD-8 pagination assistant {turn:03d}",
                        }
                    ],
                    "turn": turn,
                    "stopReason": "end_turn",
                    "model": args.model,
                },
                stamp,
                append_count,
            )
            created_children.append(child.get("id"))
            append_count += 1

        initial_page, reconstruct_child = reconstruct(ws, session_id, stamp, 100)
        created_children.append(reconstruct_child.get("id"))

        session_rows = db_rows(
            """
            SELECT id, title, message_count, event_count, turn_count, latest_model, working_directory
            FROM sessions
            WHERE id = ?
            """,
            (session_id,),
        )
        type_counts = db_rows(
            """
            SELECT type, COUNT(*) AS count
            FROM events
            WHERE session_id = ?
            GROUP BY type
            ORDER BY type
            """,
            (session_id,),
        )

        evidence = {
            "createdAt": dt.datetime.now(dt.UTC).isoformat(),
            "health": health,
            "helloType": hello.get("type"),
            "server": harness.SERVER,
            "dbPath": harness.DB_PATH,
            "sessionId": session_id,
            "title": title,
            "model": args.model,
            "pairs": args.pairs,
            "appendedEvents": append_count,
            "lastAssistantEventId": assistant_event.get("id"),
            "initialReconstruct": {
                "eventCount": len(initial_page.get("events", [])),
                "hasMoreEvents": initial_page.get("hasMoreEvents"),
                "oldestEventId": initial_page.get("oldestEventId"),
                "lastSequence": initial_page.get("lastSequence"),
            },
            "sessionRows": session_rows,
            "eventTypeCounts": type_counts,
            "engineChildInvocationIds": created_children,
            "openUrl": f"tron://session/{session_id}",
        }
        args.output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"sessionId": session_id, "output": str(args.output), "openUrl": evidence["openUrl"]}))
    finally:
        ws.close()


if __name__ == "__main__":
    main()
