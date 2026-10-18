# Installed Swift apps

Experimental single-file SwiftUI apps (#889) can be *installed*: kept on the Mac
with their own data, so the iPhone runs them like proper apps (epic #1156). The
interpreter and runner sheet live on the iPhone
([`packages/ios-app/docs/swift-apps.md`](../../ios-app/docs/swift-apps.md)). The
Gateway is the canonical owner of every installed app; the phone only holds a
projection of what it last read.

## Store

`SwiftAppStore` (`src/apps/swift-app-store.ts`) is the only writer of
`<tronHome>/workspace/state/apps/`, a managed namespace under the
[internal workspace](internal-workspace.md) contract. Each app is one owner-only
directory named by its id (`^[a-z0-9][a-z0-9-]{0,62}$`):

| File | Contents |
| --- | --- |
| `app.json` | `{version: 1, id, name, icon?, revision, sourceSha256, sourceBytes, updatedAt}`. `revision` is the source revision: 1 at install, +1 for each reinstall. `icon` is an SF Symbol name. |
| `App.swift` | The current source, at most 320,000 bytes (the iPhone's complete-preview bound; a longer file could never run). |
| `data.sqlite` | The app's state: a `state(key, value)` table of JSON values plus a state `revision` in `meta`, schema `user_version` 1. |

The manifest has no fields for feeds (#1159) or link hosts (#1160) yet. Each of
those slices adds its field, with a manifest version bump, when it consumes it.

- **Lost state.** The first install creates `state/apps/` and records
  `gateway/workspace-state/apps-initialized.json`. If the container is missing
  after that, every read and install refuses rather than starting over empty.
  Malformed, newer or unsafe manifests, databases and directories are refused
  and left unchanged. An installed app's missing, linked or uninitialized
  `data.sqlite` is not fresh state: state reads, commits and reinstalls refuse.
  Only first installation may create the database/schema; existing state opens
  with SQLite's no-create mode. A `conflict` reporting missing/unsafe state or
  an unsupported schema means restore the database, not retry revision zero.
- **Install/update.** Installing an existing id replaces its source, name and
  icon and keeps `data.sqlite`. The source is published before the manifest
  that names its SHA-256, so a crash between the two shows up as a mismatch, and
  `apps.get` refuses it ("reinstall it") instead of serving code the manifest
  does not name. At most 200 apps can be installed.
- **State.** Keys are 1–256 bytes without control characters. Values are plain
  JSON, nest at most 32 levels and encode to at most 256 KiB. One app holds at
  most 1,000 keys and 512 KiB of keys plus values, so a whole snapshot fits in
  one RPC frame. A commit carries 1–256 writes and names the state revision it
  was computed from. A stale revision is refused (`conflict`, with the current
  revision in `details`), and the writer reloads instead of overwriting. Writes
  apply in one SQLite transaction; a commit that would exceed a bound changes
  nothing.
- **Remove.** The app's directory is renamed aside, the rename is synced, then
  the directory is deleted, so a crash never leaves a half-removed app listed.
- Operations are serialized by one mutex and use one short-lived database
  connection each, so removal and restart never race a held handle.

## RPCs (`swift-apps.v1`)

`system.info` always advertises `swift-apps.v1`. Each operation still refuses
when the internal workspace is unavailable.

| Method | Params | Result |
| --- | --- | --- |
| `apps.list` | none | `{apps: [manifest]}`, sorted by id |
| `apps.get` | `appId` | `{app: manifest, source}` |
| `apps.state` | `appId` | `{appId, revision, entries: [{key, value}]}`, sorted by key; revision 0 before any commit |
| `apps.commit` | `commandId, appId, expectedRevision, set?: [{key, value}], remove?: [key]` | `{appId, revision}` |

`apps.commit` is a receipt-backed mutation: replaying a `commandId` returns the
original result without applying the writes again. A key may appear only once
per commit. Sources and state values are exact data the runner executes and
restores, so these results bypass the transcript projection's string and array
clipping; the store's bounds are their limit. The reads remain available while
the Gateway drains. Nothing is broadcast on change yet: the Apps sheet (#1161)
adds a change event if it needs one, along with any phone-side removal RPC.

## Agent tool

The `tron-swift-apps` module registers `swift_app` in ordinary sessions; Home's
curated profile does not include it. Actions:

- `list`
- `install {appId, name, icon?, source: {kind: path | internal_file, path}}`:
  reads a visible, link-free `.swift` file relative to the session directory or
  the internal workspace's `files/`.
- `state {appId}`
- `commit {appId, expectedRevision, set?, remove?}`: seeds or updates data, with
  the same revision rule as the phone.
- `remove {appId}`: deletes the app's source and all of its data, and its
  result says so.

Every write goes through the store.

`src/apps/swift-app-store.integration.test.ts` drives these actions through a
faux model in a real `RuntimeRegistry`, and drives the RPCs through
`GatewayService`. It covers install, exact large-source reads, idempotent and
stale commits, bound refusals, reinstall keeping data, a Gateway restart,
removal, source path boundaries, a vanished store and missing, uninitialized
or linked per-app databases (including unchanged source and database bytes on
refusal). Its artifact is
`test-results/swift-app-store/report.json`:

```bash
cd packages/gateway && ../../scripts/tron-node exec npx vitest run src/apps/swift-app-store.integration.test.ts
```
