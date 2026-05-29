#!/usr/bin/env python3
"""Deterministic live worker fixture for the RWO-N15 queue/trigger/stream scenario."""

import argparse
import json
import os
import select
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rwo_n7_live_worker_fixture as base

DEFAULT_ENDPOINT = base.DEFAULT_ENDPOINT
DEFAULT_AUTH_PATH = base.DEFAULT_AUTH_PATH
DEFAULT_WORKER_ID = "rwo-n15-fixture-worker"
DEFAULT_FUNCTION_ID = "rwo_n15::queued_echo"
DEFAULT_TRIGGER_ID = "manual:rwo_n15.queued_echo"
DEFAULT_STREAM_TOPIC = "rwo_n15.worker.events"

STOP = False


def request_stop(_signum, _frame):
    global STOP
    STOP = True


def scoped_provenance(args):
    return {
        "created_by": "system",
        "source": "rwo-n15-live-worker-fixture",
        "session_id": args.session_id,
        "workspace_id": args.workspace_id,
    }


def worker_token(args):
    namespace = base.namespace_from_function(args.function_id)
    return {
        "pluginId": f"session_generated.{args.worker_id}",
        "namespaceClaims": [namespace],
        "authorityGrantId": "worker-runtime",
        "authorityGrantRevision": 1,
        "authorityGrantHash": "loopback-bootstrap",
        "resourceSelectors": ["*"],
        "visibilityCeiling": args.visibility,
        "trustTier": "session_generated",
        "sessionId": args.session_id,
        "workspaceId": args.workspace_id,
        "expiresAt": None,
        "signatureStatus": "session_scoped",
    }


def worker_definition(args, token):
    namespace = base.namespace_from_function(args.function_id)
    return {
        "id": args.worker_id,
        "revision": 1,
        "kind": "External",
        "lifecycle": "Ready",
        "owner_actor": "rwo-n15-fixture-owner",
        "authority_grant": token["authorityGrantId"],
        "namespace_claims": [namespace],
        "visibility": base.engine_visibility(args.visibility),
        "provenance": scoped_provenance(args),
    }


def function_definition(args):
    namespace = base.namespace_from_function(args.function_id)
    return {
        "id": args.function_id,
        "revision": 1,
        "owner_worker": args.worker_id,
        "description": "RWO-N15 deterministic queued live worker echo fixture",
        "request_schema": {"type": "object", "additionalProperties": True},
        "response_schema": {"type": "object", "additionalProperties": True},
        "opaque_response": False,
        "tags": ["rwo-n15", "live-worker", "queue", "trigger", "stream"],
        "visibility": base.engine_visibility(args.visibility),
        "effect_class": "PureRead",
        "risk_level": "Low",
        "idempotency": None,
        "resource_lease": None,
        "compensation": None,
        "output_contract": {"kind": "none"},
        "required_authority": {"scopes": ["rwo_n15.invoke"], "approval_required": False},
        "allowed_delivery_modes": ["Sync", "Enqueue"],
        "health": "Healthy",
        "provenance": scoped_provenance(args),
        "metadata": {
            "contractId": args.function_id,
            "implementationId": f"session_generated.{namespace}.queued_echo",
            "pluginId": f"session_generated.{args.worker_id}",
            "trustTier": "session_generated",
            "contextPrimerLevel": "catalog",
            "runtimeRequirements": {"workerKind": "external", "deliveryModes": ["Sync", "Enqueue"]},
            "examples": [{"payload": {"message": "rwo-n15", "nonce": "example"}}],
            "modelPrimitiveName": "rwo_n15_queued_echo",
            "streamTopics": [args.stream_topic, "worker.lifecycle", "queue.lifecycle"],
        },
    }


def trigger_definition(args):
    return {
        "id": args.trigger_id,
        "revision": 1,
        "owner_worker": args.worker_id,
        "trigger_type": "manual",
        "target_function": args.function_id,
        "target_revision": None,
        "config": {"purpose": "RWO-N15 queued trigger fixture", "queue": "default"},
        "delivery_mode": "Enqueue",
        "authority_grant": "worker-runtime",
        "idempotency_key_strategy": None,
        "max_depth": 1,
        "visibility": base.engine_visibility(args.visibility),
        "provenance": scoped_provenance(args),
    }


def stream_publish_message(args, invoke_message, result):
    return {
        "type": "publish_stream",
        "workerId": args.worker_id,
        "topic": args.stream_topic,
        "payload": {
            "rwoN15Fixture": True,
            "workerId": args.worker_id,
            "functionId": args.function_id,
            "triggerId": invoke_message.get("triggerId"),
            "invocationId": invoke_message.get("invocationId"),
            "result": result,
        },
        "visibility": base.engine_visibility(args.visibility),
        "sessionId": invoke_message.get("sessionId") or args.session_id,
        "workspaceId": invoke_message.get("workspaceId") or args.workspace_id,
        "traceId": invoke_message.get("traceId"),
        "parentInvocationId": invoke_message.get("invocationId"),
        "idempotencyKey": f"rwo-n15-stream:{invoke_message.get('invocationId')}",
    }


