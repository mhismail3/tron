# Folder-backed Apps

**Proposal for approval · #2108 · 2026-10-29 · design only**

No implementation, deployment or live-data conversion is authorized by this document.
The approval images are synthetic native iOS Simulator compositions, not a running
folder index, working permission broker, device capture or migration proof.

## Decision

Replace offer → Pending → Install review → installed registry with **files → open**.
`~/.tron/workspace/files/apps/<id>/` is the only membership authority. Every immediate
entry directory produces exactly one row while it exists. Neither state, grants,
chat history nor a cached index can create a row. There are exactly two sections:
**Apps** (interactive Swift/web apps) and **Artifacts** (documents, images and other
read-only displayed material). No Installed, Pending, Install or Update vocabulary.

This adopts Mohsin's nine decisions confirmed in Home on 2026-10-29. It does not
change the unrelated native **Install Build** OS handoff. #2107 is the concrete
warning: one retained build-identity shape made the entire feed unavailable. Entry
errors must be values in a catalog, not exceptions that discard its good siblings.

## 1. Files, identity and ownership

```text
~/.tron/workspace/
  files/apps/
    builds/                     # stable, agent/user-chosen id
      app.json                  # optional; metadata and requested capabilities
      Main.swift
    reading-list/
      app.json
      index.html
      assets/...
    display-<sha256>/            # automatic display copy, deterministic id
      app.json
      content.png
  state/apps/<id>/               # saved app data only; existing SQLite stays here
    data.sqlite                 # preserve existing basename/schema/revision
  state/app-permissions/<id>.json # Gateway-owned grants, never app-writable
```

`<id>` is the directory basename, not a manifest field; normal new ids match
`[a-z0-9][a-z0-9-]{0,79}` (allows the full automatic digest). A bad/foreign name is
still a broken row with an opaque row key, never used as an unchecked path. Regular
loose files are not entries. Symlinks at an entry position become broken rows;
never follow them. Nested links, traversal, device files and FIFOs are refused
without blocking. No entry-owned registry, source history, immutable source store
or installation incarnation. Source-control/history outside Apps is unrelated.

Files are ordinary user/agent-editable content. Gateway owns index and capability
admission; app runtimes own neither. Keep existing state SQL and its revision/CAS
contract, separate from file membership. Do not move user data into app folders.
Stage Gateway copies outside the catalog (`files/.apps-staging/<random>/`), sync
files then atomically rename into place. Never ignore a hidden entry directory to
hide persistent lifecycle state. External partial writes can briefly produce a
broken row; an atomic folder replacement avoids that. Renaming a folder changes
its id and does **not** silently move state or grants.

## 2. Gateway index/watch and replacement protocol

**Inspected seam:** `sessions/session-catalog.ts` owns `watchCatalogFolder`, a
recursive `fs.watch` backend with bounded hints, reconciliation, watcher recovery
and shutdown. `TronWorkspace` owns paths/availability/lease, not a general files
index. There is currently no generic workspace Apps watcher to switch on. Reuse
that existing watcher backend/lifecycle pattern by extracting its narrow filesystem
observation portion without changing session-catalog semantics. Do not make Apps
pretend to be sessions or add an independent iOS polling loop.

One `AppsFolderIndex` in `modules/apps` watches the canonical files/apps root,
indexes immediate candidates and invalidates only the affected entry on nested
changes. Attach watch before baseline scan; serialize scan/event reconciliation;
generation-fence every async read. Filesystem events are hints: unknown/overflow
hints and watch reset trigger a complete rescan. Reuse the existing watcher-owner
backstop/recovery cadence, not a second per-feature timer/retry subsystem. Close
and join owned reads/watchers on module disposal. Publication by `display` awaits
this same owner's reconcile cut; no duplicate hand-maintained catalog write.

