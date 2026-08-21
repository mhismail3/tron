# Extension Activity Hub and Lifecycle Hardening Plan

Status: Implemented; focused automated validation passed, physical lifecycle/expiry verification pending

## Objective

Make extension-owned delegated work feel like one native, resilient part of Tron:

- show one compact composer-adjacent pill **per extension** while that extension has queued, running, paused, or attention-requiring delegated work, or terminal work completed within the previous 15 minutes;
- make that pill the entry point to one integrated extension hub containing lifecycle, status, widget, and bounded progress updates;
- move activity older than 15 minutes into an Extension Activity sheet owned by Manage Session;
- preserve stable identity and truthful state through tool settlement, detached execution, reconnect, runtime eviction, Gateway restart, artifact replacement, and canonical history pagination;
- keep canonical Pi JSONL and extension-owned lifecycle artifacts authoritative, without an iOS history mirror, Gateway SQLite mirror, or a second event journal.

The 15-minute rule is a presentation partition, not a deletion policy. Crossing the boundary removes a terminal run from the composer hub but does not remove it from canonical session history.

## Product contract

### Composer visibility

An extension pill is visible when its group has at least one:

1. queued, running, paused, or attention-requiring structured extension run; or
2. completed, failed, stopped, or rejected run whose authoritative terminal time is less than 15 minutes old.

At exactly `terminalAt + 900_000 ms`, the run is historical and no longer keeps the pill visible. Running or paused work remains visible regardless of age. A missing or stale producer update never fabricates completion.

Only an admitted structured lifecycle run creates ambient pill eligibility. Mounted statuses, widgets, and unstructured extension service tools enrich an already-qualifying hub, but do not by themselves keep a permanent composer pill alive. Pending extension interactions continue to use the existing higher-priority native interaction flow. Unknown or ambiguous source-only ownership stays available in ordinary tool/history evidence but cannot collapse several extensions into one ambient pill.

### One pill per extension

Each admitted extension owner gets one stable pill. The pill shows:

- the extension's bounded display name;
- a typed lifecycle summary such as **2 running**, **Needs attention**, **Completed 3m ago**, or **1 failed**;
- a color-independent symbol and optional count;
- local, interruptible state transitions that do not animate transcript structure or issue scroll commands.

Exact opaque Gateway owner identity is primary. Exact public source identity is a compatibility fallback only when the current owner inventory proves it maps to one owner. Ambiguous source fallback fails closed. Package names, rendered widget text, timestamps, and tool names are never grouping keys.

### Extension hub

Tapping a pill always opens the extension hub; it does not bypass the hub merely because one run exists. The hub contains, in order:

1. **Overview** — extension name, aggregate state, freshness, and counts.
2. **Current work** — queued, running, paused, and attention-requiring runs.
3. **Recently finished** — terminal runs still inside the 15-minute window.
4. **Extension updates** — attributed semantic statuses and native/read-only widgets.
5. **Service activity** — extension-owned tools that lack a structured delegated-run projection, without duplicating structured runs.
6. **View all activity** — opens the session's historical Extension Activity destination.

Run rows open a reusable native run detail route. Statuses, widgets, and runs render together; the presence of a structured activity must not suppress the extension's status or widget content.

### Manage Session history

Manage Session owns one **Extension Activity** row rather than a dynamic collection of extension-history rows. Its subtitle reports a bounded summary such as **2 current · 14 earlier** or **14 recorded runs**.

The destination sheet contains:

- **Current and recent** when applicable;
- **Earlier activity**, reverse chronological and grouped by extension/date;
- compact filters for All, Active, Completed, and Problems only when they materially reduce a nontrivial list;
- bounded pagination with an explicit Load More state;
- reusable run details;
- truthful loading, unavailable, empty, reconnecting, and pagination-conflict states.

The sheet may show current work for completeness, but only the composer pill is the ambient current/recent affordance. Historical pages are fetched from the Gateway and are never treated as authoritative when only an iOS cache is available.

## Current-state audit

### What is already sound

