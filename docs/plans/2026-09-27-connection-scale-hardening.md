# Connection and scale hardening

- **Started:** 2026-09-27
- **Status:** Active (Phase 1 runs on `hardening/integration`; that branch's copy of this plan is authoritative until R-1)
- **Last updated:** 2026-09-28, O-6a blocked on a quiet-host repeat (second review response landed)
- **Goal:** A clean, efficient and predictable Gateway and phone connection: the phone stays connected and loads any session promptly whenever the network path is up, however many sessions run and however large the history grows, and every disconnect or slow operation is attributable to one cause from the logs in one step.

## Goal and constraints

### End state

When this plan closes, these are true and measured (exit criteria are in
Plan rules, "Exit criteria"):

- **The request path never does work proportional to history.** Session list,
  open, attention and automation reads use an owned, change-driven catalog
  index. No request walks the session folder or re-parses a transcript it does
  not return.
- **No work without an audience.** Snapshots and frames are built only for
  clients that will receive them. Superseded state is replaced in queues.
- **Every operation is bounded.** Disposable reads have server-side deadlines,
  can be cancelled, and join an identical in-flight read. Memory, queues,
  background work and durable writes have named budgets. Overload sheds
  predictably with a typed `busy` and a retry hint instead of slowing down.
- **The event loop stays responsive.** No single synchronous task on the
  Gateway loop exceeds a named bound under the qualification workload.
- **Background work cannot starve interactive work.** It runs in one scheduler
  that yields to requests.
- **The phone's connection is truthful and self-healing.** "Connected" means a
  live socket. While foreground and not connected, an attempt is always in
  flight or scheduled. Recovery after a path outage is immediate. At home the
  phone uses a direct, pinned LAN endpoint, so Tailscale flaps do not
  disconnect it.
- **Reconnect is cheap.** It sends only what changed.
- **Every critical juncture is logged once, correlated across phone and Mac.**
  One command turns an incident's logs into a list of episodes by cause.
- **Superseded mechanisms are deleted.** Whole-tree catalog validation,
  full-parse fallbacks and per-stage slow warnings that the new owners replace
  are gone, with their docs and tests.

### How the plan runs

1. **Phase 1 — Build and qualify everything.** Every task that does not need
   real-world use is built on one integration branch and proven against the
   qualification scenario and E2E harnesses. The user's running Tron is not
   touched.
2. **Phase 2 — One release and one evaluation day.** The integration branch
   merges to `main` as a single release (protocol 6). The user installs it
   once, uses Tron normally for at least a day, and exports the phone's logs.
   The triage tool turns that day into numbers against the exit criteria and a
   precise list of anything left.
3. **Phase 3 — Follow-ups.** Only what the evaluation day shows, plus the two
   tasks that need its data to be scoped. The plan closes when every exit
   criterion holds on an evaluation day.

### What must not change

- **No UI or UX regression.** Chat identity, scroll continuity, native layout,
  composer and keyboard behaviour stay as they are. The only intended visible
  changes are those decided in D-2 (label) and D-5 (a one-time iOS Local
  Network prompt).
- **Canonical truth stays canonical.** Runtime JSONL remains the only authority
  for session content. Any index or projection this plan adds is bounded,
  rebuildable and owned by one component.
- **Gateway transitions stay manual** (`AGENTS.md` rules 8 and 9). Agents build
  and validate; the user restarts the Gateway and installs the app.
- **Accepted commands keep their owners.** Cancellation, deadlines and load
  shedding apply to disposable reads and to admission of new work, never to
  admitted mutations or prompts. Acknowledged mutations stay durable before
  their response.
- **One release.** Everything built in Phase 1 ships together as protocol 6
  (Plan rules, "The release"). No compatibility shims unless the user approves
  one.
- **Tests follow the testing policy.** Every task proves itself with an E2E or
  integration case that leaves an artifact; isolated tests only where the task
  lists the failure modes first.

### Design principles every task is held to

1. **The request path does O(result) work, never O(history).**
2. **State is maintained by the owner that changes it (push), not re-proved by
   scanning (pull).** External writers are observed, not polled per request.
3. **No audience, no work.**
4. **Every read has a deadline and can be cancelled.** A retried read joins the
   in-flight one.
5. **Bounded by bytes and time, not counts.** Superseded state is replaced, not
   queued.
6. **Reconnect resumes; it does not reload.**
7. **The phone's connection state machine has a liveness invariant** and
   publishes the transport's state, not projection progress.
8. **Interactive work has priority.** Background work yields.
9. **Every critical juncture writes one correlated record**, with a stage
   breakdown when slow.
10. **Delete before adding.** Each task removes what it supersedes in the same
    change.

### User decisions (2026-09-27)

These are settled; tasks implement them without asking again.

- **D-1 — One reconnect plan.** The phone reconnect tuning plan folds into this
  plan (P-0).
- **D-2 — "Connected" follows the transport.** A live, authenticated socket is
  shown as connected. Slow chat restoration shows its own loading state and
  never flips the connection back to "Reconnecting" (C-2).
- **D-3 — Change-driven session catalog.** The most robust and efficient
  design: one owner keeps an index current from change events, with background
  reconciliation as the backstop, and the request path never walks the session
  folder. JSONL stays authoritative. The "speculative caches" wording in
  `packages/gateway/docs/connection-resilience.md` is replaced by the index
  contract (G-1d).
- **D-4 — Faster, truer liveness and retry.** Transport-open gives up after
  about 5 s, retries at once when the path changes, and any inbound frame
  proves liveness (C-3, C-4).
- **D-5 — Direct LAN endpoint, approved on condition.** Built only as specified
  in E-3: encrypted and pinned, explicitly bound, raced efficiently with
  Tailscale, falling back without a visible disconnect. If a requirement cannot
  be met, the task stops and reports.

Decisions still open (tasks marked Needs scoping carry them): moving work to a
worker thread (G-11, only if chunking cannot meet the bound), a host budget
for agent child processes (G-14), viewing sessions without a runtime (G-6).

## Context

Measured 2026-09-27 and 2026-09-28 on this Mac (18 cores, 36 GB) with five
sessions running, from the Gateway log, three phone exports, the Tailscale
network-extension log and direct measurement. "Measured" means reproduced
here; "inferred" means read from code and not yet reproduced.

### What the user saw

One 7-hour phone export (2026-09-27 22:50 to 2026-09-28 05:49 UTC): 77
reconnect episodes (60 resolved within 5 s, most in about 0.25 s after
foregrounding; 17 lasted longer), 149 connection attempts that timed out after
15 s (most while the main connection was up, so from the dashboard pool's
second profile; inferred), 15 `session.open.failure` records and 8 app
launches, several straight after a stuck state.

### Four independent causes

1. **Network path flaps (measured).** The iPhone (`iphone193`, 192.168.4.23) and
   the Mac (192.168.4.24) share a LAN, yet Tailscale's direct path between them
   dropped to relay-only about 14 times in 5.5 hours, for 30–121 s each, with no
   traffic in either direction. Every abnormal Gateway close with a long-silent
   phone on 2026-09-28 (01:35, 02:40, 03:24, 03:53, 04:56, 05:38, 05:46, 05:55,
   05:58 UTC) and every phone episode in the 01:27–01:35 cluster falls inside
   one of these windows.
2. **"Reconnecting" over a live connection (measured, cause inferred).**
   04:05:25–04:11:46 UTC the published state stayed `reconnecting` while chats
   opened on the same socket. The reconnect loop in
   `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift` sets
   `.reconnecting` again after the handshake while it restores the mounted
   chat, so slow server work looks like a network problem.
3. **Silent recovery gaps (measured, cause unknown).** 03:24:45–03:30:30 and
   04:56:31–04:58:46 UTC: not connected, the last scene record says foreground,
   and neither the selected-profile loop nor the dashboard pool recorded any
   attempt. Suspension without a scene record, a blocked main actor, or parked
   loops all fit. Code shows how parking can happen: `requestReconnect` and
   `scheduleReconnect` return silently while `networkPathSatisfied` is false or
   a connection or projection task exists, and the loop awaits mounted-chat
   restoration before it can retry. The deciding records were lost with the
   96-record incident store.
4. **The Gateway is slow under load (measured).** Since the 01:33 UTC restart,
   every `session.list` (35 of 35) took over 1 s: successful ones averaged
   10.3 s (max 43.9 s), abandoned ones 22.6 s (max 68.3 s). Cold `session.open`
   reached 52.4 s; `push.registration.upsert` averaged 4.5 s (max 20.6 s). At
   04:11 a cold open ran 52 s, the phone timed out at 30 s, its retries were
   rejected as duplicate opens, and the user force-quit.

### Why the Gateway is slow

- **Whole-catalog re-validation on the request path (inferred, cost
  measured).** `packages/gateway/src/sessions/runtime-registry.ts` re-proves the
  catalog per request: `session.list` forces a fresh structure walk
  (`validatedStructuralIndex` → `sharedCatalogStructureEvidence(true)`); a cold
  open walks at acquisition and again at final validation; attention writes on
  cold rows walk inside the attention lane (`attentionEntryStillAdmitted`),
  which also serializes reply completions. A walk opens, stats and reads the
  header of every file (about seven filesystem operations each). Routine events
  bump the structural generation and force index reconciliation
  (`CatalogMetadataIndex.reconcile`, about nine operations and a 64 KiB read per
  row) plus more walks. If a file changes mid-walk (subagent children append
  constantly), `fallbackCatalogAcquisition` parses every JSONL in full, twice.
- **Catalog size (measured):** 2,995 walked JSONL files, 11.2 GB (225 sessions,
  2.8 GB; 460 forks, 6.4 GB; the rest subagent transcripts), about 50 new files
  a day, largest 188 MB. The 4 MiB identity budget is 1.05 MB used; near 11,000
  files every read would take the full-parse fallback.
- **Walk cost scales with event-loop load (measured):** 82 ms idle; 160, 415
  and 940 ms at 50, 80 and 90% synthetic load. Disk contention alone did not
  reproduce the slowdown.
- **Snapshots built for nobody (inferred).** `RuntimeSlot.publishSnapshot` in
  `packages/gateway/src/sessions/runtime-slot.ts` builds a full snapshot
  (canonical branch walk plus a transcript page up to about 600 KB) on every
  state change, and `GatewayServer.broadcastSession` in
  `packages/gateway/src/transport/server.ts` serializes it before checking
  subscribers. The Gateway sat at about 83% CPU with five sessions running. A
  JavaScript CPU profile was not taken (it needs a restart).
- **No cancellation (inferred).** No cancel frame exists; abandoned reads run to
  completion and keep the per-connection open slot, so a retry fails as a
  duplicate.
- **No memory budget (measured).** Live runtimes are capped by count (128), not
  bytes. A 108 MB session costs about 230 ms of blocked event loop and 310 MB of
  heap to open. Node's default heap limit is 4.2 GB; the Gateway peaked at
  1.06 GB RSS and 581 MB heap, with event-loop utilization 1.00 and a 101 ms GC
  pause.
- **Queues keep superseded snapshots (measured once).** The 8 MiB outbound cap
  counts uncompressed bytes and keeps every queued snapshot; a slow path fills
  it (2026-09-27 22:20:37: 282 frames, 8.37 MB, next frame 638 KB).
- **Durable writes serialize (inferred).** Every receipt-backed mutation writes
  two fsynced receipts under one process-wide mutex in
  `packages/gateway/src/transport/command-receipts.ts`; a durable write took
  8–16 ms on an idle disk.

### Other waste found

- About 19 requests per reconnect, including `model.list` five times,
  `provider.list` twice and a durable `push.registration.upsert` when nothing
  changed.
- An unreachable second Gateway profile retries every ~17 s while the app is in
  the foreground.
- `extension.artifact-rejected` fired 88 times in 4.5 hours (five owners
  repeating `artifact-replacement-in-progress`).
- Something invokes the Tailscale CLI about every 37 s on the Mac. Candidates:
  `packages/mac-app/Sources/Support/Onboarding/TailscaleProbe.swift` and
  `packages/gateway/src/admin/diagnose.ts`.
- Phone `operation.*` signposts span background time (a 22-minute
  `scrollCommandSettle`); `session.open.failure` reports `code=transport` for a
  Gateway conflict.
- The `tron-profile-ios` profiler peaked near 10 GB RSS on 2026-09-28.

### Why diagnosis took hours

- Phone reconnect and path records live only in a 96-record incident store; a
  7-hour export explains the last ~6 minutes. Scene records are sometimes
  written at resume, and nothing records a blocked main actor.
- The Gateway records nothing for an upgrade the phone abandons.
- Slow requests log only stages that individually exceed 1 s; 40 s of the 52 s
  open is unaccounted for.
- Nothing records broadcast volume, catalog walks, per-runtime memory or the
  Tailscale peer path, and phone and Gateway connection IDs share no key.
- Correlating the three logs took manual work; there is no triage tool.

Signals that would have named each cause in one step: O-2's
`connection.inbound-silent` with the Tailscale peer path (cause 1), O-4's
`connection.episode` and `reconnect.stalled` (causes 2 and 3), O-3's request
span on `session.open` (cause 4), all joined by O-7.

### Related plans

- The phone reconnect tuning plan (`phone-reconnect-tuning`): folded in by P-0.
- `docs/plans/2026-09-27-simulator-lifecycle.md`: owns host memory from
  simulators; its SIM-8 overlaps O-5 (one owner for host memory records).
- `docs/plans/2026-09-27-energy-efficiency.md`: its Gateway profiler is O-6's
  base; its T-GW-DUPSNAP touches snapshot publication (coordinate with G-3);
  its R-FOLLOW owns chat layout cycling (relevant if C-1 finds a blocked main
  actor).

## Plan rules

### Roles

- **Orchestrator:** owns the integration branch, schedules tasks, hands each
  worker one task, reviews the result against the review gate, merges, runs the
  release tasks R-1 and R-4 and asks the user for the install (R-2) and the
  evaluation day (R-3). The orchestrator does not implement Phase 1 tasks.
- **Worker:** implements exactly one task from its section in this file,
  following the worker procedure. A worker never widens scope; anything else
  becomes a new row proposed in its handoff.

### Branch model

The whole of Phase 1 is built on one integration branch, so `main` never holds
a half-finished protocol change and the user's running Tron is untouched until
the release. This is a deliberate exception to the claim-on-`main` rule in
`docs/plans/README.md`, approved with this plan.

- **Integration branch:** `hardening/integration`, created from `main` when the
  plan is activated, checked out in its own worktree (suggested:
  `~/Workspace/tron-hardening`). Only the orchestrator merges into it.
- **Task branches:** each task is built on `hardening/<task-id>` (lowercase, for
  example `hardening/o-3`), branched from the current `hardening/integration`,
  in its own worktree.
- **Plan updates:** during Phase 1 the authoritative copy of this plan is the
  one on `hardening/integration`. Claims, row statuses and handoff entries are
  committed there. The copy on `main` says so in its Status line.
- **Staying current:** the orchestrator merges `main` into
  `hardening/integration` at least once a day and before every task branch is
  created, resolves conflicts, and re-runs the checks of any conflict zone the
  merge touched. Other active plans (iOS module split, energy efficiency,
  simulator lifecycle) change the same areas; when a path in this plan moves,
  the orchestrator updates the plan in the same merge.
- **Release:** R-1 merges `hardening/integration` into `main` once. After that,
  Phase 2 and Phase 3 follow the normal protocol on `main`.

### Worker procedure (every task)

1. Read `AGENTS.md`, this plan's Goal and constraints, Plan rules, and your
   task's section. Read the owning docs your task names.
2. The orchestrator has claimed your task on `hardening/integration`. Do not
   claim or edit other rows.
3. Work in a worktree on branch `hardening/<task-id>`, created from the current
   `hardening/integration`.
4. If the task needs an isolated test, write its failure-modes list into your
   handoff draft before writing code. Each isolated test targets one listed
   failure mode.
5. Implement the smallest change that meets "Done when". Delete what it
   supersedes. No `any` casts, no compatibility branches, no speculative
   options.
6. Run the task's checks. Use focused commands only: never the full Gateway
   vitest suite on this Mac (it stalls the live Gateway); never
   `xcrun simctl shutdown all`; clean up every process and simulator you start.
7. Update in the same commit: owning docs, observability rows, this plan's row
   status and a handoff entry (template in `docs/plans/README.md`).
8. Run `python3 scripts/check-documentation-policy.py` and
   `scripts/personal-info-guard.sh`.
9. Commit with a conventional message (`feat(gateway): …`, `fix(ios): …`,
   `perf(gateway): …`). Do not push or merge; the orchestrator merges.
10. Never restart, rebuild or update the running Gateway, and never install
    the app. Nothing ships before R-2.
11. **Stop and mark Blocked** with a handoff entry when: a "Done when" item
    cannot be met, a decision is needed, a failure mode cannot be covered, the
    task would need the live Gateway or the user's data, or the change would
    exceed the owning files by more than their tests and docs.

### Orchestrator procedure

1. At activation: create `hardening/integration` and its worktree, and do P-0
   on `main`.
2. Pick Phase 1 rows whose dependencies are Done, in table order, respecting
   the conflict zones. Claim each on `hardening/integration` before handing it
   out. Run independent zones in parallel.
3. Give the worker: the task ID, the path to this file in the integration
   worktree, and "follow the worker procedure". Do not paraphrase the task; the
   section is the contract.
4. Review gate before merging a task branch into `hardening/integration`:
   - the diff stays within the task's owning and new files plus tests and docs;
   - every "Done when" item has evidence (command output, artifact path,
     numbers) in the handoff;
   - new records have rows in `packages/gateway/docs/observability.md` and the
     logging contract is followed;
   - superseded code, tests and doc lines are deleted;
   - no new `any` casts, shims, TODOs or disabled tests;
   - `python3 scripts/check-documentation-policy.py` passes.
5. After each merge, re-run the focused checks of the zones the task touched on
   the integration branch.
6. Keep "Findings" current: the `main` baseline from O-6a and O-6b, then the
   release-candidate numbers from R-1.
7. When every Phase 1 row is Done, run R-1. From R-2 on, follow the Phase 2
   task sections.

### Conflict zones

At most one in-flight task per zone. Tasks listed in order.

| Zone | Files | Tasks |
| --- | --- | --- |
| Transport | `packages/gateway/src/transport/server.ts` | O-1, O-2, O-3, O-5, G-3, C-6, G-12, G-4, E-3a, E-3b |
| Registry | `packages/gateway/src/sessions/runtime-registry.ts` | O-3, O-5, G-1a, G-1b, G-1c, G-3, G-2, G-12, G-5, G-9 |
| Slot | `packages/gateway/src/sessions/runtime-slot.ts` | O-3, O-5, G-3, G-11 |
| Catalog | `packages/gateway/src/sessions/catalog-discovery.ts`, `packages/gateway/src/sessions/catalog-metadata-index.ts` | G-1a, G-1b, G-1c |
| Phone lifecycle | `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift`, `packages/ios-app/Sources/State/AppModel.swift` | O-4, C-1, C-2, C-3, G-7, E-3c |
| Phone client | `packages/ios-app/Sources/Gateway/GatewayClient.swift`, `packages/ios-app/Sources/Gateway/GatewaySocketTransport.swift` | O-1, O-4, C-3, C-4, C-6, G-12, E-3c |
| Phone pool | `packages/ios-app/Sources/State/DashboardGatewayConnectionPool.swift` | C-5 |
| Launcher | `packages/mac-app/scripts/tron-gateway-launcher.c` | G-9, G-5 |
| Profiler | `scripts/tron-profile-gateway`, `scripts/tron-profile-gateway-driver.mjs` | O-6a, O-6b, G-13 |

A task in several zones holds all of them while it runs.

Also check the energy-efficiency plan's Claimed rows before starting G-3 or
G-11 (same files).

### Phase 1 waves

A suggested schedule; dependencies in the table are authoritative.

- **Wave 0 (parallel):** O-1, O-6a, E-2.
- **Wave 1:** O-2, O-3, O-4, O-6b.
- **Wave 2:** O-5, O-7, C-1.
- **Wave 3:** G-1a → G-1b → G-1c → G-1d; G-3; C-2; C-5; G-10.
- **Wave 4:** C-3, C-4, C-6, G-12, G-2, G-7, G-11, G-9.
- **Wave 5:** G-4, G-5, E-3a → E-3b → E-3c → E-3d, G-13, G-8, E-1.

### The release

Everything from Phase 1 ships in one release (R-1, R-2), so the user makes one
change to their setup and the evaluation day sees every improvement and every
new record at once.

- **Protocol:** the release is protocol 6. `PROTOCOL_VERSION` and
  `MIN_PROTOCOL_VERSION` in `packages/gateway/src/version.ts` and
  `packages/ios-app/Core/Gateway/GatewayProtocolContract.swift` change together
  in the first Phase 1 task that changes a message shape (C-6, G-7, G-12 or
  E-3b), and no other task changes them. The Mac Gateway and the iOS app must
  be updated together.
- **What the user installs (R-2):** the Mac app Release build, which stages the
  Gateway and the launcher (`packages/mac-app/docs/development.md`, "Reinstall
  a local Release build"), and the iOS build from the repository device
  helpers. Agents prepare both and give exact paths; the user performs the
  installs.
- **Rollback:** if the day goes badly, the user reinstalls the previous Mac app
  build and iOS build together (protocol 6 cannot talk to protocol 5). R-1
  records the previous build identities before the release. The LAN endpoint
  alone can be turned off with its setting.

### Logging contract

Every task that touches a critical juncture adds or replaces records under
these rules, with a row in `packages/gateway/docs/observability.md` and a test
in the same change.

- **Correlated.** Connection-scoped records on both sides carry the O-1 key
  (`peerClientId`, `peerAttemptId`, `peerEpoch` on the Gateway;
  `gatewayConnectionId` on the phone).
- **Slow means broken down.** A slow operation logs one record with every stage
  duration, wait and count, not one record per slow stage.
- **Levels.** Transitions at info, detail at debug, thresholds at warning,
  broken invariants at error, per the level policy in
  `packages/gateway/docs/observability.md`. Every promoting threshold is a named
  constant with a one-line reason next to it.
- **Names.** Event names are `area.noun` or `area.noun-verb` in lower case, as
  existing events are. Field names are camelCase; durations end in `Ms`, sizes
  in `Bytes`.
- **Volume budget.** Persisted Gateway volume at most 1 MB/day on a normal day
  (3× the measured 300 KB/day); phone AppLog at most 1 MiB/day. O-5 and O-4
  state their expected volume; V-1 measures.
- **Cheap.** No synchronous I/O and no per-frame records on hot paths. Samplers
  use native histograms and counters, not timers faster than 1 s.
- **Privacy unchanged.** No content, tokens, full device identifiers or
  absolute paths beyond what existing records already carry.

Critical junctures:

| Juncture | Owner | Record(s) | Task |
| --- | --- | --- | --- |
| TCP accept → upgrade → auth → WebSocket → hello | Gateway transport | `http.upgrade` | O-2 |
| Silence on an open socket | Gateway transport | `connection.inbound-silent`, `connection.inbound-resumed` (with Tailscale peer path) | O-2 |
| Every RPC | Gateway transport | `rpc.completed` with `stages` | O-3 |
| Catalog change, reconcile, watcher | Catalog owner | `catalog.changed` (debug), `catalog.reconciled`, `catalog.watcher-reset` | G-1 |
| Snapshot build and broadcast | Slot / transport | per-topic counters in `gateway.resources` | O-5 |
| Runtime load and eviction | Registry | `runtime.loaded`, `runtime.evicted` | O-5, G-5 |
| Background work | Scheduler | `background.slice` (debug), `background.backlog` | G-9 |
| Durable writes | Each store | counters in `gateway.resources` | G-10 |
| Load shedding | Transport / registry | `gateway.shed` | G-12 |
| Outbound queue | Transport | coalescing counters, `connection.outbound-capacity` with topics | G-4 |
| Phone attempt, path, scene, episode | iOS lifecycle | `gateway.attempt`, `connection.episode`, `reconnect.stalled`, `app.main-stall` | O-4 |
| Phone request timeout, cancel, retry-after | iOS client | `rpc.cancelled`, `rpc.retry-after` | C-6, G-12 |
| Endpoint selection | iOS client / Gateway | `transport=lan\|tailscale` on connection records, race outcome, `lan.listener` | E-3 |

### Exit criteria

"R-1" rows are measured before the release by O-6's multi-session scenario on
a quiet host. "R-4" rows are measured from the evaluation day's real logs with
the triage tool and the Gateway's own records. A task that claims an
improvement reports before and after numbers with the artifact path.

| Area | Target | Checked at |
| --- | --- | --- |
| `session.list` | p99 ≤ 150 ms with 8 running sessions and a 3,000-file catalog | R-1 |
| `session.list` in real use | p99 ≤ 150 ms over the day (from O-3 spans and O-5 records) | R-4 |
| `session.open` | warm p99 ≤ 300 ms; cold p99 ≤ 1.5 s for sessions up to 200 MB | R-1 and R-4 |
| Prompt admission | response p99 ≤ 250 ms | R-1 |
| Event loop | delay p99 ≤ 20 ms and max ≤ 250 ms | R-1 (scenario) and R-4 (O-5 records) |
| Request-path catalog walks | 0 | R-1 and R-4 |
| Snapshots built without an audience | 0 | R-1 and R-4 |
| Gateway CPU | ≤ 1% over a 10-minute idle window with no running sessions; with 8 running sessions and no subscriber, at most 40% of the O-6a baseline | R-1 |
| Memory | heap never above 70% of the configured limit | R-1 and R-4 |
| Memory growth | RSS within ±10% across the day at similar load | R-4 |
| Reconnect | p95 ≤ 5 s after the path returns; a 90 s Tailscale blackhole with the LAN endpoint up causes no visible disconnect | R-1 (O-6b, E-3c) and R-4 |
| Phone state | no "Reconnecting" over a live socket; zero `reconnect.stalled` | R-1 (E2E) and R-4 |
| Reconnect cost | requests and bytes per reconnect at or below G-7's recorded target, each request justified | R-1 and R-4 |
| Restart | with 3 connected clients, all reconnect within 10 s and no request exceeds 1 s (G-13) | R-1 |
| Stability | zero Gateway crashes, OOMs or capacity closes | R-4 (the day) |
| Diagnosability | the triage tool attributes at least 95% of the day's episodes to one cause; the rest are listed with evidence | R-4 |
| Logging | within the volume budget | R-1 (estimate) and R-4 (measured) |

### Commands

```bash
cd packages/gateway && npm run build
cd packages/gateway && npx vitest run src/transport/server-heartbeat.integration.test.ts
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/AppModelReconnectTests
scripts/ios-gateway-e2e-test all
scripts/tron-profile gateway --list
python3 scripts/check-documentation-policy.py
scripts/personal-info-guard.sh
```

Replace the test file or suite with your task's owner. Qualification runs
(`scripts/tron-profile`, `scripts/ios-gateway-e2e-test`) start a private
fixture Gateway and never touch the user's.

### Definitions

- **Disposable read:** a request whose result only projects state and that
  changes nothing durable (for example `session.list`, `session.open` before its
  subscription commits, transcript pages, catalog and settings reads).
- **Request path:** code that runs between receiving a request and sending its
  response.
- **Named constant:** a `const` (TypeScript) or `static let` (Swift) with an
  upper-case or policy name and a one-line reason comment, next to its only
  user.

## Tasks

Rows are grouped by phase. Within a phase, dependencies are authoritative and
rows are in priority order.

### Phase 1 — Build and qualify everything (integration branch, nothing deployed)

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| P-0 | Done | Fold the phone reconnect tuning plan into this plan (D-1) and close it through history; done on `main` at activation | none | |
| O-1 | Done | Correlation key across phone and Gateway on every connection record | none | orchestrator-dispatched worker, 2026-09-28 |
| O-6a | Blocked | Multi-session qualification scenario with a generated catalog; record the `main` baseline | none | orchestrator-dispatched worker, 2026-09-28 (second review response) |
| E-2 | Blocked | Bound the iOS profiler's memory or hand the row to the simulator-lifecycle plan | none | orchestrator-dispatched worker, 2026-09-28 |
| E-2b | Done | Record `time-profiler` with `xctrace record --attach <pid>` if a real traced run proves it samples the simulator app; re-measure export and parser peaks (see E-2 handoff) | E-2 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| E-2c | Ready | Bound the `time-profiler` export under 2 GB for `--scenario all` (see E-2b handoff: simulator-device recording, or a size refusal plus shorter windows) | E-2b | |
| O-2 | Ready | Gateway transport records: upgrade phases, inbound silence with Tailscale peer path | O-1 | |
| O-3 | Done | Request span: one `rpc.completed` per slow RPC with every stage, wait and count | O-1 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| O-4 | Claimed | Phone connection records that survive an export, stall watchdog, exact scene records | O-1 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| O-6b | Claimed | Impairment in the qualification scenario: blackhole, bandwidth cap, Gateway restart | O-6a | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| O-5 | Claimed | Gateway resource sampler and event-loop histogram | O-3 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| O-7 | Ready | Incident triage tool: phone export plus Gateway log in, episodes by cause out | O-1, O-2, O-4 | |
| C-1 | Ready | Projection work never blocks or parks reconnect; parked episodes self-resume | O-4, O-6b | |
| G-1a | Ready | Catalog owner and in-memory index fed by Gateway-owned changes | O-3, O-6a | |
| G-1b | Ready | Filesystem watcher and background reconciliation for external writers | G-1a | |
| G-1c | Ready | Move every catalog reader to the index; delete request-path walks and the full-parse fallback | G-1b | |
| G-1d | Ready | Replace the catalog wording in `connection-resilience.md` with the index contract (D-3) | G-1c | |
| G-3 | Ready | No audience, no projection: build and serialize snapshots only for subscribers | O-5, O-6a | |
| C-2 | Ready | "Connected" follows the transport (D-2); chat restoration shows its own loading state | C-1 | |
| C-5 | Ready | Back off an unreachable non-selected Gateway profile; record pool attempts and episodes | O-4 | |
| G-10 | Ready | Durable-write audit: no process-wide serialization of fsyncs, no fsync on reads | O-5 | |
| C-3 | Ready | Faster retry (D-4): about 5 s transport-open deadline, immediate retry on path change | C-1 | |
| C-4 | Ready | Truer liveness (D-4): any inbound frame proves liveness | O-4 | |
| C-6 | Ready | Cancel frame for disposable reads; a retried `session.open` joins the in-flight one | O-3 | |
| G-12 | Ready | Server-side deadlines, concurrency caps and heap-pressure shedding with typed retry hints | O-3, O-5 | |
| G-2 | Ready | Cold open in bounded time from the index and a single-file fence | G-1c | |
| G-7 | Ready | Reconnect diet: send only what changed | O-1, O-6a | |
| G-11 | Ready | Event-loop budget: find and bound every synchronous task over 50 ms | O-5, O-6a | |
| G-9 | Ready | One background-work scheduler that yields to requests; measure the libuv pool size | O-5, G-1b | |
| G-4 | Ready | Outbound queue coalescing of superseded snapshots and keyed events | G-3 | |
| G-5 | Ready | Byte budget for live runtimes and an explicit heap limit | O-5 | |
| E-3a | Ready | LAN endpoint (D-5), Gateway side: pinned TLS listener bound to the private LAN address | O-1, O-2 | |
| E-3b | Ready | LAN endpoint: advertise endpoints and pin in pairing and hello | E-3a | |
| E-3c | Ready | LAN endpoint, phone side: pin validation, staggered race, seamless fallback | E-3b, C-3 | |
| E-3d | Ready | LAN endpoint on by default in the release once E-3c's E2E cases pass; the setting is the kill switch | E-3c | |
| G-13 | Ready | Restart and reconnect storm: startup budget and a qualification case | G-1c, O-6b | |
| G-8 | Ready | Background work audit: delete or bound each unowned or repeating job | O-5 | |
| E-1 | Ready | Document Tailscale flap diagnosis and user-side checks; the evaluation day confirms | O-2, O-7 | |

### Phase 2 — Release and one evaluation day

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| R-1 | Ready | Release candidate: every synthetic exit criterion passes, merge to `main`, prepare Mac and iOS builds | all Phase 1 | |
| R-2 | Ready | User installs the Mac Release build and the iOS build; agent verifies the deployment | R-1 | |
| R-3 | Ready | User runs Tron normally for at least 24 hours, then exports phone logs | R-2 | |
| R-4 | Ready | Analyse the day with the triage tool; check real-use exit criteria; open Phase 3 rows | R-3 | |

### Phase 3 — Follow-ups from the evaluation day

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| G-6 | Needs scoping | View an idle session without loading a full runtime; scope with R-4's data | R-4 | |
| G-14 | Needs scoping | Host budget for agent child processes (subagents, tools, browsers); user decision with R-4's data | R-4 | |
| V-1 | Needs scoping | Close-out: all exit criteria met (repeat R-3 and R-4 after any runtime-affecting follow-up), protect the gains, close the plan | R-4 and every row R-4 adds | |

R-4 adds a row here for every exit criterion the day missed and every new
cause it finds.

## Task details

Every section uses the same shape: **Goal**, **Owning files**, **Do**,
**Do not**, **Failure modes to write first** (only where an isolated test is
needed), **Checks**, **Docs**, **Done when**, **User action**.

### P-0 — Fold in the phone reconnect tuning plan

- **Goal:** one plan owns phone reconnect behaviour (D-1).
- **Who and where:** the orchestrator, directly on `main`, at activation (plan
  housekeeping, not integration-branch work).
- **Owning files:** the reconnect tuning plan file (in `docs/plans/`, named
  2026-09-24-phone-reconnect-tuning.md), `docs/plans/HISTORY.md`, this file.
- **Do:**
  1. In the reconnect tuning plan, add a handoff entry: its own R-1 is answered
     by this plan's Context (most long episodes are path outages or phone-side
     state, not Gateway stalls; option B alone would not have prevented any
     observed episode); its own R-2 is decided by D-4.
  2. Append its entry to `docs/plans/HISTORY.md` in that file's format.
  3. Delete the reconnect tuning plan file.
  4. In this file, confirm no backticked path still names it.
- **Checks:** `python3 scripts/check-documentation-policy.py`.
- **Done when:** the file is gone, history has the entry, the doc check passes.
- **User action:** none.

### O-1 — Correlation key

- **Goal:** join any phone record to the Gateway's records for the same
  connection attempt without guessing.
- **Owning files:** `packages/ios-app/Sources/Gateway/GatewayClient.swift`
  (`establishConnection` builds hello), `packages/gateway/src/transport/server.ts`
  (`onMessage` handles hello; connection records), the Gateway hello payload
  producer (`GatewayService.info()` in
  `packages/gateway/src/transport/gateway-service.ts`).
- **Do:**
  1. Phone hello adds `diagnostics: { clientId, attemptId, epoch }`: `clientId`
     is the client's stable `diagnosticOwnerID`, `attemptId` the reconnect loop
     ID or `"initial"`, `epoch` the connection epoch number.
  2. Gateway validates each as a bounded token (at most 64 characters of
     `[A-Za-z0-9-]`; drop invalid ones, never reject the hello) and stores them
     on the connection.
  3. Add `peerClientId`, `peerAttemptId`, `peerEpoch` fields to
     `connection.opened`, `connection.closed`, `connection.heartbeat-timeout`,
     `connection.write-error`, `connection.superseded` and
     `connection.outbound-capacity`.
  4. Gateway hello response adds `connectionId`. The phone logs it as
     `gatewayConnectionId` on `reconnect.connected` and on its connection
     records.
- **Do not:** bump the protocol version; change any other hello field.
- **Checks:** the Gateway integration test that exercises hello (find it with
  `grep -rln '"hello"' packages/gateway/src/transport/*.integration.test.ts`),
  extended to assert the fields; `packages/ios-app/Tests/Gateway/GatewayClientTransportTests.swift`
  asserts the hello fields and the logged Gateway ID.
- **Docs:** hello contract in `packages/gateway/README.md`; field notes on the
  affected rows in `packages/gateway/docs/observability.md`.
- **Done when:** both tests pass; a local fixture run shows one phone attempt
  and its Gateway records sharing the three values.
- **User action:** none; ships in the release (R-2).

### O-2 — Gateway transport records

- **Goal:** the Gateway log alone says whether a failed connection reached the
  Mac, how far it got, and whether the Tailscale path to that device was up.
- **Owning files:** `packages/gateway/src/transport/server.ts`
  (`handleUpgrade`, `admit`, heartbeat interval), `packages/gateway/src/admin/diagnose.ts`
  (reuse its Tailscale status reading), `packages/gateway/src/transport/stall-diagnostics.ts`
  if a shared helper belongs there.
- **Do:**
  1. `http.upgrade` record per upgrade with phase durations: `acceptToUpgradeMs`,
     `authMs`, `handshakeMs`, `helloMs`, `phaseReached`, `outcome`
     (`opened`, `abandoned`, `rejected`). Debug when opened within
     `UPGRADE_SLOW_WARNING_MS` (1,000 ms); warning when abandoned, rejected or
     slow.
  2. On each heartbeat tick, a socket with no inbound frame for
     `INBOUND_SILENCE_WARNING_MS` (12,000 ms, above the phone's 10 s ping) gets
     one `connection.inbound-silent` (warning); the next inbound frame logs
     `connection.inbound-resumed` (info) with `silentMs`.
  3. The silent record includes the paired peer's Tailscale path, captured once
     per silence episode: extract from `diagnose.ts` a bounded function that runs
     `tailscale status --json` (existing candidates, 2 s timeout, one in flight
     at a time, result reused for 10 s), finds the peer by the socket's remote
     address and returns `peerPath` (`direct`, `relay`, `offline`, `unknown`)
     and `peerRelay` (region code or empty).
- **Do not:** poll Tailscale on a timer; block the heartbeat on the capture;
  change heartbeat timing.
- **Failure modes to write first:** peer abandons at each phase; Tailscale CLI
  missing, slow or failing; many sockets silent at once (one shared capture);
  silence ends during the capture; remote address not in Tailscale status (LAN
  or loopback).
- **Checks:** `packages/gateway/src/transport/server-heartbeat.integration.test.ts`
  (silence and resume on its fake clock), `packages/gateway/src/transport/server-http-lifecycle.integration.test.ts`
  (abandoned upgrade), a focused test for the Tailscale parser with fixture
  JSON.
- **Docs:** rows in `packages/gateway/docs/observability.md`; interpretation
  lines in `packages/gateway/docs/connection-resilience.md` ("Interpret the
  diagnostics" table).
- **Done when:** the tests pass; in O-6b's blackhole run the Gateway log shows
  silence, resume and duration without the phone's log.
- **User action:** none; ships in the release (R-2).

### O-3 — Request span

- **Goal:** every slow or failed request explains at least 95% of its wall time.
- **Owning files:** `packages/gateway/src/transport/server.ts` (where
  `rpc.completed` is written), `packages/gateway/src/sessions/runtime-registry.ts`
  (`timedStage`, mutexes, catalog calls), `packages/gateway/src/sessions/runtime-slot.ts`
  (snapshot build), new `request-span.ts` in `packages/gateway/src/transport/`.
- **Do:**
  1. Create the span with `AsyncLocalStorage` when a request is admitted in
     `onMessage`. API: `stage(name, fn)`, `wait(name, fn)` for lock and queue
     waits, `count(name, n)`, `bytes(name, n)`.
  2. Route `timedStage` through the span. Wrap: registry mutex, attention lane,
     catalog walk and reconcile (with counts), `SessionManager.open`,
     `RuntimeSlot.create`, snapshot build, frame preparation (bytes), outbound
     enqueue wait.
  3. `rpc.completed` gains `stages` as one compact string, for example
     `catalog.walk=1234ms×2;registry.mutex=5ms;runtime.load=1685ms;snapshot.build=33ms;frame.serialize=12ms/610KB`,
     plus `unaccountedMs`. Keep the existing level rule (debug when fast and
     successful).
  4. Delete the `session.stage` warnings and fold `session.open.prepared` into
     the span; remove their catalog rows.
- **Do not:** add per-stage log records; change request behaviour.
- **Checks:** a focused test that a slow fake stage appears in `stages` and
  `unaccountedMs` is small; `packages/gateway/src/transport/sync-protocol.integration.test.ts`
  still passes.
- **Docs:** `packages/gateway/docs/observability.md` rows changed and removed.
- **Done when:** in O-6a, the slowest `session.open` accounts for at least 95% of
  its time in named stages; volume stays within the logging budget.
- **User action:** none; ships in the release (R-2).

### O-4 — Phone connection records

- **Goal:** a phone export explains every second of every episode, however long
  ago it happened within the log's retention.
- **Owning files:** `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift`,
  `packages/ios-app/Sources/Gateway/GatewayClient.swift`,
  `packages/ios-app/Sources/State/AppModel.swift` (`lifecycleRecordDiagnostic`,
  scene handling), `packages/ios-app/Sources/Support/AppLog.swift`,
  `packages/ios-app/Sources/Support/IOSClientDiagnostics.swift`.
- **Do:**
  1. `gateway.attempt` (AppLog, info) per attempt: `profile` (selected or pool),
     `attemptId`, `retry`, `stageReached`, `reason`, `interfaces`,
     `pathSatisfied`, `delayBeforeMs`, `durationMs`, `foreground`,
     `gatewayConnectionId` when opened.
  2. `connection.episode` (info) when an episode ends: `startedAt`, `endedAt`,
     `attempts`, `causes`, `foregroundMs`, `maxGapBetweenAttemptsMs`,
     `endedBy` (`connected`, `background`, `stopped`).
  3. Watchdog on the lifecycle owner, running only while an episode is open and
     the app is foreground: if no attempt is in flight or scheduled for
     `RECONNECT_STALL_BOUND` (20 s), record `reconnect.stalled` (error) naming
     the guard that is holding (`pathUnsatisfied`, `connectionAdmissionTask`,
     `committedConnectionTask`, `reconnectTaskBusy`, `nonRetryable`, `other`).
     Recording only; C-1 fixes causes.
  4. Main-actor stall detector with the same gating: a background check every
     1 s; if the main actor has not answered for `MAIN_STALL_BOUND` (2 s),
     record `app.main-stall` with its duration when it recovers.
  5. Scene records at the moment they happen: `scene.resign-active`,
     `scene.background`, `scene.foreground`, `scene.active`, each with the
     scene's timestamp. Find out why exports often show `app.backgrounded`
     immediately before `app.foregrounded` at resume (a late write or a second
     notification source) and fix the owner so each transition is recorded
     once, when it happens. Do not delete a record until you know which
     transition it represents.
  6. `operation.*` signposts end with outcome `backgrounded` at background.
  7. `session.open.failure` reports the Gateway's error code (for example
     `conflict`) instead of `transport` when the Gateway answered.
- **Do not:** add per-frame or per-RPC info records; change reconnect behaviour.
- **Failure modes to write first:** watchdog while backgrounded (must not
  run); episode spanning background; two profiles attempting at once; main
  actor blocked while backgrounding.
- **Checks:** `packages/ios-app/Tests/Gateway/AppModelReconnectTests.swift`,
  `packages/ios-app/Tests/Gateway/AppModelLifecycleTests.swift`,
  `packages/ios-app/Tests/Support/GatewayReconnectScheduleTests.swift` extended
  for the new records and the watchdog on a manual clock.
- **Docs:** phone rows in `packages/gateway/docs/observability.md`; expected
  AppLog volume per episode.
- **Done when:** tests pass; an export from O-6b's phone blackhole run (or the
  iOS Gateway E2E harness) shows every attempt and one episode record with
  correct gaps.
- **User action:** none; ships in the release (R-2).

### O-5 — Gateway resource sampler

- **Goal:** one record a minute says what the Gateway is spending memory, CPU
  and I/O on, and warns before trouble.
- **Owning files:** `packages/gateway/src/transport/stall-diagnostics.ts`
  (existing sampler owner), `packages/gateway/src/transport/server.ts`
  (per-topic counters in `broadcastSession` and `broadcast`),
  `packages/gateway/src/sessions/runtime-slot.ts` (snapshot builds with and
  without audience), `packages/gateway/src/sessions/runtime-registry.ts`
  (runtime inventory).
- **Do:**
  1. `gateway.resources` every 60 s at debug, and at info when a value crosses a
     named step: heap used and limit, RSS, event-loop delay p50/p99/max from
     `perf_hooks.monitorEventLoopDelay` (reset each minute), event-loop
     utilization, live runtimes with estimated bytes each (JSONL size until G-5
     measures better), snapshot builds with and without an audience, frames and
     bytes per topic with subscriber counts, catalog walks and their time,
     durable writes and their time, outbound bytes.
  2. Warnings at named thresholds: heap over 70% of the limit
     (`HEAP_WARNING_SHARE`), event-loop p99 over 100 ms in a minute
     (`EVENT_LOOP_P99_WARNING_MS`), any snapshot built without an audience after
     G-3 (`resources.unaudienced-work`).
  3. Agree with the simulator-lifecycle plan's SIM-8 owner that host memory is
     recorded by one of the two, and link the rows.
- **Do not:** add timers faster than 1 s; log per frame.
- **Checks:** a focused test for counter accounting and threshold warnings on a
  fake clock.
- **Docs:** rows in `packages/gateway/docs/observability.md` with expected
  volume (about 1,440 debug records a day, info only on change).
- **Done when:** O-6a's report can be cross-checked against the sampler's
  numbers within 5%.
- **User action:** none; ships in the release (R-2).

### O-6a — Multi-session qualification scenario

- **Goal:** a repeatable scenario that reproduces this incident's load and
  measures every exit criterion.
- **Owning files:** `scripts/tron-profile-gateway`, `scripts/tron-profile-gateway-driver.mjs`,
  `scripts/tron-profile-gateway-extension.ts`, `scripts/tron_profile_report.py`,
  `scripts/test-tron-profile.py`.
- **Do:**
  1. Scenario `multi-session`: a generated catalog in the fixture Gateway's
     private home (default 3,000 JSONL files, 2 GB total, including five files
     of 100–200 MB and subagent-style child files); 8 concurrently running
     faux-model sessions doing tool loops; a helper appending to child JSONL
     files every 500 ms (subagent-like external writers); one mobile client
     mounted on one session; one dashboard client; a reconnect of each client
     every 60 s.
  2. Report: p50/p99/max of `session.list`, warm and cold `session.open`,
     prompt admission, reconnect-to-ready; pong-deadline misses; Gateway CPU
     time and RSS; frames and bytes per topic; request-path catalog walks (from
     O-3 spans once available; from a counter otherwise).
  3. Host guard: refuse to start (exit 73) when memory pressure is not normal or
     swap exceeds 4 GB; take the existing profiler lock; delete the generated
     catalog on every exit path.
  4. Record the `main` baseline in Findings.
- **Do not:** touch the user's `~/.tron`; run longer than 15 minutes by default.
- **Checks:** `python3 scripts/test-tron-profile.py` extended for the new
  scenario's report shape and cleanup.
- **Docs:** the wire-traffic profile section of `packages/gateway/README.md`.
- **Done when:** two consecutive runs on a quiet host agree within the report's
  noise bound; the baseline is in Findings; no files remain after the run.
- **User action:** none.

### O-6b — Impairment and restart cases

- **Goal:** measure recovery, not only throughput.
- **Owning files:** as O-6a, plus `scripts/ios-gateway-fault-proxy.mjs`.
- **Do:** add cases to `multi-session`: a blackhole of `--blackhole-seconds`
  (default 90) between the mobile client and the Gateway; a bandwidth cap
  (default 2 Mbit/s); a fixture Gateway restart with all clients connected.
  Report time from path return to ready, attempts during the outage, requests
  over 1 s during the restart storm.
- **Checks:** as O-6a.
- **Done when:** each case runs and reports; the baseline for each is in
  Findings.
- **User action:** none.

### O-7 — Incident triage tool

- **Goal:** one command turns an incident's logs into episodes by cause,
  replacing the manual correlation done for this plan.
- **Owning files:** new `tron-triage` in `scripts/`, new `tron_triage.py` in
  `scripts/`, new `test-tron-triage.py` in `scripts/`.
- **Do:**
  1. Inputs: one or more phone exports, the Gateway log and its rotations
     (default `~/.tron/logs`), optional `--tailscale-window` to capture the
     Tailscale extension log with `log show` for the export's time range.
  2. Join records by the O-1 key, falling back to time windows for older logs.
  3. Classify each episode by rules, in order: `path` (inbound silence with
     `peerPath` relay or offline, or transport-open timeouts with no Gateway
     upgrade), `phone-background`, `phone-stall` (`reconnect.stalled`,
     `app.main-stall`, label over a live socket), `gateway-stall` (event-loop
     delay or slow spans), `gateway-capacity`, `unknown`.
  4. Output a text table and JSON: start, end, duration, cause, evidence lines.
- **Do not:** send data anywhere; modify inputs.
- **Checks:** `python3 scripts/test-tron-triage.py` with small sanitized
  fixtures reproducing each cause from this plan's Context.
- **Docs:** "Collect evidence before recovery" in
  `packages/gateway/docs/connection-resilience.md` names the command first.
- **Done when:** run on this incident's exports and Gateway log, it reproduces
  the causes in Context.
- **User action:** none.

### C-1 — Silent recovery gaps

- **Goal:** while foreground and not connected, an attempt is always in flight
  or scheduled; slow projection work never delays reconnection.
- **Owning files:** `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift`,
  `packages/ios-app/Sources/State/AppModel.swift`
  (`lifecycleRestoreMountedPresentation`, `lifecycleRefreshAll`).
- **Do:**
  1. Cover all three explanations before the release, because the deciding
     real-device evidence only arrives on the evaluation day: a parked loop is
     fixed by steps 2–4; a blocked main actor is recorded by O-4's
     `app.main-stall`; suspension is made visible by O-4's exact scene records.
     If the E2E harness reproduces a main-actor block, add a Phase 1 row with
     the evidence and coordinate with the energy-efficiency plan's R-FOLLOW.
     R-4 decides which explanation held on the real day.
  2. Make restoration run beneath a connected socket: the reconnect task ends at
     handshake plus event activation; mounted-chat restoration and refresh run
     as separate tasks owned by their presentation, cancelled when the socket
     drops, and never awaited by the reconnect task.
  3. A parked episode resumes on the next path callback, on foreground, or after
     `PARKED_RETRY_BOUND` (30 s) even without a callback.
  4. Every early `return` in `requestReconnect` and `scheduleReconnect` either
     is provably covered by another owner or records its reason at debug.
- **Do not:** change the backoff policy (C-3 does); change the label (C-2 does).
- **Failure modes to write first:** socket drops during mounted restoration;
  path unsatisfied then satisfied without a second callback; the Gateway
  accepts then stalls `session.open`; background during an attempt; two
  profiles.
- **Checks:** `packages/ios-app/Tests/Gateway/AppModelReconnectTests.swift`,
  `packages/ios-app/Tests/Gateway/SessionPresentationStoreTests.swift`;
  `scripts/ios-gateway-e2e-test all` with a 90 s blackhole case added.
- **Docs:** `packages/ios-app/docs/architecture.md` reconnect section.
- **Done when:** the E2E case shows attempts at the scheduled cadence for the
  whole outage, reconnect within one attempt of the path returning, and zero
  `reconnect.stalled`.
- **User action:** none; ships in the release (R-2).

### C-2 — "Connected" follows the transport

- **Goal:** the dashboard and header never say "Reconnecting" over a live
  socket (D-2).
- **Owning files:** `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift`,
  `packages/ios-app/Sources/State/SessionPresentationStore.swift` (mounted
  restoration state), the chat view that shows catch-up state (find it from
  `SessionPresentationStore` observers).
- **Do:**
  1. `.connected` from event activation until the socket is lost; only transport
     loss sets `.reconnecting`. In the reconnect loop, remove every
     `.reconnecting` assignment made after a successful handshake while
     restoration or refresh runs (search `self.connectionState = .reconnecting`
     after `reconnect.connected` is recorded); keep the ones made on transport
     failure.
  2. Mounted restoration exposes its own state; the chat shows its existing
     catch-up treatment (or a "Loading conversation" state if none exists).
  3. Send, route activation and mutation fences stay unchanged.
- **Failure modes to write first:** socket dies during restoration (state goes
  to `.reconnecting` at once); restoration fails while the socket lives
  (connected, chat retry surface shown); profile switch during restoration;
  background during restoration.
- **Checks:** `packages/ios-app/Tests/Gateway/AppModelReconnectTests.swift`;
  a hosted UI test that the label never reads "Reconnecting" while the socket
  is live and the Gateway answers `session.open` slowly.
- **Docs:** `packages/ios-app/docs/architecture.md`.
- **Done when:** tests pass; O-6b's slow-open case shows "Connected" throughout.
- **User action:** none; ships in the release (R-2).

### C-5 — Secondary-profile backoff

- **Goal:** an unreachable non-selected profile costs almost nothing.
- **Owning files:** `packages/ios-app/Sources/State/DashboardGatewayConnectionPool.swift`.
- **Do:** after `POOL_UNREACHABLE_AFTER` (3) consecutive transport-open
  failures, back off exponentially to `POOL_MAX_RETRY` (5 minutes); retry at
  once on foreground and path change; show the profile as unreachable. The
  selected profile's policy is unchanged.
  Also record the pool's attempts and episodes with O-4's recorder
  (`gateway.attempt` with `profile=pool`, one `connection.episode` per pool
  profile), as the O-4 handoff describes; O-4 wired only the selected profile.
- **Checks:** `packages/ios-app/Tests/UI/DashboardStateOwnerTests.swift` or the
  pool's existing test owner, on a manual clock.
- **Done when:** a pool profile pointing at a closed port makes at most one
  attempt per 5 minutes after backing off.
- **User action:** none; ships in the release (R-2).

### C-3 — Faster retry

- **Goal:** recover within one attempt of the path returning (D-4).
- **Owning files:** `packages/ios-app/Core/Gateway/GatewayConnectionPolicy.swift`,
  `packages/ios-app/Sources/Gateway/GatewayClient.swift` (handshake deadline),
  `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift`,
  `packages/protocol-fixtures/gateway-connection-contract.json`.
- **Do:**
  1. Split the deadline: `transportOpenDeadline` (5 s) until the socket opens,
     then the existing 15 s for hello. Add the value and reason to the contract
     fixture.
  2. A path change cancels the backoff wait, resets the schedule and starts an
     attempt at once.
  3. Keep cap and jitter for repeated failures on an unchanged path.
  4. Confirm with the iOS Gateway E2E harness and O-6b that a working path
     opens well under 5 s. Real transport-open times arrive with the
     evaluation day: R-4 checks that successful opens stay under 3 s p99 and
     opens a follow-up if not.
- **Failure modes to write first:** slow working path opening in 4–6 s; path
  flapping every second; attempt in flight when the path changes.
- **Checks:** `packages/ios-app/Tests/Support/GatewayReconnectScheduleTests.swift`,
  `packages/ios-app/Tests/Gateway/SharedProtocolFixtureTests.swift`,
  `packages/ios-app/Tests/Gateway/GatewayClientTransportTests.swift`.
- **Docs:** "Mobile recovery" in `packages/gateway/docs/connection-resilience.md`.
- **Done when:** O-6b's blackhole case reconnects with p95 ≤ 5 s after the path
  returns.
- **User action:** none; ships in the release (R-2).

### C-4 — Truer liveness

- **Goal:** a busy link is never torn down for a queued pong (D-4).
- **Owning files:** `packages/ios-app/Sources/Gateway/GatewayClient.swift`
  (`startLivenessWait`), `packages/ios-app/Core/Gateway/GatewayConnectionPolicy.swift`,
  `packages/protocol-fixtures/gateway-connection-contract.json`,
  `packages/gateway/src/transport/connection-policy.ts` (parity only).
- **Do:**
  1. Track the last inbound frame time (messages, pongs, any data).
  2. On each ping tick, send a ping only if nothing arrived for the ping
     interval; declare the link dead only when that ping's pong misses its
     deadline.
  3. Dead-link detection stays within 18 s of the last inbound frame.
- **Failure modes to write first:** large frame in flight when a ping is due;
  data then total silence; pongs but no data; clock suspension across
  background.
- **Checks:** `packages/ios-app/Tests/Gateway/GatewayClientTransportTests.swift`
  on a manual clock; `packages/gateway/src/transport/connection-policy.test.ts`
  for fixture parity; `packages/gateway/src/transport/server-heartbeat.integration.test.ts`.
- **Docs:** "Heartbeat" in `packages/gateway/docs/connection-resilience.md`.
- **Done when:** tests pass; O-6b's bandwidth-cap case shows zero pong-deadline
  misses while data flows.
- **User action:** none; ships in the release (R-2).

### C-6 — Cancellation and joining

- **Goal:** nobody computes an answer nobody waits for; a retry never fails as a
  duplicate.
- **Owning files:** `packages/gateway/src/transport/server.ts` (`onMessage`,
  `requestControllers`, `pendingSessionOpens`),
  `packages/gateway/src/transport/gateway-service.ts` (read handlers),
  `packages/ios-app/Sources/Gateway/GatewayClient.swift` (`expire`,
  `cancelRequest`).
- **Do:**
  1. Protocol: frame `{ type: "cancel", id }`. The phone sends it when a
     disposable read times out or is cancelled locally.
  2. Gateway aborts that request's controller; disposable reads check the
     signal between stages; shared work (one catalog materialization) continues
     while any waiter remains.
  3. A second `session.open` for the same connection and session joins the
     in-flight one and receives its result instead of `conflict`.
  4. Record `rpc.cancelled` (debug; warning when cancelled after more than
     `SLOW_RPC_WARNING_MS`) with the stage the request was in.
- **Do not:** cancel mutations or prompts.
- **Failure modes to write first:** cancel after the response was sent; cancel
  of an unknown ID; join while the first open is committing its subscription;
  connection closes with joined waiters.
- **Checks:** `packages/gateway/src/transport/sync-protocol.integration.test.ts`
  extended; `packages/ios-app/Tests/Gateway/GatewayClientTransportTests.swift`.
- **Docs:** protocol section of `packages/gateway/README.md`.
- **Done when:** O-6a's slow-open case shows no duplicate-open failures and no
  server work after the last waiter cancels.
- **User action:** none; ships in the release (R-2).

### G-1a — Catalog owner and index

- **Goal:** one owner holds an in-memory index of every canonical session,
  updated by the Gateway's own changes.
- **Owning files:** new `session-catalog.ts` in `packages/gateway/src/sessions/`,
  `packages/gateway/src/sessions/runtime-registry.ts` (hooks: create, persist,
  summary changes, rename, rekey, delete, archive),
  `packages/gateway/src/sessions/catalog-metadata-index.ts` (durable form).
- **Do:**
  1. Index row: id, canonical path, cwd, parent path, name, first message,
     message count, created and updated times, file identity (`dev:ino`), size,
     end offset, delegated flag.
  2. Startup: load the durable index, then reconcile in the background (G-1b
     adds the watcher; until then, reconcile once at startup).
  3. Apply every Gateway-owned change to the index at its commit point (the same
     hooks that today call `invalidateCatalogAcquisition`).
  4. Persist the durable index debounced (`CATALOG_PERSIST_DEBOUNCE_MS`, 5 s)
     and on shutdown, never per read.
  5. Readers are not switched yet (G-1c does that).
- **Failure modes to write first:** crash between a file write and the index
  update (startup reconciliation repairs it); duplicate session ID; rekey while a
  reader holds a page source; durable index corrupt or from another root.
- **Checks:** new `session-catalog.test.ts` in `packages/gateway/src/sessions/`
  for the failure modes; `packages/gateway/src/sessions/runtime-registry.integration.test.ts`.
- **Done when:** after a create, rename, fork and delete in the integration test,
  the index matches a full scan exactly.
- **User action:** none; ships in the release (R-2).

### G-1b — Watcher and reconciliation

- **Goal:** external writers (subagent children, copied files) reach the index
  without request-path scans.
- **Owning files:** the catalog owner G-1a creates (`session-catalog.ts` in
  `packages/gateway/src/sessions/`), `packages/gateway/src/sessions/catalog-discovery.ts`
  (reuse its header and path rules).
- **Do:**
  1. Recursive `fs.watch` on the sessions root (FSEvents on macOS), ignoring the
     same directories as today's discovery.
  2. Each event is a hint: debounce per path (`CATALOG_EVENT_DEBOUNCE_MS`,
     250 ms), then re-read that file's identity and tail (the tail-append logic
     of `CatalogMetadataIndex.append`) and update one row.
  3. Watcher error or overflow: record `catalog.watcher-reset`, restart the
     watcher, run a full reconciliation. Reads continue from the last good index.
  4. Full reconciliation also runs every `CATALOG_RECONCILE_INTERVAL_MS`
     (30 minutes), in batches of at most 50 files, yielding between batches
     (G-9 later moves it into the scheduler). Record `catalog.reconciled` with
     files, changes and duration.
