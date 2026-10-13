#!/usr/bin/env python3
"""End-to-end journey for `scripts/tron-ios-device share`.

Runs the real command (XcodeGen, signed device build, artifact and protocol
validation, IPA packaging, HTTP upload) against a loopback server that speaks
the Speedflight API, then inspects the IPA that arrived over the socket. It
needs this Mac's development signing and a clean, pushed checkout, so it is a
maintainer/agent journey rather than a CI check. The report is written to
packages/ios-app/build/share-e2e/report.json.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMMAND = ROOT / "scripts" / "tron-ios-device"
REPORT = ROOT / "packages" / "ios-app" / "build" / "share-e2e" / "report.json"
BUNDLE_ID = "com.tron.mobile"


class Speedflight(BaseHTTPRequestHandler):
    """The subset of https://speedflight.dev's write API the command uses."""

    received: dict = {}

    def log_message(self, *_args):
        pass

    def _body(self) -> bytes:
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def _reply(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        match = re.fullmatch(r"/api/apps/([^/]+)/([^/]+)/builds", self.path)
        if not match:
            return self._reply(404, {"error": "not found"})
        self.received.update(secret=match[1], bundle=match[2], meta=json.loads(self._body()))
        self._reply(201, {"buildId": "b1", "pageId": "p1", "pageUrl": f"http://127.0.0.1:{self.server.server_port}/a/p1"})

    def do_PUT(self):
        match = re.fullmatch(r"/api/apps/([^/]+)/([^/]+)/builds/b1/app\.ipa", self.path)
        if not match:
            return self._reply(404, {"error": "not found"})
        self.received["ipa"] = self._body()
        self._reply(200, {"ok": True})


def run(env: dict, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(COMMAND), "share", *args], env=env, cwd=ROOT,
                          capture_output=True, text=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"ok: {message}", flush=True)


def main() -> None:
    status = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
    if status.strip():
        raise SystemExit("FAIL: share needs a clean checkout; commit and push first")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    upload_secret = secrets.token_hex(24)
    base_env = {**os.environ, "TRON_IOS_GATEWAY_PROTOCOL_TARGET": "source", "TRON_SPEEDFLIGHT_AUTHOR": "share-e2e"}

    # Refusals happen before any build work.
    started = time.monotonic()
    weak = run({**base_env, "TRON_SPEEDFLIGHT_SECRET": "short"}, "--title", "t", "--notes", "n")
    check(weak.returncode != 0 and "32-128" in weak.stderr, "malformed upload secret is refused")
    plain = run({**base_env, "TRON_SPEEDFLIGHT_SECRET": upload_secret, "TRON_SPEEDFLIGHT_BASE": "http://example.com"},
                "--title", "t", "--notes", "n")
    check(plain.returncode != 0 and "https" in plain.stderr, "non-https service URL is refused")
    check(time.monotonic() - started < 30, "refusals fail before building")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Speedflight)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        env = {**base_env, "TRON_SPEEDFLIGHT_SECRET": upload_secret,
               "TRON_SPEEDFLIGHT_BASE": f"http://127.0.0.1:{server.server_port}"}
        started = time.monotonic()
        shared = run(env, "--title", "share-e2e", "--notes", "journey build")
        elapsed = time.monotonic() - started
    finally:
        server.shutdown()
    output = shared.stdout + shared.stderr
    if shared.returncode != 0:
        sys.stderr.write(output[-4000:])
    check(shared.returncode == 0, "share succeeds")
    check(upload_secret not in output, "upload secret never printed")
    lines = [line for line in shared.stdout.splitlines() if line.strip()]
    page = f"http://127.0.0.1:{server.server_port}/a/p1"
    check(lines[-1] == f"Build page: {page}", "last line is the build page link")

    received = Speedflight.received
    check(received.get("secret") == upload_secret and received.get("bundle") == BUNDLE_ID, "secret and bundle id route the upload")
    meta = received["meta"]
    check(meta["commit"] == head and meta["deepLink"] == "tron://" and meta["title"] == "share-e2e", "metadata names the pushed commit")

    with tempfile.TemporaryDirectory() as tmp:
        ipa = Path(tmp) / "app.ipa"
        ipa.write_bytes(received["ipa"])
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(tmp)
        apps = list((Path(tmp) / "Payload").glob("*.app"))
        check(len(apps) == 1, "IPA holds exactly one app under Payload/")
        app = apps[0]
        info = plistlib.loads((app / "Info.plist").read_bytes())
        check(info["CFBundleIdentifier"] == BUNDLE_ID, "IPA app is the canonical device identity")
        # The device checks this signature after the over-the-air download.
        verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True)
        check(verify.returncode == 0, f"extracted app signature verifies {verify.stderr.strip()}")
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")]))
        devices = profile.get("ProvisionedDevices", [])
        check(len(devices) > 0, "development profile lists registered devices for over-the-air install")
        entitlements = profile.get("Entitlements", {})

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({
        "commit": head,
        "share_seconds": round(elapsed, 1),
        "ipa_bytes": len(received["ipa"]),
        "provisioned_device_count": len(devices),
        "aps_environment": entitlements.get("aps-environment"),
        "bundle_id": BUNDLE_ID,
    }, indent=2) + "\n")
    print(f"report: {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
