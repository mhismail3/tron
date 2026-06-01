#!/usr/bin/env python3
"""Live no-tool provider canary for canonical token-record evidence."""

import argparse
import datetime as dt
import json
import math
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roc2_hosted_model_matrix as roc2
import rwo_n16_live_agent_harness as n16

ROOT = n16.ROOT
TERMINAL_STOP_REASON = "end_turn"


def configure_from_shared_runtime():
    roc2.configure_from_shared_runtime()


def safe_model_label(model):
    return re.sub(r"[^a-zA-Z0-9_.:-]+", "-", model)


def expected_provider_for_model(model, catalog):
    for item in catalog:
        if item.get("id") == model:
            provider = item.get("provider")
            if provider:
                return provider
    lowered = model.lower()
    if lowered.startswith("claude"):
        return "anthropic"
    if lowered.startswith(("gpt", "o1", "o3", "o4", "codex")):
        return "openai"
    if lowered.startswith("gemini"):
        return "google"
    if lowered.startswith("minimax") or lowered.startswith("minimax/"):
        return "minimax"
    if lowered.startswith("kimi") or lowered.startswith("kimi/"):
        return "kimi"
    return "ollama"


def create_session(ws, model, stamp):
    request_id = f"psg-token-create-{safe_model_label(model)}"
    response = roc2.invoke(
        ws,
        "session::create",
        {
            "workingDirectory": str(ROOT),
            "model": model,
            "title": f"PSG token provider canary {model} {stamp}",
            "useWorktree": False,
        },
        request_id,
        f"{request_id}-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {
                "scenario": "PSG-2",
                "harness": "token-provider-canary",
            },
        },
        timeout=60,
    )
    value, child = roc2.child_value(response)
    return value["sessionId"], child


def send_no_tool_prompt(ws, session_id, model, stamp):
    marker = f"PSG-TOKEN-CANARY {safe_model_label(model)} {stamp}"
    prompt = (
        "This is a token accounting canary. Do not call tools, capabilities, "
        "execute, shell, filesystem, web, browser, or resource APIs. Reply with "
        f"exactly this marker and one short sentence: {marker}"
    )
    request_id = f"psg-token-prompt-{safe_model_label(model)}"
    response = roc2.invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": session_id,
            "prompt": prompt,
            "source": f"psg-token-provider-canary-{stamp}",
        },
        request_id,
        f"{request_id}-{stamp}",
        {
            "sessionId": session_id,
            "authorityScopes": [
                "session.write",
                "session.read",
                "agent.read",
                "agent.write",
            ],
            "runtimeMetadata": {
                "scenario": "PSG-2",
                "harness": "token-provider-canary",
            },
        },
        timeout=60,
    )
    value, child = roc2.child_value(response)
    return marker, prompt, value, child


def event_stop_reason(row):
    if row.get("stop_reason"):
        return row["stop_reason"]
    try:
        payload = json.loads(row.get("payload") or "{}")
    except json.JSONDecodeError:
        return None
    return payload.get("stopReason")