- **Failure modes to write first:** events dropped (periodic reconciliation
  repairs within one interval); file replaced with a new inode; child file
  before its parent; root moved or unavailable; burst of 1,000 events.
- **Checks:** G-1a's `session-catalog.test.ts` (in
  `packages/gateway/src/sessions/`), extended with a temporary directory.
- **Done when:** in O-6a, child-file appends reach the index within 1 s without
  any request-path walk.
- **User action:** none; ships in the release (R-2).

### G-1c — Readers use the index; delete the walks

- **Goal:** the request path never walks the session folder.
- **Owning files:** `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/gateway/src/sessions/catalog-discovery.ts`,
  `packages/gateway/src/transport/session-list-pagination.ts`.
- **Do:**
  1. Switch `list`, `pageSource`, `catalogAcquisition`, attention resolution,
     automation targets, `workspaceForSession` and storage maintenance to the
     index.
  2. Membership fences check only the target file (stat and header) at commit.
  3. Delete: per-request structure evidence walks
     (`validatedStructuralIndex` refresh, `sharedCatalogStructureEvidence` on
     read paths), `fallbackCatalogAcquisition`, whole-tree
     `attentionEntryStillAdmitted` and `attentionLiveOnlyStillAdmitted`, the
     cold-open final validation walk, and discovery budgets that exist only for
     those walks, with their tests.
