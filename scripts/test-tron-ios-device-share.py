#!/usr/bin/env python3
"""End-to-end journey for over-the-air development builds.

1. Publisher and server, in a temp fixture: the real publish script lays out
   builds behind the real loopback server; retention, the latest manifest, the
   index, escaping and served content types are checked over a socket.
2. Share-host disable ownership, in a temp HOME with fixture `tailscale` and
   `launchctl` executables first on PATH: the real `share-host disable` entry
   point removes only its own exact :8443 handler and LaunchAgent, refuses
   foreign, mixed, TCP-forward, Funnel and unreadable configurations without
   changing anything, handles an absent handler, and preserves other serve
   ports and retained builds. It never runs the installed Tailscale or
   launchctl.
3. The live journey (skipped with --fixture-only): the real
   `scripts/tron-ios-device share` builds, signs, validates and publishes this
   clean checkout to the share host, then everything the phone fetches - the
   index, latest.plist, the build manifest and the IPA - is downloaded over the
   tailnet HTTPS URL with normal certificate verification, and the IPA is
   checked to be byte-identical, correctly signed and provisioned.

For visual review only, --preview-dir NEW_DIRECTORY renders through the real
publisher with synthetic metadata and non-installable IPAs, without running
tests or contacting a live host. Fixture regression results persist at
`test-results/ios-share-publisher/report.json`. For real-browser acceptance,
see scripts/test-ios-share-browser.js and tools/web/README.md.

The live journey needs this Mac's development signing, a clean checkout and an
enabled share host (`scripts/tron-ios-device share-host enable`); it publishes
a real, installable build. The report is written to
packages/ios-app/build/share-e2e/report.json.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
import plistlib
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
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
FIXTURE_REPORT = ROOT / "test-results" / "ios-share-publisher" / "report.json"
CHECKS: list[dict] = []
BUNDLE_ID = "com.tron.mobile"
LINK = re.compile(r'href="(itms-services://\?action=download-manifest&amp;url=[^"]+)"')


def check(condition: bool, message: str) -> None:
    CHECKS.append({"behavior": message, "passed": condition})
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


def fixture_ipa(tmp: Path) -> Path:
    app = tmp / "src" / "Payload" / "TronMobile.app"
    app.mkdir(parents=True)
    (app / "Info.plist").write_bytes(plistlib.dumps(
        {"CFBundleIdentifier": BUNDLE_ID, "CFBundleShortVersionString": "1.2"}))
    ipa = tmp / "fixture.ipa"
    with zipfile.ZipFile(ipa, "w") as archive:
        archive.write(app / "Info.plist", "Payload/TronMobile.app/Info.plist")
    return ipa


def preview_page(directory: Path) -> None:
    # A fresh, explicitly selected output protects prior review evidence. Only
    # the real publisher renders HTML; these synthetic IPAs cannot be installed.
    directory.mkdir(parents=True, exist_ok=False)
    samples = [
        ("111111111", "More useful build diagnostics", "Clearer connection errors and build details.", "optimized", "preview/build-diagnostics"),
        ("222222222", "A small layout experiment", "A fast-debug build for checking longer titles and notes on a narrow screen.", "fast-debug", "preview/narrow-layout-and-keyboard"),
        ("333333333", "Smoother chat, clearer controls", "Keeps your place while chat updates.\nPolishes controls and makes long messages easier to read.", "optimized", "preview/chat-and-controls"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        ipa = fixture_ipa(Path(tmp))
        for commit, title, notes, mode, branch in samples:
            subprocess.run([sys.executable, str(PUBLISH), "--ipa", str(ipa), "--dir", str(directory),
                            "--base-url", "https://builds.example.ts.net:8443", "--title", title,
                            "--notes", notes, "--commit", commit, "--branch", branch, "--mode", mode],
                           check=True, capture_output=True, text=True)
    print(f"Local fixture preview: {directory / 'index.html'}")
    print("Synthetic metadata and non-installable fixture IPA; no live host was contacted.")


def fixture_journey() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        ipa = fixture_ipa(tmp)
        served = tmp / "served"
        base = "https://host.example.ts.net:8443"
        for n in range(7):
            subprocess.run([sys.executable, str(PUBLISH), "--ipa", str(ipa), "--dir", str(served),
                            "--base-url", base, "--title", f"build {n} <b>", "--notes", "n & m",
                            "--commit", f"{n:07x}abc", "--branch", "feat/x", "--keep", "5"],
                           check=True, capture_output=True, text=True)
            if n == 0:
                removed_build = next((served / "builds").iterdir()).name
            time.sleep(1.05)  # build ids carry a one-second UTC timestamp
        builds = sorted(p.name for p in (served / "builds").iterdir())
        check(len(builds) == 5 and builds[0].endswith("-0000002ab"), "retention keeps the newest 5 builds")

        # Observe entry into the real flock syscall in a spawned publisher, not
        # a timing guess about whether Python has finished starting. The wrapper
        # only signals a pipe; the actual OS lock and complete publisher run.
        before = (served / "index.html").read_bytes()
        read_fd, write_fd = os.pipe()
        wrapper = """import fcntl, os, runpy, sys
