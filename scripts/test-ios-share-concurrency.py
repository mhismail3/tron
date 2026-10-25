#!/usr/bin/env python3
"""Real publisher CLI/process/filesystem journey; private non-installable IPA only."""
from __future__ import annotations

import hashlib
import html
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parent.parent
PUBLISH = ROOT / "scripts/ios-share-publish.py"
REPORT = ROOT / "test-results/ios-share-concurrency/report.json"
BASE = "https://fixture.invalid"
# Only the clock is fixed. Each subprocess executes the complete unmodified
# publisher front door, real flock, ZIP reads, staging, renames and retention.
CLOCK = """import datetime, runpy, sys
second = int(sys.argv.pop(1))
class Clock(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 10, 25, 12, 0, second, tzinfo=datetime.timezone.utc)
datetime.datetime = Clock
runpy.run_path(sys.argv.pop(1), run_name='__main__')
"""


class ConcurrentPublicationTests(unittest.TestCase):
    def test_same_revision_calls_keep_distinct_records_and_urls(self) -> None:
        report = {"scope": "private non-installable fixture; no network or live host", "passed": False, "stages": []}
        try:
            with tempfile.TemporaryDirectory(prefix="tron-share-concurrency-") as temporary:
                root = Path(temporary)
                ipa, served = root / "fixture.ipa", root / "published"
                with zipfile.ZipFile(ipa, "w") as archive:
                    archive.writestr("Payload/Fixture.app/Info.plist", plistlib.dumps({
                        "CFBundleIdentifier": "invalid.fixture.tron", "CFBundleShortVersionString": "0",
                    }))
                digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
                def command(title: str, second: int, keep: int) -> list[str]:
                    return [sys.executable, "-c", CLOCK, str(second), str(PUBLISH),
                            "--ipa", str(ipa), "--dir", str(served), "--base-url", BASE,
                            "--title", title, "--notes", "Non-installable fixture", "--commit", "a" * 40,
                            "--branch", "fixture/concurrency", "--keep", str(keep)]
                children = []
                try:
                    # Start all eight before waiting for any; they contend on
                    # the real publication lock at the exact same clock value.
                    for n in range(8):
                        children.append(subprocess.Popen(command(f"call-{n}", 0, 8),
                                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
                    results = []
                    for child in children:
                        stdout, stderr = child.communicate(timeout=20)
                        results.append({"exit": child.returncode, "stdout": stdout, "stderr": stderr})
                    report["stages"].append({"concurrent": results, "successes": sum(r["exit"] == 0 for r in results)})
                finally:
                    for child in children:
                        if child.poll() is None:
                            child.kill()
                        child.wait()
                self.assertEqual([r["exit"] for r in results], [0] * 8, json.dumps(report))
                ids = [re.search(r"^Published (\S+) ", r["stdout"]).group(1) for r in results]
                self.assertEqual(len(set(ids)), 8)
                self.assertEqual({p.name for p in (served / "builds").iterdir()}, set(ids))
                originals = {}
                urls = []
                for n, build_id in enumerate(ids):
                    directory = served / "builds" / build_id
                    record = json.loads((directory / "build.json").read_text())
                    self.assertEqual((record["id"], record["title"], record["commit"]), (build_id, f"call-{n}", "a" * 40))
                    self.assertEqual(record["sha256"], digest)
                    self.assertEqual((directory / "TronMobile.ipa").read_bytes(), ipa.read_bytes())
                    manifest = plistlib.loads((directory / "manifest.plist").read_bytes())
                    url = manifest["items"][0]["assets"][0]["url"]
                    self.assertEqual(url, f"{BASE}/builds/{build_id}/TronMobile.ipa")
                    urls.append(url)
                    originals[build_id] = {p.name: p.read_bytes() for p in directory.iterdir()}
                self.assertEqual(len(set(urls)), 8)
                page = (served / "index.html").read_text()
                links = [urllib.parse.parse_qs(urllib.parse.urlsplit(html.unescape(link)).query)["url"][0]
                         for link in re.findall(r'href="(itms-services:[^"]+)"', page)]
                self.assertEqual(set(links), {f"{BASE}/builds/{build_id}/manifest.plist" for build_id in ids})
                self.assertEqual(len(links), 8)
                latest = (served / "latest.plist").read_bytes()
                self.assertIn(latest, [data["manifest.plist"] for data in originals.values()])
                report["stages"].append({"persisted_ids": ids, "unique_ipa_urls": urls, "index_manifest_urls": links})
                # Retention and latest remain a single real publication path,
                # including records created before the newest five-call window.
                for n in range(1, 4):
                    result = subprocess.run(command(f"later-{n}", n, 5), capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    newest = re.search(r"^Published (\S+) ", result.stdout).group(1)
                    retained = list((served / "builds").iterdir())
                    self.assertEqual(len(retained), 5)
                    self.assertEqual((served / "latest.plist").read_bytes(), (served / "builds" / newest / "manifest.plist").read_bytes())
                    for directory in retained:
                        if directory.name in originals:
                            self.assertEqual({p.name: p.read_bytes() for p in directory.iterdir()}, originals[directory.name])
                    self.assertIn(f"/builds/{newest}/manifest.plist", urllib.parse.unquote(html.unescape((served / "index.html").read_text())))
                    report["stages"].append({"later": newest, "retained": sorted(p.name for p in retained)})
                report["passed"] = True
        finally:
            REPORT.parent.mkdir(parents=True, exist_ok=True)
            REPORT.write_text(json.dumps(report, indent=2) + "\n")
            print(f"report: {REPORT.relative_to(ROOT)}", flush=True)


if __name__ == "__main__":
    unittest.main()