- **Failure modes to write first:** reader races a rekey; target file replaced
  between index read and commit; index still reconciling at startup (reads
  served from the loaded durable index, marked stale in the span).
- **Checks:** `packages/gateway/src/sessions/runtime-registry.integration.test.ts`,
  `packages/gateway/src/sessions/catalog-discovery.test.ts` (pruned),
  `packages/gateway/src/transport/session-archive.integration.test.ts`.
- **Done when:** O-6a shows request-path walks = 0 and `session.list` p99 ≤
  150 ms.
- **User action:** none; ships in the release (R-2).

### G-1d — Catalog contract in the docs

- **Goal:** the docs describe the catalog that exists (D-3).
- **Owning files:** `packages/gateway/docs/connection-resilience.md`,
  `packages/gateway/README.md` (session invariants, catalog paragraphs).
- **Do:** replace "Do not introduce transcript mirrors, workers, speculative
  caches, or higher queue limits to conceal them" with: the catalog index
  contract (owner, feeds, reconciliation, JSONL authority, rebuild on loss), and
  keep "no transcript mirrors" and "no higher queue limits". Update the catalog
  acquisition paragraph in the README.
- **Done when:** no doc describes a request-path walk.
- **User action:** none; ships in the release (R-2).

### G-3 — No audience, no projection

