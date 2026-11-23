# gateway/artifacts

## Purpose

List the internal workspace's artifacts: finished, mobile-responsive web pages that
Tron and its agents make for the user or each other. The agent that makes an artifact
decides its content, logic and data; this module knows only the folder convention.

## Contract

- An artifact is `<workspace>/artifacts/yyyy-mm-dd_<slug>/` holding an `index.html`.
  Name sort is chronological. Other entries (`shared/`, loose files, folders without
  `index.html`, symlinks) are never listed; `shared/` holds styles and data artifacts reuse.
- `artifacts.list` (read, no parameters) returns `{artifacts: [{name, url}]}` newest
  first, at most 500, with `url` = `https://<this Mac's tailnet name>:8443/artifacts/<name>/`.
  With artifacts present but no tailnet name it refuses with `conflict` rather than
  invent a host.
- Serving is the existing share host (`scripts/tron-ios-device share-host enable`):
  the loopback server maps `/artifacts/` to this folder behind Tailscale Serve :8443,
  tailnet only, no listing, hidden names, traversal or symlink escape. There is no
  second server, per-type logic, schema, template or registry. The share host serves
  the Stable workspace (`~/.tron/workspace/artifacts`); a Debug or custom home lists its
  own folder, whose URLs resolve only if the same files exist there. URLs are dead
  while the share host is disabled; `scripts/tron-ios-device share-host status` says so.
- The installed LaunchAgent embeds the server source and its arguments when
  `share-host enable` runs, so `/artifacts/` starts serving only after enable runs again.

## Verify

```bash
scripts/tron test gateway src/modules/artifacts/artifacts.integration.test.ts
python3 scripts/test-tron-ios-device-share.py
```
