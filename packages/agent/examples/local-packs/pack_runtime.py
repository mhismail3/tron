#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import select
import socket
import ssl
import struct
import time
import urllib.parse


def _env(name, default=None):
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def _hash_json(value):
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def _connect_websocket(endpoint, token):
    endpoint = endpoint.strip()
    if "://" not in endpoint:
        endpoint = "ws://" + endpoint
    url = urllib.parse.urlparse(endpoint)
    if url.scheme not in ("ws", "wss"):
        raise RuntimeError("TRON_ENGINE_WORKER_ENDPOINT must use ws:// or wss://")
    host = url.hostname or "127.0.0.1"
    port = url.port or (443 if url.scheme == "wss" else 80)
    path = url.path or "/engine/workers"
    if path.rstrip("/") == "/engine":
        path = "/engine/workers"
    elif path.rstrip("/") != "/engine/workers":
        raise RuntimeError(f"worker endpoint must target /engine/workers, got {path}")
    if url.query:
        path += "?" + url.query
    raw = socket.create_connection((host, port), timeout=10)
    if url.scheme == "wss":
        raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Authorization: Bearer {token}\r\n"
        "\r\n"
    ).encode("ascii")
    raw.sendall(request)
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = raw.recv(4096)
        if not chunk:
            raise RuntimeError("worker websocket closed during handshake")
        response += chunk
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError(response.decode("utf-8", "replace"))
    return raw


def _read_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("worker websocket closed")
        data += chunk
    return data


def _send_json(sock, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    header = bytearray([0x81])
    if len(payload) < 126:
        header.append(0x80 | len(payload))
    elif len(payload) < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", len(payload)))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", len(payload)))
    mask = os.urandom(4)
    header.extend(mask)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(header + masked)


def _recv_json(sock):
    first, second = _read_exact(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _read_exact(sock, 8))[0]
    mask = _read_exact(sock, 4) if second & 0x80 else b""
    payload = _read_exact(sock, length)
    if mask:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if opcode == 8:
        raise EOFError("worker websocket close frame")
    if opcode == 9:
        sock.sendall(bytes([0x8A, 0x00]))
        return _recv_json(sock)
    if opcode != 1:
        return _recv_json(sock)
    return json.loads(payload.decode("utf-8"))


def _visibility_values():
    visibility = _env("TRON_ENGINE_WORKER_VISIBILITY", "workspace")
    engine = {"session": "Session", "workspace": "Workspace", "system": "System"}[visibility]
    worker = {"session": "session", "workspace": "workspace", "system": "system"}[visibility]
    return visibility, engine, worker


def _worker_token(worker_id, namespace, visibility):
    fallback = {
        "pluginId": "local_pack." + worker_id,
        "namespaceClaims": [namespace],
        "authorityGrantId": "worker-runtime",
        "authorityGrantRevision": 1,
        "authorityGrantHash": "local-pack-bootstrap",
        "resourceSelectors": ["*"],
        "visibilityCeiling": visibility,
        "trustTier": "local_digest_pinned",
        "sessionId": _env("TRON_ENGINE_SESSION_ID"),
        "workspaceId": _env("TRON_ENGINE_WORKSPACE_ID"),
        "expiresAt": None,
        "signatureStatus": "unsigned_digest_pinned",
    }
    return json.loads(_env("TRON_ENGINE_WORKER_TOKEN", json.dumps(fallback)))


def _provenance():
    return {
        "created_by": "system",
        "source": "local-example-pack",
        "session_id": _env("TRON_ENGINE_SESSION_ID"),
        "workspace_id": _env("TRON_ENGINE_WORKSPACE_ID"),
    }


def _idempotency_for(effect_class):
    if effect_class in ("PureRead", "DeterministicCompute", "DelegatedInvocation"):
        return None
    return {
        "key_source": "Caller",
        "dedupe_scope": "Session",
        "replay_behavior": "ReturnPrevious",
        "ledger_kind": "EngineLedger",
    }


def _output_contract(kinds):
    if not kinds:
        return {"kind": "none"}
    return {
        "kind": "resourceBacked",
        "produced_resource_kinds": kinds,
        "required_resource_refs": True,
    }


def _function_definition(pack, spec, worker_id, engine_visibility, token):
    function_id = spec["id"]
    local_name = function_id.split("::", 1)[1]
    output_kinds = spec.get("output_resource_kinds", [])
    return {
        "id": function_id,
        "revision": 1,
        "owner_worker": worker_id,
        "description": spec["description"],
        "request_schema": spec.get(
            "request_schema", {"type": "object", "additionalProperties": True}
        ),
        "response_schema": spec.get(
            "response_schema", {"type": "object", "additionalProperties": True}
        ),
        "opaque_response": False,
        "output_contract": _output_contract(output_kinds),
        "tags": spec.get("tags", []),
        "visibility": engine_visibility,
        "effect_class": spec["effect_class"],
        "risk_level": spec.get("risk", "Low"),
        "idempotency": _idempotency_for(spec["effect_class"]),
        "resource_lease": None,
        "compensation": None,
        "required_authority": {
            "scopes": spec.get("required_authority", []),
            "approval_required": False,
        },
        "allowed_delivery_modes": ["Sync"],
        "health": "Healthy",
        "provenance": _provenance(),
        "metadata": {
            "contractId": function_id,
            "implementationId": f"local_pack.{pack['namespace']}.{local_name}",
            "pluginId": token["pluginId"],
            "trustTier": "local_digest_pinned",
            "contextPrimerLevel": "catalog",
            "runtimeRequirements": {"workerKind": "local_process", "deliveryModes": ["Sync"]},
            "examples": spec.get("examples", []),
            "productCategory": pack["category"],
            "modelPreset": pack.get("model_preset", "balanced"),
            "subagentRoles": pack.get("subagent_roles", []),
        },
    }