- **Goal:** zero snapshots built or serialized for nobody.
- **Owning files:** `packages/gateway/src/sessions/runtime-slot.ts`
  (`publishSnapshot`, `scheduleSnapshot`), `packages/gateway/src/transport/server.ts`
  (`broadcastSession`), `packages/gateway/src/sessions/runtime-registry.ts`
  (subscriber sets).
- **Do:**
  1. Verify first which clients consume `session.snapshot` for sessions they
     are not subscribed to (expected: none; the dashboard reads summaries).
     Record the finding.
  2. `publishSnapshot` builds a snapshot only if the slot has a subscriber or a
     pending synchronization barrier; otherwise it publishes only the summary.
  3. `broadcastSession` checks for recipients before preparing a frame.
  4. When a client subscribes, it receives a fresh snapshot through the existing
     open and sync path (unchanged).
- **Failure modes to write first:** subscriber arrives between a skipped build
  and the next change; barrier pending with no subscribers; summary fields that
  today come only from a snapshot.
- **Checks:** `packages/gateway/src/transport/sync-protocol.integration.test.ts`,
  `packages/gateway/src/transport/server-capacity.integration.test.ts`.
- **Done when:** O-6a shows zero unaudienced builds and a CPU drop against the
  baseline; subscribed clients receive identical frames.
- **User action:** none; ships in the release (R-2).

### G-10 — Durable-write audit

- **Goal:** durable writes never serialize unrelated work or sit on read paths.
- **Owning files:** `packages/gateway/src/transport/command-receipts.ts`, and
  each store O-5's counters show writing on interactive paths (expected:
  `packages/gateway/src/notifications/notification-service.ts`, attention,
  run markers, the catalog index).
- **Do:**
  1. From O-5, list every fsync on an interactive path with rate and latency.
  2. Receipts: the process-wide `inventoryMutex` covers accounting only; the
     fsync of one receipt does not hold it.
  3. Reads never fsync. Non-critical persistence is debounced.
