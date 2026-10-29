# gateway/apps

## Purpose

Own folder-backed Apps membership and scoped access separately from saved SQLite
data. The target design is pinned at `b4d1a8ce21ed9bfcfa3f09b6bd36e0b09af7d8e6`
on branch `design/2108-apps-folders`. This checkpoint is not a paired-client
release: display materialization and the paired iOS consumer remain incomplete.
The maintainer removed conversion from scope: there is no converter or live
migration. The excluded retained offer remains untouched.

## Owners

- `AppsFolderIndex` derives disposable rows from immediate directories in
  `files/apps/`. Entry errors are row values; loose files never create rows.
  It watches the files parent so removing/replacing the apps root is visible.
  Filesystem events are hints, reconciled on one serial lane. The shared
  background scheduler owns the reconciliation backstop. Backend outages retain
  inspected membership, retry observation at the shared five-second cadence and
  fence delayed callbacks to their original watcher handle. Disposal closes the
  watcher and joins reads. A rejected content admission also invalidates its
  metadata cut, so a lost OS hint cannot strand the next refresh on known stale
  bytes. Reads also compare the Apps root inode/mtime/ctime cut to catch missing
  startup membership hints. The index retains only row metadata, never cleared
  execution objects or source/assets. Binary preview cuts retain only primary-file
  identity/stat/hash metadata; ranged reads reopen and fence that descriptor instead
  of rehashing a multi-GiB file for each playback range. Native open/grant/write
  admission still hashes fresh bytes. All fresh entry and opaque-row admission
  routes through this owner. A vanished entry returns `not_found`; losing the
  whole workspace during admission remains unavailable, not an empty catalog.
- `index.publish` serializes immutable leased-byte publication on that same lane.
  It hashes kind/entry/permissions and sorted asset bytes into `display-<sha256>`,
  excluding presentation labels. Private staging is synced and validated through
  the existing typed entry edge before the native exclusive rename. The owner can
  bootstrap missing files/apps namespaces only for explicit publication; it never
  recreates a lost workspace. Pinned canonical parent identities are fenced before
  and after native completion; collisions are freshly admitted and compared, never
  overwritten. Reuse preserves existing metadata. Publication then awaits normal
  reconciliation and fresh admission, not a second catalog write.
  `AppPublicationStaging` owns `state/apps-publication-staging/stage-<uuid>`:
  owner-only 0700, pinned root, outside user-replaceable files/apps. It verifies
  destination/staging device identity before staging, refuses mismatches with
  `details.reason=apps_staging_filesystem_mismatch`, and never falls back to copy.
  Startup recovery removes only owned UUID stages; unknown/corrupt entries refuse
  recovery rather than becoming garbage. Replacing files cannot redirect cleanup.
  Source acquisitions must honor cancellation; disposal aborts source reads and
  joins streams/leases while accepted native work still joins its real callback.
  Successful display execution awaits immutable materialization through this port
  before its canonical result becomes visible; publication grants no runtime/data permission.
  Producers lease admitted artifact bytes, including Markdown dependencies, rather
  than reopening original source paths. The index alone selects an explicit existing
  entry or publishes a fresh content identity. App labels are bounded independently
  of chat titles. app.json and link/live descriptor names are copied as ordinary
  content.json; standalone Swift source uses a .txt suffix, preserving the 5 MiB
  display-data limit without changing executable Swift's 320,000-byte ceiling.
  Selecting an already-declared app entry instead preserves its normal admission.
- `apps-folder-format.ts` is the index-internal filesystem edge: one private
  manifest decoder and typed ready/broken snapshots. `apps-folder-files.ts`
  admits regular descriptors without following any parent/leaf link and hashes
  with a 64 KiB buffer. Only bounded text retains immutable bytes; binary files
  carry stamped/hash descriptors, never empty stand-in Buffers. The ready type
  requires its primary file and discriminated Swift/artifact payload; downstream
  code never parses app.json or decodes binary files as UTF-8.
- `AppPreviewLeases` is the index's disposable-reader owner: at most four active
  descriptors, 64 KiB stream chunks, range validation, stat checks before/after
  reads, abort/release/disposal and retirement on a changed catalog cut. It has
  no discovery, membership or grant authority.
  Unsupported web entries and non-link network scopes remain blocked. Displayed
  HTML/Swift snapshots remain inert documents; explicit executable entries still
  require their normal runtime/data admission.
- `AppsFolderStore` serializes grant/content admission and saved-data management. An open revalidates bytes instead of trusting the
  index. Prompt tokens bind exact content, folder identity, device and expiry.
  Tokens are one-use, expire after ten minutes, are bounded to 256 live prompts,
  and are invalidated on grant/revoke. Gateway-only grants live under
  `state/app-permissions/`; no grant tool exists.
- `AppDataStore` keeps the existing `data.sqlite` schema, revision/CAS, JSON/key/
  whole-state bounds and short-lived SQLite connections. Files never determine
  data lifetime. Losing an established database is not revision zero.
- `ios-builds-feed.ts` reads the existing publisher under its POSIX lock; it
  neither publishes nor runs source, fetches network, or indexes Apps.

There is no registry/offer/install source owner. Legacy corpus source/manifest
files are inert retained bytes; the recorded lock reads saved values only.

## Signals

- `Apps staging recovery unavailable`: inspect the private staging root's owner,
  mode, links and unknown entries; ordinary catalog reads remain independent.