- `RuntimeSlot` is the sole per-session live owner of tool and extension projections.
- Extension tool provenance fails open when ownership is unknown or ambiguous.
- Artifact paths are lexical- and realpath-allowlisted and status files are byte bounded.
- A Gateway-owned run binding prevents arbitrary artifact-to-tool reassignment.
- Synthetic artifact identities can hand off to real tool-call ownership.
- Terminal tool lifecycle prevents late running artifacts from resurrecting completed work in several existing paths.
- Child count, depth, text, and output projections are bounded.
- Session snapshots and events already use runtime generation, revision, sequence, and resynchronization admission.
- iOS already has opaque extension grouping, native semantic widgets, a composer pill, run details, and a Manage Session history section.
- Unknown extension provenance remains separate rather than being guessed.

### Gaps that block the target

1. **No 15-minute contract.** `liveGroups` admits only running activities. Terminal activities disappear immediately from the composer and no exact expiry owner exists.
2. **History is runtime-only.** `extensionActivities` is an in-memory map capped at 64. It disappears on runtime disposal/Gateway restart and is not a canonical paginated history source.
3. **Detached terminal truth can disappear.** A background run may finish only in `status.json`; once that artifact is cleaned, canonical tool acknowledgement alone does not retain terminal status.
4. **Lifecycle states are collapsed.** Queued and paused map to running; stopped maps to completed; rejected may remain incorrectly running; attention state is dropped.
5. **Ordering is wall-clock-heavy.** Producer timestamps and Gateway observation timestamps are mixed, equal timestamp replacements are not sequence-owned, and UI elapsed/age calculations use device wall time.
6. **Terminal precedence is incomplete.** The projector supports authoritative terminal status but current callers do not consistently latch and pass it.
7. **Duplicate run handling is incomplete.** Ownership rejection can occur after a second activity has already entered the runtime map.
8. **Artifact scanning scales per slot.** Every live slot scans shared temporary roots every 750 ms, multiplying filesystem work and race surfaces.
9. **Activity decoding is under-validated on iOS.** Recursive children, strings, timestamps, counts, state combinations, and aggregate bytes lack the strict admission used by extension surfaces.
10. **The current hub is not integrated.** When activities exist, `groupSection` suppresses statuses, services, and widgets. A single run bypasses the hub entirely.
11. **Manage Session is not a durable history surface.** It shows only terminal rows retained by the current runtime and describes that limitation in user-facing copy.
12. **No freshness/error model.** Empty, settled, disconnected, stale, unavailable, and never-published states are conflated.
13. **Presentation identity can hand off structurally.** Synthetic artifact rows may be re-keyed when the real tool call arrives, and routes rely on compatibility alias lookup after the fact.
14. **Tool progress does not upsert the activity list.** `SessionPresentationStore` replaces the tool record, but `ChatExtensionWidgetPolicy.groups` does not consume `tool.extensionActivity`; the composer can temporarily degrade to a generic service until a full snapshot arrives.
15. **Nested progress is not fully presented.** Gateway retains bounded nested children, while the native details sheet renders only the first level.
16. **Instrumentation is incomplete.** There is no hosted presented-frame record for extension pill state, hub routing, expiry, stale resolution, or historical pagination.
17. **Privacy is only partially specified.** Paths are reduced to basenames, but tasks/output/summaries have bounds without a complete persistence and instrumentation policy.

## Architecture

### Canonical and disposable layers

| Layer | Owner | Contents | Lifetime |
| --- | --- | --- | --- |
| Pi session JSONL | Pi SessionManager | Tool invocation/result plus normalized terminal extension lifecycle receipts | Canonical session lifetime |
| Extension lifecycle artifact | Extension producer | Current structured runner status and progress | Producer-defined, independently replaceable |
| Gateway activity monitor | Gateway process | Validated artifact observations routed to exact session owners | Process-only, bounded |
| Runtime activity overlay | RuntimeSlot | Current/recent activities, identity bindings, terminal latches, recency deadlines | Runtime-only, bounded |
| Historical query projection | Gateway | Pages derived from canonical JSONL plus the current runtime overlay | Request-only |
| iOS presentation state | Mounted session owner | Authoritative current/recent projection and loaded history page generation | Disposable; no canonical mirror |

Do not add SQLite, a session sidecar mirror, a second lifecycle journal, or durable iOS activity history.

### Canonical terminal receipts

Introduce a reserved Pi custom entry, for example `tron.extension-activity.v1`, written only for an admitted terminal lifecycle transition. This is a normalized canonical receipt, not a transcript message.