- **Do not:** weaken "acknowledged mutation is durable before its response".
- **Checks:** `packages/gateway/src/transport/command-receipts.test.ts` for
  concurrent receipts; crash-safety tests stay green.
- **Done when:** under O-6a, two concurrent mutations' receipt writes overlap;
  no read path appears in the fsync list.
- **User action:** none; ships in the release (R-2).

### G-12 — Deadlines, caps and load shedding

- **Goal:** overload is predictable: typed `busy` with a retry hint, never a
  one-minute wait.
- **Owning files:** `packages/gateway/src/transport/server.ts`,
  `packages/gateway/src/transport/gateway-service.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/ios-app/Sources/Gateway/GatewayClient.swift` (honour the hint).
- **Do:**
  1. Server-side deadline per disposable read method, in one table of named
     constants (initial: `session.list` 5 s, `session.open` before commit 10 s,
     transcript pages 5 s). On expiry: abort the request and answer `busy` with
     `retryAfterMs`.
  2. Concurrency caps with queueing: cold runtime loads (2), session exports
     (1), workspace inspection (2).
  3. Heap pressure: above 70% of the limit, evict idle runtimes largest first;
     above 85%, refuse new cold loads with `busy` and `retryAfterMs`. Record
     `gateway.shed` with reason and counts.
  4. The phone waits `retryAfterMs` (bounded to 10 s) before retrying a `busy`
     disposable read and records `rpc.retry-after`.
- **Do not:** shed admitted mutations or prompts.
- **Failure modes to write first:** deadline fires during subscription commit;
  queued cold load whose client disconnects; heap pressure with all runtimes
  protected.
- **Checks:** `packages/gateway/src/transport/server-capacity.integration.test.ts`,
  `packages/gateway/src/sessions/runtime-registry.integration.test.ts`.
- **Docs:** limits table in `packages/gateway/docs/connection-resilience.md`.
- **Done when:** in O-6a with the heap limit lowered for the test, the Gateway
  sheds instead of exceeding it and no request exceeds its deadline.
- **User action:** none; ships in the release (R-2).

### G-2 — Cold open

- **Goal:** cold `session.open` p99 ≤ 1.5 s for sessions up to 200 MB.
- **Owning files:** `packages/gateway/src/sessions/runtime-registry.ts`
  (`acquire`, `acquireMissing`, `startAcquiredSlot`, `resolveForkBoundary`).
- **Do:** use O-3 spans from O-6a to find what fills the rest of a slow open
  (candidates: registry mutex, idle eviction, fork-boundary parent reads) and
  remove it at its owner. Report the parse share of the time separately.
- **Done when:** the target holds in O-6a.
- **User action:** none; ships in the release (R-2).

### G-7 — Reconnect diet

- **Goal:** a reconnect sends only what changed.
- **Owning files:** `packages/ios-app/Sources/State/AppModel.swift` (connect-time
  loads), the push registration owner on the phone,
  `packages/gateway/src/transport/gateway-service.ts`
  (`push.registration.upsert`, `session.list`),
  `packages/gateway/src/notifications/notification-service.ts`.
- **Do:**
  1. Record every request on connect, foreground and chat open with its trigger,
     from the O-6a mobile client and a code audit of the phone's connect-time
     owners. The 2026-09-27 phone export already lists one real reconnect's
     requests (debug `rpc.completed` records around 22:16:43 UTC in
     `tron-diagnostics.jsonl`; ask the user for the file if it is not in the
     repository). Set the target list in the handoff; R-4 compares it with a
     real reconnect from the evaluation day.
  2. Push registration: the phone sends it only when the registration changed
     since the last acknowledged one for this Gateway; the Gateway answers an
     identical registration with no receipt write and no store write.
  3. One owner each for `model.list` and `provider.list` per connection.
  4. Conditional `session.list`: the phone sends its last `listRevision`; the
     Gateway answers `notModified` without rows when unchanged.
- **Checks:** `packages/ios-app/Tests/Gateway/AppModelReconnectTests.swift`,
  `packages/gateway/src/transport/session-archive.integration.test.ts` for list
  behaviour.
- **Done when:** requests and bytes per reconnect meet the recorded target.
- **User action:** none; ships in the release (R-2).

### G-11 — Event-loop budget

- **Goal:** no synchronous task over 50 ms on the Gateway loop in O-6a.
- **Owning files:** decided by the findings (expected:
  `packages/gateway/src/sessions/runtime-slot.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`).
- **Do:**
  1. From O-5 and O-3, list operations with synchronous stretches over 50 ms
     (expected: large JSONL parse at cold load, snapshot build, serialization of
     large frames).
  2. Fix each at its owner by chunking with yields or bounded concurrency.
  3. If a stretch cannot be bounded without a worker thread, stop and ask the
     user (`connection-resilience.md` forbids workers today).
- **Done when:** O-6a event-loop max ≤ 250 ms and p99 ≤ 20 ms.
- **User action:** none; ships in the release (R-2).

### G-9 — Background-work scheduler

- **Goal:** background work never starves requests.
- **Owning files:** new `background-work.ts` in `packages/gateway/src/`,
  `packages/gateway/src/gateway-main.ts` (registration), each background owner
  found by G-8 and G-1b.
- **Do:**
  1. One scheduler runs registered jobs one slice at a time, yielding with
     `setImmediate` between slices, pausing while requests are in flight or
     event-loop p99 exceeds `BACKGROUND_PAUSE_P99_MS` (50 ms).
  2. Move catalog reconciliation, receipt pruning, blob and upload maintenance
     and session-search indexing into it. Record `background.slice` (debug) and
     `background.backlog` (warning past a named age).
  3. Measure `UV_THREADPOOL_SIZE` 4, 8 and 16 under O-6a; if a larger pool
     improves p99 latency, set it in `packages/mac-app/scripts/tron-gateway-launcher.c`
     with the measurement in the comment.
- **Checks:** a focused scheduler test for yielding and pausing.
- **Done when:** O-6a latency targets hold while reconciliation runs.
- **User action:** none; ships in the release (R-2).

### G-4 — Outbound queue coalescing

- **Goal:** a slow link never fills the queue with superseded state.
- **Owning files:** `packages/gateway/src/transport/server.ts`
  (`OrderedOutboundQueue`, send paths).
- **Do:** per connection, a newer `session.snapshot` for a session replaces an
  unsent older one; keyed events (summaries per session, process activity per
  process) replace unsent predecessors with the same key. Order relative to
  other events and synchronization barriers is preserved. The 8 MiB cap stays
  as the backstop; `connection.outbound-capacity` names the topics of the
  oldest and next frames.
- **Failure modes to write first:** snapshot superseded while its sequence is
  pending in a barrier; replacement larger than the cap; coalescing a frame
  already being written; interleaved progress and snapshot frames.
- **Checks:** `packages/gateway/src/transport/server-capacity.integration.test.ts`,
  `packages/gateway/src/transport/sync-protocol.integration.test.ts`.
- **Done when:** O-6b's bandwidth-cap case never closes a socket for capacity.
- **User action:** none; ships in the release (R-2).

### G-5 — Memory budget

- **Goal:** the Gateway never approaches its heap limit because of loaded
  sessions.
- **Owning files:** `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/mac-app/scripts/tron-gateway-launcher.c` (heap flag).
- **Do:**
  1. Measure heap per runtime against JSONL size in O-6a; set the estimate
     factor from the data.
  2. Byte budget `LIVE_RUNTIME_BYTE_BUDGET` (initial 1.5 GB) for admission and
     pressure eviction, largest idle runtime first; protected runtimes stay
     protected. Record `runtime.loaded` and `runtime.evicted` with bytes.
  3. Set `--max-old-space-size` explicitly (initial 4,096 MB) with the budget
     below it.
- **Checks:** `packages/gateway/src/sessions/runtime-registry.integration.test.ts`.
- **Done when:** opening a sequence of large idle sessions in O-6a never exceeds
  the budget.
- **User action:** none; ships in the release (R-2).

### E-3a — LAN listener (Gateway)

- **Goal:** a second, TLS-only listener on the Mac's private LAN address,
  behind a setting whose default E-3d decides (D-5).
- **Owning files:** `packages/gateway/src/config.ts` (address resolution beside
  the `tailscale` host), `packages/gateway/src/transport/server.ts` (second
  listener sharing admission, capacity, heartbeat and revocation), new
  `lan-endpoint.ts` in `packages/gateway/src/transport/`.
- **Do:**
  1. Generate and keep a TLS key and self-signed certificate in the Gateway's
     private state directory (0600), created once, rotated only by an explicit
     command.
  2. Bind only to private addresses (RFC 1918 and IPv6 ULA) on the interface
     that has them; never a wildcard. Rebind when the address changes; disable
     when none exists. Record `lan.listener` (bound, rebound, disabled) with
     address family, not address.
  3. Serve the WebSocket route and authenticated HTTP routes only; no
     `POST /v1/pair`, no other unauthenticated route except a minimal health
     check.
  4. A Gateway setting `lanEndpoint.enabled` (default false until E-3d).
- **Do not:** weaken any admission or revocation rule; expose pairing.
- **Failure modes to write first:** no private address; address changes while
  sockets are open; two private interfaces; certificate file missing or
  unreadable; setting toggled off with sockets open.
- **Checks:** a focused integration test with a loopback-bound fixture
  pretending to be the LAN address.
- **Docs:** `packages/gateway/README.md` transport section; `AGENTS.md`
  exposure invariant names both listeners.
- **Done when:** the fixture test passes all failure modes.
- **User action:** none; ships in the release (R-2).

### E-3b — Advertise endpoints and pin

- **Goal:** the phone learns LAN endpoints and the pin only over an already
  authenticated channel.
- **Owning files:** `packages/gateway/src/transport/server.ts` (pairing and
  hello), `packages/ios-app/Sources/Gateway/GatewayProfile.swift`,
  `packages/ios-app/Sources/Gateway/GatewayProfileStore.swift`.