real_flock = fcntl.flock
notice = int(sys.argv.pop(1))
def observed_flock(fd, operation):
    os.write(notice, b'entered')
    return real_flock(fd, operation)
fcntl.flock = observed_flock
runpy.run_path(sys.argv.pop(1), run_name='__main__')
"""
        with (served / ".publish.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            child = subprocess.Popen([sys.executable, "-c", wrapper, str(write_fd), str(PUBLISH),
                                      "--ipa", str(ipa), "--dir", str(served), "--base-url", base,
                                      "--title", 'Concurrent <script>alert("x")</script>',
                                      "--notes", 'Notes & <img src=x onerror="alert(1)">',
                                      "--commit", "fffffffabc", "--branch", "feat/lock-and-escaping"],
                                     pass_fds=(write_fd,), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            os.close(write_fd)
            try:
                check(bool(select.select([read_fd], [], [], 10)[0]) and os.read(read_fd, 7) == b"entered",
                      "real publisher reaches the shared publication lock")
                try:
                    child.communicate(timeout=0.2)
                    blocked = False
                except subprocess.TimeoutExpired:
                    blocked = True
                check(blocked and (served / "index.html").read_bytes() == before,
                      "held publication lock prevents a concurrent publish from changing the index")
                fcntl.flock(lock, fcntl.LOCK_UN)
                _, errors = child.communicate(timeout=10)
                check(child.returncode == 0, f"publisher completes after lock release ({errors.decode().strip()})")
            finally:
                os.close(read_fd)
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=10)
        builds = sorted(p.name for p in (served / "builds").iterdir() if not p.name.startswith("."))
        check(len(builds) == 5 and builds[-1].endswith("-fffffffab"),
              "serialized publish still retains five builds with the new build first")

        # Missing CSS must fail before touching an existing tree, not leave a
        # half-published page. Run a real isolated copy with no asset present.
        copied = tmp / "missing-css" / "scripts" / PUBLISH.name
        copied.parent.mkdir(parents=True)
        shutil.copyfile(PUBLISH, copied)
        snapshot = {str(p.relative_to(served)): p.read_bytes() for p in served.rglob("*") if p.is_file()}
        refused = subprocess.run([sys.executable, str(copied), "--ipa", str(ipa), "--dir", str(served),
                                  "--base-url", base, "--title", "unpublished", "--notes", "no CSS",
                                  "--commit", "eeeeeeeabc", "--branch", "fixture/missing-css"], capture_output=True, timeout=10)
        check(refused.returncode != 0 and snapshot == {
            str(p.relative_to(served)): p.read_bytes() for p in served.rglob("*") if p.is_file()},
              "missing stylesheet refuses publication without modifying retained bytes")

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
            check('Concurrent &lt;script&gt;' in page and '<script>' not in page
                  and '&lt;img src=x' in page, "index escapes title and notes instead of executing markup")
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
            for link in links:
                url = manifest_url(link)
                parsed = urllib.parse.urlparse(url)
                check(url.startswith(base + "/builds/") and parsed.path.endswith("/manifest.plist"),
                      "install link stays on the HTTPS manifest route")
                raw, _ = fetch(local + parsed.path)
                record, record_type = fetch(local + parsed.path.rsplit("/", 1)[0] + "/build.json")
                metadata = json.loads(record)
                asset = plistlib.loads(raw)["items"][0]["assets"][0]["url"]
                downloaded, _ = fetch(local + urllib.parse.urlparse(asset).path)
                check(record_type == "application/json" and hashlib.sha256(downloaded).hexdigest() == metadata["sha256"],
                      "each displayed manifest downloads its recorded IPA bytes")
            request = urllib.request.Request(local + "/", method="HEAD")
            with urllib.request.urlopen(request) as response:
                check(response.status == 200 and response.headers.get("Cache-Control") == "no-store",
                      "unchanged static host serves self-contained HTML with no-store on HEAD")
            check(status(local + "/builds/" + removed_build + "/manifest.plist") == 404,
                  "pruned build manifest remains unavailable")
            ready, stop = threading.Event(), threading.Event()
            def read_while_publishing() -> list[bytes]:
                pages = []
                while not stop.is_set():
                    pages.append(fetch(local + "/")[0])
                    ready.set()
                return pages
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                reader = pool.submit(read_while_publishing)
                try:
                    check(ready.wait(5), "HTTP reader is active before republishing")
                    subprocess.run([sys.executable, str(PUBLISH), "--ipa", str(ipa), "--dir", str(served),
                                    "--base-url", base, "--title", "Atomic update", "--notes", "New complete page",
                                    "--commit", "dddddddabc", "--branch", "fixture/atomic", "--mode", "fast-debug"],
                                   check=True, capture_output=True, timeout=10)
                finally:
                    stop.set()
                pages = reader.result()
            after, _ = fetch(local + "/")
            check(after != index and all(p in (index, after) for p in pages),
                  "HTTP reads across publication see only complete old or new index bytes")
        finally:
            server.terminate()
            server.wait(timeout=10)


FAKE_TAILSCALE = """#!/usr/bin/env python3
import json, os, sys
state, log = os.environ["SHARE_FIXTURE_STATE"], os.environ["SHARE_FIXTURE_LOG"]
args = sys.argv[1:]
with open(log, "a") as handle:
    handle.write(json.dumps(["tailscale", *args]) + "\\n")
