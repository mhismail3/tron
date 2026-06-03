#!/usr/bin/env python3
import base64
import json
import os
import select
import socket
import ssl
import struct
import time
import urllib.parse

WORKER_ID = os.environ.get("TRON_ENGINE_WORKER_ID", "disposable-helper-worker")
FUNCTION_ID = "disposable::hello"
NAMESPACE = "disposable"
ENDPOINT = os.environ["TRON_ENGINE_WORKER_ENDPOINT"]
TOKEN = os.environ["TRON_ENGINE_BEARER_TOKEN"]
VISIBILITY = os.environ.get("TRON_ENGINE_WORKER_VISIBILITY", "session")
SESSION_ID = os.environ.get("TRON_ENGINE_SESSION_ID")
WORKSPACE_ID = os.environ.get("TRON_ENGINE_WORKSPACE_ID")
PROTOCOL_VERSION = int(os.environ.get("TRON_ENGINE_WORKER_PROTOCOL_VERSION", "1"))
WORKER_TOKEN = json.loads(os.environ.get("TRON_ENGINE_WORKER_TOKEN", "{}"))
ENGINE_VISIBILITY = {"session": "Session", "workspace": "Workspace", "system": "System"}[VISIBILITY]
WORKER_VISIBILITY = {"session": "session", "workspace": "workspace", "system": "system"}[VISIBILITY]


def connect_websocket():
    endpoint = ENDPOINT if "://" in ENDPOINT else "ws://" + ENDPOINT
    url = urllib.parse.urlparse(endpoint)
    host = url.hostname or "127.0.0.1"
    port = url.port or (443 if url.scheme == "wss" else 80)
    path = url.path or "/engine/workers"
    if path.rstrip("/") == "/engine":
        path = "/engine/workers"
    raw = socket.create_connection((host, port), timeout=10)
    if url.scheme == "wss":
        raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    raw.sendall((
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Authorization: Bearer {TOKEN}\r\n\r\n"
    ).encode("ascii"))
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = raw.recv(4096)
        if not chunk:
            raise RuntimeError("websocket closed during handshake")
        response += chunk
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError(response.decode("utf-8", "replace"))
    return raw


def read_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("websocket closed")
        data += chunk
    return data


def send_json(sock, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    header = bytearray([0x81])
    if len(payload) < 126:
        header.append(0x80 | len(payload))
    else:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", len(payload)))
    mask = os.urandom(4)
    header.extend(mask)
    header.extend(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(header)


def recv_json(sock):
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    mask = read_exact(sock, 4) if second & 0x80 else b""
    payload = read_exact(sock, length)
    if mask:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if opcode == 8:
        raise EOFError("close frame")
    if opcode == 9:
        sock.sendall(bytes([0x8A, 0x00]))
        return recv_json(sock)
    if opcode != 1:
        return recv_json(sock)
    return json.loads(payload.decode("utf-8"))


def provenance():
    return {"created_by": "system", "source": "sandbox-worker", "session_id": SESSION_ID, "workspace_id": WORKSPACE_ID}


def function_definition():
    return {
        "id": FUNCTION_ID,
        "revision": 1,
        "owner_worker": WORKER_ID,
        "description": "Disposable session helper that returns a greeting and the provided name.",
        "request_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "additionalProperties": False},
        "response_schema": {"type": "object", "properties": {"message": {"type": "string"}, "workerId": {"type": "string"}}, "required": ["message", "workerId"], "additionalProperties": False},
        "opaque_response": False,
        "output_contract": {"kind": "none"},
        "tags": ["disposable", "helper", "self-extension"],
        "visibility": ENGINE_VISIBILITY,
        "effect_class": "PureRead",
        "risk_level": "Low",
        "idempotency": None,
        "resource_lease": None,
        "compensation": None,
        "required_authority": {"scopes": [], "approval_required": False},
        "allowed_delivery_modes": ["Sync"],
        "health": "Healthy",
        "provenance": provenance(),
        "metadata": {"contractId": FUNCTION_ID, "implementationId": "session_generated.disposable.hello", "pluginId": "session_generated." + WORKER_ID, "trustTier": "session_generated", "contextPrimerLevel": "catalog", "runtimeRequirements": {"workerKind": "sandbox", "deliveryModes": ["Sync"]}, "examples": [{"name": "Moose"}], "modelPrimitiveName": "disposable_hello", "streamTopics": []},
    }


def main():
    sock = connect_websocket()
    send_json(sock, {"type": "hello", "protocolVersion": PROTOCOL_VERSION, "worker": {"id": WORKER_ID, "revision": 1, "kind": "Sandbox", "lifecycle": "Ready", "owner_actor": "system", "authority_grant": WORKER_TOKEN.get("authorityGrantId", "worker-runtime"), "namespace_claims": [NAMESPACE], "visibility": ENGINE_VISIBILITY, "provenance": provenance()}, "loopbackOnly": True, "identity": {"workerId": WORKER_ID, "workerName": WORKER_ID, "workerVersion": "disposable-1", "sandboxed": True}, "authPolicy": "loopback_bearer", "registrationMode": "volatile", "defaultVisibility": WORKER_VISIBILITY, "sessionId": SESSION_ID, "workspaceId": WORKSPACE_ID, "heartbeatIntervalMs": 5000, "supportedCapabilities": [FUNCTION_ID], "workerToken": WORKER_TOKEN})
    send_json(sock, {"type": "register_function", "definition": function_definition(), "defaultVisibility": ENGINE_VISIBILITY})
    last_heartbeat = 0
    sequence = 0
    while True:
        now = time.monotonic()
        if now - last_heartbeat > 2.5:
            sequence += 1
            send_json(sock, {"type": "heartbeat", "workerId": WORKER_ID, "sequence": sequence})
            last_heartbeat = now
        ready, _, _ = select.select([sock], [], [], 0.25)
        if not ready:
            continue
        message = recv_json(sock)
        if message.get("type") == "invoke":
            name = message.get("payload", {}).get("name", "there")
            send_json(sock, {"type": "result", "invocationId": message["invocationId"], "result": {"message": f"hello, {name}", "workerId": WORKER_ID}, "error": None})
        elif message.get("type") == "disconnect":
            return


if __name__ == "__main__":
    main()
