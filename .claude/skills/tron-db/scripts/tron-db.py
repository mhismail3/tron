#!/usr/bin/env python3
"""
Tron Database CLI - Debug Tron agent sessions, events, and logs.

Usage:
    tron-db.py <command> [options]

Commands:
    sessions    List recent sessions
    session     Get session details
    events      Get events for a session
    messages    Get messages (user/assistant) for a session
    tools       Get tool executions for a session
    errors      Find errors in a session
    logs        Get logs for a session
    tokens      Token usage analysis
    turn        Get events for a specific turn
    search      Full-text search events or logs
    stats       Database statistics

Environment:
    TRON_DB - Path to database (default: ~/.tron/events.db or events-beta.db)
"""

import os
import sys
import json
import sqlite3
import argparse
from pathlib import Path
from datetime import datetime, timedelta


def get_db_path():
    """Find the Tron database."""
    if os.environ.get("TRON_DB"):
        return os.environ["TRON_DB"]

    tron_dir = Path.home() / ".tron"
    for db_name in ["events.db", "events-beta.db"]:
        db_path = tron_dir / db_name
        if db_path.exists():
            return str(db_path)

    print("Error: No Tron database found at ~/.tron/events.db or events-beta.db", file=sys.stderr)
    print("Set TRON_DB environment variable to specify database path", file=sys.stderr)
    sys.exit(1)


def get_connection():
    """Get database connection."""
    db_path = get_db_path()
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def format_timestamp(ts):
    """Format ISO timestamp to readable format."""
    if not ts:
        return "-"
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except:
        return ts[:19] if ts else "-"


def format_tokens(n):
    """Format token count with K/M suffix."""
    if n is None:
        return "-"
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)


def format_cost(cost):
    """Format cost in USD."""
    if cost is None or cost == 0:
        return "-"
    return f"${cost:.4f}"


def truncate(s, max_len=80):
    """Truncate string with ellipsis."""
    if not s:
        return ""
    s = str(s).replace("\n", " ").strip()
    if len(s) <= max_len:
        return s
    return s[:max_len-3] + "..."


def print_table(rows, headers, widths=None):
    """Print formatted table."""
    if not rows:
        print("No results found.")
        return

    # Calculate widths
    if widths is None:
        widths = [len(h) for h in headers]
        for row in rows:
            for i, val in enumerate(row):
                widths[i] = max(widths[i], len(str(val or "")))

    # Print header
    header_line = " | ".join(h.ljust(widths[i]) for i, h in enumerate(headers))
    print(header_line)
    print("-" * len(header_line))

    # Print rows
    for row in rows:
        print(" | ".join(str(val or "").ljust(widths[i]) for i, val in enumerate(row)))


def output_json(data):
    """Output data as JSON."""
    print(json.dumps(data, indent=2, default=str))


# === Commands ===

def cmd_sessions(args):
    """List recent sessions."""
    conn = get_connection()

    query = """
        SELECT
            id,
            title,
            created_at,
            last_activity_at,
            event_count,
            turn_count,
            total_input_tokens + total_output_tokens as total_tokens,
            total_cost
        FROM sessions
        ORDER BY last_activity_at DESC
        LIMIT ?
    """

    rows = conn.execute(query, (args.limit,)).fetchall()

    if args.json:
        output_json([dict(r) for r in rows])
        return

    table_rows = []
    for r in rows:
        table_rows.append([
            r["id"][:20] + "..." if len(r["id"]) > 20 else r["id"],
            truncate(r["title"], 30) or "(untitled)",
            format_timestamp(r["last_activity_at"]),
            r["event_count"] or 0,
            r["turn_count"] or 0,
            format_tokens(r["total_tokens"]),
            format_cost(r["total_cost"]),
        ])

    print_table(table_rows, ["Session ID", "Title", "Last Activity", "Events", "Turns", "Tokens", "Cost"])