## Gateway contract

Capability: `apps-folder.v1`. The module descriptor retains its existing runtime
composition name, `tron-swift-apps`.

- `apps.catalog {cursor?, limit?}`: revision-bound pages of at most 50 rows,
  Apps before Artifacts, then content-change time and id. A stale cursor returns
  `conflict` with diagnostic reason `catalog_changed`, never a mixed cut.
- `apps.open {id, expectedContentRevision}`: reopens safe bytes; either returns
  the closed `swift | artifact | reference | permissionRequired` projection. Only Swift has
  source/state/feeds; artifacts carry media/MIME/size/digest and `resourcePath`.
  A changed entry refuses. URL references require exact-origin first-open consent
  and never fetch during publication. Live references revalidate their original
  active session/view/generation owner at open and cannot reconnect an ended view.
  The paired iOS renderer remains incomplete.
- Authenticated `GET` of an artifact's `resourcePath` supports byte ranges,
  immutable ETags/304 and 416 with total size. One shared byte HTTP adapter serves
  Apps, retained display artifacts and blobs; every outcome releases its lease.
  The module contract supplies the same index-owned store to HTTP and RPC. This
  route cannot serve executable source and confers no data or runtime grant.
- `apps.permissions.grant {commandId, token}` and
  `apps.permissions.revoke {commandId, id}`: authenticated receipt-backed device
  actions. Code/assets/scopes/folder identity invalidate old grants; title/icon
  changes alone do not. Revocation invalidates subsequent data operations.
- `apps.commit {commandId, id, expectedContentRevision, grantRevision,
  expectedRevision, set?, remove?}`: checks live write authority before the SQLite
  transaction. Accepted duplicates return the original durable receipt.
- `apps.deleteFiles {commandId, rowKey, expectedContentRevision}`: validates the
  current row without mutation, then returns `unsupported`. Client deletion is
  disabled: Node's pathname rename cannot safely restore a raced external
  replacement without a native no-replace transaction. No directory is moved.
- `apps.state {id}` reads saved values separately from membership.
  `apps.reset {commandId, id, expectedRevision, confirmed:true}` clears only those
  saved values with revision CAS and separate explicit authorization. Neither
  operation creates an Apps row or grants executable access.
- The built-in `app_data` tool lists at most 50 saved-data ids/byte counts/orphan
  flags per page. Inventory cursors bind saved-data id membership and refuse
  changed inventories; byte counts/orphan flags are live observations. It reads
  one state, seeds values using revision CAS, and clears values only with separate
  explicit confirmation. Unsafe state remains intact.
  It does not grant access or manage files. Built-in operating context and
  delegated workspace handoff point writers to `files/apps/<id>/`, not a profile.

There are no list/pending/review/install/legacy RPC aliases. Metadata editing,
Apps change broadcasting and paired protocol advancement are incomplete and must
land atomically with their consumers.
Text is limited to 5 MiB/file, images/documents to 25 MiB/file, streamed
video/audio to 2 GiB/file. Swift remains 320,000 bytes, manifests 32 KiB and
executable bundles 32 MiB/1,000 files. All bundles cap retained text at 32 MiB
and aggregate streamed bytes at 2 GiB. Signature/type mismatches become broken
rows. Canonical display publication copies admitted immutable source/dependency
leases; browser app bindings survive nested parent resealing. Browser receipts
remain process-ephemeral. The app reference survives in canonical details after
process restart, but no live projection or reconnect authority is restored.
Cold-history app-card presentation awaits the paired inert UI/protocol consumer.

## Signals

`GatewayError` distinguishes invalid input, missing access, changed content and
unsafe/lost state. `details.outcomeUnknown` is not replay permission. A missing
Apps subfolder is empty; a missing/unsafe workspace files root is unavailable.

| Signal | One-step diagnosis / boundary |
| --- | --- |
| `ios-builds` unavailable | `ls -1 <configured-Gateway-home>/ios-builds/builds` identifies committed candidates. Both timestamp/commit and timestamp/UUID/commit names are valid. Inspect the publisher lock and bounded record/IPA/manifest identity, not app state or reinstall. |

## Verify

```bash
scripts/tron test gateway src/modules/apps/apps-folder.integration.test.ts
scripts/tron test gateway src/modules/apps/apps-folder-runtime.integration.test.ts
scripts/tron test gateway src/modules/apps/apps.store.lock.integration.test.ts
scripts/tron test gateway src/modules/apps/apps-preview.integration.test.ts src/transport/apps-artifacts.integration.test.ts
scripts/tron test gateway src/transport/server-blob.integration.test.ts src/sessions/blob-store.lock.integration.test.ts
scripts/tron-node exec npm --prefix packages/gateway run check
scripts/tron-node exec npm --prefix packages/gateway run lint
```

The folder suites cross a real RuntimeRegistry, GatewayService, receipt store,
filesystem watchers, a real Pi turn and SQLite. Runtime coverage compiles the Swift
engine, persists actions and dictionaries, checks retained/current feeds and URL
consent gates, kills fixture writers at three receipt cuts, and checks drain,
JSON bounds and damaged databases. Preview coverage crosses real files, binary
range streams, disposal and a real HTTP listener with the real device credential
owner. Display publication, UI, watcher overflow recovery and runner shutdown on
revoke require separate validation. Run changed-code Gateway/iOS journeys and one
full verify before merge; the broad shard plan and converter suite are out of scope.
