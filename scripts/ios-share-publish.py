#!/usr/bin/env python3
"""Publish a signed development IPA for over-the-air install.

Called by `scripts/tron-ios-device share` after the build is validated. Lays
out the served directory (the share host's only content):

  index.html                 newest build first, an Install button per build
  latest.plist               manifest of the newest build (stable install link)
  builds/<id>/TronMobile.ipa
  builds/<id>/manifest.plist  itms-services manifest; its IPA URL is absolute
  builds/<id>/build.json      title, notes, commit, branch, time, sha256

Each build directory is completed under a temporary name and renamed into
place, and the index and latest manifest are replaced atomically, so a phone
never reads a half-written build. Only the newest --keep builds are retained.
Prints the page and install links as its last two lines.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import html
import json
import os
import plistlib
import re
import shutil
import tempfile
import urllib.parse
import zipfile
from pathlib import Path

IPA_NAME = "TronMobile.ipa"
BUILD_ID = re.compile(r"^\d{8}T\d{6}Z-[0-9a-f]{7,40}$")
SHARED_STYLES = Path(__file__).resolve().parent.parent / "tools" / "web" / "tron.css"


def atomic_write(path: Path, data: bytes) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def app_info(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist()
                 if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            raise SystemExit(f"error: {ipa} must hold exactly one Payload/*.app")
        return plistlib.loads(archive.read(names[0]))


def install_link(manifest_url: str) -> str:
    return "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest_url, safe="")


def manifest(ipa_url: str, info: dict, title: str) -> bytes:
    return plistlib.dumps({"items": [{
        "assets": [{"kind": "software-package", "url": ipa_url}],
        "metadata": {
            "bundle-identifier": info["CFBundleIdentifier"],
            "bundle-version": str(info.get("CFBundleShortVersionString", "1.0")),
            "kind": "software",
            "title": title,
        },
    }]})


def render_index(base_url: str, builds: list[dict], styles: str) -> bytes:
    rows = []
    for i, build in enumerate(builds):
        url = f"{base_url}/builds/{build['id']}/manifest.plist"
        when = dt.datetime.fromisoformat(build["time"]).strftime("%Y-%m-%d %H:%M UTC")
        badge = '<span class="tron-badge tron-badge--accent">Latest build</span>' if i == 0 else '<span class="tron-badge">Previous build</span>'
        mode = 'Fast debug' if build.get('mode') == 'fast-debug' else 'Optimized'
        rows.append(f"""
<section class="tron-card{' tron-card--featured' if i == 0 else ''}" aria-labelledby="build-{i}">
  <div class="tron-row">
    {badge}
    <time class="tron-meta" datetime="{html.escape(build['time'])}">{html.escape(when)}</time>
  </div>
  <div class="tron-stack">
    <h2 id="build-{i}">{html.escape(build['title'])}</h2>
    <p class="tron-reading">{html.escape(build['notes'])}</p>
    <p class="tron-meta"><code>{html.escape(build['commit'][:9])}</code> &middot; {html.escape(build['branch'])}</p>
  </div>
  <div class="tron-row">
    <span class="tron-meta">{mode}</span>
    <a class="tron-button{' tron-button--primary' if i == 0 else ''}" href="{html.escape(install_link(url))}">{'Install latest' if i == 0 else 'Install'}</a>
  </div>
</section>""")
    body = "".join(rows) or '<p class="tron-card tron-meta">No builds published yet.</p>'
    # Embed the canonical CSS: index publication stays atomic and an installed
    # static host needs no new asset route, checkout access, or restart.
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Tron development builds</title>
<style>{styles}</style></head>
<body class="tron-page"><div class="tron-shell">
<header class="tron-toolbar tron-row">
  <span class="tron-brand">Tron</span>
  <span class="tron-meta">Development</span>
</header>
<main>
  <div class="tron-intro">
    <h1>Development builds</h1>
    <p class="tron-meta">Choose a build to install on your iPhone.</p>
  </div>
  <div class="tron-stack">{body}</div>
</main>
<footer class="tron-footer tron-meta">Development-signed for registered devices with Developer Mode on.</footer>
</div></body></html>
""".encode()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--dir", type=Path, required=True)
    parser.add_argument("--base-url", required=True, help="https origin that serves --dir")
    parser.add_argument("--title", required=True)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--mode", default="optimized")
    parser.add_argument("--keep", type=int, default=5)
    args = parser.parse_args()
    # Resolve the page's only asset before touching the published tree.
    styles = SHARED_STYLES.read_text(encoding="utf-8")

    base_url = args.base_url.rstrip("/")
    if not base_url.startswith("https://"):
        raise SystemExit("error: --base-url must be https (iOS installs only from trusted HTTPS)")
    if args.keep < 1:
        raise SystemExit("error: --keep must be at least 1")
    info = app_info(args.ipa)

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    build_id = f"{now.strftime('%Y%m%dT%H%M%SZ')}-{args.commit[:9]}"
    if not BUILD_ID.match(build_id):
        raise SystemExit(f"error: invalid commit {args.commit!r}")
    builds_dir = args.dir / "builds"
    builds_dir.mkdir(parents=True, exist_ok=True)
    # Concurrent shares (several worktrees) serialize on the published tree.
    lock = open(args.dir / ".publish.lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)

    staging = Path(tempfile.mkdtemp(dir=builds_dir, prefix=".staging-"))
    try:
        ipa = staging / IPA_NAME
        shutil.copyfile(args.ipa, ipa)
        digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
        title = f"Tron · {args.title}"
        (staging / "manifest.plist").write_bytes(
            manifest(f"{base_url}/builds/{build_id}/{IPA_NAME}", info, title))
        record = {
            "id": build_id, "title": args.title, "notes": args.notes,
            "commit": args.commit, "branch": args.branch, "mode": args.mode,
            "time": now.isoformat(), "sha256": digest, "bytes": ipa.stat().st_size,
            "bundle_id": info["CFBundleIdentifier"],
        }
        (staging / "build.json").write_text(json.dumps(record, indent=2) + "\n")
        staging.chmod(0o755)
        for child in staging.iterdir():
            child.chmod(0o644)
        staging.rename(builds_dir / build_id)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    # Newest first by id (UTC timestamp prefix). Partial staging directories
    # from an interrupted publish are dot-prefixed and removed here too.
    for stray in builds_dir.glob(".staging-*"):
        shutil.rmtree(stray, ignore_errors=True)
    ids = sorted((p.name for p in builds_dir.iterdir() if BUILD_ID.match(p.name)), reverse=True)
    builds = []
    for old in ids[args.keep:]:
        shutil.rmtree(builds_dir / old)
    for kept in ids[:args.keep]:
        builds.append(json.loads((builds_dir / kept / "build.json").read_text()))

    newest_manifest = (builds_dir / builds[0]["id"] / "manifest.plist").read_bytes()
    atomic_write(args.dir / "latest.plist", newest_manifest)
    atomic_write(args.dir / "index.html", render_index(base_url, builds, styles))

    print(f"Published {build_id} ({len(builds)} kept)")
    print(f"Install page: {base_url}/")
    print(f"Install link: {install_link(base_url + '/latest.plist')}")


if __name__ == "__main__":
    main()