if args == ["serve", "status", "--json"]:
    if os.path.exists(state + ".down"):
        sys.exit(1)
    sys.stdout.write(open(state).read())
elif len(args) == 3 and args[0] == "serve" and args[1].startswith("--https=") and args[2] == "off":
    # Tailscale clears the whole port: every web host/path, TCP and Funnel entry.
    port = args[1].removeprefix("--https=")
    config = json.load(open(state))
    config["Web"] = {h: c for h, c in (config.get("Web") or {}).items() if not h.endswith(":" + port)}
    (config.get("TCP") or {}).pop(port, None)
    if "AllowFunnel" in config:
        config["AllowFunnel"] = {h: v for h, v in config["AllowFunnel"].items() if not h.endswith(":" + port)}
    json.dump(config, open(state, "w"), sort_keys=True)
else:
    sys.exit(f"fixture tailscale: unexpected {args}")
"""

FAKE_LAUNCHCTL = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["SHARE_FIXTURE_LOG"], "a") as handle:
    handle.write(json.dumps(["launchctl", *sys.argv[1:]]) + "\\n")
"""

HOST = "mac.example.ts.net"
OWNED = {"/": {"Proxy": "http://127.0.0.1:8444"}}
OTHER_PORT = {"Web": {f"{HOST}:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3000"}}}},
              "TCP": {"443": {"HTTPS": True}, "22": {"TCPForward": "127.0.0.1:22"}}}


def serve_config(handlers: dict | None = None, tcp: dict | None = None, funnel: bool = False) -> dict:
    config = json.loads(json.dumps(OTHER_PORT))
    if handlers is not None:
        config["Web"][f"{HOST}:8443"] = {"Handlers": handlers}
    if tcp is not None:
        config["TCP"]["8443"] = tcp
    if funnel:
        config["AllowFunnel"] = {f"{HOST}:8443": True}
    return config


