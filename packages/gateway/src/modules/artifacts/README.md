# gateway/artifacts

## Purpose

List the internal workspace's web pages that Tron and its agents make for the user or
each other: durable tools and one-off reports. The agent that makes a page decides its
content, logic and data; this module knows only the folder convention.

## Contract

- A tool is `<workspace>/artifacts/<slug>/` holding an `index.html`: a page that stays
  useful and current on its own. A report is `<workspace>/reports/yyyy-mm-dd_<slug>/`
  holding an `index.html`: a one-off, point-in-time page. A slug is up to 121 letters,
  digits, `.`, `_` or `-`, starting with a letter or digit. Other entries (`shared/`,
  loose files, folders without `index.html`, symlinks, undated report folders) are never
  listed; `artifacts/shared/` holds styles and data pages reuse.
- `artifacts.list` (read, no parameters) returns `{tools, reports}`, at most 500 of each.
  Each entry is `{name, title, updatedAt, url}`; reports add `day` (`yyyy-mm-dd` from the
  name). `title` is the page's `<title>` (first 16 KiB, entities decoded, whitespace collapsed,
  at most 200 characters) or the folder name; `updatedAt` is the later of the folder's and `index.html`'s modification times.
  Tools sort by `updatedAt`, newest first; reports by `day`, then `updatedAt`, newest
  first. `url` is `https://<this Mac's tailnet name>:8443/artifacts/<name>/` or
  `.../reports/<name>/`. With pages present but no tailnet name it refuses with
  `conflict` rather than invent a host.
- Serving is the existing share host (`scripts/tron-ios-device share-host enable`):
  the loopback server maps `/artifacts/` and `/reports/` to these folders behind
  Tailscale Serve :8443, tailnet only, no listing, hidden names, traversal or symlink
  escape. There is no second server, per-type logic, schema, template or registry. The
  share host serves the Stable workspace (`~/.tron/workspace`); a Debug or custom home
  lists its own folders, whose URLs resolve only if the same files exist there. URLs are
  dead while the share host is disabled; `scripts/tron-ios-device share-host status`
  says so.
- The installed LaunchAgent embeds the server source and its arguments when
  `share-host enable` runs, so a new route starts serving only after enable runs again.

## Verify

```bash
scripts/tron test gateway src/modules/artifacts/artifacts.integration.test.ts
python3 scripts/test-tron-ios-device-share.py
```
