# Installed Swift apps

The Gateway owns installed single-file SwiftUI apps and their data. The iPhone
interprets bounded source/state/feed projections; it does not execute native Swift
or acquire files, networking or credentials. See the
[iPhone runner](../../ios-app/docs/swift-apps.md).

## Store and versions

`SwiftAppStore` is the sole writer of
`<tronHome>/workspace/state/apps/`, under the
[internal workspace](internal-workspace.md). The apps descriptor constructs it
over the workspace contract. Directories are owner-only; app ids match
`^[a-z0-9][a-z0-9-]{0,62}$`. At most 200 apps and 200 pending offers are admitted.

| File | Authority |
| --- | --- |
| `app.json` | Explicit manifest version 1 or 2; the current source/configuration head |
| `App.swift` | Named v1 source; at most 320,000 UTF-8 bytes |
| `sources/<sha256>.swift` | Immutable v2 source, addressed by the manifest |
| `data.sqlite` | State table and state revision; SQLite `user_version` remains 1 |
| `backups/v1-<revision>[-<uuid>]/` | Explicit upgrade snapshots of v1 manifest, source and byte-identical SQLite |
| `.offers/<reference-key>/` | Bounded pending source/configuration bound to its producing session/artifact |

Pending offers are reconciled under the Apps mutex on first root access, catalog
reads and before refusing a full offer store. DisplayOwner first proves canonical
session membership, including live-only runtimes; offers without their exact
producing artifact owner are then erased with their source/configuration. This
reclaims deleted-session capacity without a second session catalog or timer.
Unreadable metadata is not authority to delete it; installed apps and live offers
are unaffected.

`swift-app-format.ts` owns the manifest/offer values and their admission.
`readSwiftAppManifestV1` is the named existing reader. V1 has
`version,id,name,icon?,revision,sourceSha256,sourceBytes,updatedAt`.
V2 adds an immutable `instanceId`, declared `feeds`, and at most 20
source/configuration history entries with session actor attribution. Historical
v1 attribution is unknown, not invented. Source revision and state revision are
independent; rename changes the label, not the source fence.

V1 is never upgraded on read, restart or reconnect. Its explicit reviewed update
requires `upgradeToV2: true` and a durable backup before publishing v2. Failed
attempts keep their backups; a later attempt snapshots current bytes rather than
reusing a potentially stale backup. At most 20 upgrade backups are retained;
reaching the bound refuses without overwriting them. No SQLite migration occurs.

## Review and publication

1. `swift_app offer` reads a complete, bounded, visible, link-free source under
   the session directory or internal `files/`. It creates a canonical code display
   and an offer; it does not install, change app state or grant a feed to a preview.
2. `apps.review` acquires that display owner's session/artifact grant and verifies
   the exact bytes against the offer. Source SHA alone is not authority: another
   session's display of identical bytes cannot review or replace its configuration.
3. `apps.install` re-acquires the same grant and checks offer/config identity,
   source SHA and the reviewed existing revision/source/instance. A changed or
   removed target refuses; an old instance cannot overwrite a reinstall.
4. New apps publish through an owner-controlled staging directory. Updates write
   immutable source before atomically publishing the single manifest head. Data
   stays in place. Startup/next-root cleanup removes only recognized unreachable
   staging, retired directories, temporary files and sources outside retained history.
   Cleanup after publication cannot turn its committed result into a failed receipt.

The existing named tool `install` remains a v1-only contract. It can create or
replace v1 source while keeping its data, but cannot update/downgrade v2.
Reviewed Install App is the v2 install/update path.

## State and removal

Keys are 1–256 bytes without controls; values are plain finite JSON nested at
most 32 levels and encoded to at most 256 KiB. One app holds at most 1,000 keys
and 512 KiB of keys plus encoded values. A transaction carries 1–256 writes.
Stale revisions and bound violations change nothing. Interpreter commits also
fence the source revision and, for v2, instance id. Agent seeding keeps its
state-revision contract.

Only first installation may initialize SQLite. Missing, linked, unsafe or
unsupported established storage refuses; it is not permission to reset state
or retry revision zero. The initialized-container marker also detects loss of
the entire apps directory. Connections close within the store mutex.

Remove durably renames the app to the exact owner-controlled
`.removed-<appId>-<hex12>` retirement name before deleting source/data. Restart
cleanup reclaims a recognized interrupted retirement without relisting the app.