The index is bounded, disposable **memory**, rebuilt from files on Gateway start.
No persistent membership database. Metadata is decoded per-entry before publishing
a discriminated row; a corrupt app.json never becomes an undecodable top-level
list. Scan incrementally/yield between pages; no old 200-app global admission cap.
Page at most 50 rows, manifest at most 32 KiB, Swift source at most 320,000 bytes;
retain current display artifact byte/disk bounds. Limit each web bundle to 1,000
files/32 MiB and report an oversized entry as broken, not a global failure. Never
silently omit the 1,001st directory; membership is paged, not truncated.

Replace `apps.list` + `apps.pending` with **`apps.catalog`**:

```text
request  {cursor?: opaque, limit?: 1..50}
response {revision, rows: [{id, rowKey, title, icon, kind, section,
            contentRevision, status: {kind:"ready"} |
              {kind:"cannotOpen", code, reason}}], nextCursor?: opaque}
event    apps.changed {revision}      # invalidation hint, not another authority
```

Sort Apps before Artifacts, then newest content change with id tie-breaker. Cursors bind
the catalog revision; a changed cut returns `catalog_changed`, causing a fresh
first page rather than duplicates/holes. Reconnect requests a new authoritative
catalog; no replay of prompts/mutations. iOS retains a labeled stale projection
only for whole-root/transport failures. Known folder deletion removes its row at
the next observed cut. A lost/unsafe workspace is an unavailable sheet, not empty.
A genuinely empty/missing apps subfolder under an available files root is empty.

`apps.open {id, expectedContentRevision}` returns either a local preview/runner
snapshot, `permissionRequired` with the exact requested access and revision, or
an entry-scoped error. It reopens safe descriptors/revalidates bytes; never trusts
cached paths or grants alone. Changes during admission return `entry_changed`.
For broken names, catalog exposes only a deletion token, not an executable id.
`apps.deleteFiles {commandId, rowKey, expectedContentRevision}` receipt-backs
phone deletion and refuses a newer replacement. `apps.permissions.grant/revoke`
are authenticated maintainer mutations (below). Replace registry rename with
`apps.setMetadata` (file edit, receipt/CAS); state/reset/commit stay data operations
with new content/grant fences. No legacy list/pending/review/install RPC aliases.
Advertise one new capability `apps-folder.v1` and advance the exact paired protocol
contract in the implementation; mismatched clients refuse rather than fallback.

## 3. `display` always materializes an entry

All successful display producers, including nested browser screenshots routed
through the canonical display owner, use **one** materialization boundary before
their visible result is published. It must be enforced below a single tool's
happy path. Returning success while the folder could not be published is forbidden.

- Already inside a valid entry: use that id; do not create a second folder. Display
  snapshots stay immutable for chat, while Apps remains a live file view. If the
  displayed file differs from the inferred entry, explicitly set that entry or
  fail with a useful ambiguity error; never silently point at another program.
- Else copy the exact admitted bytes, not a later reread of the source path, plus
  the renderer's already-admitted local dependencies (Markdown images, web bundle
  assets). Copy, not mutable hardlinks/symlinks to arbitrary sources. An isolated
  HTML file with unresolved dependencies is rejected with remediation, not allowed
  to fetch undeclared files/network. Existing ingestion link/size/ownership bounds
  remain. No copying entire project directories as an inferred bundle.
- Compute `display-<sha256>` over canonical kind/media + sorted relative asset
  names and bytes + execution/permission configuration. Title/caption/session are
  excluded. Repeated display of the same payload in different chats/surfaces
  reuses one folder; different content/config creates a new id. Do not mutate
  metadata on reuse. Explicit stable folders are the way to regenerate in place.
  Verify an existing digest folder's content before reuse; conflicting edits yield
  a conflict, never overwrite the user's file. Serialize Gateway materializations
  and publish no-clobber; reconcile after a racing external write.
- Public URLs also get a small `entry.link.json` with normalized public HTTPS URL
  and media. They appear as read-only link/video Artifacts, not installed web apps.
  Generated app.json requests the descriptor's exact HTTPS origin; viewing waits
  for first-open network consent. A remote interactive site must be explicitly
  declared `web` with origin access.