- **Do:** pairing response and hello include `lanEndpoints: [{ host, port }]`
  and `lanPin` (SHA-256 of the certificate's public key). The phone stores them
  with the profile and replaces them on every hello.
- **Checks:** `packages/ios-app/Tests/Gateway/GatewayClientTransportTests.swift`;
  the Gateway pairing test.
- **Done when:** a paired fixture phone holds the current endpoints and pin.
- **User action:** none; ships in the release (R-2).

### E-3c — Pinned race and fallback (phone)

- **Goal:** at home the phone connects over LAN; any leg's loss costs at most
  one liveness interval.
- **Owning files:** `packages/ios-app/Sources/Gateway/GatewayClient.swift`,
  `packages/ios-app/Sources/Gateway/GatewaySocketTransport.swift` (pin check in
  the URLSession delegate), `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift`,
  `packages/ios-app/Sources/Info.plist` (`NSLocalNetworkUsageDescription`).
- **Do:**
  1. TLS trust evaluation accepts only the pinned key; no credential is sent
     before the pin matches.
  2. When the path includes Wi-Fi and the profile has LAN endpoints, start the
     LAN leg first and the Tailscale leg after `LAN_RACE_STAGGER` (250 ms)
     unless the LAN leg has opened; the first completed hello wins; cancel the
     loser before hello. Remember the winning leg for the current network and
     skip the stagger when it is known to work.
  3. HTTP routes use the winning endpoint for that epoch.
  4. On liveness loss, the next attempt races both legs immediately.
  5. If Local Network permission is denied, record it and stay on Tailscale for
     that install.
- **Failure modes to write first:** pin mismatch (no credential sent); guest
  network with client isolation; Mac's LAN address changed while on Tailscale;
  both legs complete together; permission denied; LAN listener disabled
  mid-connection; phone leaves Wi-Fi mid-epoch.
- **Checks:** `scripts/ios-gateway-e2e-test all` with two proxy legs;
  `packages/ios-app/Tests/Gateway/GatewayClientTransportTests.swift`.
- **Done when:** with the Tailscale leg blackholed 90 s there is no visible
  disconnect; with the LAN leg blocked, Tailscale wins within the stagger plus
  one handshake; a pin mismatch sends no credential.
- **User action:** none; ships in the release (R-2).

### E-3d — Enable by default

- **Goal:** the release and the evaluation day use the LAN endpoint, because
  it is the main fix for the Tailscale flaps that caused most disconnects.
- **Do:** after every E-3c E2E case passes (no visible disconnect with the
  Tailscale leg blackholed; Tailscale wins within the stagger plus one
  handshake with the LAN leg blocked; no credential sent on pin mismatch), set
  `lanEndpoint.enabled` to default true. If any case fails, leave the default
  false, mark E-3c Blocked with the evidence, and the release ships without the
  LAN endpoint. The setting stays the kill switch during the evaluation day;
  R-4 reviews LAN use and every fallback.
- **Done when:** the default is set according to the E2E results and the
  decision is recorded in a handoff entry.
- **User action:** none; ships in the release (R-2).

### G-13 — Restart and reconnect storm

- **Goal:** a Gateway restart with connected clients is quick and calm.
- **Owning files:** `packages/gateway/src/gateway-main.ts` (startup steps),
  O-6b's restart case.
- **Do:** set startup budgets from the existing `gateway.startup-step` records
  (listening within 5 s on the qualification catalog, index served from the
  durable file while reconciliation runs in the background); make O-6b's
  restart case meet the exit criterion.
- **Done when:** all clients reconnect within 10 s and no request exceeds 1 s
  during the storm.
- **User action:** none; ships in the release (R-2).

### G-8 — Background work audit

- **Goal:** every recurring job has an owner, a reason and a bound.
- **Do:** using the code, O-6a runs and the live Gateway's existing log
  (`~/.tron/logs/gateway.jsonl`, read only), find the cause of each, then delete
  or bound it: the repeating `extension.artifact-rejected` (why five owners
  retry replacement), the Tailscale CLI caller every ~37 s (see Context
  candidates), session-search and knowledge background work, Mac app local
  probe connections. Each non-trivial finding becomes its own Phase 1 row.
- **Done when:** each item has a cause and a change or a new row; R-4 confirms
  with the day's O-5 records that none still recurs.
- **User action:** none; ships in the release (R-2).

### E-1 — Tailscale flaps

- **Goal:** anyone can recognize a Tailscale flap from the logs and knows what
  to check; E-3 removes the effect at home.
- **Do:** document in `packages/gateway/docs/connection-resilience.md` how a
  flap appears in O-2's records and in the triage tool's output (use this
  plan's Context as the worked example), and the user-side checks (iPhone
  Tailscale app version and settings, Wi-Fi private address, router client
  steering). R-4 counts the evaluation day's flaps.
- **Done when:** the doc names the records, the triage output and the checks.
- **User action:** none; ships in the release (R-2).

### E-2 — Profiler memory

- **Goal:** the iOS profiler cannot take 10 GB of the Mac's memory.
- **Owning files:** `scripts/tron-profile-ios` (or hand the row to the
  simulator-lifecycle plan and record that).
- **Done when:** a trace export is streamed or bounded and the profiler's peak
  RSS is recorded under 2 GB for the default scenarios.
- **User action:** none.

### R-1 — Release candidate

- **Goal:** the integration branch is proven on every exit criterion that a
  synthetic run can measure, then becomes `main`.
- **Owner:** the orchestrator (not a worker).
- **Do:**
  1. Confirm every Phase 1 row is Done and merged into `hardening/integration`.
  2. Merge `main` into `hardening/integration` one last time; resolve conflicts.
  3. On the integration worktree: `cd packages/gateway && npm run build`, the
     focused Gateway tests of every conflict zone, `scripts/tron-ios-test run`
     for the phone suites named in Phase 1 tasks, `scripts/ios-gateway-e2e-test all`,
     and `scripts/tron-profile gateway --scenario multi-session` with the O-6b
     cases. Only on a quiet host (O-6a's guard).
  4. Fill the "Release candidate" column in Findings. Every exit criterion
     marked "R-1" must pass. If one does not, open a Phase 1 row for it and stop;
     do not release with a known miss unless the user accepts it in writing in
     a handoff entry.
  5. Estimate log volume from the synthetic run against the logging budget.
  6. Record the identities of the builds currently installed (Mac app version
     and Gateway payload version from `~/.tron/logs/deploy.jsonl`, iOS build
     number) for rollback.
  7. Merge `hardening/integration` into `main` (the plan's copy on `main`
     becomes authoritative again), then prepare the Mac app Release build and
     the iOS build with the repository helpers and write their exact paths into
     a handoff entry.
- **Done when:** Findings has the release-candidate numbers, all R-1 criteria
  pass, `main` contains Phase 1, and both builds are ready with paths.

### R-2 — Deploy

- **Goal:** the user runs the release; the agent proves it is the release.
- **User action:** install the Mac app Release build by following
  `packages/mac-app/docs/development.md`, "Reinstall a local Release build",
  then install the iOS build on the phone. Allow the iOS Local Network prompt
  when it appears.
- **Agent, after the user confirms:**
  1. Run `scripts/tron mac verify` (it must pass).
  2. Check `~/.tron/logs/gateway.jsonl` for the release's source revision on
     `gateway.started`, protocol 6 in the phone's hello, and at least one each
     of: `connection.opened` with `peerClientId`, `http.upgrade`,
     `gateway.resources`, `rpc.completed` with `stages` (from any slow
     request), `lan.listener` bound, and `connection.opened` with
     `transport=lan` when the phone is at home.
  3. Record the check results in a handoff entry.
- **Done when:** every check passes; otherwise the user rolls back (see "The
  release") and R-1 reopens with the finding.

### R-3 — Evaluation day

- **Goal:** one ordinary day of real use with everything in place.
- **User action:** use Tron normally for at least 24 hours: several sessions
  running at once, the phone at home and away if that is typical, background
  and foreground as usual. Do not force-quit to recover; if the app gets stuck,
  note the time and then recover however you need to. At the end, export iOS
  logs from the app (Settings → Gateway Logs → Export) and say when the day
  started and ended.
- **Agent during the day:** nothing, unless the user reports a problem. Then
  collect evidence only (O-7 on the logs so far); do not deploy fixes during
  the day.
- **Done when:** the user reports the day finished and the export exists.

### R-4 — Evaluation analysis

- **Goal:** turn the day into numbers and a precise follow-up list.
- **Do:**
  1. Run the triage tool on the day's phone export and Gateway log, with
     `--tailscale-window` for the day. Save its JSON output and the text summary
     as the day's artifact (path in the handoff).
  2. Fill the "Evaluation day" column in Findings and check every exit
     criterion marked "R-4".
  3. Answer the questions Phase 1 could not:
     - Which explanation held for any silent recovery gap (suspension, blocked
       main actor, parked loop)? Zero `reconnect.stalled` and zero
       `app.main-stall` is the expected answer.
     - Do successful transport opens stay under 3 s p99 (C-3's 5 s deadline)?
     - How many Tailscale flaps happened, and did any cause a visible
       disconnect while the phone was on the LAN endpoint (E-1, E-3)?
     - What did a real reconnect send, compared with G-7's target?
     - Did any recurring background job from G-8 still show up?
  4. Add a Phase 3 row for every missed criterion and every new cause, with the
     triage evidence in its scope.
  5. Report to the user: a short summary of the day by cause, the criteria met
     and missed, and the proposed Phase 3 rows.
- **Done when:** Findings has the day's column, each missed criterion has a
  row, and the user has the summary.

### G-6 — Viewing without a runtime (needs scoping)

Opening an old chat to read it loads a full runtime (hundreds of MB for large
sessions). Scope serving the open-for-viewing projection from a bounded tail
read and loading the runtime on the first command. This changes the
subscription contract; present options to the user before any code.

### G-14 — Host budget for agent child processes (needs scoping)

Subagents, tool processes and browsers run as children outside the Gateway's
runtime budget and compete with it for memory and CPU. Scope a host-level
budget (count and memory, with queueing) and present it to the user; it
changes agent behaviour.

### V-1 — Close-out (needs scoping)

When R-4's follow-up rows are Done: if any of them changed runtime behaviour,
build it the same way (integration branch, R-1 for that change), then repeat
R-2, R-3 and R-4 once more. The plan closes only when one evaluation day meets
every exit criterion. Then move lasting knowledge into
`packages/gateway/README.md`, `packages/gateway/docs/connection-resilience.md`,
`packages/gateway/docs/observability.md` and `packages/ios-app/docs/architecture.md`;
close the plan through `docs/plans/HISTORY.md`.

Leave the gains protected after the plan closes:

- The exit criteria become the documented budgets in
  `packages/gateway/docs/connection-resilience.md`, each with its measuring
  command.
- `scripts/tron-profile gateway --scenario multi-session` and the triage tool
  are documented as the standing check before any Gateway release and after
  any change to the transport, catalog, registry or slot.
- `packages/gateway/docs/observability.md` warning rows for the budgets stay, so
  a regression shows up in the log before a user notices it.

## Findings

### Measurements

The `main` baseline is filled by O-6a and O-6b at the start of Phase 1, the
release candidate by R-1, and the evaluation day by R-4 (real logs; "n/a" where
the day cannot measure a synthetic case).

The `main` column is **provisional**. O-6a recorded it on a host at 1-minute
load 20–55 (the report warned "host busy") with the pre-fix variable-length
mixed windows (205–230 s), so every window total scales with how long the
fixture took, not with the Gateway's work. The overrun is fixed — the mixed
window now closes at 120 s and in-flight operations get a bounded 45 s tail —
but the quiet-host repeat that replaces this column is still outstanding, so
read it as the shape of `main`, not as a target.

Read the quiet-host repeat metric by metric. Some metrics vary with how many
operations fit in the fixed window rather than with the Gateway's per-request
cost, so a `compare` verdict on them is window volume, not a latency change:
the dashboard's `session.list` frames and bytes (a whole number of lists per
window, 8 against 9 is about 12%), `catalog.walks` (one per list and per open),
and the fixture's CPU and wakeup totals. `session_open_cold_large` p99 rests on
1–5 samples per iteration, one of which a tail may censor. The exit criterion is
the latency percentiles; the volume metrics above are expected to move with
list latency and need no fix. Open work if a quiet-host pair still disagrees on
a latency percentile.

| Metric | `main` baseline (provisional) | Release candidate (R-1) | Evaluation day (R-4) |
| --- | --- | --- | --- |
| `session.list` p99 | 46.5 s (p50 27.5 s) | | |
| warm / cold `session.open` p99 | 3.3 s / 140 s (1 MiB); 25.7 s for 100–200 MiB | | |
| prompt admission p99 | 631 ms | | |
| event-loop delay p99 / max | 125 ms / 6.3 s (no subscriber: 263 ms / 5.7 s) | | |
| request-path catalog walks | 37 walks per mixed window (~219 s), all causes (probe) | | |
| snapshots built without an audience | | | |
| Gateway CPU, 8 running, no subscriber | 57% of one core | | n/a |
| Gateway heap peak (% of limit) / RSS peak | 1.98 GiB (49%) / 2.00 GiB | | |
| reconnect after path return p95 | | | |
| requests / bytes per reconnect | | | |
| episodes by cause (triage) | n/a | n/a | |
| visible disconnects during Tailscale flaps | n/a | n/a | |
| persisted log volume per day | | (estimate) | |

## Handoff log

### Draft · 2026-09-27 · connection investigation session

- Result: drafted from the investigation of the 2026-09-27/28 reconnect and
  slow-loading reports.
- Evidence: Gateway log since the 01:33 UTC restart; phone exports
  `tron-diagnostics.jsonl`, `tron-diagnostics 2.jsonl` and
  `tron-diagnostics-3.jsonl`; Tailscale network-extension log via `log show`;
  catalog walk, header, contention, busy-loop, durable-write and large-parse
  measurements on this Mac; a native sample of the live Gateway.
- Changes: this file only.
- For the next agent: nothing here was reproduced under O-6 yet. Treat the
  "inferred" items in Context as hypotheses until O-3 and O-4 confirm them. The
  JavaScript CPU split of the Gateway is unmeasured.

### Decisions · 2026-09-27 · connection investigation session

- Result: the user answered D-1 to D-5: fold in the reconnect plan (yes);
  "Connected" follows the transport (yes); catalog design left to the most
  robust and efficient option (change-driven index chosen); faster retry and
  inbound-frame liveness (yes); direct LAN endpoint (yes, only if robust,
  resilient and efficient, carried by E-3's conditions).
- Changes: this file only.

### Restructure · 2026-09-28 · connection investigation session

- Result: restructured for an orchestrator and worker models: roles, worker
  and orchestrator procedures, conflict zones, waves, release trains, exit
  criteria, commands and a uniform task shape. Added stability tasks found in a
  second pass: O-7 (triage tool), G-9 (background scheduler and libuv pool),
  G-10 (durable writes), G-11 (event-loop budget), G-12 (deadlines, caps,
  shedding), G-13 (restart storm), G-14 (child-process budget, needs scoping).
  Split O-6, G-1 and E-3 into worker-sized tasks.
- Changes: this file only.
- For the next agent: the plan is Proposed until the user approves it; no task
  can be claimed before then.

### Restructure · 2026-09-28 · connection investigation session (second)

- Result: at the user's request, reorganized into three phases: Phase 1 builds
  and qualifies every task that does not need real-world use on one
  integration branch; Phase 2 ships it as a single protocol-6 release, runs one
  evaluation day and analyses it with the triage tool (R-1 to R-4); Phase 3
  holds only what the day shows, plus G-6 and G-14, and V-1 repeats the day
  until every exit criterion holds.
- Changes: this file only. Release trains replaced by one release with a
  rollback path; branch model added (a stated exception to claiming on
  `main`, approved with the plan); exit criteria split into R-1 (synthetic)
  and R-4 (real day); C-1, C-3, G-7, G-8, E-1 and E-3d no longer wait for
  real-use data before the release; E-3d turns the LAN endpoint on in the
  release only if every E-3c case passes.
- For the next agent: the plan is Proposed until the user approves it; no task
  can be claimed before then.

### Activation · 2026-09-28 · orchestrator session

- Result: the user approved the plan and asked this session to coordinate it.
  Status set to Active; Phase 1 continues on `hardening/integration`.
- Changes: this file only.

### P-0 · Done · 2026-09-28 · orchestrator session

- Result: the phone reconnect tuning plan got its closing handoff entry, a
  `docs/plans/HISTORY.md` entry, and was deleted. The energy-efficiency plan's
  coordination link now points here.
- Evidence: `python3 scripts/check-documentation-policy.py` passes.
- Changes: `plan(connection-scale-hardening): P-0 fold in phone reconnect tuning`.

### O-1 · Done · 2026-09-28 · worker session (branch `hardening/o-1`)

- Result: the phone's hello sends `diagnostics: { clientId, attemptId, epoch }`.
  The Gateway keeps each valid token and stamps it as `peerClientId`,
  `peerAttemptId` and `peerEpoch` on `connection.opened`, `connection.closed`,
  `connection.heartbeat-timeout`, `connection.write-error`,
  `connection.superseded` and `connection.outbound-capacity`. It returns
  `connectionId` in its hello. The phone logs that value as
  `gatewayConnectionId` on `reconnect.connected` and on every `gateway.connection`
  record of that epoch.
- Failure modes written before the tests. Gateway: a malformed diagnostics
  object rejects the hello; an unsafe value reaches a record; a connection
  record lacks the key; the hello's `connectionId` differs from the records'; a
  superseded record carries the newcomer's key. Phone: the hello omits or
  mis-populates the key; the Gateway ID is missing from the success record or a
  later record of the epoch; a successor epoch inherits its predecessor's
  Gateway ID; a hello without `connectionId` fails the handshake.
- Evidence:
  - The new Gateway tests failed first (5 failures) and then passed.
    `npx vitest run src/transport/server-capacity.integration.test.ts src/transport/server-heartbeat.integration.test.ts src/transport/logger.test.ts`
    passes 40/40. The neighbouring suites (http-admission, compression,
    sync-protocol, revocation) pass 41/41, and `npm run build` is clean.
  - `scripts/tron-ios-test run --only-testing TronMobileTests/GatewayClientTransportTests`
    passes 49/49, including the new correlation test. AppModelReconnectTests,
    GatewayDiagnosticsServiceTests and GatewayProtocolContractTests pass 66/66.
  - Local fixture run: `scripts/ios-gateway-e2e-test run` passed 1/1 in 35 s.
    RealGatewayPiBoundaryTests now reads `system.logs` from the real fixture
    Gateway and asserts the join. The phone attempt and the Gateway's
    `connection.opened` and `connection.closed` records share
    `clientId`/`peerClientId` = `D5BF99B5-F90E-4DC9-A946-CC72370BE552`,
    `attemptId`/`peerAttemptId` = `initial` and `epoch`/`peerEpoch` = `1`, joined
    by `connectionId` = `43605766-d485-4f98-81e6-8696e86dab0d`. The xcresult
    attachment `connection-correlation-key` holds these values. They are also
    retained as `connection-correlation-key.txt` and `gateway-records.jsonl` in
    the internal workspace under `files/hardening/o-1/`.
- Changes: the O-1 commit on `hardening/o-1`.
- Tasks added: none.
- Kept on purpose:
  - The phone's existing top-level hello `clientId`, a fresh UUID per hello
    that the Gateway ignores, stays because the task says not to change other
    hello fields. It is a candidate for deletion in the protocol-6 release.
  - The phone decodes hello `connectionId` as optional, and the Gateway accepts
    a hello without `diagnostics`. O-1 does not bump the protocol, so a
    protocol-5 peer on either side must still connect. The key is diagnostic
    only.
- Deviations:
  - `epoch` travels as a decimal string, so all three values follow the one
    token rule.
  - `connection.heartbeat-timeout` and `connection.superseded` now also carry
    `connectionId` as a field. Before, it appeared only in the message, so these
    records could not be joined by field.
  - Carrying the fields needed edits outside the named owning files. The logger
    (`logger.ts`) gained the three fields. On the phone, `GatewayProtocol.swift`,
    `GatewayClientDiagnostics.swift` and `IOSClientDiagnostics.swift` changed,
    and a one-line change in `GatewayLifecycleCoordinator.swift` (phone
    lifecycle zone) adds the ID to `reconnect.connected`, as Do item 4 requires.
    RealGatewayPiBoundaryTests gained the E2E join assertion.
- For the next agent: O-2, O-4 and O-7 can key on
  `connectionId` + `peer*` (Gateway) and `clientID`/`attemptID`/`connectionID` +
  `gatewayConnectionId` (phone). The profiler driver
  (`scripts/tron-profile-gateway-driver.mjs`, Profiler zone) does not send the
  key yet.

### E-2 · Blocked · 2026-09-28 · orchestrator-dispatched worker

- Result: the attribution parser the iOS profiler runs after a traced scenario
  (`scripts/tron_profile_attribution.py`, imported by `scripts/tron-profile-ios`)
  now keeps each repeated xctrace value once: when an element ends, every
  `ref` child is replaced by its shared definition, so memory grows with
  distinct values instead of references. Cause of the ~10 GB: a host-wide
  Time Profiler export of a loaded Mac (1,044,042 rows; 15.3 M `<frame ref>`
  children inside 396,657 retained backtraces) kept every reference as its own
  element. Not handed to the simulator-lifecycle plan: it has no row for the
  profiler's own memory, and SIM-7 (`sim-lifecycle` b9c11e9d0, not yet on
  `main`) touches only the lease, sweep and provision parts of
  `scripts/tron-profile-ios`, which this change does not edit. Marked Blocked,
  not Done, by the reviewer's finding: the Done-when needs the profiler's peak
  RSS under 2 GB for the default scenarios, and the `xcrun xctrace export`
  child the profiler launches still peaked at 4,599 MB on the largest default
  trace, so only the parser half of the goal is met. The branch itself can
  merge as it is; the row stays Blocked until a recording small enough for the
  export is measured (proposed E-2b below).
- Evidence: offline re-attribution of copies of existing traces with a
  tree-RSS sampler (`~/.tron/workspace/files/hardening/e-2/`, `README.md` has
  the command). idle-dashboard, 342 MB host-wide trace: old parser killed at
  a 5 GB cap and still growing, new parser peak 1,672 MB. control-cpu, 57 MB:
  481 MB to 136 MB, and with `PYTHONHASHSEED=0` `attribution.json` and
  `attribution.md` are byte-identical before and after. New failure mode 9 in
  `scripts/test-tron-profile-attribution.py`
  (`test_retained_memory_does_not_grow_with_references`, 398,000 references):
  peak 174 MB (166 MiB) on the old parser (fails), 6.9 MB (6.6 MiB) on the new
  one, against the test's 24 MiB limit;
  `python3 scripts/test-tron-profile-attribution.py` 10/10 pass.
- Changes: `perf(ios): keep each xctrace value once in profiler attribution (E-2)`;
  the review response below adds
  `refactor(ios): correct the attribution memory notes and helper name (E-2)` and
  `plan(connection-scale-hardening): mark E-2 Blocked after review`.
- Tasks added: none; proposed below.
- Kept on purpose: `time-profiler` still records `--all-processes`.
  `xcrun xctrace export` itself peaked at 4,599 MB on the 342 MB trace (978 MB
  on the 57 MB one), and only a smaller recording can reduce that. The target
  process was 1.2% of the rows. Switching the recording to
  `--attach <pid>` needs a real traced run, and the lane lease and profiler
  lock were held by other sessions for this task's time budget.
- Deviations: the peak numbers were measured offline on copies of existing
  default-scenario traces (idle-dashboard, the largest), not on a fresh
  `--scenario all` traced run, so the other default scenarios are unmeasured.
  Both the parser peak and the export peak grow with how busy the Mac is during
  an `--all-processes` recording; 99% of the rows were other processes
  (1,031,812 of 1,044,042), so this bounds the growth, it does not cap it.
  Ranking ties (equal ms) are ordered by string hash, so without a fixed
  `PYTHONHASHSEED` two runs of either parser can list tied rows differently.
  This behavior predates the change and was left as is.
- For the next agent: proposed row E-2b (the row stays Blocked until it is
  measured): record `time-profiler` with host
  `xcrun xctrace record --attach <pid>` if a real traced run proves it samples the
  simulator app. Accept only when no report section reads other processes'
  rows (today only `samples_other_processes` does) and a paired control-cpu
  run shows the same app numbers within noise. Then re-measure `xctrace export`
  and the parser on `--scenario all --trace time-profiler --iterations 1`.
  The simulator-lifecycle plan's owner should know that
  `scripts/tron_profile_attribution.py` changed here, and that `sim-lifecycle` edits
  `scripts/tron-profile-ios`.
- Review response (the two commits on this branch after the profiling change):
  the row and this heading moved from Done to Blocked as finding 1 requires; the
  test comment records the measured peaks (174 MB old, 6.9 MB new, finding 2);
  the module docstring says every id-carrying value is kept once (finding 3); and
  `Table.resolve` became `Table.value`, since it only drops absent or
  `<sentinel/>` cells now (finding 4).

### E-2b · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: host `xcrun xctrace record --attach <pid>` cannot sample a simulator
  app process, so E-2's "otherwise" branch applies — `time-profiler` keeps
  `--all-processes` and no source changed. The switch was implemented and run on
  the real path (`--no-build --scenario control-cpu --trace time-profiler
  --iterations 5`); xctrace exited 21 before recording with `Cannot find process
  for provided pid: 98691`, the pid the hosted test reports for itself and the
  same pid `--all-processes` samples and attributes in E-2's baseline. The same
  host attach against a simulator process that had been up for an hour
  (`SpringBoard`, pid 65793) fails identically, while it succeeds against a plain
  host process and records that process alone (2,721 rows, 702 KB, one process,
  1.7 s to export). The device form (`--device <udid> --attach SpringBoard`) did
  not return within 180 s, matching the documented simulator-device failure, and
  the recorder's bounded start would abort it anyway. E-2 stays Blocked: its
  2 GB Done-when is not met, because with `--all-processes` kept the export still
  peaks in gigabytes on the default scenarios.
- Evidence: `~/.tron/workspace/files/hardening/e-2b/` — `README.md` holds the
  commands, exit statuses and numbers, with `hosted-test-attach-xctrace.log`,
  `hosted-test-process.json`, `attach-cpu.out/.err` (the failed traced run's
  output and tree-RSS peaks: 532 MB, exit 74) and the `simattach.py` /
  `devattach.py` / `e2b-probe.py` probes. Failed run retained at
  `~/Library/Developer/Tron/profiles/ios/20260928T090007Z-control-cpu-trace-time-profiler-1d4470/`.
  The kept `--all-processes` mode is unchanged: `python3
  scripts/test-tron-profile-attribution.py` 10/10 and `python3
  scripts/test-tron-profile-ios.py` 7/7 pass after the reverted switch.
- Changes: `docs(ios): record that host xctrace attach cannot sample simulator
  processes (E-2b)` — `packages/ios-app/docs/development.md` and this plan; the
  review response below adds `docs(ios): correct the time-profiler attach note
  after review (E-2b)`.
- Tasks added: none; E-2c proposed below.
- Kept on purpose: `--all-processes` and its `samples_other_processes` field,
  which is exactly what showed 73,865 other-process samples against 273 measured
  ones in E-2's control-cpu baseline; it would be dead reporting only under
  attach. The `swiftui` and `points-of-interest` device templates were not
  touched: their failure is the same documented one, re-confirmed once here.
- Deviations: the `--scenario all --trace time-profiler --iterations 1`
  re-measure was not run. Its premise had already failed, and the simulator
  lease was then needed by O-4, so the lane was released rather than held for an
  `--all-processes` run whose export peak E-2 already measured (4,599 MB on the
  342 MB idle-dashboard trace, `files/hardening/e-2/peaks.txt`). The build
  products for this worktree were made before that release and are identity-
  stamped for it (`~/Library/Developer/Tron/ios/profile-derived-data/`,
  worktree key `tron-hardening-e-2b-0d0b09bd1a08`).
- For the next agent: proposed row E-2c — bound the `time-profiler` export so
  `--scenario all --trace time-profiler --iterations 1` fits the 2 GB budget:
  first find why simulator-device recording never starts (`--device <sim>
  --attach <pid>`, 180 s without returning, then the recorder's 300 s abort),
  since a device recording would sample the app alone and would also restore
  signposts and SwiftUI for every template; if that stays broken, have the
  profiler refuse a trace whose export cannot stay inside the budget, with the
  refusal's message naming the trace size, and shorten the default windows as
  far as `attribution.json` still ranks the scenario's work. Do not re-try host
  `--attach` — it cannot see simulator processes at all.
- Review response (the follow-up commit on this branch): the owning doc's added
  paragraph no longer blames the kernel — xctrace cannot be told to record the
  test process alone, and host attach by name fails the same way (status 19) —
  it points up to the export-memory paragraph instead of down, and the hour-long
  uptime detail is gone (it stays in this handoff). The `Changes` line above now
  quotes the real commit title and names both files that commit changed. The
  retained evidence folder renamed the Python `simattach.sh` to `simattach.py`,
  added the host positive-control probe (`e2b-probe.py`), and describes
  `verdict.py`.

### O-3 · Done · 2026-09-28 · worker session (branch `hardening/o-3`)

- Result: one request span per admitted RPC (`packages/gateway/src/transport/request-span.ts`,
  `AsyncLocalStorage`, `stage`/`wait`/`count`/`bytes`). `rpc.completed` carries
  `stages` — one compact string, most expensive entry first, e.g.
  `session.open.manager=434ms;session.open.runtime=48ms;snapshot.build=18ms×2;
  catalog.walk=16ms×2;frame.serialize=36ms/572KB;catalog.walk.files=×6` — plus
  `unaccountedMs`, the wall time no named entry covered. `GatewayLogger`
  normalizes both fields (`LogMetadata`, `LogRecord`, `normalizedFields`) and
  bounds `stages` at 1 KiB, so the breakdown reaches the JSONL line and the
  restored persisted tail, not just a test double. Measured stages: the
  registry's `timedStage` wrappers (now the span's `stage`), `catalog.walk` with
  a walked-file count, `catalog.reconcile` with a row count, `SessionManager.open`
  (`session.open.manager`), `RuntimeSlot.create` (`session.open.runtime`),
  `snapshot.build`, `response.encode`, and `frame.serialize` with bytes. Measured
  waits: the registry's four lanes report their queue wait (`registry.mutex`,
  `registry.catalog-mutex`, `registry.attention-lane`, `registry.display-lane`).
  `session.stage` and `session.open.prepared` are deleted with their rows;
  `SLOW_SESSION_STAGE_MS`, `SLOW_SESSION_OPEN_WARNING_MS` and the registry's
  `stageTiming` option went with them, but the two handled failures that only
  that record surfaced keep their own warning records: `runtime.dispose-timeout`
  and `catalog-index.failure`.
- Failure modes written before the isolated tests
  (`packages/gateway/src/transport/request-span.test.ts`,
  `packages/gateway/src/util/async-mutex.test.ts`): (1) a wrapped stage never
  records, so the slow stage is missing and `unaccountedMs` stays as large as the
  stage; (2) nested stages are counted twice, so the entries claim more time than
  the request took and `unaccountedMs` reads 0 while the request was unmeasured;
  (3) a lock wait is charged the work it admits, so the wait inflates and hides
  the real stage; (4) records arriving after `breakdown` move a published
  breakdown; (5) counts and bytes are dropped from the compact string; (6) two
  requests share one span and stages land on the wrong one; (7) wrapping a
  synchronous owner makes it asynchronous; (8) two stages started concurrently
  are nested into each other through a stack shared by the span, so the
  later-started one is charged the earlier one's time; (9) a queued `AsyncMutex`
  operation observes the holder's async context instead of its caller's. Every
  one of these was reproduced against the pre-change code: swapping the old
  `request-span.ts` back makes 8 and 9 fail, and removing the two `normalizedFields`
  entries makes the integration case below fail.
- Evidence:
  - `npx vitest run src/transport/request-span.test.ts` passes 9/9;
    `src/util/async-mutex.test.ts` passes 3/3; `src/transport/logger.test.ts`
    passes 13/13; `src/sessions/catalog-metadata-index.test.ts` passes 17/17.
  - `npx vitest run src/transport/request-span.integration.test.ts` passes 1/1
    (three cold opens of generated 105 MB canonical JSONL each through a real
    `GatewayServer` + `GatewayService` + `RuntimeRegistry` + `GatewayLogger`).
    Retained at `packages/gateway/test-results/request-span.integration.json`,
    written by the test itself like the other integration cases; the two runs
    before the second review kept their report at the worker's older
    `~/.tron/workspace/files/hardening/o-3/` path and gave accounted shares
    0.965 / 0.9823 / 0.9828 and 0.9858 / 0.9926 / 0.9932, medians 0.9823 and
    0.9926, `stages` 146–191 bytes and a whole record 595–640 bytes; the
    review-response run gave 0.9681 / 0.9758 / 0.9808, median 0.9758, `stages`
    189 bytes and a whole record 638 bytes. The case asserts the bar on the
    median of three repeats and
    asserts no per-open ratio (a parallel run of six suites stalled one open's
    measured interval and moved a single-open dominance ratio below its bar,
    which is why the per-open numbers stay in the report instead); the failures
    it previously hid (a missing breakdown) now fail it. The remaining "Done
    when" number, the slowest `session.open` in the qualification workload, is
    measured by the orchestrator after O-6a merges, from the persisted JSONL
    line; this case is the interim evidence for the 95% accounting, accepted as
    such by the orchestrator's review decision of the second review.
  - The same run persists a failed `session.open` (unknown session ID) as
    `stages` + `unaccountedMs` on the JSONL line, 512 bytes, which is the
    writer-path proof the previous revision lacked.
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts` passes
    243/243 in 56 s (the changed `catalog.metadata-materialize` hook test now
    spies on `sharedCatalogSessionInfos`; the dispose-timeout case drives the
    registry's own `runtimeDisposeTimeout` option; the review-response case
    below contends two spans on the registry's own `registry.mutex` lane).
    `src/extensions/owner-attribution.test.ts`,
    `semantic-ui-broker`, `delegated-provider`, `knowledge/connectors`,
    `browser-live-loader`, `runtime-registry-notification-read` pass 106/106;
    `command-receipts`, `session-attention-store`, `run-markers`,
    `invocation-receipts`, `sync-protocol` pass 48/48; `server-capacity`,
    `server-compression`, `server-live-view`, `rpc-idle-admission`,
    `server-frame` pass 47/47; `diagnostic-export`, `catalog-discovery`,
    `session-sync`, `session-archive-store` pass 26/26. `npm run build` is clean.
  - Volume: a slow or failed `rpc.completed` grows by the `stages` string plus
    `unaccountedMs` (146–191 + 20 bytes measured on the real line). Fast
    successes stay debug (memory-only), so the added persisted volume is (slow +
    failed completions) × about 200 bytes; 1,000 such records a day is 200 KB
    against the 1 MB budget. V-1 measures it.
- Changes: the O-3 commit and the review-response commits on `hardening/o-3`
  (`fix(gateway): persist the request span breakdown and fix its attribution (O-3)`
  and `fix(gateway): count catalog walks once and make the span tests catch their
  guards (O-3)`).
- Tasks added: none.
- Kept on purpose: `catalog.walk` is recorded where the walk is created, and a
  caller that joins another caller's shared walk records `catalog.walk-join` as
  a wait, because waiting for that walk is this request's cost but not a walk
  this request performed; without the separate name the count of `catalog.walk`
  would include joins, and a join would be counted against the walk it joined.
  The registry's lane subclass only measures the wait now; `AsyncMutex` itself
  preserves the calling async context.
- Known loss: the `startup.*` stage timings (`startup.attention.initialize`,
  `startup.archive.initialize`, `startup.recent-model.initialize`,
  `startup.run-marker.read`, `startup.catalog.evidence`,
  `startup.attention.reconcile`, `startup.run-marker.interrupted`) went with
  `timedStage` and nothing replaced them, since they run outside any request.
  Only the coarse `gateway.startup-phase` transitions remain; recovering those
  timings needs a startup span, which no row owns today.
- Deviations:
  - The plan's API is `wait(name, fn)`; the implementation is
    `wait(name, fn)` where `fn` receives an `acquired` callback, because a lock
    hands over inside its own operation and only that operation can report the
    handover. `stage` also accepts a synchronous operation so `RuntimeSlot.snapshot`
    keeps its signature. Both are documented in `request-span.ts`.
  - Two stages are measured that the task's Do list does not name:
    `response.encode` (`safeJson` over the whole snapshot in
    `gateway-service.ts`) and `attention.reconcile` (marker evidence and
    settlement in `runtime-slot.ts`). Both are on the `session.open` path and were
    added because the measured unaccounted remainder landed in them.
  - "Outbound enqueue wait" has no await to measure: `OrderedOutboundQueue.enqueue`
    is synchronous and returns a boolean on overflow, so the response send path is
    covered by `frame.serialize` (+ bytes). The wait appears when G-4's coalescing
    queue adds one.
  - Scope widened with the orchestrator's approval to files outside O-3's owning
    list: `packages/gateway/src/util/async-mutex.ts` (the queued-operation
    async-context fix, root cause of finding 2) and
    `packages/gateway/src/sessions/catalog-metadata-index.ts` (the failure-only
    reporting hook). No mutex user was found to depend on the old leaking
    behaviour: every focused test listed above passes unchanged.
  - `unaccountedMs` cannot stay meaningful when two stages genuinely overlap
    (concurrent background work started inside one request): their entries add up
    to more than the request took and `unaccountedMs` reads its floor of zero.
    Nesting now follows the async context, so a stage is only charged its own
    parent; the docstring says so.
- Withdrawn: none.
- For the next agent: O-6a's scenario is not committed on `hardening/o-6a`
  (its `scripts/tron-profile-gateway` work is uncommitted), so the qualification
  measurement is still owed; the orchestrator owns it after O-6a merges: run the
  multi-session scenario and record the slowest `session.open`'s
  `stages`/`unaccountedMs` there, from the persisted JSONL line rather than the
  debug buffer. The span API is the seam for
  G-1c (delete a walk → delete its `catalog.walk`), G-3 (snapshot build without
  an audience) and C-6 (a cancelled read's span ends at cancellation, so a
  cancelled open will report a short `durationMs` with the stages it reached).
- Review response: the row and this heading moved from Done to Claimed (finding
  3) because the O-6a measurement is still owed. `stages`/`unaccountedMs` are now
  normalized and persisted by `GatewayLogger`, bounded at 1 KiB with their `=`,
  `;`, `×` and `/` separators intact (finding 1). `AsyncMutex.run` captures
  `AsyncLocalStorage.snapshot()` at call time, so a queued operation runs in its
  caller's context for every mutex, not only the four registry lanes (finding 2).
  `runtime.dispose-timeout` and `catalog-index.failure` are dedicated warning
  records with rows and tests that drive the real failure paths, and the
  test-only hooks are gone (finding 4). Nesting follows the async context, with a
  concurrent-sibling failure-mode test (finding 5). The integration case uses a
  real `GatewayLogger` and a stable artifact path (finding 6); the unit tests pin
  the clock instead of asserting sleep ratios (finding 7); sub-millisecond and
  zero-byte entries are dropped and totals stay fractional until formatting
  (finding 9); the new `as never` casts are gone (finding 10). The removal of the
  `startup.*` stage timings is stated as a known loss (finding 8).
- Review response (second review): the orchestrator decided finding 1, so this
  row and heading are Done again and the O-6a measurement of the slowest
  `session.open` is the orchestrator's, run after O-6a merges (see "For the next
  agent"); the in-repo integration case is accepted as the interim 95%
  accounting evidence. The report is written to
  `packages/gateway/test-results/request-span.integration.json` like the other
  integration cases and `TRON_O3_SPAN_REPORT` is gone (finding 2). Each open's
  record is selected by its `requestID`, not by position (finding 3). The
  late-record case now holds a continuation inside the span's async context and
  releases it after `breakdown()`, so it exercises the `finished` guard: with
  the guard removed the republished breakdown reads
  `late.stage=7ms;session.open.catalog=5ms;catalog.walk.files=×2;frame.serialize=×0/4KB`
  and the case fails, and it passes again with the guard restored (finding 4,
  negative control). The registry suite gained one focused case where two spans
  contend on the registry's own `registry.mutex` lane under `runInRequestSpan`:
  the queued request's breakdown is exactly
  `registry.mutex=50ms;waiter.work=5ms`, it covers the holder's hold, and its
  admitted work lands on its own span (finding 5). A caller that joins another
  caller's catalog walk now records `catalog.walk-join` as a wait, so
  `catalog.walk` counts walks performed and a join is not counted against the
  walk it joined (finding 6). Plan task IDs are gone from code comments, with
  the reasons kept (finding 7). `catalog-index.failure` (finding 8): its message,
  its `observability.md` row and the failure type's
  docstring all say the affected rows are rebuilt from canonical files.
  Drive-by: the `sharedCatalogSessionInfos` spy cast added by this
  task named `CatalogSessionInfo` without importing it (never caught, since test
  files are outside the build); the type is imported now.

### O-6a · Blocked · 2026-09-28 · orchestrator-dispatched worker

- Result: `scripts/tron-profile gateway --scenario multi-session` generates a
  seeded 3,000-file/2 GiB catalog in the fixture's private agent directory,
  starts a fresh fixture Gateway per iteration and reports latency
  percentiles, event-loop delay, heap, RSS, CPU and catalog walks under eight
  running tool loops. The `main` baseline is in Findings (medians of three
  iterations of run `20260928T083106Z-multi-session-491859`, recorded with the
  pre-fix variable-length windows, so the column is provisional).
- Failure modes written before the isolated tests: the generator drifts
  between runs of one seed (baselines would compare different catalogs); forks
  or subagent runs land outside the Gateway's delegated layout (the user list
  would count them as sessions); an interrupted or failed run leaves gigabytes
  of catalog in the temporary directory; the probe's walk counter misses the
  Gateway's ES-module `opendir` (reporting zero walks, a false pass for G-1c);
  the probe loads outside a fixture; a percentile off by one or an operation
  without samples is reported as a value.
- Evidence: `python3 scripts/test-tron-profile.py` passes 18 tests (10 new:
  determinism, layout, failure-after-generation and SIGINT-during-generation
  cleanup, probe refusal, probe walk counting through an ES-module import,
  nearest-rank percentiles, rejection of an iteration without samples). Probe
  positive control on the real Gateway: every measured window counted walks
  (37 per mixed window, 6 per no-subscriber window; the dashboard's
  `session.list` walks). Full runs: `20260928T083106Z-multi-session-491859`
  (19.9 min, exit 0, catalog digest `b1f20a87…` from seed 2027) and the
  consecutive `20260928T085100Z-multi-session-2406dc` (13.2 min, exit 0, same
  digest). `scripts/tron-profile compare` of the two exits 3: one regression,
  `wire.dashboard.hello.bytes` (run A 1180 B median against run B 2360 B), which
  is the fixed 1.18 KB hello exchange counted once or twice depending on whether
  the longer window caught the dashboard's scheduled reconnect; 26 improvements
  are window totals (CPU time, wire frames and bytes) that scale with the window
  length; cold `session.open` p99 improved (140 s to 29 s). After
  every run, success or interruption (an interrupted run was also observed
  live), no `tron-profile-gateway-*` directory remained in the temporary
  directory. Reports live under `~/Library/Developer/Tron/profiles/gateway/`.
  The host was not quiet (1-minute load 20–50 from other sessions' builds);
  treat latency spreads accordingly.
- Changes: `scripts/tron-profile-gateway`,
  `scripts/tron-profile-gateway-driver.mjs`, new
  `scripts/tron-profile-gateway-probe.mjs` (approved by the orchestrator),
  `scripts/test-tron-profile.py`, the wire-traffic profile section of
  `packages/gateway/README.md`, `.github/workflows/ci.yml` (syntax check of
  the probe).
- Kept on purpose: `scripts/tron_profile_report.py` unchanged (the
  multi-session metrics fit its schema); `all` still means the four
  wire-traffic scenarios, so the 2 GiB run never starts implicitly.
- Deviations: each iteration restarts the fixture Gateway so every session is
  cold again (five large files cannot stay cold otherwise); a priming start
  pairs and builds the durable index. Warm, cold-plus-prompt and large-open
  probes run as three concurrent lanes on their own devices (the Gateway
  admits one `session.open` per connection, and a single large open took
  130 s on `main`). Retryable `busy` errors are retried and counted
  (`requests.busy_retries`). Operations in flight at a window's end finish
  inside it, so on `main` a default run takes about 20 minutes, over the
  15-minute bound; it should fall to about 13 once lists and opens are fast.
  `catalog.walks` counts every walk (probe), not only request-path ones.
  "Snapshots built without an audience" is not measured by this scenario.
- Blocked on: "two consecutive runs on a quiet host agree within the report's
  noise bound". The host was at load 20–55 throughout, and totals depend on
  how long in-flight operations overrun a window. To unblock: bound the
  overrun (or report totals per second), then repeat two runs when the host
  is quiet and confirm `compare` reports no verdicts; the Findings column may
  then be refreshed from them.
- For the next agent: the probe (event-loop delay, heap, RSS, walks) is a
  stand-in; once O-3 spans and the O-5 sampler report the same numbers,
  delete or reduce `scripts/tron-profile-gateway-probe.mjs` and read request
  path walks from spans. O-6b adds its cases to `multi-session`; its
  reconnect-to-ready already exists (`latency.reconnect_ready_*`, mobile p99
  0.58 s, dashboard p99 28.9 s on `main`). Run baselines when the host load
  is low; the report warns when it is not.

### O-6a · Blocked · 2026-09-28 · orchestrator-dispatched worker (review fixes)

- Result: the review's findings are fixed inside the scenario's own files.
  - The mixed window closes at `--mixed-seconds` whatever is still in flight. It
    used to wait for the slowest operation, so its length (205–230 s) and every
    window total (frames, bytes, CPU time, catalog walks) scaled with the
    fixture's latency. In-flight operations now get a fixed 45 s tail
    (`tailGraceMs`): their latency still lands in the samples, and whatever the
    tail outlasts is censored — its elapsed time becomes the sample,
    `requests.censored_tail` counts it, and it counts in
    `requests.over_phone_deadline` (an operation abandoned by the tail has been
    running for at least the tail).
  - The dashboard's reconnect runs on its own device. A single `session.list`
    can outlast the whole window on `main`, so the scheduled reconnect was
    starved and the run was rejected with "no reconnectReadyDashboard samples".
    The reconnect lane's own wire traffic is not recorded, as the prober lanes'
    is not, so `wire.dashboard.hello.*` is no longer a window metric (the mobile
    reconnect still reports it). The first reconnect also lands inside the
    window for any `--mixed-seconds`, not only for 120 s.
  - A lane abandoned by the tail can no longer keep the driver process alive: a
    closed client is retired, so a reconnect in flight cannot leave a socket
    open (the first fixed-window run hung on exactly that and never exited).
  - A first Ctrl-C can no longer skip the fixture group kill, and a removal it
    interrupts is resumed and its signal re-raised only after every removal
    finished, so neither a half-deleted catalog nor a half-deleted home is left.
  - The retained `gateway.stdout.log` appends, so it keeps the priming run and
    every iteration; `failure.json` is written by one helper.
  - The subagent-like writers start with the first measured window instead of
    with the setup. On `main` every append re-scans the whole catalog, so the
    eight setup opens queued behind that backlog (35–180 s each observed) and
    two full runs failed there; the appends still cover every measured window.
- Evidence: `python3 scripts/test-tron-profile.py` passes 21 tests (3 new: a
  fixture that survives `stop()` keeps its home while the catalog is still
  deleted; an interrupted removal resumes and re-raises afterwards; every
  removal action finishes before the re-raise). A short smoke run
  (`scripts/tron-profile gateway --scenario multi-session --iterations 1
  --catalog-files 200 --catalog-mib 32 --mixed-seconds 30 --no-build`) completes
  with exit 0: `window.seconds` 30.00 s, `no_subscriber.window.seconds` 30.00 s,
  every latency kind sampled, and no `tron-profile-gateway-*` directory left in
  the temporary directory. Of the full 2 GiB runs, iteration 1 of
  `20260928T103121Z-multi-session-52660d` completed with a 120.01 s window, a
  complete tail and every kind sampled; the two consecutive full runs were not
  finished because the host stayed at 1-minute load 22–70 from other sessions'
  builds.
- Blocked on: "two consecutive runs on a quiet host agree within the report's
  noise bound". The window overrun that made that impossible is fixed. To
  unblock, on an idle host run twice, consecutively:
  `scripts/tron-profile gateway --scenario multi-session` (the measured part of
  an iteration is now `--mixed-seconds` plus at most the 45 s tail plus the 30 s
  no-subscriber window; the rest is the host's fixture start and setup opens),
  then `scripts/tron-profile compare <run-1> <run-2>`. The bound is that
  command's exit 0 with its default floor: a metric may move by up to 3%, three
  robust standard deviations, or one unit without a verdict. Refresh the
  provisional `main` column in Findings from those two runs.
- For the next agent: the probe (event-loop delay, heap, RSS, walks) is a
  stand-in; once O-3 spans and the O-5 sampler report the same numbers, delete or
  reduce `scripts/tron-profile-gateway-probe.mjs` and read request path walks
  from spans. O-6b adds its cases to `multi-session`. Once O-1 is merged, the
  driver's hello needs O-1's `diagnostics {clientId, attemptId, epoch}` to stay
  phone-faithful (`GatewayClient.establishConnection`).

### O-6a · Blocked · 2026-09-28 · orchestrator-dispatched worker (second review response)

- Result: the second review's eight findings are addressed in the scenario's own
  files. The row stays Blocked on the orchestrator's two quiet-host runs.
  - A lane that fails inside the fixed window is now thrown through the normal
    path as soon as it fails. The window used to keep the lanes' promise
    unhandled until the tail, so a non-retryable Gateway error (or an unexpected
    socket close) became an unhandled rejection: the process died without
    `finally`, leaving the appender running and `timeline.jsonl` unflushed.
  - The tail's timer is cancelled in `finally`. An un-cleared `setTimeout` held
    the driver process alive for the whole 45 s grace period after a window that
    closed on its deadline (the review's smoke run had a 0 s tail and still
    lingered about 47 s; a default three-iteration run lost about 2.25 minutes).
  - `stop()` suppresses only `subprocess.TimeoutExpired` around its post-SIGKILL
    wait: `contextlib.suppress(BaseException)` also swallowed `Interrupted` (a
    `BaseException`), losing the user's first Ctrl-C while every later signal was
    already ignored.
  - The cold lane checks the deadline before `session.setModel` and before the
    prompt, so no sample is timed after the window closed (a post-deadline
    prompt was biased low and, when the tail censored it, recorded an elapsed
    time under the tail instead of the tail's length). The sample set is frozen
    when the tail ends: `timed` stops recording, so a lane that settles during
    cleanup can no longer append to `result.samples`.
  - Home removal proves ownership once, in the new `FixtureGateway.removals()`,
    and the retried actions no longer re-check the marker: `rmtree` deletes the
    marker on its way through the home, so a resumed removal that re-checked it
    no-opped and left a half-deleted home. The wire-traffic scenarios now use the
    same rule as the multi-session one: the generated catalog is removed on every
    path, the home only when the child is dead.
  - The driver comment about the reconnect offsets now says what the code does
    (the dashboard's offset is clamped to half the window, so for
    `--mixed-seconds` under 40 s it comes before the mobile's 20 s, and a window
    of 20 s or less is rejected by validation), and the README sentence about a
    "device retired by a reconnect" is replaced by the owning rule (each lane
    that can starve another runs on its own device and keeps its schedule; a
    prompt is not started after the deadline).
  - Findings now names the metrics whose quiet-host spread is window volume
    rather than latency (the dashboard's list frames and bytes,
    `catalog.walks`, fixture CPU and wakeups, large-open p99 from 1–5 samples).
    Rejected as a fix: converting those to per-operation or per-second rates.
    The report's schema is shared with the other scenarios, `bytes_per_second`
    already exists, and a rate does not remove the sample-count variance that
    causes the spread.
- Failure modes written before the isolated tests: a lane that fails inside the
  window must not become an unhandled rejection that skips `finally`; the tail's
  timer must not outlive the window; an operation that cannot start inside the
  window (a cold open that outlasts it) must not be measured afterwards;
  `stop()` must not swallow the first Ctrl-C; a removal interrupted after its
  ownership marker is already gone must still finish; and a directory that is not
  this profiler's fixture must never be removed.
- Evidence: `python3 scripts/test-tron-profile.py` passes 27 tests (6 new: a
  lane that fails inside the window still closes its clients (clean close 1000
  against the stub's 1006 before the fix, run both ways); the tail timer does not
  outlive the window (a 30 s window took 77.8 s before the fix and about 36 s
  after it, and the test's own 10 s window must finish under 40 s); a cold open
  that outlasts the window leaves no prompt sample (the pre-fix driver measured a
  0.2 ms prompt there); an interrupt in `stop()`'s post-SIGKILL wait is re-raised
  with the group kill still done; a home removal interrupted after the marker is
  gone still finishes; a home without the marker is never removed). The three
  driver cases run the real driver against a stub Gateway surface (a test fixture
  in `scripts/test-tron-profile.py`, like the probe client) because a lane
  failure, a lingering timer and a post-deadline operation cannot be produced
  reliably inside a qualification run.
  A smoke run
  (`--iterations 1 --catalog-files 200 --catalog-mib 32 --mixed-seconds 30
  --no-build`) exits 0 in 1.3 minutes as
  `20260928T111159Z-multi-session-5d3bb8`: both windows 30.00 s, tail complete in
  0 s, no censored operations, every latency kind sampled, and no
  `tron-profile-gateway-*` directory or fixture process left behind (the same
  command took 2.0 minutes before the tail timer was cleared).
- Changes: `scripts/tron-profile-gateway`,
  `scripts/tron-profile-gateway-driver.mjs`, `scripts/test-tron-profile.py`, the
  multi-session qualification section of `packages/gateway/README.md`, and this
  plan (Findings, this entry).
- Blocked on: unchanged — "two consecutive runs on a quiet host agree within the
  report's noise bound". To unblock, run
  `scripts/tron-profile gateway --scenario multi-session` twice on an idle host
  and `scripts/tron-profile compare <run-1> <run-2>`; read a verdict on the
  window-volume metrics listed in Findings as spread, not regression.
- For the next agent: unchanged from the previous entry.

### Orchestrator · 2026-09-28 · O-6a merged while Blocked

- Result: `hardening/o-6a` is merged into `hardening/integration` after its
  third review approved the scenario code. The row stays Blocked only on the
  two consecutive quiet-host baseline runs, which the orchestrator runs from
  the `hardening/o-6a` worktree (`main` Gateway code) when no other hardening
  work loads the host. Tasks that depend on O-6a use the merged scenario now.
- Decision on the O-6a noise bound (review round 3): the two quiet-host runs
  must agree (`scripts/tron-profile compare` with the default floor) on every
  latency percentile, on the no-subscriber Gateway CPU (a fixed sleep window, so
  not window volume) and on heap/RSS peaks. Closed-loop volume counts in the
  mixed window (dashboard list frames and bytes, `catalog.walks`, mixed-window
  CPU and wakeups) are exempt.
- Owed with the baseline: O-3's slowest-`session.open` accounting check and
  O-5's 5% cross-check, both from the same runs on the integration branch once
  O-5 merges.
- Also cleaned: stray `|||||||` merge-base marker lines that two earlier
  handoff-log merges left in this file.
