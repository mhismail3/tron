#!/usr/bin/env python3
"""Live local-model breadth harness for ROC-3 scorecard evidence."""

import argparse
import datetime as dt
import json
import subprocess
import sys
import time

import roc2_hosted_model_matrix as harness

LOCAL_SMOKE_MODEL = "gemma4:e4b"
LARGER_MODEL = "gemma4:26b"


def create_local_session(ws, model, title, stamp):
    response = harness.invoke(
        ws,
        "session::create",
        {
            "workingDirectory": str(harness.ROOT),
            "model": model,
            "profile": "local",
            "title": title,
            "useWorktree": False,
        },
        f"roc3-create-{model}-{stamp}",
        f"roc3-create-{model}-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {"scenario": "ROC-3", "harness": "local-model-breadth"},
        },
        timeout=60,
    )
    value, child = harness.child_value(response)
    return value["sessionId"], child


def send_prompt(ws, session_id, prompt, stamp):
    response = harness.invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": session_id,
            "prompt": prompt,
            "source": f"roc3-local-model-breadth-{stamp}",
        },
        f"roc3-prompt-{stamp}",
        f"roc3-prompt-{stamp}",
        {
            "sessionId": session_id,
            "authorityScopes": ["session.write", "session.read", "agent.read", "agent.write"],
            "runtimeMetadata": {"scenario": "ROC-3", "harness": "local-model-breadth"},
        },
        timeout=60,
    )
    value, child = harness.child_value(response)
    return value, child


def collect_local(session_id, start_ts):
    invocations = harness.db_json(
        """
        SELECT invocation_id, function_id, worker_id, parent_invocation_id, trace_id,
               session_id, idempotency_key, succeeded,
               produced_resource_refs_json, substr(result_json, 1, 5000) AS result_preview,
               substr(error_json, 1, 3000) AS error_preview, timestamp
        FROM engine_invocations
        WHERE session_id = ? AND timestamp >= ?
        ORDER BY timestamp
        """,
        (session_id, start_ts),
    )
    events = harness.db_json(
        """
        SELECT sequence, type, timestamp, model, provider_type, stop_reason,
               model_primitive_name, invocation_id, substr(payload, 1, 5000) AS payload_preview
        FROM events
        WHERE session_id = ?
        ORDER BY sequence
        """,
        (session_id,),
    )
    logs = harness.db_json(
        """
        SELECT timestamp, level, component, message, session_id, trace_id,
               substr(data, 1, 2000) AS data_preview, error_message
        FROM logs
        WHERE timestamp >= ?
          AND (session_id = ?
               OR trace_id IN (SELECT trace_id FROM engine_invocations WHERE session_id = ?))
        ORDER BY timestamp
        """,
        (start_ts, session_id, session_id),
    )
    execute_ids = {
        row["invocation_id"]
        for row in invocations
        if row["function_id"] == "capability::execute"
    }
    children = [
        row
        for row in invocations
        if row["parent_invocation_id"] in execute_ids
    ]
    failed = [row for row in invocations if row["succeeded"] == 0]
    error_logs = [
        row for row in logs if str(row["level"]).lower() in {"error", "fatal"}
    ]
    compact_events = [row for row in events if row["type"].startswith("compact.")]
    assistant_payloads = [
        row["payload_preview"] or ""
        for row in events
        if row["type"] == "message.assistant"
    ]
    model_events = [
        {
            "sequence": row["sequence"],
            "type": row["type"],
            "model": row["model"],
            "providerType": row["provider_type"],
            "modelPrimitiveName": row["model_primitive_name"],
            "invocationId": row["invocation_id"],
        }
        for row in events
        if row["model"] or row["provider_type"] or row["model_primitive_name"]
    ]
    return {
        "invocations": invocations,
        "events": events,
        "logs": logs,
        "summary": {
            "invocationCount": len(invocations),
            "executeCount": len(execute_ids),
            "executeChildFunctions": [row["function_id"] for row in children],
            "failedInvocationCount": len(failed),
            "errorLogCount": len(error_logs),
            "compactEventCount": len(compact_events),
            "assistantPayloads": assistant_payloads,
            "modelEvents": model_events,
        },
    }