- Live browser/native displays get `entry.live.json` with opaque session-scoped
  viewId/generation and producer kind, **not** endpoints, PID, cookies or credentials.
  Classify as Artifacts. Opening revalidates the existing live-view owner; an expired
  reference reads “Can’t open · Live view ended”. Never rediscover or restart capture.

Auto entries are not tied to session retention. Deleting a chat does not delete
its copied files. Deleting an entry does not erase a historical chat snapshot;
opening that old card may read the snapshot but cannot execute deleted code or
recreate the folder. A new explicit display invocation can create it again.
Accepted tool-result replay reads its original receipt, never rematerializes it.

## 4. Optional manifest and classification

```json
{
  "title": "Builds",
  "icon": "hammer",
  "entry": "Main.swift",
  "kind": "swift",
  "permissions": {"data": "readWrite", "feeds": ["ios-builds"], "network": []}
}
```

Strict single object, no unknown keys. All five keys optional. `title`: 1–80 UTF-8
bytes, one line; `icon`: valid SF Symbol name ≤80 bytes, unknown symbol falls back
to the kind icon, not a broken app. `entry`: safe relative regular file within the
entry directory. `kind`: `swift | web | document | image | video | link | live`.
`permissions`: `{data?: "none"|"read"|"readWrite", feeds?: [known feed ids],
network?: [canonical https origins]}`; missing permissions means zero extra access.
No arbitrary paths, wildcard hosts, cookies, credentials or app-authored grants.
Unknown feed/permission/kind is broken, never silently downgraded. Permission fields
are valid only for interactive kinds, except link/video's explicit network origins.

Inference fills missing keys, never guesses capabilities: title from basename,
icon from kind; choose `index.html` or `Main.swift`/`App.swift`, else the sole supported
primary file; exclude manifests/descriptors/assets. Conflicting primary candidates
need `entry` and become one broken row. Infer `.swift` → swift, `.html` → web,
known document/image/video MIME → corresponding kind, owned descriptor → link/live.
HTML documents can opt into `document` for inert rendering (scripts/network disabled).
Explicit entry/kind mismatch is broken. Unsupported types remain Artifacts with
“Can’t open · Unsupported file type”. Missing/malformed manifests are different:
missing infers; malformed reports its reason. `swift`/`web` → Apps; all others →
Artifacts. If kind cannot be safely resolved, use Artifacts, preserving one visible
row. Never execute a sniffed image as HTML or inspect source to infer permissions.

## 5. Sandbox, first-open access and revocation

Opening a zero-permission app runs it immediately in the existing restricted
Swift interpreter or an isolated local web runner: no ambient files, processes,
credentials, feeds, network or native APIs. Listing/thumbnailing never executes.
Do not imply WKWebView is a sandbox by itself: nonpersistent store, no file URL
access, navigation/redirect/subresource/WebSocket denial, CSP and a scoped native
bridge must enforce denial before web execution is accepted. Web networking is
brokered through an origin allowlist, never raw JavaScript sockets. Support must
be proven before advertising it; unsupported runtime capabilities show cannotOpen.

When nonempty permissions are requested, **first open** (Apps or chat, same gate)
shows **App Access**: title, each precise data/feed/origin scope, limits, **Allow &
Open** and **Not Now**. No install/source approval ceremony. Builds requests its
own saved values and read-only ios-builds; this grants neither publishing nor an
OS install. Network-only requests name actual origins and warn that data may be
sent there. Unsupported requests are errors, not prompts that cannot be honored.

Gateway persists a grant at `state/app-permissions/<id>.json`, owner-only, schema
versioned and atomic, containing canonical permissions, executable bundle digest,
folder identity (device/inode/birth time), grant revision and maintainer device
attribution. This is authorization state, **not membership**. Agents/app manifests
cannot grant themselves access. A prompt token binds the exact code/config and
current folder incarnation; changed files during consent reject the old token.
Only that authenticated native user action sends `apps.permissions.grant` through
the existing mutation-receipt coordinator. Never expose it as an agent tool.

