#!/usr/bin/env python3
"""DB-backed terminal-state guard for simulator and live-session harnesses."""

import argparse
import json
import os
import sqlite3
import sys
import time
from dataclasses import dataclass

DEFAULT_DB_PATH = os.path.expanduser("~/.tron/internal/database/tron.sqlite")
TERMINAL_STOP_REASON = "end_turn"
TERMINAL_QUEUE_STATUSES = ("completed", "cancelled", "dead_lettered")


@dataclass(frozen=True)
class TerminalState:
    terminal: bool
    reason: str
    terminal_sequence: int | None = None
    latest_sequence: int | None = None
    pending_approvals: int = 0
    open_queue_items: int = 0

    def to_json(self):
        return {
            "terminal": self.terminal,
            "reason": self.reason,
            "terminalSequence": self.terminal_sequence,
            "latestSequence": self.latest_sequence,
            "pendingApprovals": self.pending_approvals,
            "openQueueItems": self.open_queue_items,
        }


def _payload_stop_reason(payload):
    if not payload:
        return None
    try:
        value = json.loads(payload)
    except json.JSONDecodeError:
        return None
    stop_reason = value.get("stopReason")
    return stop_reason if isinstance(stop_reason, str) else None


def event_stop_reason(event):
    return event.get("stop_reason") or _payload_stop_reason(event.get("payload"))


def evaluate_terminal_state(events, pending_approvals=0, open_queue_items=0):
    latest_sequence = max((event["sequence"] for event in events), default=None)
    terminal_turns = [
        event
        for event in events
        if event.get("type") == "stream.turn_end"
        and event_stop_reason(event) == TERMINAL_STOP_REASON
    ]
    if not terminal_turns:
        return TerminalState(
            terminal=False,
            reason="no_end_turn",
            latest_sequence=latest_sequence,
            pending_approvals=pending_approvals,
            open_queue_items=open_queue_items,
        )
    terminal_event = max(terminal_turns, key=lambda event: event["sequence"])
    terminal_sequence = terminal_event["sequence"]
    later_turn_start = any(
        event.get("type") == "stream.turn_start"
        and event["sequence"] > terminal_sequence
        for event in events
    )
    if later_turn_start:
        return TerminalState(
            terminal=False,
            reason="later_turn_start",
            terminal_sequence=terminal_sequence,
            latest_sequence=latest_sequence,
            pending_approvals=pending_approvals,
            open_queue_items=open_queue_items,
        )
    if pending_approvals:
        return TerminalState(
            terminal=False,
            reason="pending_approvals",
            terminal_sequence=terminal_sequence,
            latest_sequence=latest_sequence,
            pending_approvals=pending_approvals,
            open_queue_items=open_queue_items,
        )
    if open_queue_items:
        return TerminalState(
            terminal=False,
            reason="open_queue_items",
            terminal_sequence=terminal_sequence,
            latest_sequence=latest_sequence,
            pending_approvals=pending_approvals,
            open_queue_items=open_queue_items,
        )
    return TerminalState(
        terminal=True,
        reason="end_turn_stable",
        terminal_sequence=terminal_sequence,
        latest_sequence=latest_sequence,
        pending_approvals=pending_approvals,
        open_queue_items=open_queue_items,
    )


def _fetch_events(conn, session_id, max_sequence=None):
    params = [session_id]
    sequence_filter = ""
    if max_sequence is not None:
        sequence_filter = " AND sequence <= ?"
        params.append(max_sequence)
    rows = conn.execute(
        f"""
        SELECT sequence, type, stop_reason, payload
        FROM events
        WHERE session_id = ?{sequence_filter}
        ORDER BY sequence
        """,
        params,
    ).fetchall()
    return [
        {
            "sequence": row[0],
            "type": row[1],
            "stop_reason": row[2],
            "payload": row[3],
        }
        for row in rows
    ]


def _pending_approvals(conn, session_id):
    return conn.execute(
        """
        SELECT COUNT(*)
        FROM engine_approvals
        WHERE session_id = ? AND status = 'pending'
        """,
        (session_id,),
    ).fetchone()[0]


def _open_queue_items(conn, session_id):
    terminal_statuses = ", ".join("?" for _ in TERMINAL_QUEUE_STATUSES)
    return conn.execute(
        f"""
        SELECT COUNT(*)
        FROM engine_queue_items
        WHERE session_id = ?
          AND status NOT IN ({terminal_statuses})
        """,
        (session_id, *TERMINAL_QUEUE_STATUSES),
    ).fetchone()[0]


