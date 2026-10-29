# gateway/apps

## Purpose

Own folder-backed Apps membership and scoped access separately from saved SQLite
data. The approved target contract is in `docs/design/apps-folder/DESIGN.md` on
`design/2108-apps-folders`. This implementation checkpoint is not a paired-client
release: display materialization, the iOS consumer, conversion and removal of
retired source owners remain incomplete.

## Owners

- `AppsFolderIndex` derives disposable rows from immediate directories in
  `files/apps/`. Entry errors are row values; loose files never create rows.
  It watches the files parent so removing/replacing the apps root is visible.
  Filesystem events are hints, reconciled on one serial lane. The shared
  background scheduler owns the reconciliation backstop. Backend outages retain
  inspected membership, retry observation at the shared five-second cadence and
  fence delayed callbacks to their original watcher handle. Disposal closes the
  watcher and joins reads. The index retains metadata, not source/assets.
- `apps-folder-format.ts` reads bounded regular files without following links,
  infers the optional manifest and computes content/executable identities.
  Unsupported web/network entries are visible but blocked, never unsandboxed.
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

The old Swift registry/offer files and their surviving boundary oracles are
retained until replacement feed/interpreter/conversion coverage is complete.
They are not registered as runtime RPCs or agent tools by `module.ts`.

## Gateway contract

Capability: `apps-folder.v1`. The module descriptor retains its existing runtime
composition name, `tron-swift-apps`.

- `apps.catalog {cursor?, limit?}`: revision-bound pages of at most 50 rows,
  Apps before Artifacts, then content-change time and id. A stale cursor returns
  `conflict` with diagnostic reason `catalog_changed`, never a mixed cut.
- `apps.open {id, expectedContentRevision}`: reopens safe bytes; either returns
  a runner snapshot or a device-bound `permissionRequired` prompt. A changed
  entry refuses. Preview payload/renderer integration is incomplete.
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
The current bundle reader uses a conservative 32 MiB bound; preserving larger
existing display-artifact limits requires the streaming materialization boundary.

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
scripts/tron-node exec npm --prefix packages/gateway run check
scripts/tron-node exec npm --prefix packages/gateway run lint
```

The folder suite crosses a real RuntimeRegistry, GatewayService, receipt store,
filesystem watchers, a real Pi tool turn and SQLite. It does not prove display publication, the native
interpreter, migration, UI, watcher overflow recovery or runner shutdown on revoke.
Do not remove the old feed/interpreter/crash oracles before their replacements pass.
