#!/usr/bin/env python3
"""End-to-end journey for over-the-air development builds.

1. Publisher and server, in a temp fixture: the real publish script lays out
   builds behind the real loopback server; retention, the latest manifest, the
   index, escaping and served content types are checked over a socket.
2. The live journey (skipped with --fixture-only): the real
   `scripts/tron-ios-device share` builds, signs, validates and publishes this
   clean checkout to the share host, then everything the phone fetches - the
   index, latest.plist, the build manifest and the IPA - is downloaded over the
   tailnet HTTPS URL with normal certificate verification, and the IPA is
   checked to be byte-identical, correctly signed and provisioned.

The live journey needs this Mac's development signing, a clean checkout and an
enabled share host (`scripts/tron-ios-device share-host enable`); it publishes
a real, installable build. The report is written to
packages/ios-app/build/share-e2e/report.json.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMMAND = ROOT / "scripts" / "tron-ios-device"
PUBLISH = ROOT / "scripts" / "ios-share-publish.py"
SERVER = ROOT / "scripts" / "ios-share-server.py"
REPORT = ROOT / "packages" / "ios-app" / "build" / "share-e2e" / "report.json"
BUNDLE_ID = "com.tron.mobile"
LINK = re.compile(r'href="(itms-services://\?action=download-manifest&amp;url=[^"]+)"')


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"ok: {message}", flush=True)


def fetch(url: str) -> tuple[bytes, str]:
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read(), response.headers.get("Content-Type", "")


def status(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def manifest_url(install_link: str) -> str:
    query = urllib.parse.urlparse(install_link.replace("&amp;", "&")).query
    return urllib.parse.parse_qs(query)["url"][0]


def fixture_journey() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        app = tmp / "src" / "Payload" / "TronMobile.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleIdentifier": BUNDLE_ID, "CFBundleShortVersionString": "1.2"}))
        ipa = tmp / "fixture.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.write(app / "Info.plist", "Payload/TronMobile.app/Info.plist")
        served = tmp / "served"
        base = "https://host.example.ts.net:8443"
        for n in range(7):
            subprocess.run([sys.executable, str(PUBLISH), "--ipa", str(ipa), "--dir", str(served),
                            "--base-url", base, "--title", f"build {n} <b>", "--notes", "n & m",
                            "--commit", f"{n:07x}abc", "--branch", "feat/x", "--keep", "5"],
                           check=True, capture_output=True, text=True)
            time.sleep(1.05)  # build ids carry a one-second UTC timestamp
        builds = sorted(p.name for p in (served / "builds").iterdir())
        check(len(builds) == 5 and builds[0].endswith("-0000002ab"), "retention keeps the newest 5 builds")

        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        server = subprocess.Popen([sys.executable, str(SERVER), str(served), str(port)],
                                  stderr=subprocess.DEVNULL)
        try:
            local = f"http://127.0.0.1:{port}"
            for _ in range(50):
                try:
                    fetch(local + "/latest.plist")
                    break
                except OSError:
                    time.sleep(0.1)
            index, index_type = fetch(local + "/")
            page = index.decode()
            check(index_type.startswith("text/html") and page.count("<section") == 5, "index lists the kept builds")
            check("build 6 &lt;b&gt;" in page and "<b>" not in page.split("<body>")[1], "index escapes build text")
            links = LINK.findall(page)
            check(manifest_url(links[0]) == f"{base}/builds/{builds[-1]}/manifest.plist", "first install link is the newest build")
            latest, latest_type = fetch(local + "/latest.plist")
            check(latest_type == "text/xml", "manifest is served as XML")
            item = plistlib.loads(latest)["items"][0]
            check(item["assets"][0]["url"] == f"{base}/builds/{builds[-1]}/TronMobile.ipa"
                  and item["metadata"]["bundle-identifier"] == BUNDLE_ID, "latest manifest names the newest IPA")
            body, ipa_type = fetch(f"{local}/builds/{builds[-1]}/TronMobile.ipa")
            check(body == ipa.read_bytes() and ipa_type == "application/octet-stream", "IPA is served byte-identical")
            check(status(local + "/builds/") == 404, "directories are never listed")
        finally:
            server.terminate()
            server.wait(timeout=10)


def live_journey() -> None:
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
    if dirty.strip():
        raise SystemExit("FAIL: share needs a clean checkout; commit first")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    subject = subprocess.check_output(["git", "log", "-1", "--format=%s"], cwd=ROOT, text=True).strip()

    started = time.monotonic()
    refused = subprocess.run([str(COMMAND), "share", "--title", "t"], cwd=ROOT, capture_output=True, text=True)
    check(refused.returncode != 0 and "--notes" in refused.stderr and time.monotonic() - started < 10,
          "share without notes is refused before building")

    started = time.monotonic()
    shared = subprocess.run([str(COMMAND), "share", "--title", "share journey",
                             "--notes", f"E2E journey build of {head[:9]}: {subject}"],
                            cwd=ROOT, capture_output=True, text=True)
    elapsed = time.monotonic() - started
    if shared.returncode != 0:
        sys.stderr.write((shared.stdout + shared.stderr)[-4000:])
    check(shared.returncode == 0, "share succeeds")
    lines = [line for line in shared.stdout.splitlines() if line.strip()]
    check(lines[-2].startswith("Install page: https://") and lines[-1].startswith("Install link: itms-services://"),
          "share prints the install page and link last")
    page_url = lines[-2].removeprefix("Install page: ")
    install_link = lines[-1].removeprefix("Install link: ")
    check(manifest_url(install_link) == page_url + "latest.plist", "install link targets the latest manifest")

    # Every fetch below verifies the certificate, as iOS does.
    index, _ = fetch(page_url)
    newest = manifest_url(LINK.findall(index.decode())[0])
    check(f"<code>{head[:9]}</code>" in index.decode().split("</section>")[0], "index shows this commit first")
    latest, _ = fetch(page_url + "latest.plist")
    build_manifest, _ = fetch(newest)
    check(latest == build_manifest, "latest.plist is the newest build manifest")
    item = plistlib.loads(latest)["items"][0]
    ipa_url = item["assets"][0]["url"]
    check(ipa_url.startswith(page_url) and item["metadata"]["bundle-identifier"] == BUNDLE_ID,
          "manifest names an IPA on the same tailnet HTTPS origin")
    ipa_bytes, _ = fetch(ipa_url)
    record, _ = fetch(ipa_url.rsplit("/", 1)[0] + "/build.json")
    record = json.loads(record)
    local_ipa = ROOT / "packages" / "ios-app" / "build" / "share" / "TronMobile.ipa"
    digest = hashlib.sha256(ipa_bytes).hexdigest()
    check(digest == record["sha256"] == hashlib.sha256(local_ipa.read_bytes()).hexdigest()
          and record["commit"] == head, "served IPA is the built IPA of this commit")

    with tempfile.TemporaryDirectory() as tmp:
        ipa = Path(tmp) / "app.ipa"
        ipa.write_bytes(ipa_bytes)
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(tmp)
        apps = list((Path(tmp) / "Payload").glob("*.app"))
        check(len(apps) == 1, "IPA holds exactly one app under Payload/")
        app = apps[0]
        info = plistlib.loads((app / "Info.plist").read_bytes())
        check(info["CFBundleIdentifier"] == BUNDLE_ID, "IPA app is the canonical device identity")
        # The device checks this signature after the over-the-air download.
        verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True)
        check(verify.returncode == 0, f"downloaded app signature verifies {verify.stderr.strip()}")
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")]))
        devices = profile.get("ProvisionedDevices", [])
        check(len(devices) > 0, "development profile lists registered devices for over-the-air install")
        entitlements = profile.get("Entitlements", {})

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps({
        "commit": head,
        "share_seconds": round(elapsed, 1),
        "install_page": page_url,
        "install_link": install_link,
        "ipa_url": ipa_url,
        "ipa_bytes": len(ipa_bytes),
        "ipa_sha256": digest,
        "provisioned_device_count": len(devices),
        "get_task_allow": entitlements.get("get-task-allow"),
        "aps_environment": entitlements.get("aps-environment"),
        "bundle_id": BUNDLE_ID,
    }, indent=2) + "\n")
    print(f"report: {REPORT.relative_to(ROOT)}")


def main() -> None:
    fixture_journey()
    if "--fixture-only" not in sys.argv[1:]:
        live_journey()


if __name__ == "__main__":
    main()