Each receipt contains bounded data sufficient for historical presentation:

- stable activity presentation ID and exact session ID;
- opaque extension owner when available and public source fallback;
- real tool-call ID and optional run ID;
- mode and rich terminal state;
- authoritative start, terminal, and observed timestamps;
- duration and bounded aggregate counts;
- an allowlisted historical summary only: child opaque ID/label/state and aggregate tool/turn counts; canonical receipts omit task text, recent output, current path, async directory, and other live-only payload;
- schema version and identity/version facts required for deterministic deduplication.

Rules:

- append through the existing per-session mutation lane;
- terminal-latch first, then append at most once per activity identity;
- capture the originating real tool-call identity before deferral and append the receipt before exposing post-settlement branch/navigation mutations when the terminal transition belongs to the foreground run;
- detached terminal transitions observed while idle may append immediately through the lane; their receipts are session-wide audit facts and do not derive ownership from whichever branch is current at append time;
- on crash/reacquisition, scan existing reserved entries before attempting a retry;
- reserved lifecycle entries remain visible in raw JSONL/export but are excluded from ordinary transcript pagination, transcript totals, session-tree rows, and model-visible conversation projection;
- no running heartbeat or progress update is persisted as a custom entry;
- old structured tool results are backfilled best-effort; missing expired artifacts are reported as unknown rather than fabricated as completed.

### Activity identity

Add one deterministic Gateway-owned activity presentation identity. A native activity is not admitted until a real current or canonical tool-call owner is known; artifact-only synthetic observations remain internal monitor facts. Derive `activityId` from the canonical session ID plus real tool-call ID, then retain it unchanged when `runId` or artifact detail arrives. Keep these separate:

- `activityId` — native route and row identity;
- `runId` — extension producer correlation identity;
- `toolCallId` — canonical Pi tool ownership;
- `extensionOwner.id` — extension grouping identity;
- aliases — bounded one-way handoff facts only.

Never use title, source label, child order, or timestamps as row identity. `runId` enriches and correlates the already-owned row; it never re-keys it. Reacquisition reproduces the ID from canonical session/tool identity even before a receipt is present. Legacy `subagent:<runId>` rows use one bounded alias handoff and fail closed on ambiguity.

### Rich lifecycle state

Keep the existing coarse `status` field for old-client compatibility and add a versioned lifecycle record:

```text
state: queued | running | paused | completed | failed | stopped | rejected | unknown
attention: none | activeLongRunning | needsAttention
sequence: nonnegative monotonic Gateway projection sequence
observedAt: Gateway admission timestamp
producerUpdatedAt: optional display-only producer timestamp
terminalAt: authoritative Gateway terminal-admission timestamp when terminal
recentUntil: terminalAt + 15 minutes when terminal
```

`attention` is orthogonal to execution state. The same versioned lifecycle record is available on bounded child rows; parent aggregate state never overwrites a child's more specific truth. `paused` and `needsAttention` remain current. `stopped` and `rejected` are terminal and remain recent for 15 minutes. `unknown` is historical/unavailable and never fabricates a live pill.

Terminal state is latched. A later advisory artifact cannot move a terminal activity back to queued/running/paused. Equal or older producer updates cannot replace a newer accepted projection. Gateway event sequence and activity sequence own ordering; producer wall time enriches display only. The supported artifact-version/state table explicitly defines how queued and rejected observations acquire exact session/tool ownership; unsupported values are omitted with bounded diagnostics rather than treated as running.

### Server-owned recency

The Gateway owns the 15-minute classification.

- `terminalAt` is the Gateway's terminal-admission wall time. Producer `endedAt` is display evidence only.
- At admission the Gateway records a wall/monotonic pair and gives each terminal activity `recentUntil = terminalAt + 15 minutes`.
- RuntimeSlot schedules one coalesced monotonic timer for the nearest expiry, not one timer per row.
- At expiry it republishes the current/recent projection and increments the live activity revision.
- A reconnect/restart snapshot recomputes the remaining interval from canonical `recentUntil` using the new Gateway process clock and clamps malformed/future values.
- The wire carries Gateway `asOf`, authoritative visibility bucket, and bounded remaining duration. iOS may use the remaining duration only for local visual countdown; the Gateway expiry frame owns removal truth, and response latency can never make iOS classify an activity as newer than an authoritative removal.
- Running/current state always outranks recency.