Grant once for unchanged executable content and scope; title/icon-only edits do
not reprompt. Changed code/assets, scopes, folder incarnation or unsafe grant
invalidate it and ask again. Thus regenerating code keeps saved data but does not
inherit access to that data from replaced code. Folder deletion revokes grants;
identity revalidation handles delete/recreate even if watcher events coalesce.
Remote origin consent covers that site, whose content can change, not a claim of
byte-pinned remote code. No background network before consent.

**Apps → long press → Manage → Permissions → Revoke Access** deletes the grant
via a receipt, closes the privileged runner and invalidates held capabilities.
Revocation survives reconnect/restart; every feed/data/network operation checks
the current grant and code incarnation, not only `open`. In-flight operations may
finish only if already committed under their owner's serialization; no later
writes or sockets continue. Next open asks again. “Not Now” writes no grant and
runs nothing; permissions are not installation state.

## 6. Delete, replacement and orphaned data

Agents and maintainer can edit, regenerate, replace or delete files without an
Apps-specific review/install gate. Normal task authorization/destructive-action
rules still apply. Phone **Delete Files** confirms “Remove this entry from Apps?
Its saved data will stay on your Mac.” It removes only the safe entry directory;
never a linked target, state, backups or unrelated files. Rename/update edits the
manifest/files. CAS protects phone actions from deleting a newer replacement;
external shell/editor operations are not claimed to participate in Gateway CAS.

Open runners pin a content revision. A watched deletion/replacement stops further
execution and closes capabilities; unsaved accepted commands stay with the
receipt/state coordinator and resolve visibly, never silently disappear. State
writes validate live content revision and grant under the same serial owner;
Gateway deletion serializes with writes. A concurrent external mutation is caught
by descriptor/content revalidation; an already committed state write is retained.

**Orphan state is retained indefinitely**, not GC'd because files disappeared.
It never produces a list row or starts an app. Recreating the same id can recover
it only after new code's first-open data consent. No automatic rename/adoption.
The bounded data-management tool can enumerate orphan ids/byte counts and clear
one explicitly confirmed id with revision/CAS; it cannot grant access. Keep “Clear
Saved Data” separate from “Delete Files”. Do not auto-remove orphan data during
cleanup, uninstall, watcher reconciliation or source regeneration. Old orphan
grants are invalid/reclaimable; they cannot resurrect state permissions.

## 7. One-time conversion — plan only, do not run

Persisted registered apps and the live offer are named consumers requiring a
maintainer-approved forward-only migration with an automatic verified backup.
This proposal is **not** that approval. Do not read or touch offer `32174289e1a1`
for this design, and do not choose source by guessing its truncated identifier.

1. Implementation release contains one offline conversion command, not runtime
   compatibility readers. Maintainer stops/drains the old Gateway using the manual
   runbook; converter acquires the existing workspace lease. Inventory exact v1/v2
   app manifests/source hashes and complete offer/session/artifact identities.
2. Back up the source registry/offer metadata and SQLite coherently, with checksums
   and a conversion plan. No live database byte-copy without its SQLite backup
   boundary. Existing folder conflicts refuse without overwrite. Resume only an
   exact checksum-bound plan; per-entry durable receipts prevent duplicate copies.
3. For each registered id copy current source into files/apps/<id>/Main.swift;
   translate name/icon/feeds to app.json, with data readWrite only for existing
   data consumers. Retain the original SQLite path/format/revision under state/apps.
   Move legacy source/manifests/history out of managed data into the migration
   backup after destination validation; do not retain a live registry reader.
4. Resolve live Builds offer **32174289e1a1** against its complete original source,
   metadata and producing artifact. Create files/apps/builds/ from those exact
   bytes and declared ios-builds feed, not tools/web's latest source. If Builds
   is also registered and matches, dedupe into the same folder. If bytes/config
   differ, stop for maintainer selection; never silently replace either version.