def ollama_list():
    proc = subprocess.run(
        ["ollama", "list"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )
    return {"returncode": proc.returncode, "output": proc.stdout}


def model_availability(catalog):
    return [
        {
            "id": m.get("id"),
            "name": m.get("name"),
            "available": m.get("available"),
            "recommended": m.get("recommended"),
            "sortOrder": m.get("sortOrder"),
            "unavailableReason": m.get("unavailableReason"),
        }
        for m in catalog
        if m.get("provider") == "ollama"
    ]


def run_substrate_smoke(ws, model, stamp):
    marker = f"ROC-3 LOCAL SUBSTRATE {model} {stamp}"
    start_ts = dt.datetime.now(dt.UTC).isoformat()
    session_id, create_child = create_local_session(
        ws,
        model,
        f"ROC-3 local substrate {model} {stamp}",
        stamp,
    )
    prompt = (
        f"Reply with exactly this marker and no extra tool calls: {marker}. "
        "Do not call execute."
    )
    prompt_value, prompt_child = send_prompt(ws, session_id, prompt, f"substrate-{stamp}")
    terminal = harness.wait_end_turn(session_id, 600)
    db = collect_local(session_id, start_ts)
    summary = db["summary"]
    assistant_text = "\n".join(summary["assistantPayloads"])
    provider_types = {
        event["providerType"]
        for event in summary["modelEvents"]
        if event.get("providerType")
    }
    problems = []
    if "ollama" not in provider_types:
        problems.append(f"{model}: assistant event did not record provider_type=ollama")
    if marker not in assistant_text:
        problems.append(f"{model}: assistant response did not include substrate marker")
    if summary["failedInvocationCount"] != 0:
        problems.append(f"{model}: failed invocation count {summary['failedInvocationCount']}")
    if summary["errorLogCount"] != 0:
        problems.append(f"{model}: error/fatal log count {summary['errorLogCount']}")
    if summary["compactEventCount"] != 0:
        problems.append(f"{model}: compact event count {summary['compactEventCount']}")
    return {
        "sessionId": session_id,
        "marker": marker,
        "startTimestamp": start_ts,
        "createChild": create_child,
        "promptValue": prompt_value,
        "promptChild": prompt_child,
        "terminalEvent": terminal,
        "db": db,
        "validationProblems": problems,
    }


def run_capability_attempt(ws, model, stamp):
    marker = f"ROC-3 LOCAL EXECUTE ATTEMPT {model} {stamp}"
    start_ts = dt.datetime.now(dt.UTC).isoformat()
    session_id, create_child = create_local_session(
        ws,
        model,
        f"ROC-3 local execute attempt {model} {stamp}",
        stamp,
    )
    prompt = f"""Use only execute. Local model capability attempt marker {marker}.

Make exactly one execute call: target filesystem::read_file, operation run, idempotencyKey roc3-local-read-{stamp}, arguments {{"path":"README.md","startLine":1,"endLine":1}}.

Final answer: include marker {marker}, say whether README.md line 1 was read, and do not make any extra calls."""
    prompt_value, prompt_child = send_prompt(ws, session_id, prompt, f"execute-{stamp}")
    terminal = harness.wait_end_turn(session_id, 600)
    db = collect_local(session_id, start_ts)
    summary = db["summary"]
    child_success = any(
        row["function_id"] == "filesystem::read_file"
        for row in db["invocations"]
        if row["parent_invocation_id"]
    )
    if child_success:
        classification = "passed"
    elif summary["failedInvocationCount"] == 0 and summary["errorLogCount"] == 0:
        classification = "inconclusive_model_comprehension"
    else:
        classification = "engine_or_provider_failure"
    return {
        "sessionId": session_id,
        "marker": marker,
        "startTimestamp": start_ts,
        "createChild": create_child,
        "promptValue": prompt_value,
        "promptChild": prompt_child,
        "terminalEvent": terminal,
        "db": db,
        "classification": classification,
    }


def run_harness(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    run_log = f"/tmp/roc3_local_model_breadth_{stamp}.json"
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "serverHealthBefore": harness.run_cmd(["curl", "-fsS", harness.HEALTH], timeout=10),
        "ollamaList": ollama_list(),
        "validationProblems": [],
    }
    ws = None
    try:
        ws, hello = harness.ws_hello("roc3-hello")
        result["hello"] = hello
        catalog = harness.list_models(ws)
        result["ollamaModels"] = model_availability(catalog)
        available = {m["id"] for m in result["ollamaModels"] if m.get("available")}
        if LOCAL_SMOKE_MODEL not in available:
            result["validationProblems"].append(f"{LOCAL_SMOKE_MODEL} is not available")
        else:
            substrate = run_substrate_smoke(ws, LOCAL_SMOKE_MODEL, f"{stamp}-1")
            result["substrateSmoke"] = substrate
            result["validationProblems"].extend(substrate["validationProblems"])
            if args.capability_attempt:
                result["capabilityAttempt"] = run_capability_attempt(
                    ws,
                    LOCAL_SMOKE_MODEL,
                    f"{stamp}-2",
                )
                if result["capabilityAttempt"]["classification"] == "engine_or_provider_failure":
                    result["validationProblems"].append(
                        f"{LOCAL_SMOKE_MODEL}: capability attempt produced engine/provider failure"
                    )
        result["largerModelLane"] = {
            "model": LARGER_MODEL,
            "available": LARGER_MODEL in available,
            "status": "available" if LARGER_MODEL in available else "not_installed",
        }
        if LARGER_MODEL in available:
            result["largerModelLane"]["substrateSmoke"] = run_substrate_smoke(
                ws,
                LARGER_MODEL,
                f"{stamp}-larger",
            )
            result["validationProblems"].extend(
                result["largerModelLane"]["substrateSmoke"]["validationProblems"]
            )
    finally:
        if ws is not None:
            ws.close()
    result["serverHealthAfter"] = harness.run_cmd(["curl", "-fsS", harness.HEALTH], timeout=10)
    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    summary = {
        "runLog": run_log,
        "ollamaModels": result.get("ollamaModels"),
        "substrateSmoke": {
            "sessionId": result.get("substrateSmoke", {}).get("sessionId"),
            "marker": result.get("substrateSmoke", {}).get("marker"),
            "dbSummary": result.get("substrateSmoke", {}).get("db", {}).get("summary"),
            "validationProblems": result.get("substrateSmoke", {}).get("validationProblems"),
        },
        "capabilityAttempt": {
            "sessionId": result.get("capabilityAttempt", {}).get("sessionId"),
            "classification": result.get("capabilityAttempt", {}).get("classification"),
            "dbSummary": result.get("capabilityAttempt", {}).get("db", {}).get("summary"),
        },
        "largerModelLane": result.get("largerModelLane"),
        "validationProblems": result["validationProblems"],
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 1 if result["validationProblems"] else 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--capability-attempt",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Attempt one execute call and classify small-model misses separately.",
    )
    return parser.parse_args(argv)


def main(argv):
    return run_harness(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