### Shared artifact monitor

Move temporary/project artifact discovery out of each RuntimeSlot into one Gateway-scoped `ExtensionActivityArtifactMonitor`.

Responsibilities:

- one bounded scan/watch owner per process;
- validate supported lifecycle artifact versions and exact file shape;
- enforce existing lexical/realpath allowlists and byte limits;
- retain only bounded observation metadata, not a canonical history mirror;
- route observations by exact canonical session/cwd/run evidence;
- prioritize current states and newest terminal files before applying per-root caps;
- publish monotonic observation generations;
- remove watches immediately on terminal state, disappearance, owner retirement, or budget eviction.

RuntimeSlot remains the final authority for canonical tool/run correlation. The monitor cannot assign ownership or write a session by itself. A slot with an admitted detached nonterminal activity remains automatic-eviction-protected and administrative-drain-busy until terminal receipt settlement or explicit cancellation/unknown-state resolution; otherwise the only session-lane owner could disappear before terminal truth becomes canonical.

### Snapshot and history protocol

Keep `extensionActivities` as an additive compatibility field but change the new-client contract to current/recent only. Add:

- separate `liveActivityRevision`/Gateway `asOf` facts for current progress and expiry;
- rich lifecycle and exact extension owner on each activity;
- a server recency reference/remaining duration suitable for monotonic client installation;
- aggregate omission metadata when current/recent projection hits count or byte bounds.

Advertise an explicit `extension-activity-history.v1` Gateway capability before clients call the new read-only methods:

```text
session.extensionActivity.list(sessionId, cursor?, limit?, filter?)
session.extensionActivity.get(sessionId, activityId)
```

The historical list response is reverse chronological, cursor-stable, bounded by count and encoded bytes, and includes a next cursor plus an immutable `historyRevision` derived only from receipt/backfill/branch changes. Mutable live progress and expiry use `liveActivityRevision` and never invalidate or reorder an older historical cursor. The first page may compose a separately tagged current/recent section, but historical cursors page receipt-backed rows only. Pagination conflicts return retryable conflict rather than silently mixing generations.

The detail response returns one bounded exact activity generation. iOS installs list summary and detail only when session ID, runtime/presentation generation, history revision, route ID, and request generation still match.

### iOS state ownership

Create focused owners rather than embedding time and pagination behavior in SwiftUI views:

- `ExtensionActivityAdmissionPolicy` — strict bounded decoding/semantic validation;
- `ExtensionActivityVisibilityPolicy` — consumes the Gateway's authoritative bucket and remaining duration; it never independently reclassifies truth from device wall time;
- `ExtensionActivityGroupProjection` — owner grouping, deduplication, typed counts, and deterministic order;
- `SessionExtensionActivityStore` — cancellation-owned historical pagination and exact-generation detail loading;
- `ExtensionActivityPresentation` — shallow pill/hub visual state;
- reuse the shared compact-pill latest-target transition state for local animation unless profiling proves extension-specific coordination is required.

`SessionPresentationStore` must upsert `session.toolProgress.extensionActivity` into `snapshot.extensionActivities` by exact activity ID/sequence before publishing the frame; a full authoritative snapshot replaces that overlay, and terminal latches prevent regression. The mounted store remains authoritative for live/recent state. Historical pages are tied to its exact session/subscription generation and are discarded on profile/session replacement. Snapshot cache continues to omit historical activity and must never turn cached activity into a 15-minute truth source. Unsupported Gateway capability falls back to the existing runtime-only live behavior and labels durable history unavailable instead of issuing unknown methods.

## Native UI design

### Pill

Use one mounted hierarchy for every state:

```text
ExtensionActivityPill
  symbol / progress indicator
  extension title
  typed summary
  optional count badge
```

State priority:

1. needs attention;
2. failed/rejected recent result;
3. running/queued;
4. paused;
5. stopped;
6. recently completed.

The pill samples a shallow visual state containing only owner ID, title, state bucket, count, tone, and symbol. Current tool, duration, output, and child payload updates do not retrigger structural animation. Rapid changes coalesce for one display frame and latest target wins.

