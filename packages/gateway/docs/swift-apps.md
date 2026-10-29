# Folder-backed Apps and saved values

Immediate directories under `workspace/files/apps/<id>/` determine membership.
An optional `app.json` supplies title/icon/entry/kind and requested permissions.
No registry, source-history store, offer, pending list or install review owns
membership. Loose files are not entries; unsafe or malformed entries remain
isolated broken rows. Source and values have independent lifetimes.

## Owners and access

[`modules/apps`](../src/modules/apps/README.md) owns catalog paging, filesystem
observation, content identities, permission grants and data admission. Its module
descriptor advertises `apps-folder.v1`. `apps.catalog` replaces both registry
list reads; `apps.open` revalidates exact content and returns a snapshot or a
native first-open permission request. An agent cannot grant its own app access.
Unsupported web/network execution is blocked, not run with ambient authority.

Native consent binds executable bytes/assets, folder identity and permission
scopes. Metadata-only title/icon edits do not request access again. Code/scope
changes and revoke invalidate subsequent data writes. A prompt token is bounded,
expiring, device-bound and one-use; durable receipt replay is not a second tap.

## Saved values

`AppDataStore` owns `workspace/state/apps/<id>/data.sqlite`, preserving the
existing SQLite schema, revision/CAS and bounds. It never makes a membership row.
A missing, linked, uninitialized or newer established database is refused without
recreating state. File removal does not clear values or migrate another id's data.

The built-in `app_data` tool lists bounded saved-data inventory with byte counts
and orphan flags, reads one state and seeds values with revision CAS. Clear needs
separate explicit authorization. Native reset is likewise a receipt-backed CAS
mutation. Management is not an app-runtime bridge and creates no grant.

Phone file deletion is outside this release. The retained server stale-row check
only refuses; it cannot move or remove a directory. Ordinary authorized filesystem
changes are observed independently of saved data.

## Declared `ios-builds` feed

Only an app declaring `permissions.feeds: ["ios-builds"]` receives that read-only
snapshot after native access approval. The reader uses the existing publisher's
POSIX lock, safe regular-file reads and record/IPA/manifest identity checks. Both
retained timestamp/commit and current timestamp/UUID/commit publications are valid.
Staging is excluded; corrupt committed data is unavailable, never empty-success.

The snapshot grants no publish/build/restart privilege. The interpreter admits an
exact paired-host installation URL only on an explicit native user action. Opening
an app or feed neither installs a build nor claims the OS completed installation.

## Verification

```sh
scripts/tron test gateway src/modules/apps/apps-folder.integration.test.ts
scripts/tron test gateway src/modules/apps/apps-folder-runtime.integration.test.ts
scripts/tron test gateway src/modules/apps/apps.store.lock.integration.test.ts
```

The runtime suite crosses real Gateway, SQLite, receipt-process crash cuts and
compiled Swift interpreter boundaries. The store lock reads the preserved legacy
SQLite corpus without mutating any recorded file; source/registry projections
are not membership. UI, converter and paired protocol validation are separate.