def _resource_refs(function_id, output_kinds, payload):
    refs = []
    for kind in output_kinds:
        digest = hashlib.sha256(
            json.dumps(payload, sort_keys=True).encode("utf-8")
        ).hexdigest()[:16]
        refs.append({
            "resourceId": f"{kind}:example:{function_id.replace('::', ':')}:{digest}",
            "versionId": f"ver-{digest}",
            "kind": kind,
            "role": "created",
            "contentHash": _hash_json(
                {"functionId": function_id, "payload": payload, "kind": kind}
            ),
        })
    return refs


def _handle(pack, spec, payload):
    summary = {
        "pack": pack["title"],
        "category": pack["category"],
        "functionId": spec["id"],
        "input": payload,
        "recommendation": spec.get("recommendation", "Ready for local review."),
    }
    if spec["handler"] == "repo_health":
        summary["repoHealth"] = ["status", "tests", "scorecard", "evidence"]
    elif spec["handler"] == "daily_digest":
        summary["digest"] = ["today", "next", "waiting"]
    elif spec["handler"] == "creative_transform":
        summary["transform"] = ["prompt", "outline", "surface"]
    refs = _resource_refs(spec["id"], spec.get("output_resource_kinds", []), payload)
    if refs:
        summary["resourceRefs"] = refs
    return summary


def run_pack_worker(pack):
    worker_id = _env("TRON_ENGINE_WORKER_ID", pack["worker_id"])
    namespace = pack["namespace"]
    endpoint = os.environ["TRON_ENGINE_WORKER_ENDPOINT"]
    token_value = os.environ["TRON_ENGINE_BEARER_TOKEN"]
    visibility, engine_visibility, worker_visibility = _visibility_values()
    token = _worker_token(worker_id, namespace, visibility)
    sock = _connect_websocket(endpoint, token_value)
    _send_json(sock, {
        "type": "hello",
        "protocolVersion": int(_env("TRON_ENGINE_WORKER_PROTOCOL_VERSION", "1")),
        "worker": {
            "id": worker_id,
            "revision": 1,
            "kind": "Sandbox",
            "lifecycle": "Ready",
            "owner_actor": "system",
            "authority_grant": token["authorityGrantId"],
            "namespace_claims": [namespace],
            "visibility": engine_visibility,
            "provenance": _provenance(),
        },
        "loopbackOnly": True,
        "identity": {
            "workerId": worker_id,
            "workerName": pack["title"],
            "workerVersion": pack["version"],
            "sandboxed": True,
        },
        "authPolicy": "loopback_bearer",
        "registrationMode": "volatile",
        "defaultVisibility": worker_visibility,
        "sessionId": _env("TRON_ENGINE_SESSION_ID"),
        "workspaceId": _env("TRON_ENGINE_WORKSPACE_ID"),
        "heartbeatIntervalMs": 5000,
        "supportedCapabilities": [spec["id"] for spec in pack["functions"]],
        "workerToken": token,
    })
    while True:
        if _recv_json(sock).get("type") == "catalog_snapshot":
            break
    specs = {spec["id"]: spec for spec in pack["functions"]}
    for spec in pack["functions"]:
        _send_json(sock, {
            "type": "register_function",
            "definition": _function_definition(pack, spec, worker_id, engine_visibility, token),
            "defaultVisibility": engine_visibility,
        })
    last_heartbeat = 0
    sequence = 0
    while True:
        now = time.monotonic()
        if now - last_heartbeat > 2.5:
            sequence += 1
            _send_json(
                sock, {"type": "heartbeat", "workerId": worker_id, "sequence": sequence}
            )
            last_heartbeat = now
        ready, _, _ = select.select([sock], [], [], 0.25)
        if not ready:
            continue
        message = _recv_json(sock)
        if message.get("type") == "disconnect":
            return
        if message.get("type") != "invoke":
            continue
        invocation_id = message["invocationId"]
        function_id = message.get("functionId")
        spec = specs.get(function_id)
        if spec is None:
            _send_json(sock, {
                "type": "result",
                "invocationId": invocation_id,
                "result": None,
                "error": {"message": "unknown function"},
            })
            continue
        result = _handle(pack, spec, message.get("payload", {}))
        _send_json(sock, {
            "type": "result",
            "invocationId": invocation_id,
            "result": result,
            "error": None,
        })