Pill insertion/removal may change composer geometry, but owns no transcript scroll command. A typed `.extensionActivity` composer-geometry reason may use the existing viewport coordinator's single nonanimated pinned-tail settlement; detached readers receive no position write and no path issues a smooth follow command. Reduce Motion uses opacity only. VoiceOver announces extension, lifecycle summary, count, and **Opens extension activity**.

### Hub sheet

Replace the current activity-exclusive branch with composable sections. Remove both single-run direct-routing branches in `ChatView` and `ExtensionDetailsSheet`. Use one session-scoped extension route enum/coordinator and one presentation host per root; pending interaction/editor UI has explicit priority, while hub/history intent is deferred or resumed without competing sheets. Inside the host, use one `NavigationStack` and value-based destinations for run details.

- Medium detent: overview, current work, recent summary.
- Large detent: full current/recent runs, statuses, widgets, and services.
- Large Dynamic Type stacks metrics and actions vertically.
- Failures and attention use symbol plus text, never color alone.
- Widget content identifies read-only vs interactive capability truthfully.
- Disconnected state preserves the last authoritative frame as visibly stale only while the mounted session owner remains valid; actions requiring Gateway authority are disabled.
- If a route disappears after canonical replacement, show **Activity no longer available** with a route back to the hub/history rather than dismissing unexpectedly.

### Run details

Refactor the current detail sheet to:

- render rich lifecycle state and attention separately;
- use monotonic active-duration anchoring instead of reparsing wall time every second;
- present recursive bounded children with native disclosure and stable IDs;
- distinguish task, current tool, current file basename, counts, and bounded recent output;
- show exact data freshness and historical/read-only state;
- install detail data atomically by activity generation;
- never open child canonical JSONL concurrently.

### Manage Session

Delete the current per-group `Extension History` section and its group/direct-run sheet state. Place one always-available Extension Activity row with the other session-level destinations; its value reports canonical count when supported and **History unavailable on this Gateway** for the compatibility fallback. Do not put one row per extension directly in Manage Session. Historical run detail accepts an explicit source (`live` or exact history page generation) and uses `session.extensionActivity.get` rather than resolving only against snapshot arrays. Reuse standard settings row alignment, typography, static high-cardinality surfaces, cancellation-owned page preparation, and adaptive navigation chrome.

## Privacy and bounds

- Never project absolute artifact paths, session-file paths, async directories, process IDs, credentials, environment values, or raw owner source paths.
- `currentPath` remains basename-only.
- Tasks, recent output, and current path remain live-artifact detail only and are never written into canonical lifecycle receipts; after artifact cleanup historical detail truthfully exposes the normalized summary as the available audit.
- Hosted instrumentation records opaque IDs/hashes, buckets, counts, revision tags, and routing outcomes—never tasks, output, paths, prompts, or source text.
- Validate nonnegative counts/durations/sequences, strict timestamps, lifecycle combinations, child depth/count, per-string UTF-8 bytes, and aggregate encoded bytes on both Gateway and iOS.
- Current/recent snapshot defaults: maximum 32 activities and a dedicated aggregate byte budget.
- History defaults: 25 rows per page, hard maximum 50, response byte cap, deterministic truncation metadata.
- Preserve the existing 32 direct children, 64 total descendants, and depth-3 ceiling unless measured UI requirements justify a smaller native projection.

## Implementation sequence

### Phase 1 — Contract and projection correctness

Gateway:

- add the rich additive lifecycle record, exact opaque owner identity, and `extension-activity-history.v1` capability;
- validate lifecycle artifact state/version instead of collapsing unknown states;
- fix top-level aggregate progress precedence over the first child;
- latch terminal state and add monotonic per-activity projection sequence;
- suppress ambiguous duplicate run IDs before insertion;
- add explicit aggregate byte bounds and diagnostics.

Tests:

- every lifecycle/attention state;
- queued/paused/rejected/stopped behavior;
- terminal-vs-late-running precedence;
- equal/older update rejection;
- duplicate run ownership suppression;
- privacy and aggregate bounds.

### Phase 2 — Shared monitor and exact recency

