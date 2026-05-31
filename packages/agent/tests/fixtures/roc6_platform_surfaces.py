#!/usr/bin/env python3
"""Live platform-surface regression harness for ROC-6."""

import argparse
import base64
import datetime as dt
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rwo_n16_live_agent_harness as n16

ROOT = n16.ROOT
DEFAULT_PORT = 9866
DEFAULT_SIM_UDID = "267F6468-09AE-471D-9157-29144173EB82"


def run_cmd(argv, env=None, timeout=120):
    started = dt.datetime.now(dt.UTC).isoformat()
    proc = subprocess.run(
        argv,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    return {
        "argv": argv,
        "returncode": proc.returncode,
        "started": started,
        "finished": dt.datetime.now(dt.UTC).isoformat(),
        "output": proc.stdout[-8000:],
    }


def load_token(tron_home):
    auth_path = tron_home / "profiles" / "auth.json"
    with open(auth_path, encoding="utf-8") as handle:
        return json.load(handle)["bearerToken"]


def db_json(db_path, query, params=()):
    with sqlite3.connect(db_path, timeout=10) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, params)]


def db_scalar(db_path, query, params=()):
    rows = db_json(db_path, query, params)
    if not rows:
        return None
    return next(iter(rows[0].values()))


def wait_health(port, timeout=45):
    deadline = time.monotonic() + timeout
    url = f"http://127.0.0.1:{port}/health"
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
    raise TimeoutError(f"server on {port} did not become healthy: {last_error}")


def start_isolated_server(stamp, port, build):
    build_result = None
    if build:
        build_result = run_cmd(
            ["cargo", "build", "--profile", "dev-server", "--manifest-path", "packages/agent/Cargo.toml"],
            timeout=600,
        )
        if build_result["returncode"] != 0:
            raise RuntimeError(f"dev-server build failed: {build_result['output']}")

    home_root = Path(tempfile.mkdtemp(prefix=f"roc6-home-{stamp}-"))
    tron_home = home_root / ".tron"
    binary = ROOT / "packages/agent/target/dev-server/tron"
    if not binary.exists():
        raise RuntimeError(f"server binary missing: {binary}")

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
    try:
        health = wait_health(port)
    except Exception:
        proc.send_signal(signal.SIGTERM)
        try:
            output = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            output = proc.communicate(timeout=5)[0]
        raise RuntimeError(f"isolated server failed to start:\n{output[-8000:]}")

    return {
        "build": build_result,
        "homeRoot": str(home_root),
        "tronHome": str(tron_home),
        "dbPath": str(tron_home / "internal/database/tron.sqlite"),
        "pid": proc.pid,
        "port": port,
        "health": health,
        "process": proc,
    }


def stop_server(proc):
    if proc.poll() is not None:
        return proc.returncode, ""
    proc.send_signal(signal.SIGTERM)
    try:
        output = proc.communicate(timeout=10)[0] or ""
    except subprocess.TimeoutExpired:
        proc.kill()
        output = proc.communicate(timeout=10)[0] or ""
    return proc.returncode, output[-8000:]


def ws_hello(port, tron_home, label):
    ws = n16.RawWebSocket(f"ws://127.0.0.1:{port}/engine", load_token(tron_home))
    ws.send_json({"type": "hello", "id": label, "protocolVersion": 1})
    hello = ws.recv_json(timeout=30)
    if hello.get("type") != "hello.ok":
        raise RuntimeError(hello)
    return ws, hello