def run_fixture(args):
    token = worker_token(args)
    bearer = base.load_bearer_token(args.auth_path)
    log_handle = open(args.log, "a", encoding="utf-8") if args.log else None
    sock = None
    heartbeat_sequence = 0
    try:
        sock = base.connect_websocket(args.endpoint, bearer)
        base.log_event(log_handle, "connected", endpoint=args.endpoint, workerId=args.worker_id)
        base.send_json(sock, {
            "type": "hello",
            "protocolVersion": 1,
            "worker": worker_definition(args, token),
            "loopbackOnly": True,
            "identity": {
                "workerId": args.worker_id,
                "workerName": "RWO-N15 live worker fixture",
                "workerVersion": "rwo-n15-1",
                "sandboxed": False,
            },
            "authPolicy": "loopback_bearer",
            "registrationMode": "volatile",
            "defaultVisibility": args.visibility,
            "sessionId": args.session_id,
            "workspaceId": args.workspace_id,
            "heartbeatIntervalMs": args.heartbeat_interval_ms,
            "supportedCapabilities": [args.function_id, args.trigger_id, args.stream_topic],
            "workerToken": token,
        })
        base.send_json(sock, {
            "type": "register_function",
            "definition": function_definition(args),
            "defaultVisibility": base.engine_visibility(args.visibility),
        })
        base.send_json(sock, {"type": "register_trigger", "definition": trigger_definition(args)})
        base.log_event(
            log_handle,
            "registration_sent",
            workerId=args.worker_id,
            functionId=args.function_id,
            triggerId=args.trigger_id,
            streamTopic=args.stream_topic,
            visibility=args.visibility,
        )

        next_heartbeat = 0.0
        while not STOP:
            now = time.monotonic()
            if now >= next_heartbeat:
                heartbeat_sequence += 1
                base.send_heartbeat(sock, args, heartbeat_sequence, log_handle)
                next_heartbeat = now + args.heartbeat_interval_ms / 2000

            readable, _, _ = select.select([sock], [], [], 0.25)
            if not readable:
                continue
            message = base.recv_json(sock)
            if message is None:
                continue
            message_type = message.get("type")
            if message_type == "error":
                base.log_event(log_handle, "server_error", message=message.get("message"))
                raise RuntimeError(message.get("message", "server_error"))
            if message_type in ("catalog_snapshot", "catalog_change"):
                base.log_event(log_handle, "worker_protocol_event", message=base.summarize_protocol_message(args, message))
                continue
            if message_type == "invoke":
                invocation_id = message["invocationId"]
                if message.get("functionId") != args.function_id:
                    base.send_json(sock, {
                        "type": "result",
                        "invocationId": invocation_id,
                        "result": None,
                        "error": {"message": "unknown function"},
                    })
                    base.log_event(log_handle, "invoke_rejected", invocationId=invocation_id)
                    continue
                payload = message.get("payload", {})
                result = {
                    "rwoN15Fixture": True,
                    "workerId": args.worker_id,
                    "functionId": args.function_id,
                    "invocationId": invocation_id,
                    "traceId": message.get("traceId"),
                    "sessionId": message.get("sessionId"),
                    "triggerId": message.get("triggerId"),
                    "echo": payload,
                }
                base.send_json(sock, stream_publish_message(args, message, result))
                base.log_event(log_handle, "stream_publish_sent", invocationId=invocation_id, topic=args.stream_topic)
                base.send_json(sock, {
                    "type": "result",
                    "invocationId": invocation_id,
                    "result": result,
                    "error": None,
                })
                base.log_event(log_handle, "invoke_completed", invocationId=invocation_id, result=result)
                if args.exit_after_invoke:
                    return
                continue
            if message_type == "disconnect":
                base.log_event(log_handle, "server_disconnect", message=message)
                return
            base.log_event(log_handle, "unhandled_message", message=message)
    finally:
        if sock is not None:
            try:
                base.send_json(sock, {
                    "type": "disconnect",
                    "workerId": args.worker_id,
                    "reason": "fixture stopped",
                })
                base.log_event(log_handle, "disconnect_sent", workerId=args.worker_id)
                base.send_frame(sock, 0x8)
            except Exception as error:
                base.log_event(log_handle, "disconnect_error", error=str(error))
            try:
                sock.close()
            except Exception:
                pass
        if log_handle:
            log_handle.close()


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default=os.environ.get("TRON_ENGINE_WORKER_ENDPOINT", DEFAULT_ENDPOINT))
    parser.add_argument("--auth-path", default=DEFAULT_AUTH_PATH)
    parser.add_argument("--worker-id", default=DEFAULT_WORKER_ID)
    parser.add_argument("--function-id", default=DEFAULT_FUNCTION_ID)
    parser.add_argument("--trigger-id", default=DEFAULT_TRIGGER_ID)
    parser.add_argument("--stream-topic", default=DEFAULT_STREAM_TOPIC)
    parser.add_argument("--visibility", choices=["session", "workspace", "system"], default="session")
    parser.add_argument("--session-id")
    parser.add_argument("--workspace-id")
    parser.add_argument("--heartbeat-interval-ms", type=int, default=5000)
    parser.add_argument("--log")
    parser.add_argument("--exit-after-invoke", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv):
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    args = parse_args(argv)
    if args.visibility == "session" and not args.session_id:
        raise SystemExit("--session-id is required for session visibility")
    if args.visibility == "workspace" and not args.workspace_id:
        raise SystemExit("--workspace-id is required for workspace visibility")
    if args.self_test:
        token = worker_token(args)
        assert function_definition(args)["allowed_delivery_modes"] == ["Sync", "Enqueue"]
        assert trigger_definition(args)["delivery_mode"] == "Enqueue"
        assert worker_definition(args, token)["authority_grant"] == token["authorityGrantId"]
        print(json.dumps({"ok": True, "functionId": args.function_id, "triggerId": args.trigger_id}))
        return 0
    run_fixture(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