- introduce the Gateway-scoped artifact monitor;
- replace per-slot 750 ms global scans;
- add coalesced 15-minute expiry scheduling;
- expose current/recent projection revision, Gateway `asOf`, authoritative bucket, and remaining duration;
- make admitted detached nonterminal work explicit eviction/drain protection;
- preserve current work regardless of age.

Tests use injected clocks and filesystem fixtures for:

- `14:59.999`, exactly `15:00.000`, and later;
- Gateway wall-clock jumps while monotonic deadlines remain stable;
- app disconnect/reconnect across expiry;
- more than 64 files with current work prioritized;
- monitor owner retirement and watcher cleanup.

### Phase 3 — Canonical history

- define and document `tron.extension-activity.v1`;
- append exactly-once terminal receipts through the session lane;
- exclude reserved receipts from ordinary transcript rendering;
- backfill compatible canonical tool results and surviving artifacts;
- implement list/detail methods with stable cursors and byte bounds;
- merge runtime overlay without duplicates;
- expose history revision and retryable pagination conflict.

Tests cover:

- synchronous and detached completion;
- restart/runtime eviction with and without surviving artifacts;
- crash between append and in-memory acknowledgement;
- branch changes and session-wide receipt discovery;
- canonical export visibility but transcript invisibility;
- pagination, filtering, conflicts, malformed receipts, and old sessions.

### Phase 4 — iOS policies and stores

- add strict models/admission for lifecycle, owners, authoritative visibility, omissions, pages, and details; malformed optional activities are omitted with bounded diagnostics when safe, while malformed snapshot-level revision/authority facts force resynchronization;
- add pure owner/admission/group/pill policies and a monotonic local visual-deadline helper that cannot override the Gateway bucket;
- merge tool-progress activities into the exact snapshot overlay by activity sequence;
- create the cancellation-owned history store;
- bind current/recent state to exact mounted presentation authority;
- preserve old-Gateway fallback without claiming durable history.

Focused owners:

- `GatewayProtocolContractTests.swift` and shared fixtures: wire compatibility, state combinations, bounds, owner privacy, capability fallback;
- `SessionPresentationStoreTests.swift`: tool-progress upsert, terminal latch, snapshot replacement, reconnect;
- `ChatTranscriptPresentationTests.swift`: lifecycle-only ambient admission, owner ambiguity, grouping, authoritative buckets;
- new history-store tests: cursor conflicts, cancellation, exact-generation page/detail admission;
- `SnapshotCacheTests.swift`: history and recency truth remain excluded.

### Phase 5 — Integrated UI

- replace single-run direct routing with the extension hub;
- render lifecycle, statuses, widgets, and services together;
- implement one stable pill per extension and latest-target animation;
- add the single Manage Session destination and paginated history sheet;
- refactor run details for rich states and nested children;
- centralize extension modal/navigation arbitration.

Hosted/UI owners:

- `ChatViewScrollHarnessTests.swift`: pill insertion/removal causes no smooth follow, detached readers receive zero writes, pinned readers receive at most one nonanimated composer-owner settlement;
- presentation policy/hosted tests: one/many extensions, one/many runs, simultaneous lifecycle/status/widget rendering, attention, recent success/failure, exact expiry, and stable pill samples;
- route/store tests: hub-first navigation, interaction priority, stale route, historical detail generation, empty/error/loading/reconnect states;
- focused UITests: Dynamic Type, VoiceOver labels/values/hints, Reduce Motion, and disconnected controls.

### Phase 6 — Accessibility, performance, and instrumentation

- VoiceOver labels/values/hints and color-independent state;
- Dynamic Type and narrow-width layouts;
- Reduce Motion and local-only animations;
- static scroll surfaces for long history pages;
- hosted pill samples and route/pagination outcomes;
- monitor scan/read/watch counters and omission diagnostics.

### Phase 7 — Documentation and validation

Update together:

- `packages/gateway/README.md` for canonical receipts, monitor ownership, protocol, clocks, bounds, and history;
- `packages/ios-app/docs/architecture.md` for authority, cache, navigation, and presentation identity;
- `packages/ios-app/docs/events.md` for live/recent/history transitions and modal priority;
- shared protocol fixtures and focused Gateway/iOS tests.

Run the narrowest owners first, then Gateway build, generic iOS build-for-testing, personal-info guard, diff check, and physical-device scenarios. Do not run broad simulator combinations that have previously hung.