def _row_counts(conn, session_id):
    return {
        "events": conn.execute(
            "SELECT COUNT(*) FROM events WHERE session_id = ?", (session_id,)
        ).fetchone()[0],
        "invocations": conn.execute(
            "SELECT COUNT(*) FROM engine_invocations WHERE session_id = ?",
            (session_id,),
        ).fetchone()[0],
        "approvals": conn.execute(
            "SELECT COUNT(*) FROM engine_approvals WHERE session_id = ?",
            (session_id,),
        ).fetchone()[0],
        "resources": conn.execute(
            """
            SELECT COUNT(*)
            FROM engine_resources
            WHERE scope_kind = 'session' AND scope_value = ?
            """,
            (session_id,),
        ).fetchone()[0],
        "resourceVersions": conn.execute(
            """
            SELECT COUNT(*)
            FROM engine_resource_versions v
            JOIN engine_resources r ON r.resource_id = v.resource_id
            WHERE r.scope_kind = 'session' AND r.scope_value = ?
            """,
            (session_id,),
        ).fetchone()[0],
        "queues": conn.execute(
            "SELECT COUNT(*) FROM engine_queue_items WHERE session_id = ?",
            (session_id,),
        ).fetchone()[0],
        "streams": conn.execute(
            "SELECT COUNT(*) FROM engine_stream_events WHERE session_id = ?",
            (session_id,),
        ).fetchone()[0],
        "logs": conn.execute(
            "SELECT COUNT(*) FROM logs WHERE session_id = ?", (session_id,)
        ).fetchone()[0],
    }


def evaluate_db_session(db_path, session_id, max_sequence=None):
    conn = sqlite3.connect(db_path)
    try:
        return evaluate_terminal_state(
            _fetch_events(conn, session_id, max_sequence=max_sequence),
            pending_approvals=_pending_approvals(conn, session_id),
            open_queue_items=_open_queue_items(conn, session_id),
        )
    finally:
        conn.close()


def wait_for_terminal(db_path, session_id, timeout_seconds, interval_seconds):
    deadline = time.monotonic() + timeout_seconds
    previous_counts = None
    latest_state = None
    while True:
        conn = sqlite3.connect(db_path)
        try:
            events = _fetch_events(conn, session_id)
            state = evaluate_terminal_state(
                events,
                pending_approvals=_pending_approvals(conn, session_id),
                open_queue_items=_open_queue_items(conn, session_id),
            )
            counts = _row_counts(conn, session_id)
        finally:
            conn.close()
        if state.terminal and previous_counts == counts:
            return state
        latest_state = state
        if time.monotonic() >= deadline:
            return TerminalState(
                terminal=False,
                reason=f"timeout:{latest_state.reason if latest_state else 'no_snapshot'}",
                terminal_sequence=latest_state.terminal_sequence if latest_state else None,
                latest_sequence=latest_state.latest_sequence if latest_state else None,
                pending_approvals=latest_state.pending_approvals if latest_state else 0,
                open_queue_items=latest_state.open_queue_items if latest_state else 0,
            )
        previous_counts = counts
        time.sleep(interval_seconds)


def self_test():
    tool_use_only = [
        {"sequence": 1, "type": "stream.turn_start", "stop_reason": None, "payload": "{}"},
        {
            "sequence": 2,
            "type": "stream.turn_end",
            "stop_reason": "tool_use",
            "payload": '{"stopReason":"tool_use"}',
        },
    ]
    assert evaluate_terminal_state(tool_use_only).terminal is False
    assert evaluate_terminal_state(tool_use_only).reason == "no_end_turn"

    end_turn = tool_use_only + [
        {
            "sequence": 3,
            "type": "stream.turn_end",
            "stop_reason": None,
            "payload": '{"stopReason":"end_turn"}',
        }
    ]
    assert evaluate_terminal_state(end_turn).terminal is True

    later_turn = end_turn + [
        {"sequence": 4, "type": "stream.turn_start", "stop_reason": None, "payload": "{}"}
    ]
    assert evaluate_terminal_state(later_turn).reason == "later_turn_start"
    assert evaluate_terminal_state(end_turn, pending_approvals=1).reason == "pending_approvals"
    assert evaluate_terminal_state(end_turn, open_queue_items=1).reason == "open_queue_items"
    assert "dead_lettered" in TERMINAL_QUEUE_STATUSES


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=DEFAULT_DB_PATH)
    parser.add_argument("--session-id")
    parser.add_argument("--max-sequence", type=int)
    parser.add_argument("--wait", action="store_true")
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--interval-seconds", type=float, default=1.0)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    if args.self_test:
        self_test()
        print(json.dumps({"ok": True}))
        return 0
    if not args.session_id:
        raise SystemExit("--session-id is required unless --self-test is used")
    if args.wait:
        state = wait_for_terminal(
            args.db,
            args.session_id,
            args.timeout_seconds,
            args.interval_seconds,
        )
    else:
        state = evaluate_db_session(
            args.db,
            args.session_id,
            max_sequence=args.max_sequence,
        )
    print(json.dumps(state.to_json(), sort_keys=True))
    return 0 if state.terminal else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