def invoke(ws, function_id, payload, request_id, idempotency_key, scopes, context=None, timeout=60):
    ctx = {
        "authorityScopes": scopes,
        "runtimeMetadata": {"scenario": "ROC-6", "harness": "platform-surfaces"},
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


def collect_validation(db_path, stamp, session_id, token, notification_id):
    validations = []
    token_rows = db_json(
        db_path,
        """
        SELECT device_token, environment, bundle_id, is_active
        FROM device_tokens WHERE device_token = ?
        """,
        (token,),
    )
    validations.append({
        "name": "synthetic_token_registered_then_unregistered",
        "ok": len(token_rows) == 1
        and token_rows[0]["environment"] == "sandbox"
        and token_rows[0]["bundle_id"] == "com.tron.mobile.beta"
        and token_rows[0]["is_active"] == 0,
        "rows": token_rows,
    })
    validations.append({
        "name": "notification_resource_is_delivery_failed_not_hidden",
        "ok": db_scalar(
            db_path,
            "SELECT lifecycle FROM engine_resources WHERE resource_id = ?",
            (notification_id,),
        )
        == "delivery_failed",
    })
    validations.append({
        "name": "voice_note_unavailable_created_no_resources",
        "ok": db_scalar(
            db_path,
            """
            SELECT count(*) FROM engine_resources
            WHERE resource_id LIKE 'artifact:voice-note:%'
               OR resource_id LIKE 'materialized_file:voice-note:%'
            """,
        )
        == 0,
    })
    validations.append({
        "name": "ios_log_ingest_deduplicated",
        "ok": db_scalar(
            db_path,
            "SELECT count(*) FROM logs WHERE origin = 'ios-client' AND message LIKE ?",
            (f"%ROC-6 diagnostic log {stamp}%",),
        )
        == 2,
    })
    validations.append({
        "name": "settings_and_platform_invocations_succeeded_or_failed_expectedly",
        "ok": db_scalar(
            db_path,
            """
            SELECT count(*) FROM engine_invocations
            WHERE idempotency_key LIKE ? AND succeeded = 0
              AND function_id NOT IN ('transcription::audio', 'voice_notes::save')
            """,
            (f"roc6-%-{stamp}",),
        )
        == 0,
    })
    validations.append({
        "name": "no_compaction_events_or_pending_queues",
        "ok": db_scalar(db_path, "SELECT count(*) FROM events WHERE type LIKE 'compact.%'") == 0
        and db_scalar(
            db_path,
            "SELECT count(*) FROM engine_queue_items WHERE status NOT IN ('completed','cancelled','dead_lettered')",
        )
        == 0,
    })
    validations.append({
        "name": "session_exists_for_visible_ios_route",
        "ok": db_scalar(db_path, "SELECT count(*) FROM sessions WHERE id = ?", (session_id,)) == 1,
    })
    return validations


def run_matrix(args):
    stamp = args.stamp or dt.datetime.now(dt.UTC).strftime("%Y%m%d%H%M%S")
    server = start_isolated_server(stamp, args.port, not args.no_build)
    proc = server.pop("process")
    try:
        tron_home = Path(server["tronHome"])
        db_path = Path(server["dbPath"])
        ws, hello = ws_hello(args.port, tron_home, f"roc6-hello-{stamp}")

        settings_value, _ = child(invoke(
            ws,
            "settings::get",
            {},
            f"roc6-settings-get-{stamp}",
            f"roc6-settings-get-{stamp}",
            ["settings.read"],
        ))
        session_value, _ = child(invoke(
            ws,
            "session::create",
            {
                "workingDirectory": str(ROOT),
                "model": "claude-sonnet-4-6",
                "title": f"ROC-6 platform surfaces {stamp}",
                "useWorktree": False,
            },
            f"roc6-session-create-{stamp}",
            f"roc6-session-create-{stamp}",
            ["session.write"],
        ))
        session_id = session_value["sessionId"]

        token = ("ab" * 40) + stamp[-8:]
        device_register_value, _ = child(invoke(
            ws,
            "device::register",
            {
                "deviceToken": token,
                "environment": "sandbox",
                "bundleId": "com.tron.mobile.beta",
            },
            f"roc6-device-register-{stamp}",
            f"roc6-device-register-{stamp}",
            ["device.write"],
        ))
        device_duplicate_value, _ = child(invoke(
            ws,
            "device::register",
            {
                "deviceToken": token,
                "environment": "sandbox",
                "bundleId": "com.tron.mobile.beta",
            },
            f"roc6-device-register-duplicate-{stamp}",
            f"roc6-device-register-duplicate-{stamp}",
            ["device.write"],
        ))
        device_unregister_value, _ = child(invoke(
            ws,
            "device::unregister",
            {"deviceToken": token},
            f"roc6-device-unregister-{stamp}",
            f"roc6-device-unregister-{stamp}",
            ["device.write"],
        ))

        notification_value, _ = child(invoke(
            ws,
            "notifications::send",
            {
                "title": f"ROC-6 {stamp}",
                "body": "Platform surface notification resource",
                "priority": "normal",
                "sessionId": session_id,
                "sheetContent": "ROC-6 notification detail",
            },
            f"roc6-notification-send-{stamp}",
            f"roc6-notification-send-{stamp}",
            ["notifications.write", "resource.write", "resource.read"],
            {"sessionId": session_id},
        ))
        notification_id = notification_value["resourceRefs"][0]["resourceId"]
        listed_notifications, _ = child(invoke(
            ws,
            "notifications::list",
            {"sessionId": session_id, "limit": 10},
            f"roc6-notification-list-{stamp}",
            f"roc6-notification-list-{stamp}",
            ["notifications.read", "resource.read"],
        ))
        event_id = listed_notifications["notifications"][0]["eventId"]
        mark_read_value, _ = child(invoke(
            ws,
            "notifications::mark_read",
            {"eventId": event_id},
            f"roc6-notification-mark-read-{stamp}",
            f"roc6-notification-mark-read-{stamp}",
            ["notifications.write", "resource.write", "resource.read"],
        ))
        mark_all_value, _ = child(invoke(
            ws,
            "notifications::mark_all_read",
            {"sessionId": session_id},
            f"roc6-notification-mark-all-{stamp}",
            f"roc6-notification-mark-all-{stamp}",
            ["notifications.write", "resource.write", "resource.read"],
        ))

        transcription_models, _ = child(invoke(
            ws,
            "transcription::list_models",
            {},
            f"roc6-transcription-models-{stamp}",
            f"roc6-transcription-models-{stamp}",
            ["transcription.read"],
        ))
        transcription_download, _ = child(invoke(
            ws,
            "transcription::download_model",
            {},
            f"roc6-transcription-download-{stamp}",
            f"roc6-transcription-download-{stamp}",
            ["transcription.write"],
        ))
        _, transcription_error = child(invoke(
            ws,
            "transcription::audio",
            {"audioBase64": base64.b64encode(b"not real speech").decode("ascii"), "mimeType": "audio/wav"},
            f"roc6-transcription-audio-{stamp}",
            f"roc6-transcription-audio-{stamp}",
            ["transcription.write"],
            timeout=120,
        ), expect_error=True)
        _, voice_note_error = child(invoke(
            ws,
            "voice_notes::save",
            {"audioBase64": base64.b64encode(b"not real speech").decode("ascii"), "mimeType": "audio/wav"},
            f"roc6-voice-note-save-{stamp}",
            f"roc6-voice-note-save-{stamp}",
            ["voice_notes.write", "resource.write"],
            timeout=120,
        ), expect_error=True)

        log_entries = [
            {
                "timestamp": dt.datetime.now(dt.UTC).isoformat(),
                "level": "info",
                "category": "Diagnostics",
                "message": f"ROC-6 diagnostic log {stamp} one",
            },
            {
                "timestamp": dt.datetime.now(dt.UTC).isoformat(),
                "level": "warning",
                "category": "Diagnostics",
                "message": f"ROC-6 diagnostic log {stamp} two",
            },
        ]
        logs_first, _ = child(invoke(
            ws,
            "logs::ingest",
            {"entries": log_entries},
            f"roc6-logs-ingest-{stamp}",
            f"roc6-logs-ingest-{stamp}",
            ["logs.write"],
        ))
        logs_second, _ = child(invoke(
            ws,
            "logs::ingest",
            {"entries": log_entries},
            f"roc6-logs-ingest-replay-{stamp}",
            f"roc6-logs-ingest-replay-{stamp}",
            ["logs.write"],
        ))

        ws.close()
        final_health = wait_health(args.port)
        validations = collect_validation(db_path, stamp, session_id, token, notification_id)
        ok = all(item["ok"] for item in validations)
        settings_payload = settings_value.get("settings", settings_value)
        result = {
            "ok": ok,
            "stamp": stamp,
            "server": server,
            "hello": hello,
            "sessionId": session_id,
            "settingsSummary": {
                "transcription": settings_payload["server"]["transcription"],
                "update": settings_payload["server"]["update"],
            },
            "device": {
                "register": device_register_value,
                "duplicate": device_duplicate_value,
                "unregister": device_unregister_value,
            },
            "notifications": {
                "send": notification_value,
                "list": listed_notifications,
                "markRead": mark_read_value,
                "markAllRead": mark_all_value,
                "notificationResourceId": notification_id,
            },
            "transcription": {
                "models": transcription_models,
                "download": transcription_download,
                "audioError": transcription_error,
            },
            "voiceNotes": {"saveError": voice_note_error},
            "logs": {"first": logs_first, "replay": logs_second},
            "validations": validations,
            "health": final_health,
            "iphoneScope": {
                "simulatorUdid": args.simulator_udid,
                "bundleId": "com.tron.mobile.beta",
                "manualTesting": "Use Computer Use on the already-open iPhone Simulator; this harness does not deep-link created sessions by default.",
            },
        }
        output_path = args.output or f"/tmp/roc6_platform_surfaces_{stamp}.json"
        with open(output_path, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
        print(json.dumps({"ok": ok, "output": output_path, "sessionId": session_id, "stamp": stamp}, sort_keys=True))
        if not ok:
            return 1
        return 0
    finally:
        returncode, output = stop_server(proc)
        if output and args.verbose_server_output:
            print(output, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--stamp")
    parser.add_argument("--output")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--simulator-udid", default=DEFAULT_SIM_UDID)
    parser.add_argument("--verbose-server-output", action="store_true")
    args = parser.parse_args()
    raise SystemExit(run_matrix(args))


if __name__ == "__main__":
    main()