## Physical-device acceptance scenarios

1. One subagent starts: one correctly named extension pill appears without moving the transcript.
2. Several children start/update: the same pill remains mounted and counts/status retarget smoothly.
3. A run needs attention or pauses: state is truthful and accessible without appearing failed/completed.
4. One child fails while others run: failure is visible, group remains current, and details preserve child identity.
5. All runs complete: the pill remains as recent activity for 15 minutes.
6. The 15-minute boundary passes with no other events: the pill disappears without a scroll command; history remains.
7. App backgrounds/disconnects before completion and reconnects afterward: one authoritative group returns with no duplicate or stale running resurrection.
8. Gateway restarts after detached completion: current/recent or history reconstructs from canonical receipt and artifact evidence.
9. Multiple extensions run simultaneously: one pill per exact owner; no source-text guessing or cross-attribution.
10. Manage Session loads multiple history pages, rotates the device, changes Dynamic Type, disconnects, and reconnects without stale page installation.
11. Old sessions without receipts show best-effort compatible history and explicit unavailable state where truth cannot be recovered.
12. VoiceOver and Reduce Motion preserve the complete workflow.

## Acceptance checklist

- [ ] One stable pill appears per exact extension owner for current or <=15-minute terminal activity.
- [ ] Exact boundary classification is Gateway-owned and tested with injected clocks.
- [ ] Queued, paused, stopped, rejected, failed, and attention states remain distinct.
- [ ] Terminal state cannot be resurrected by advisory artifacts.
- [ ] Artifact observations are not native-admitted before real tool ownership; run enrichment never replaces the native activity identity.
- [ ] Status, widget, service, and lifecycle content coexist in one hub.
- [ ] Single-run groups no longer bypass the hub.
- [ ] Manage Session owns one Extension Activity destination with bounded canonical pagination.
- [ ] Older activity survives runtime eviction and Gateway restart when canonical truth exists.
- [ ] Detached nonterminal work protects its session owner from eviction/drain until terminal receipt or explicit resolution.
- [ ] Detached terminal truth receives an exactly-once canonical receipt.
- [ ] Reserved receipts remain in JSONL/export and out of the ordinary transcript.
- [ ] iOS stores no durable activity-history mirror.
- [ ] Artifact discovery has one bounded Gateway owner rather than one global scan per slot.
- [ ] Recursive activity payloads are strictly bounded and validated on both sides.
- [ ] Device wall clock does not decide recency or active duration; Gateway bucket/expiry frames remain authoritative.
- [ ] Pill transitions are local, latest-target-wins, and Reduce Motion compliant.
- [ ] Transcript structure receives no extension-pill animation; detached readers receive no scroll write and pinned settlement is nonanimated/composer-owned.
- [ ] Hub/history/detail routes install only exact authoritative generations.
- [ ] Old Gateway capability fallback never claims canonical history support.
- [ ] Hosted instrumentation contains no task/output/path/source text.
- [ ] Focused Gateway and iOS tests pass.
- [ ] Generic iOS build-for-testing succeeds.
- [ ] Physical-device acceptance scenarios pass.
- [ ] `git diff --check` and `scripts/personal-info-guard.sh` pass.

## Explicit decisions captured by this plan

- The 15-minute clock starts at authoritative terminal time, not last progress time.
- Failed, stopped, and rejected work remains recent for the same 15-minute window.
- Paused and attention-requiring work is current.
- Composer presentation is per extension, not one global activity pill and not one pill per child.
- Statuses/widgets enrich lifecycle-qualified hubs; they do not create permanent ambient pills by themselves.
- Manage Session uses one Extension Activity destination rather than one row per extension.
- Historical truth is canonical Gateway data, not an iOS cache.
- Terminal detached lifecycle is normalized into the existing Pi JSONL rather than a new database or sidecar journal; receipts are session-wide audit facts and omitted from transcript/tree/model projection.
- Current/recent and historical projections remain bounded and explicitly incomplete when limits apply.

## Known migration limitation

Runs completed before canonical lifecycle receipts exist can be reconstructed only from compatible canonical tool results or lifecycle artifacts that still survive. Tron must label unrecoverable status as unavailable; it must not invent completion times or outcomes.