5. Convert other reachable retained offers into unique folders, deduping exact
   source/config; conflicting intended ids require explicit resolution. Leave
   unreadable/unreachable offer material only in backup with a report; never
   silently discard it or manufacture source. Offers are not runtime fallback.
6. Seed **no grants**: all migrated capability-using apps ask on first open. Verify
   folder count/source hashes, identical state rows/revisions, restart and open
   using new-only contracts in an isolated fixture. Retire old offers/registry
   metadata only after conversion checks; preserve backup and a completion marker
   in the migration owner. No dual write or fallback. Old chat offers remain
   ordinary historical tool results, with source available in the converted folder
   or backup, not active install cards. Do not retain swift_app offer admission to
   preserve an old card. Invalidate disposable typed snapshot caches at the new
   protocol boundary; canonical JSONL is not rewritten.

## 8. Exact removal inventory and estimate

Inventory is based on inspected base `6768b1799` (includes #2107); paths below are
repo-relative. This is a deletion **plan**, not a diff claiming to have removed code.
“Replace” means delete the old contract, then keep only the named surviving oracle.
In partial-removal bullets, `modules/apps` is under `packages/gateway/src/`;
`Sources`, `Core`, `Fixtures` and `UITests` are under `packages/ios-app/`.
Gateway `test-support`/`test-fixtures` paths are under `packages/gateway/`.

| Delete whole file | Lines | Symbols / oracle replacing it |
| --- | ---: | --- |
| `packages/gateway/src/modules/apps/swift-app-format.ts` | 104 | SwiftAppManifestV1/V2, SwiftAppOffer, SwiftAppActor/Revision, readSwiftAppManifest(V1), readSwiftAppOffer, offerIdentity, referenceKey; new folder manifest; retain digest/bounds/feed validation in new owner |
| `packages/gateway/src/modules/apps/tron-swift-app-extension.ts` | 152 | createTronSwiftAppExtension, old swift_app actions/schema/prompt; filesystem + display and bounded app_data tool replace it |
| `packages/gateway/src/modules/apps/swift-app-display.ts` | 24 | readSwiftDisplaySource; install-only artifact lease adapter; ordinary display ingestion survives |
| `packages/ios-app/Sources/Features/SwiftApps/State/SwiftAppInstallWire.swift` | 75 | SwiftAppDisplayReference, SwiftAppInstallOffer/Review/Command/Result, SwiftAppPendingList, InstalledSwiftAppCatalog |
| `packages/ios-app/Sources/Features/SwiftApps/State/SwiftAppInstallation.swift` | 50 | SwiftAppInstallation and retained install mutation lifecycle |
| `packages/ios-app/Sources/UI/SwiftApps/SwiftAppInstallReviewSheet.swift` | 241 | SwiftAppPendingOfferReview, SwiftAppInstallReviewSheet, install details/source navigation |
| `packages/ios-app/Fixtures/HostedInstallReviewFixture.swift` | 61 | HostedInstallReviewGateway/Observation/Probe |
| `packages/ios-app/Fixtures/HostedAppsInstallDesignFixture.swift` | 79 | HostedAppsInstallDesignFixture, AppsInstallDesignReview |
| `packages/ios-app/UITests/TronInstallReviewUITests.swift` | 107 | all seven methods: testOfferOpensOnlyInstallReview, testPlayOpensOnlyInstallReview, testToolbarInstallUsesReviewedOffer, testDetailsAndSourceLight/Dark/LightXXXL/DarkXXXL |
| `packages/ios-app/UITests/TronAppsInstallDesignUITests.swift` | 101 | testLightDefaultReview, testDarkDefaultReview, testLightXXXLReview, testDarkXXXLReview, testCaptureSourceBeforeInstallReview |
| `packages/gateway/src/modules/apps/apps-install.integration.test.ts` | 523 | retire install/offer/v1-upgrade tests; port live feed/native interpreter oracles to folder suite first |
| `packages/gateway/src/modules/apps/swift-app-store.integration.test.ts` | 502 | retire registry tests; port real SQLite/CAS/drain/path/interpreter oracles to folder/state suite first |
| `tools/web/apps/builds-preview/BuildsInstallDesign.swift` | 116 | retired install-design source; retain current Builds.swift and non-install previews |
| **Whole-file subtotal** | **2,135** | no blanket deletion of runtime or state coverage |

Partial removal/replacement (all other logic in these files remains coherent):

- `modules/apps/swift-app-store.ts`: remove `SwiftAppStore`'s registry root/manifest
  authority, cleanupOffers, pending, offer, readOffer, review, discardOffer,
  installOffer, backupV1, install, requireInstance, source/history publication and
  destructive source+data remove/retirement. Replace list/get/open/rename/remove
  with folder semantics. Preserve/move `state`, `commit`, `resetState`, revision,
  snapshot, withDatabase and safe filesystem/bounds primitives. ~400 old lines.
- `modules/apps/module.ts`: remove apps.list, apps.pending, apps.review, apps.install,
  apps.get and old remove/rename/open shapes; replace composition, capability and
  retained state fences. `SWIFT_APPS_CAPABILITY` in store goes. ~65 old lines.
- `Sources/Features/SwiftApps/State/InstalledSwiftApps.swift`: remove pending,
  installations, review/install ports, review, installation, requireInstallCanStart
  and registry-list admission. Keep accepted state-write ownership and replace
  projection/open ports atomically. ~100 lines. `InstalledSwiftAppWire.swift`:
  remove v1/v2 source/history/install manifest model; retain state values/CAS in
  new folder DTOs. `Sources/State/InstalledSwiftAppsGateway.swift`: remove dual
  list reads and install/review bindings. ~100 lines across these latter files.
- `Sources/UI/SwiftApps/InstalledAppsSheet.swift`: replace Pending/Installed groups,
  pendingReview/onChange, install wording and remove-with-data confirmation; use
  two sections, entry errors, permissions and file-only deletion. ~160 old lines.
- `Sources/UI/SwiftApps/SwiftAppDisplayCard.swift`: remove Review, review state,
  install-specific branch in SwiftAppDisplayRunner, offer acquisition and install
  completion open; retain card/source preview/runner. ~90 lines.
- `Sources/UI/Chat/ChatDisplayViews.swift`: remove DisplayRoute.installsSwiftApp,
  :install identity and tool-name install routing. `Core/Models/DisplayModels.swift`:
  remove swift_app offer intent; `TranscriptModels.swift` remove live producer
  acceptance of swift_app offers (historical persisted display snapshots remain
  ordinary readable values). `gateway/src/display/display-contract.ts`: delete
  swift_app offer producer admission. ~30 lines total; no permissive legacy alias.
- `Fixtures/HostedReadonlyAttachmentFixture.swift`: remove install-review branch,
  installFixture and install probe. `Sources/App/TronMobileApp.swift`: remove
  install-design route. `scripts/ios-gateway-e2e-fixture.sh`: remove offered Builds
  faux tool call; replace with folder seed. ~65 old lines.
- `UITests/RealGateway/RealGatewayBuildsAppsUITests.swift`: remove
  testPendingAppReviewInstallLight/Dark and pendingAppJourney; replace
  testBuildsInstallLight/Dark/LightXXXL/DarkXXXL install setup with folder/open
  journeys, preserving actual feed/interpreter assertions. ~100 old lines.
- Retire old offer/install/upgrade test descriptions in the two deleted Gateway
  suites, specifically list-valid-pending, deleted-session-offer reclamation,
  exact-artifact offer binding, v1 backup retry, offer-review-install-update-remove,
  backed-up v1-to-v2 opt-in and remove/reinstall incarnation. Surviving oracles:
  safe home/publisher path, mixed retained/UUID build feed (#2107), declared bounded
  feed freshness, real interpreter persistence, stale writer, CAS across restart,
  FIFO/path rejection, drain receipts. Port these before deleting their old files.
- `UITests/RealGateway/RealGatewayInstalledAppsUITests.swift`: replace installProofApp
  and old installed-row selectors in testTronMenuListsInstalledAppAndKeepsItsValuesAcrossReopen,
  testRefusedSaveAfterAnAppUpdateIsShownAndKeptUntilDiscarded,
  testManageRenamesClearsDataAndRemovesOnlyAfterConfirmation,
  testCaptureAppsAndManageLight and testCaptureAppsAndManageDark. Preserve
  persistence/refused-save/confirmation behavior; change removal's oracle to data retained.
- `Sources/UI/Chat/ChatTranscriptPresentation.swift`: remove the swift_app branch
  of ChatToolPresentation.isDisplayTool. `ToolDetailPresentation.swift`: remove
  the swift_app label/icon mapping; ordinary historic tool results use generic UI.
- `packages/gateway/test-support/apps-crash-child.ts`: remove the retired install
  source/removal crash cut; keep real receipt-process cuts for new file/data operations.
  `test-support/tron-store-specs.ts`: replace the store-swift-apps install/list/get
  seed/observe specification. `src/modules/apps/apps.store.lock.integration.test.ts`,
  `src/modules/apps/locks/store-swift-apps.golden.json` and
  `test-fixtures/tron-corpus/home/workspace/state/apps/corpus-counter/{App.swift,app.json,data.sqlite}`:
  replace obsolete store-shape lock/recorded fixture only
  after new migration+state preservation oracle passes, not because text changed.
  Keep `fixtures/InstalledPersistence.swift`/`PersistenceBoundaryMain.swift` and
  engine persistence/feed tests. Do not delete SwiftAppViews.swift or SwiftAppEngine.
- Update module manifests/references and owning docs: gateway modules/apps README,
  gateway docs/swift-apps + internal-workspace + display README, iOS docs/swift-apps
  + display-artifacts + events, SwiftApps state/UI READMEs, tools/web Apps/Builds
  guidance; retire install-design documentation, not unrelated Builds source.

Estimate: **~3,350 old executable/test lines removed**, ~1,600–2,100 added for the
folder index, permission broker, DTO/UI and replacement boundary journeys: **net
−1,250 to −1,750 lines**, before a separately bounded one-shot converter (~200–350
lines) and documentation. Not a measured patch delta; watcher extraction should
mostly move lines, and web capability enforcement may increase the estimate.
The design-only commit adds this document and deletes **zero production lines**.

## 9. Verification required before implementation approval/landing

Start with a failing real-boundary reproduction of mixed good/bad entries. No
isolated/mocked unit suite duplicating decoding or UI literals. Stable artifacts
under `test-results/apps-folder/` record fixture identities, RPC outcomes and UI
attachments; synthetic approval PNGs are not these implementation test results.

1. **GatewayService/RuntimeRegistry + real temporary filesystem/socket**: seed Swift,
   web, document, image, malformed manifest, missing entry, unsupported type, unsafe
   name/link/FIFO, oversized bundle. Real catalog returns all rows, only bad ones
   cannotOpen; good apps still open. Repair/remove one and observe apps.changed and
   correct next catalog without restarting or reseeding healthy entries. Repeat
   with 1,001+ directories, paged reads and changes between pages.
2. **Real watcher lifecycle**: create/atomic replace/nested edit/delete externally,
   restart index, replace root, force dropped/overflow events via existing watcher
   boundary seam; verify eventual exact folder membership, stale cursors, shutdown
   with no live handles and recovery from a temporarily absent root. No source-text
   assertions or fake independent timer tests.
3. **Real Pi faux-model display**: invoke each source kind and nested screenshot,
   prove its admitted bytes/descriptor exist in catalog before successful tool
   result, dedupe across sessions/surfaces, dependency handling, canceled/disk-full
   publication, racing identical calls and edited digest collision. Delete entry,
   replay historical result/reconnect; it stays deleted. Explicit new display can
   create it. No live-view restart/credential persistence on expired references.
4. **Grant+runner boundary**: zero access has no authority; requesting access prompts
   only on first open, decline runs nothing, approved data/feed/origin scopes work,
   code/scope/recreated-folder changes invalidate old prompt/grant. Verify revoke
   while running, expired tokens, restart and agent inability to self-grant. Real
   web runner exercises redirect, fetch, subresource, WebSocket and file escapes;
   Swift interpreter tests retain budget/transaction/read-only-feed oracles.
5. **Real SQLite and receipts**: delete/regenerate keeps state bytes/rows/revision,
   stale runner writes fail, duplicate accepted commands settle once, orphan state
   does not list, recreate prompts before restoring data, explicit data clear does
   not delete files; lost established database is an error, not revision zero.
6. **Offline converter fixture/process**: v1/v2 + complete offer, matching and
   conflicting Builds, backup failure/crash-resume cuts, unreadable source and
   destination conflicts; assert no silent fallback, state unchanged, no grants,
   and new-only runtime after conversion. Preserve #2107 mixed-publisher/native
   feed journey in the replacement suite.
7. **Behavioral XCUITest through real fixture Gateway**: both sections; tap good
   sibling after broken row, repair visible while sheet stays open, first-open
   Allow & Open/Not Now, subsequent open without prompt, revoke and reprompt,
   delete confirmation retains data, live empty→populated→empty, gateway switch
   discards stale reads, disconnected mutation receipts never replay automatically.
   Light/dark and accessibility XXXL/VoiceOver semantic controls. No pixel/literal
   assertions as the behavior oracle; visual captures are separate human approval.

## 10. Agent instructions, approval visuals and open decisions

Put the canonical rule in built-in `workspace/tron-core-extension.ts`'s
`tronContext` and delegated workspace handoff, plus `display`'s description and
prompt guidelines (and new `app_data` description). Proposed agent-facing copy:
“Write reusable apps and artifacts under files/apps/<id>/ in Tron's internal
workspace. app.json is optional. display automatically copies external displayed
files there. Files determine Apps membership; deleting files preserves saved app
data. Ask before clearing data or granting access.” No user-profile instruction,
Home-memory dependency or agent-only promise enforcing display membership.

Approval set (full native simulator frames; default type, emerald theme):
`apps-sheet-light.png`, `apps-sheet-dark.png` (both sections + one broken row),
`permission-light.png`, `permission-dark.png`, `empty-light.png`, `empty-dark.png`.
Retained under `~/.tron/gateway/home/workspace/files/apps-folder-design/`; this is
the requested **review-output** location, not the proposed Apps canonical root.
Fixture and capture source are retained beside the PNGs, not in shipping code.
Only the isolated UI-validation simulator test host was provisioned by the owned
test runner; no device/production app installation, OTA, Gateway/Mac restart or live
migration is part of capture.

**Approval questions (nonblocking for this design):**
- Approve conservative reprompt after any executable/assets change or folder
  replacement? Recommended yes; state survives, grants do not follow new code.
- Approve URL/live displays as durable read-only Artifacts descriptors (expired
  live views become broken rows), rather than exceptions to “anything displayed”?
- Approve indefinite orphan-state retention and explicit separate clearing? No
  automatic age/space purge is proposed.
- New web/network support is larger than deleting install flow. Recommended
  delivery order: folder/display/index + existing restricted Swift + inert
  artifacts first; advertise interactive web/network only when its sandbox tests
  pass. Until then those entries remain visible cannotOpen, never run unsandboxed.

Documentation/code mismatch found: current gateway Apps README explicitly excludes
HTML apps, and TronWorkspace explicitly does not scan content. The desired web
runner/general folder index are new work, not existing mechanisms this proposal
can claim already work. Current docs correctly describe pending/install semantics;
these are intentional replacement contracts, not evidence of deployed folder UX.