def cmd_session(args):
    """Get session details."""
    conn = get_connection()

    query = """
        SELECT
            s.*,
            w.path as workspace_path,
            w.name as workspace_name
        FROM sessions s
        LEFT JOIN workspaces w ON s.workspace_id = w.id
        WHERE s.id = ? OR s.id LIKE ?
    """

    row = conn.execute(query, (args.session_id, f"{args.session_id}%")).fetchone()

    if not row:
        print(f"Session not found: {args.session_id}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        output_json(dict(row))
        return

    print(f"Session: {row['id']}")
    print(f"Title: {row['title'] or '(untitled)'}")
    print(f"Workspace: {row['workspace_path'] or '-'}")
    print(f"Model: {row['latest_model'] or '-'}")
    print()
    print(f"Created: {format_timestamp(row['created_at'])}")
    print(f"Last Activity: {format_timestamp(row['last_activity_at'])}")
    print(f"Ended: {format_timestamp(row['ended_at']) if row['ended_at'] else 'Active'}")
    print()
    print(f"Events: {row['event_count']}")
    print(f"Messages: {row['message_count']}")
    print(f"Turns: {row['turn_count']}")
    print()
    print(f"Input Tokens: {format_tokens(row['total_input_tokens'])}")
    print(f"Output Tokens: {format_tokens(row['total_output_tokens'])}")
    print(f"Cache Read: {format_tokens(row['total_cache_read_tokens'])}")
    print(f"Cache Creation: {format_tokens(row['total_cache_creation_tokens'])}")
    print(f"Total Cost: {format_cost(row['total_cost'])}")

    if row['parent_session_id']:
        print()
        print(f"Forked from: {row['parent_session_id']}")
        print(f"Fork event: {row['fork_from_event_id']}")


def cmd_events(args):
    """Get events for a session."""
    conn = get_connection()

    query = """
        SELECT
            id,
            sequence,
            type,
            timestamp,
            turn,
            tool_name,
            input_tokens,
            output_tokens,
            payload
        FROM events
        WHERE session_id = ? OR session_id LIKE ?
    """
    params = [args.session_id, f"{args.session_id}%"]

    if args.type:
        query += " AND type LIKE ?"
        params.append(f"%{args.type}%")

    if args.turn is not None:
        query += " AND turn = ?"
        params.append(args.turn)

    query += " ORDER BY sequence"

    if args.limit:
        query += " LIMIT ?"
        params.append(args.limit)

    rows = conn.execute(query, params).fetchall()

    if args.json:
        output_json([dict(r) for r in rows])
        return

    table_rows = []
    for r in rows:
        table_rows.append([
            r["sequence"],
            r["type"],
            r["turn"] if r["turn"] is not None else "-",
            r["tool_name"] or "-",
            format_tokens(r["input_tokens"]) if r["input_tokens"] else "-",
            format_tokens(r["output_tokens"]) if r["output_tokens"] else "-",
            format_timestamp(r["timestamp"]),
        ])

    print_table(table_rows, ["Seq", "Type", "Turn", "Tool", "In", "Out", "Time"])


def cmd_messages(args):
    """Get messages for a session."""
    conn = get_connection()

    query = """
        SELECT
            sequence,
            type,
            timestamp,
            turn,
            payload
        FROM events
        WHERE (session_id = ? OR session_id LIKE ?)
          AND type IN ('message.user', 'message.assistant')
        ORDER BY sequence
    """

    rows = conn.execute(query, (args.session_id, f"{args.session_id}%")).fetchall()

    if args.json:
        output_json([dict(r) for r in rows])
        return

    for r in rows:
        role = "USER" if r["type"] == "message.user" else "ASSISTANT"
        print(f"--- [{r['sequence']}] {role} (turn {r['turn'] or '-'}) ---")

        try:
            payload = json.loads(r["payload"]) if r["payload"] else {}
            content = payload.get("content", "")
            if isinstance(content, list):
                # Handle content blocks
                for block in content:
                    if isinstance(block, dict):
                        if block.get("type") == "text":
                            print(block.get("text", ""))
                        elif block.get("type") == "tool_use":
                            print(f"[Tool: {block.get('name')}]")
                    else:
                        print(block)
            else:
                print(content if not args.truncate else truncate(content, 500))
        except:
            print(truncate(r["payload"], 500) if args.truncate else r["payload"])
        print()


def cmd_tools(args):
    """Get tool executions for a session."""
    conn = get_connection()

    query = """
        SELECT
            sequence,
            type,
            timestamp,
            turn,
            tool_name,
            tool_call_id,
            payload
        FROM events
        WHERE (session_id = ? OR session_id LIKE ?)
          AND type LIKE 'tool_execution%'
        ORDER BY sequence
    """

    rows = conn.execute(query, (args.session_id, f"{args.session_id}%")).fetchall()

    if args.json:
        output_json([dict(r) for r in rows])
        return

    table_rows = []
    for r in rows:
        try:
            payload = json.loads(r["payload"]) if r["payload"] else {}
            status = payload.get("status", "-")
            error = payload.get("error", {})
            error_msg = error.get("message", "") if isinstance(error, dict) else str(error) if error else ""
        except:
            status = "-"
            error_msg = ""

        event_type = r["type"].replace("tool_execution_", "")
        table_rows.append([
            r["sequence"],
            r["tool_name"] or "-",
            event_type,
            status if event_type == "end" else "-",
            truncate(error_msg, 40) or "-",
            format_timestamp(r["timestamp"]),
        ])

    print_table(table_rows, ["Seq", "Tool", "Event", "Status", "Error", "Time"])


def cmd_errors(args):
    """Find errors in a session."""
    conn = get_connection()

    # Event errors
    event_query = """
        SELECT
            'event' as source,
            sequence,
            type,
            timestamp,
            payload
        FROM events
        WHERE (session_id = ? OR session_id LIKE ?)
          AND (type = 'error' OR type = 'api_retry' OR payload LIKE '%"error"%')
        ORDER BY sequence
    """

    # Log errors
    log_query = """
        SELECT
            'log' as source,
            id as sequence,
            level as type,
            timestamp,
            message || COALESCE(': ' || error_message, '') as payload
        FROM logs
        WHERE (session_id = ? OR session_id LIKE ?)
          AND level_num >= 50
        ORDER BY timestamp
    """

    event_rows = conn.execute(event_query, (args.session_id, f"{args.session_id}%")).fetchall()
    log_rows = conn.execute(log_query, (args.session_id, f"{args.session_id}%")).fetchall()

    if args.json:
        output_json({
            "events": [dict(r) for r in event_rows],
            "logs": [dict(r) for r in log_rows]
        })
        return

    if not event_rows and not log_rows:
        print("No errors found.")
        return

    if event_rows:
        print("=== Event Errors ===")
        for r in event_rows:
            print(f"[{r['sequence']}] {r['type']} at {format_timestamp(r['timestamp'])}")
            try:
                payload = json.loads(r["payload"]) if r["payload"] else {}
                error = payload.get("error", {})
                if error:
                    print(f"  Message: {error.get('message', str(error))}")
                    if error.get("code"):
                        print(f"  Code: {error.get('code')}")
            except:
                print(f"  {truncate(r['payload'], 200)}")
            print()

    if log_rows:
        print("=== Log Errors ===")
        for r in log_rows:
            print(f"[{r['type']}] {format_timestamp(r['timestamp'])}")
            print(f"  {r['payload']}")
            print()


def cmd_logs(args):
    """Get logs for a session."""
    conn = get_connection()

    query = """
        SELECT
            id,
            timestamp,
            level,
            component,
            message,
            error_message,
            error_stack,
            data
        FROM logs
        WHERE session_id = ? OR session_id LIKE ?
    """
    params = [args.session_id, f"{args.session_id}%"]

    if args.level:
        level_map = {"trace": 10, "debug": 20, "info": 30, "warn": 40, "error": 50, "fatal": 60}
        min_level = level_map.get(args.level.lower(), 30)
        query += " AND level_num >= ?"
        params.append(min_level)

    if args.component:
        query += " AND component LIKE ?"
        params.append(f"%{args.component}%")

    query += " ORDER BY timestamp"

    if args.limit:
        query += " LIMIT ?"
        params.append(args.limit)

    rows = conn.execute(query, params).fetchall()

    if args.json:
        output_json([dict(r) for r in rows])
        return

    for r in rows:
        level_colors = {"error": "!", "fatal": "!!", "warn": "?", "info": "", "debug": ".", "trace": ".."}
        prefix = level_colors.get(r["level"], "")
        print(f"{prefix}[{r['level'].upper():5}] {format_timestamp(r['timestamp'])} [{r['component']}]")
        print(f"  {r['message']}")
        if r["error_message"]:
            print(f"  Error: {r['error_message']}")
        if args.verbose and r["error_stack"]:
            print(f"  Stack: {r['error_stack'][:500]}")
        if args.verbose and r["data"]:
            print(f"  Data: {truncate(r['data'], 200)}")
        print()


def cmd_tokens(args):
    """Token usage analysis."""
    conn = get_connection()

    if args.session_id:
        # Token breakdown by turn for a session
        query = """
            SELECT
                turn,
                type,
                input_tokens,
                output_tokens,
                cache_read_tokens,
                cache_creation_tokens,
                timestamp
            FROM events
            WHERE (session_id = ? OR session_id LIKE ?)
              AND (input_tokens > 0 OR output_tokens > 0)
            ORDER BY sequence
        """

        rows = conn.execute(query, (args.session_id, f"{args.session_id}%")).fetchall()

        if args.json:
            output_json([dict(r) for r in rows])
            return

        table_rows = []
        for r in rows:
            table_rows.append([
                r["turn"] if r["turn"] is not None else "-",
                r["type"],
                format_tokens(r["input_tokens"]),
                format_tokens(r["output_tokens"]),
                format_tokens(r["cache_read_tokens"]),
                format_timestamp(r["timestamp"]),
            ])

        print_table(table_rows, ["Turn", "Type", "Input", "Output", "Cache Read", "Time"])
    else:
        # Top sessions by token usage
        order_col = "total_cost" if args.sort == "cost" else "total_input_tokens + total_output_tokens"
        query = f"""
            SELECT
                id,
                title,
                total_input_tokens,
                total_output_tokens,
                total_cache_read_tokens,
                total_cost,
                last_activity_at
            FROM sessions
            WHERE total_input_tokens > 0 OR total_output_tokens > 0
            ORDER BY {order_col} DESC
            LIMIT ?
        """

        rows = conn.execute(query, (args.limit,)).fetchall()

        if args.json:
            output_json([dict(r) for r in rows])
            return

        table_rows = []
        for r in rows:
            total = (r["total_input_tokens"] or 0) + (r["total_output_tokens"] or 0)
            table_rows.append([
                r["id"][:20] + "..." if len(r["id"]) > 20 else r["id"],
                truncate(r["title"], 25) or "(untitled)",
                format_tokens(r["total_input_tokens"]),
                format_tokens(r["total_output_tokens"]),
                format_tokens(total),
                format_cost(r["total_cost"]),
            ])

        print_table(table_rows, ["Session", "Title", "Input", "Output", "Total", "Cost"])


def cmd_turn(args):
    """Get events for a specific turn."""
    conn = get_connection()

    query = """
        SELECT
            id,
            sequence,
            type,
            timestamp,
            tool_name,
            input_tokens,
            output_tokens,
            payload
        FROM events
        WHERE (session_id = ? OR session_id LIKE ?)
          AND turn = ?
        ORDER BY sequence
    """

    rows = conn.execute(query, (args.session_id, f"{args.session_id}%", args.turn)).fetchall()

    if args.json:
        output_json([dict(r) for r in rows])
        return

    if not rows:
        print(f"No events found for turn {args.turn}")
        return

    print(f"=== Turn {args.turn} ===\n")

    for r in rows:
        print(f"[{r['sequence']}] {r['type']}", end="")
        if r["tool_name"]:
            print(f" ({r['tool_name']})", end="")
        if r["input_tokens"] or r["output_tokens"]:
            print(f" - {format_tokens(r['input_tokens'])} in / {format_tokens(r['output_tokens'])} out", end="")
        print()

        if args.verbose and r["payload"]:
            try:
                payload = json.loads(r["payload"])
                if r["type"] in ("message.user", "message.assistant"):
                    content = payload.get("content", "")
                    if isinstance(content, str):
                        print(f"  Content: {truncate(content, 200)}")
                elif r["type"] == "tool_execution_end":
                    status = payload.get("status", "")
                    print(f"  Status: {status}")
            except:
                pass
        print()


def cmd_search(args):
    """Full-text search events or logs."""
    conn = get_connection()

    if args.logs:
        query = """
            SELECT
                l.id,
                l.session_id,
                l.timestamp,
                l.level,
                l.component,
                snippet(logs_fts, 0, '>>>', '<<<', '...', 50) as match
            FROM logs_fts
            JOIN logs l ON logs_fts.rowid = l.id
            WHERE logs_fts MATCH ?
            ORDER BY l.timestamp DESC
            LIMIT ?
        """
    else:
        query = """
            SELECT
                e.id,
                e.session_id,
                e.timestamp,
                e.type,
                e.sequence,
                snippet(events_fts, 0, '>>>', '<<<', '...', 50) as match
            FROM events_fts
            JOIN events e ON events_fts.rowid = e.rowid
            WHERE events_fts MATCH ?
            ORDER BY e.timestamp DESC
            LIMIT ?
        """

    try:
        rows = conn.execute(query, (args.query, args.limit)).fetchall()
    except sqlite3.OperationalError as e:
        if "no such table" in str(e):
            print("Full-text search index not available.", file=sys.stderr)
            sys.exit(1)
        raise

    if args.json:
        output_json([dict(r) for r in rows])
        return

    if not rows:
        print("No results found.")
        return

    for r in rows:
        sess_short = r["session_id"][:15] + "..." if r["session_id"] and len(r["session_id"]) > 15 else r["session_id"]
        if args.logs:
            print(f"[{r['level']}] {format_timestamp(r['timestamp'])} - {sess_short}")
            print(f"  Component: {r['component']}")
        else:
            print(f"[{r['type']}] {format_timestamp(r['timestamp'])} - {sess_short}")
            print(f"  Sequence: {r['sequence']}")
        print(f"  Match: {r['match']}")
        print()


def cmd_stats(args):
    """Database statistics."""
    conn = get_connection()

    stats_query = """
        SELECT
            (SELECT COUNT(*) FROM sessions) as total_sessions,
            (SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL) as active_sessions,
            (SELECT COUNT(*) FROM events) as total_events,
            (SELECT COUNT(*) FROM logs) as total_logs,
            (SELECT COUNT(*) FROM workspaces) as total_workspaces,
            (SELECT COALESCE(SUM(total_cost), 0) FROM sessions) as total_cost,
            (SELECT COALESCE(SUM(total_input_tokens + total_output_tokens), 0) FROM sessions) as total_tokens
    """

    row = conn.execute(stats_query).fetchone()

    if args.json:
        output_json(dict(row))
        return

    print("=== Tron Database Statistics ===")
    print()
    print(f"Database: {get_db_path()}")
    print()
    print(f"Sessions: {row['total_sessions']} ({row['active_sessions']} active)")
    print(f"Events: {row['total_events']:,}")
    print(f"Logs: {row['total_logs']:,}")
    print(f"Workspaces: {row['total_workspaces']}")
    print()
    print(f"Total Tokens: {format_tokens(row['total_tokens'])}")
    print(f"Total Cost: {format_cost(row['total_cost'])}")

    # Recent activity
    recent_query = """
        SELECT
            id,
            title,
            last_activity_at
        FROM sessions
        ORDER BY last_activity_at DESC
        LIMIT 5
    """
    recent = conn.execute(recent_query).fetchall()

    if recent:
        print()
        print("Recent Sessions:")
        for r in recent:
            title = truncate(r["title"], 40) or "(untitled)"
            print(f"  {format_timestamp(r['last_activity_at'])} - {title}")


# === Main ===

def main():
    parser = argparse.ArgumentParser(
        description="Tron Database CLI - Debug sessions, events, and logs",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # sessions
    p_sessions = subparsers.add_parser("sessions", help="List recent sessions")
    p_sessions.add_argument("--limit", type=int, default=20, help="Max results")
    p_sessions.set_defaults(func=cmd_sessions)

    # session
    p_session = subparsers.add_parser("session", help="Get session details")
    p_session.add_argument("session_id", help="Session ID (or prefix)")
    p_session.set_defaults(func=cmd_session)

    # events
    p_events = subparsers.add_parser("events", help="Get events for a session")
    p_events.add_argument("session_id", help="Session ID (or prefix)")
    p_events.add_argument("--type", help="Filter by event type")
    p_events.add_argument("--turn", type=int, help="Filter by turn number")
    p_events.add_argument("--limit", type=int, help="Max results")
    p_events.set_defaults(func=cmd_events)

    # messages
    p_messages = subparsers.add_parser("messages", help="Get messages for a session")
    p_messages.add_argument("session_id", help="Session ID (or prefix)")
    p_messages.add_argument("--truncate", action="store_true", help="Truncate long messages")
    p_messages.set_defaults(func=cmd_messages)

    # tools
    p_tools = subparsers.add_parser("tools", help="Get tool executions for a session")
    p_tools.add_argument("session_id", help="Session ID (or prefix)")
    p_tools.set_defaults(func=cmd_tools)

    # errors
    p_errors = subparsers.add_parser("errors", help="Find errors in a session")
    p_errors.add_argument("session_id", help="Session ID (or prefix)")
    p_errors.set_defaults(func=cmd_errors)

    # logs
    p_logs = subparsers.add_parser("logs", help="Get logs for a session")
    p_logs.add_argument("session_id", help="Session ID (or prefix)")
    p_logs.add_argument("--level", help="Minimum log level (trace/debug/info/warn/error/fatal)")
    p_logs.add_argument("--component", help="Filter by component name")
    p_logs.add_argument("--limit", type=int, help="Max results")
    p_logs.add_argument("-v", "--verbose", action="store_true", help="Show stack traces and data")
    p_logs.set_defaults(func=cmd_logs)

    # tokens
    p_tokens = subparsers.add_parser("tokens", help="Token usage analysis")
    p_tokens.add_argument("session_id", nargs="?", help="Session ID for per-turn breakdown")
    p_tokens.add_argument("--sort", choices=["tokens", "cost"], default="tokens", help="Sort by")
    p_tokens.add_argument("--limit", type=int, default=20, help="Max results (for session list)")
    p_tokens.set_defaults(func=cmd_tokens)

    # turn
    p_turn = subparsers.add_parser("turn", help="Get events for a specific turn")
    p_turn.add_argument("session_id", help="Session ID (or prefix)")
    p_turn.add_argument("turn", type=int, help="Turn number")
    p_turn.add_argument("-v", "--verbose", action="store_true", help="Show payload details")
    p_turn.set_defaults(func=cmd_turn)

    # search
    p_search = subparsers.add_parser("search", help="Full-text search")
    p_search.add_argument("query", help="Search query")
    p_search.add_argument("--logs", action="store_true", help="Search logs instead of events")
    p_search.add_argument("--limit", type=int, default=20, help="Max results")
    p_search.set_defaults(func=cmd_search)

    # stats
    p_stats = subparsers.add_parser("stats", help="Database statistics")
    p_stats.set_defaults(func=cmd_stats)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