def wait_end_turn(session_id, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    latest = None
    while time.monotonic() < deadline:
        rows = n16.db_json(
            """
            SELECT sequence, type, stop_reason, payload
            FROM events
            WHERE session_id = ?
            ORDER BY sequence
            """,
            (session_id,),
        )
        terminal = [
            row
            for row in rows
            if row["type"] == "stream.turn_end"
            and event_stop_reason(row) == TERMINAL_STOP_REASON
        ]
        if terminal:
            last = terminal[-1]
            later_start = any(
                row["type"] == "stream.turn_start" and row["sequence"] > last["sequence"]
                for row in rows
            )
            if not later_start:
                return last
        latest = rows[-1] if rows else None
        time.sleep(1)
    raise TimeoutError(f"no terminal end_turn for {session_id}; latest={latest}")


def schema_columns(table):
    return [row["name"] for row in n16.db_json(f"PRAGMA table_info({table})")]


def session_row(session_id):
    rows = n16.db_json(
        """
        SELECT id, latest_model, event_count, message_count, turn_count,
               total_input_tokens, total_output_tokens, last_turn_input_tokens,
               total_cost, total_cache_read_tokens, total_cache_creation_tokens
        FROM sessions
        WHERE id = ?
        """,
        (session_id,),
    )
    return rows[0] if rows else None


def collect(session_id, start_ts):
    events = n16.db_json(
        """
        SELECT sequence, type, timestamp, model, provider_type, stop_reason,
               input_tokens, output_tokens, cache_read_tokens,
               cache_creation_tokens, cost, payload
        FROM events
        WHERE session_id = ?
        ORDER BY sequence
        """,
        (session_id,),
    )
    invocations = n16.db_json(
        """
        SELECT invocation_id, function_id, parent_invocation_id, succeeded,
               timestamp, substr(error_json, 1, 3000) AS error_preview
        FROM engine_invocations
        WHERE session_id = ? AND timestamp >= ?
        ORDER BY timestamp
        """,
        (session_id, start_ts),
    )
    logs = n16.db_json(
        """
        SELECT timestamp, level, component, message, session_id, trace_id,
               substr(data, 1, 1200) AS data_preview, error_message
        FROM logs
        WHERE timestamp >= ?
          AND (session_id = ?
               OR trace_id IN (SELECT trace_id FROM engine_invocations WHERE session_id = ?))
        ORDER BY timestamp
        """,
        (start_ts, session_id, session_id),
    )
    return {
        "schema": {
            "events": schema_columns("events"),
            "sessions": schema_columns("sessions"),
        },
        "session": session_row(session_id),
        "events": events,
        "invocations": invocations,
        "logs": logs,
    }


def parse_payload(row):
    try:
        return json.loads(row.get("payload") or "{}")
    except json.JSONDecodeError:
        return {}


def token_records_from_events(events):
    records = []
    for row in events:
        payload = parse_payload(row)
        record = payload.get("tokenRecord")
        if isinstance(record, dict):
            records.append(
                {
                    "sequence": row["sequence"],
                    "type": row["type"],
                    "model": row["model"],
                    "providerType": row["provider_type"],
                    "inputTokens": row["input_tokens"],
                    "outputTokens": row["output_tokens"],
                    "cacheReadTokens": row["cache_read_tokens"],
                    "cacheCreationTokens": row["cache_creation_tokens"],
                    "cost": row["cost"],
                    "tokenRecord": record,
                }
            )
    return records


def turn_record_key(record):
    meta = record["tokenRecord"].get("meta", {})
    source = record["tokenRecord"].get("source", {})
    computed = record["tokenRecord"].get("computed", {})
    return (
        meta.get("turn"),
        meta.get("contextSegmentId"),
        meta.get("model"),
        source.get("rawTotalTokens"),
        computed.get("contextWindowTokens"),
    )


def unique_turn_records(records):
    by_key = {}
    for record in records:
        key = turn_record_key(record)
        if key not in by_key:
            by_key[key] = record
    return list(by_key.values())


def require_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def validate_token_record(record, session_id, model, expected_provider):
    problems = []
    token_record = record["tokenRecord"]
    for section in ("source", "computed", "meta", "pricing"):
        if not isinstance(token_record.get(section), dict):
            problems.append(f"{record['type']} seq {record['sequence']}: missing {section}")
    if problems:
        return problems

    source = token_record["source"]
    computed = token_record["computed"]
    meta = token_record["meta"]
    pricing = token_record["pricing"]

    if source.get("provider") != expected_provider:
        problems.append(
            f"{record['type']} seq {record['sequence']}: provider "
            f"{source.get('provider')} != {expected_provider}"
        )
    for field in (
        "rawInputTokens",
        "rawOutputTokens",
        "rawCacheReadTokens",
        "rawCachedInputTokens",
        "rawCacheCreationTokens",
        "rawCacheCreation5mTokens",
        "rawCacheCreation1hTokens",
        "rawReasoningOutputTokens",
        "rawThoughtTokens",
        "rawToolUsePromptTokens",
        "rawTotalTokens",
    ):
        if not isinstance(source.get(field), int) or source[field] < 0:
            problems.append(f"{record['type']} seq {record['sequence']}: invalid source.{field}")
    if isinstance(source.get("rawInputTokens"), int) and source["rawInputTokens"] <= 0:
        problems.append(f"{record['type']} seq {record['sequence']}: raw input must be positive")
    if isinstance(source.get("rawOutputTokens"), int) and source["rawOutputTokens"] <= 0:
        problems.append(f"{record['type']} seq {record['sequence']}: raw output must be positive")
    if isinstance(source.get("rawTotalTokens"), int):
        raw_minimum = (source.get("rawInputTokens") or 0) + (source.get("rawOutputTokens") or 0)
        if source["rawTotalTokens"] < raw_minimum:
            problems.append(
                f"{record['type']} seq {record['sequence']}: raw total below input+output"
            )

    for field in ("contextWindowTokens", "newInputTokens", "previousContextBaseline"):
        if not isinstance(computed.get(field), int) or computed[field] < 0:
            problems.append(f"{record['type']} seq {record['sequence']}: invalid computed.{field}")
    if computed.get("contextWindowTokens", 0) <= 0:
        problems.append(f"{record['type']} seq {record['sequence']}: context window must be positive")
    if computed.get("newInputTokens", 0) <= 0:
        problems.append(f"{record['type']} seq {record['sequence']}: new input must be positive")

    if meta.get("sessionId") != session_id:
        problems.append(f"{record['type']} seq {record['sequence']}: session id mismatch")
    if meta.get("model") != model:
        problems.append(f"{record['type']} seq {record['sequence']}: model mismatch")
    if not isinstance(meta.get("turn"), int) or meta["turn"] <= 0:
        problems.append(f"{record['type']} seq {record['sequence']}: invalid meta.turn")
    if not meta.get("contextSegmentId"):
        problems.append(f"{record['type']} seq {record['sequence']}: missing context segment")
    if not meta.get("baselineResetReason"):
        problems.append(f"{record['type']} seq {record['sequence']}: missing baseline reset reason")

    if not isinstance(pricing.get("available"), bool):
        problems.append(f"{record['type']} seq {record['sequence']}: pricing.available is not bool")
    if pricing.get("model") != model:
        problems.append(f"{record['type']} seq {record['sequence']}: pricing model mismatch")
    if pricing.get("available"):
        cost = pricing.get("cost")
        if not isinstance(cost, dict):
            problems.append(f"{record['type']} seq {record['sequence']}: missing pricing.cost")
        else:
            for field in (
                "baseInputTokens",
                "outputTokens",
                "cacheReadTokens",
                "cacheWriteTokens",
                "cacheWrite5mTokens",
                "cacheWrite1hTokens",
                "baseInputCost",
                "outputCost",
                "cacheReadCost",
                "cacheWriteCost",
                "totalCost",
            ):
                if not require_number(cost.get(field)):
                    problems.append(
                        f"{record['type']} seq {record['sequence']}: invalid pricing.cost.{field}"
                    )
            component_sum = (
                (cost.get("baseInputCost") or 0.0)
                + (cost.get("outputCost") or 0.0)
                + (cost.get("cacheReadCost") or 0.0)
                + (cost.get("cacheWriteCost") or 0.0)
            )
            if require_number(cost.get("totalCost")) and not math.isclose(
                float(cost["totalCost"]),
                float(component_sum),
                rel_tol=1e-9,
                abs_tol=1e-12,
            ):
                problems.append(
                    f"{record['type']} seq {record['sequence']}: cost components do not sum"
                )
    elif not pricing.get("reason"):
        problems.append(f"{record['type']} seq {record['sequence']}: unavailable pricing has no reason")
    return problems


def validate_consistency(db, session_id, model, expected_provider):
    problems = []
    records = token_records_from_events(db["events"])
    if not records:
        return ["no tokenRecord payloads found"]

    for record in records:
        problems.extend(validate_token_record(record, session_id, model, expected_provider))

    for key in {turn_record_key(record) for record in records}:
        matching = [record["tokenRecord"] for record in records if turn_record_key(record) == key]
        canonical = json.dumps(matching[0], sort_keys=True, separators=(",", ":"))
        for duplicate in matching[1:]:
            encoded = json.dumps(duplicate, sort_keys=True, separators=(",", ":"))
            if encoded != canonical:
                problems.append(f"tokenRecord mismatch for turn key {key}")

    unique_records = unique_turn_records(records)
    session = db.get("session")
    if not session:
        problems.append("missing sessions row")
    else:
        sum_input = sum(r["tokenRecord"]["source"]["rawInputTokens"] for r in unique_records)
        sum_output = sum(r["tokenRecord"]["source"]["rawOutputTokens"] for r in unique_records)
        sum_cache_read = sum(r["tokenRecord"]["source"]["rawCacheReadTokens"] for r in unique_records)
        sum_cache_write = sum(r["tokenRecord"]["source"]["rawCacheCreationTokens"] for r in unique_records)
        sum_cost = sum(
            (r["tokenRecord"]["pricing"].get("cost") or {}).get("totalCost", 0.0)
            for r in unique_records
            if r["tokenRecord"]["pricing"].get("available")
        )
        last_context = unique_records[-1]["tokenRecord"]["computed"]["contextWindowTokens"]
        checks = [
            ("total_input_tokens", sum_input),
            ("total_output_tokens", sum_output),
            ("total_cache_read_tokens", sum_cache_read),
            ("total_cache_creation_tokens", sum_cache_write),
            ("last_turn_input_tokens", last_context),
        ]
        for field, expected in checks:
            if session.get(field) != expected:
                problems.append(f"session.{field} {session.get(field)} != {expected}")
        if not math.isclose(
            float(session.get("total_cost") or 0.0),
            float(sum_cost),
            rel_tol=1e-9,
            abs_tol=1e-9,
        ):
            problems.append(f"session.total_cost {session.get('total_cost')} != {sum_cost}")

    failed_invocations = [row for row in db["invocations"] if row.get("succeeded") == 0]
    error_logs = [row for row in db["logs"] if str(row.get("level", "")).lower() in {"error", "fatal"}]
    compact_events = [row for row in db["events"] if str(row.get("type", "")).startswith("compact.")]
    execute_invocations = [
        row for row in db["invocations"] if row.get("function_id") == "capability::execute"
    ]
    if failed_invocations:
        problems.append(f"failed invocation count {len(failed_invocations)}")
    if error_logs:
        problems.append(f"error/fatal log count {len(error_logs)}")
    if compact_events:
        problems.append(f"compact event count {len(compact_events)}")
    if execute_invocations:
        problems.append(f"unexpected capability::execute count {len(execute_invocations)}")

    return problems


def summarize_model(model, data):
    records = token_records_from_events(data["db"]["events"])
    unique_records = unique_turn_records(records)
    source_totals = {
        "rawInputTokens": sum(r["tokenRecord"]["source"]["rawInputTokens"] for r in unique_records),
        "rawOutputTokens": sum(r["tokenRecord"]["source"]["rawOutputTokens"] for r in unique_records),
        "rawCacheReadTokens": sum(r["tokenRecord"]["source"]["rawCacheReadTokens"] for r in unique_records),
        "rawCachedInputTokens": sum(
            r["tokenRecord"]["source"]["rawCachedInputTokens"] for r in unique_records
        ),
        "rawCacheCreationTokens": sum(
            r["tokenRecord"]["source"]["rawCacheCreationTokens"] for r in unique_records
        ),
        "rawCacheCreation5mTokens": sum(
            r["tokenRecord"]["source"]["rawCacheCreation5mTokens"] for r in unique_records
        ),
        "rawCacheCreation1hTokens": sum(
            r["tokenRecord"]["source"]["rawCacheCreation1hTokens"] for r in unique_records
        ),
        "rawReasoningOutputTokens": sum(
            r["tokenRecord"]["source"]["rawReasoningOutputTokens"] for r in unique_records
        ),
        "rawThoughtTokens": sum(r["tokenRecord"]["source"]["rawThoughtTokens"] for r in unique_records),
        "rawToolUsePromptTokens": sum(
            r["tokenRecord"]["source"]["rawToolUsePromptTokens"] for r in unique_records
        ),
        "rawTotalTokens": sum(r["tokenRecord"]["source"]["rawTotalTokens"] for r in unique_records),
    }
    pricing = [
        {
            "available": r["tokenRecord"]["pricing"].get("available"),
            "reason": r["tokenRecord"]["pricing"].get("reason"),
            "totalCost": (r["tokenRecord"]["pricing"].get("cost") or {}).get("totalCost"),
        }
        for r in unique_records
    ]
    return {
        "sessionId": data["sessionId"],
        "expectedProvider": data["expectedProvider"],
        "terminalSequence": data["terminalEvent"]["sequence"],
        "session": data["db"]["session"],
        "tokenRecordEventCount": len(records),
        "uniqueTurnRecordCount": len(unique_records),
        "sourceTotals": source_totals,
        "pricing": pricing,
        "validationProblems": data["validationProblems"],
    }


def run_canaries(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    run_log = f"/tmp/psg_token_provider_canary_{stamp}.json"
    isolated_server = n16.maybe_start_isolated_server(args, stamp, "psg-token")
    configure_from_shared_runtime()
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "serverMode": "current_user" if args.use_current_server else "isolated",
        "isolatedServer": n16.public_server_info(isolated_server),
        "serverHealthBefore": n16.run_cmd(["curl", "-fsS", n16.HEALTH], timeout=10),
        "models": {},
        "validationProblems": [],
    }
    ws = None
    try:
        ws, hello = roc2.ws_hello("psg-token-hello")
        result["hello"] = hello
        catalog = roc2.list_models(ws)
        models = args.models or ["kimi-k2.5"]
        result["selectedModels"] = models
        result["catalog"] = {
            "modelCount": len(catalog),
            "selected": [
                {
                    "id": item.get("id"),
                    "provider": item.get("provider"),
                    "name": item.get("name"),
                    "recommended": item.get("recommended"),
                    "isRetired": item.get("isRetired") or item.get("retired"),
                }
                for item in catalog
                if item.get("id") in models
            ],
        }
        for index, model in enumerate(models, start=1):
            model_stamp = f"{stamp}-{index}"
            start_ts = dt.datetime.now(dt.UTC).isoformat()
            expected_provider = expected_provider_for_model(model, catalog)
            session_id, create_child = create_session(ws, model, model_stamp)
            marker, prompt, prompt_value, prompt_child = send_no_tool_prompt(
                ws,
                session_id,
                model,
                model_stamp,
            )
            terminal = wait_end_turn(session_id, args.timeout_seconds)
            db = collect(session_id, start_ts)
            problems = validate_consistency(db, session_id, model, expected_provider)
            result["validationProblems"].extend(f"{model}: {problem}" for problem in problems)
            result["models"][model] = {
                "sessionId": session_id,
                "startTimestamp": start_ts,
                "expectedProvider": expected_provider,
                "marker": marker,
                "prompt": prompt,
                "createChild": create_child,
                "promptValue": prompt_value,
                "promptChild": prompt_child,
                "terminalEvent": terminal,
                "db": db,
                "validationProblems": problems,
            }
    finally:
        if ws is not None:
            ws.close()
    result["serverHealthAfter"] = n16.run_cmd(["curl", "-fsS", n16.HEALTH], timeout=10)
    if isolated_server is not None:
        result["isolatedServerStop"] = n16.stop_isolated_server(isolated_server["process"])
    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    summary = {
        "runLog": run_log,
        "selectedModels": result.get("selectedModels"),
        "validationProblems": result["validationProblems"],
        "models": {
            model: summarize_model(model, data)
            for model, data in result["models"].items()
        },
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 1 if result["validationProblems"] else 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", dest="models", action="append", help="Model to test; may be repeated.")
    parser.add_argument("--timeout-seconds", type=int, default=240)
    n16.add_runtime_args(parser)
    return parser.parse_args(argv)


def main(argv):
    return run_canaries(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