## Declared `ios-builds` feed

Only v2 may declare `feeds: ["ios-builds"]` (or `[]`). A v2 open reads a new,
immutable snapshot; v1's response stays unchanged. The feed reads
`<configured Gateway home>/ios-builds`, not an arbitrary client path. The trusted
home is canonicalized; linked publisher roots and children refuse. Debug's
`~/.tron-dev` is separate from Stable's publisher home; there is no implicit
cross-home fallback or live-data copy.

The system Python reader shares the publisher's POSIX `.publish.lock`. It opens
bounded regular files descriptor-relatively without following links, ignores
dot/staging entries, and validates committed metadata, IPA size/type, manifest
bundle identity and exact HTTPS artifact path. It reads no network, creates no
second catalog and changes neither the publisher nor the static `:8443` page.
A read is bounded to five seconds, 20 builds and 256,000 output bytes.
`ready`, `empty` and `unavailable` are distinct; missing, unsafe, malformed or
contended input never masquerades as a successful empty feed.

The native interpreter receives only declared snapshots through
`AppFeed.iosBuilds()`. V2 OS-install links require an explicit native user action,
the paired host and an exact manifest URL from that snapshot. It hands the link
to iOS; neither Gateway nor phone claims that iOS completed an installation.

## RPCs (`swift-apps.v1` capability)

The descriptor advertises the existing capability; paired Gateway/iPhone
versions own wire admission. Reads remain available while draining.

| Method | Params / result |
| --- | --- |
| `apps.list` | none → `{apps}`, sorted by id |
| `apps.get` | `appId` → `{app,source}` |
| `apps.open` | `appId` → coherent `{app,source,state}`; v2 also `feeds` |
| `apps.review` | `sessionId,artifactId` → `{offer,installed,reference}` |
| `apps.install` | `commandId,sessionId,artifactId,offerId,expectedRevision,expectedSourceSha256,expectedInstanceId,upgradeToV2` → `{app,created}` |
| `apps.rename` | `commandId,appId,name` → `{app}` |
| `apps.reset` | `commandId,appId,expectedRevision` → `{appId,revision}` |
| `apps.remove` | `commandId,appId,expectedInstanceId?` → `{appId,removed:true}`; v2 requires the instance fence |
| `apps.state` | `appId` → `{appId,revision,entries:[{key,value}]}` |
| `apps.commit` | `commandId,appId,expectedRevision,expectedSourceRevision?,expectedInstanceId?,set?,remove?` → `{appId,revision}` |

Mutations use the existing transport receipt coordinator, not a second Apps
ledger. Completed commands replay their result. Interrupted pending/effects
receipts remain conflicts with `details.outcomeUnknown: true`; reconnect is
not permission to apply again. Source/state/feed results bypass transcript
clipping; transport's aggregate frame ceiling still applies and an oversized
composed response refuses rather than silently clipping executable data.
No change broadcast, scheduling, HTML backend or background feed polling exists.

## Tool

Ordinary sessions, not Home's curated profile, expose `swift_app`:
`list`, `offer {appId,name,icon?,source,feeds}`,
`discardOffer {artifactId}` (producing session only),
the named v1 `install {appId,name,icon?,source}`, `state {appId}`,
`commit {appId,expectedRevision,set?,remove?}`, and `remove {appId}`.
Source kinds are `path` and `internal_file`, relative to their existing owners.

## Verification

`swift-app-store.integration.test.ts` and `apps.store.lock.integration.test.ts`
exercise real RuntimeRegistry/Gateway/SQLite restoration, bounds and named v1
behavior. `apps-install.integration.test.ts` adds canonical display grants,
cross-session same-source refusal, reviewed updates, opt-in backups, real
publisher reads, native engine feed/link admission and receipt restart cuts.
Its artifacts are under `test-results/apps-install/`.

Crash cuts kill a fixture process **after releasing its RuntimeRegistry/workspace
lease** at the held Apps/receipt cut. They prove Apps restart state and receipt
replay fencing, not an ungraceful whole-Gateway crash, stale-lock recovery,
power-loss/page-cache durability or physical-device installation.

```bash
scripts/tron verify --module gateway/apps
scripts/tron test gateway src/modules/apps/apps-install.integration.test.ts
```