def share_host_disable(tmp: Path, name: str, config: dict | None) -> dict:
    """Run the real disable entry point against one fixture host and report what changed."""
    case = tmp / name
    home, bin_dir = case / "home", case / "bin"
    plist = home / "Library" / "LaunchAgents" / "com.tron.ios-builds.plist"
    build = home / ".tron" / "ios-builds" / "builds" / "20261019T000000Z-abc" / "build.json"
    for path in (plist.parent, build.parent, bin_dir, case / "tmp"):
        path.mkdir(parents=True)
    plist.write_bytes(b"fixture LaunchAgent")
    build.write_text('{"title": "retained"}')
    for tool, source in (("tailscale", FAKE_TAILSCALE), ("launchctl", FAKE_LAUNCHCTL)):
        (bin_dir / tool).write_text(source)
        (bin_dir / tool).chmod(0o755)
    state, log = case / "serve.json", case / "calls.jsonl"
    state.write_text(json.dumps(config if config is not None else {}, sort_keys=True))
    if config is None:
        Path(str(state) + ".down").touch()
    before = json.loads(state.read_text())
    env = {"HOME": str(home), "TMPDIR": str(case / "tmp"), "PATH": f"{bin_dir}:/usr/bin:/bin",
           "SHARE_FIXTURE_STATE": str(state), "SHARE_FIXTURE_LOG": str(log)}
    run = subprocess.run([str(COMMAND), "share-host", "disable"], env=env, capture_output=True, text=True, timeout=60)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return {"returncode": run.returncode, "output": run.stdout + run.stderr, "calls": calls,
            "before": before, "after": json.loads(state.read_text()), "plist": plist.exists(),
            "build": build.read_text() == '{"title": "retained"}'}


def share_host_journey() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        owned = share_host_disable(tmp, "owned", serve_config(OWNED, {"HTTPS": True}))
        check(owned["returncode"] == 0 and ["tailscale", "serve", "--https=8443", "off"] in owned["calls"]
              and owned["after"] == serve_config() and not owned["plist"] and owned["build"]
              and any(c[:2] == ["launchctl", "bootout"] for c in owned["calls"]),
              "disable removes its own exact :8443 handler and LaunchAgent, keeping other ports and builds")

        refusals = {
            "foreign": serve_config({"/": {"Proxy": "http://127.0.0.1:9000"}}, {"HTTPS": True}),
            "mixed": serve_config({**OWNED, "/app/": {"Proxy": "http://127.0.0.1:9100"}}, {"HTTPS": True}),
            "tcp-forward": serve_config(None, {"TCPForward": "127.0.0.1:9200"}),
            "funnel": serve_config(OWNED, {"HTTPS": True}, funnel=True),
            "unreadable": None,
        }
        for name, config in refusals.items():
            result = share_host_disable(tmp, name, config)
            changed = [c for c in result["calls"] if c != ["tailscale", "serve", "status", "--json"]]
            check(result["returncode"] != 0 and "nothing changed" in result["output"] and not changed
                  and result["after"] == result["before"] and result["plist"] and result["build"],
                  f"disable refuses a {name} :8443 configuration and changes nothing")

        absent = share_host_disable(tmp, "absent", serve_config())
        check(absent["returncode"] == 0 and absent["after"] == serve_config() and not absent["plist"]
              and absent["build"] and not any(c[:2] == ["tailscale", "serve"] and c[-1] == "off" for c in absent["calls"]),
              "disable with no :8443 handler removes only the LaunchAgent")


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
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--fixture-only", action="store_true", help="temporary publisher/server and share-host fixture checks; no live publish")
    mode.add_argument("--preview-dir", type=Path, help="render a non-installable fixture into a NEW output directory; no tests or live publish")
    args = parser.parse_args()
    if args.preview_dir:
        preview_page(args.preview_dir.resolve())
        return
    completed = False
    try:
        fixture_journey()
        share_host_journey()
        completed = True
    finally:
        FIXTURE_REPORT.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE_REPORT.write_text(json.dumps({
            "command": "python3 scripts/test-tron-ios-device-share.py --fixture-only",
            "checks": CHECKS, "passed": completed and all(c["passed"] for c in CHECKS),
        }, indent=2) + "\n")
        print(f"fixture report: {FIXTURE_REPORT.relative_to(ROOT)}")
    if not args.fixture_only:
        live_journey()


if __name__ == "__main__":
    main()
