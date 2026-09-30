# Connection and scale hardening

- **Started:** 2026-09-27
- **Status:** Active (Phase 1 merged to `main` early on 2026-09-28 at the user's request; remaining Phase 1 work continues on `hardening/integration`, merged to `main` again at R-1)
- **Last updated:** 2026-09-28, G-12 review round 1 addressed: a shared cold start no longer carries one requester's signal (the queued load is dropped only when its last waiter leaves), the heap pass measures progress from its own accounting, and the deadline table is limited to the reads the plan names (see the handoff)
- **Last updated:** 2026-09-28, G-8a/G-8d/T-1 Done: an unchanged extension artifact costs one `stat` and no read, the ambient pass stays bound and reports a stop, and both read lanes retry a replace before warning (see the handoff)
- **Last updated:** 2026-09-28, G-2 Done: a 100–200 MiB cold `session.open` is the parse (45–56%, `session.open.manager`) plus the SDK runtime create (22–28%) and the bounded snapshot projection (19–24%) — the three named candidates (registry mutex, idle eviction, fork-boundary reads) are 3–13 ms (`session.open.catalog`) or absent; the whole-branch receipt index maps the snapshot projection allocated for nothing are gone (≈19 ms per snapshot at 100 k entries, measured) and the O-6a prime now retries the fresh fixture's `catalog_not_ready` (see the handoff)
- **Last updated:** 2026-09-28, G-11 Done: the Slot's publish-time full-transcript summary walk is now an incremental fold (largest run 86.9 ms → 4.8 ms); the dominant remaining stretches are session-search (G-8c) and catalog/registry (G-1c), both in flight, and the combined O-6a max/p99 is re-measured after they merge (see the handoff)
- **Last updated:** 2026-09-29, E-3d Done after review fixes: the LAN lane is on by default for a Gateway that is not bound to loopback (`--lan-endpoint on` still forces it on for a loopback bind), and the kill switch on the Mac-supervised release is the launchd session's `TRON_GATEWAY_LAN_ENDPOINT` (see the handoff)
- **Last updated:** 2026-09-29, E-3c2 Done: HTTP routes on the epoch's winning lane (live view, media, uploads, with the lane's pin) and the E-3c two-lane E2E cases both land; the E2E's blocked-lane leg now proves the 250 ms stagger and a retired LAN socket, and its blackhole leg uploads an attachment through a proxied HTTP blackhole

- **Last updated:** 2026-09-29, F-2 Done: the O-6b page leg's refusal was the driver mounting six presentations on one mobile connection (one presentation slot, by contract); the lane now abandons a superseded page with the phone's own `cancel`, the repro is green with zero `session.sync` refusals, and the driver's page leg no longer fails on a mount the connection retired by design (see the handoff)
- **Last updated:** 2026-09-29, G-3a Done: streaming progress follows the snapshot rule — a `session.progress` frame is projected and serialized only for a session with a subscriber (the O-6a CPU profile's throttled-flush subtree 551.7 → 193.5 ms, the subscriber's wire frames unchanged at 177 → 178; see the handoff)

- **Last updated:** 2026-09-28, G-13 review response 1: the row is Blocked, not
  Done — no run has met the restart criterion — the startup budget's stated
  reason is corrected and the case is judged on the clients' own close →
  listening span, read from the Gateway's own record (see the handoff)

- **Last updated:** 2026-09-28, E-3b done: pairing and hello advertise the
  lane's bound endpoint and pin (base64 SHA-256 of the certificate's public key
  as its raw X9.63 point, frozen in `protocol-fixtures/lan-endpoint-pin.json`),
  and the phone stores both with the profile and replaces them on every hello
  (see the handoff)

- **Last updated:** 2026-09-28, E-3a done: the pinned LAN listener binds a
  private address, rebinds or disables when that address changes, shares the
  transport's admission and refuses pairing (see the handoff)

- **Last updated:** 2026-09-28, G-8c review round 1 addressed: the search index
  is persisted and keyed by the catalog owner's verified file facts (fileIdentity,
  size, mtime), a start parses only what the catalog proves changed, and the write
  path is sliced - the session's old rows are deleted in bounded batches that
  yield, the byte total reads the persisted per-row posting total, only a cut read
  from the file is stamped as file-verified, and writers share one lane (see
  handoff). A 3,000-passage replacement over a 6,000-passage index holds the loop
  ~0.3 s against G-11's 565-821 ms insert and 491 ms delete, and a summary
  publication's invalidation is 0.1 ms
- **Last updated:** 2026-09-28, G-8b review round 2 addressed: the poller
  owns one admission cache shared with the explicit user actions, the explicit
  probe records its outcome, and the runtime fence stamps the bundled manifest
  too
- **Last updated:** 2026-09-28, G-8b review round 1 addressed: the poll
  republishes the fence's uptime, reuses only an admission whose ping identity
  still matches, realigns the windowed Tailscale ping to the poll alone, and the
  row returns to Claimed until the app-level cadence measurement runs

- **Last updated:** 2026-09-28, G-7 (final review round addressed: an unchanged catalog answer rebuilds the row projection, a cleared automation marker moves the catalog token)

- **Last updated:** 2026-09-28, C-1 final review round (a failed probe re-parks; a park cannot take over an in-flight connect or pairing)

- **Last updated:** 2026-09-28, C-1 review round addressed and its E2E re-run passed (Done)

- **Last updated:** 2026-09-28, G-3 review round 2 addressed: the `unaudiencedSnapshotBuilds` warning and its test are now stated as a tripwire for a lost slot guard or a divergence between the registry's subscription record and the transport's, not for a closing socket

- **Last updated:** 2026-09-28, C-4 (second review round addressed)

- **Last updated:** 2026-09-28, O-7 review round 4 addressed; O-7 Blocked until the Context causes reproduce on the real incident export

- **Last updated:** 2026-09-28, O-6a blocked on a quiet-host repeat (second review response landed)

- **Last updated:** 2026-09-28, O-4 (review round 4 addressed)

- **Last updated:** 2026-09-28, O-2 review response (silence requires expected
  liveness, upgrade refusals collapse into one record)

- **Last updated:** 2026-09-28, G-10 second review round (receipt totals kept across a rebuild, connection-owner row added)

- **Last updated:** 2026-09-28, G-9 background-work scheduler: catalog reconciliation, receipt pruning and attachment/display maintenance now share one scheduler that yields to requests, a reconcile pass yields to the pause between bounded batches, and only requests on the loop pause it; the libuv pool measurement was host-limited and the launcher is unchanged

- **Last updated:** 2026-09-28, G-8 background work audit: third review round corrected the re-admission fence, the socket promise and the discovery-open ceiling

- **Last updated:** 2026-09-28, G-1b catalog watcher (review round 2: spurious whole-folder passes, true `catalog.changed` bound, O-6a evidence)

- **Last updated:** 2026-09-28, E-2c blocked and review-addressed: the profiler refuses a host-wide `time-profiler` trace whose export is projected over its 2 GiB budget and names the trace's size, so no traced scenario's export is projected above 2 GiB; a device capture is not held to that ratio, the shorter-window half and a passing `--scenario all` run remain

- **Last updated:** 2026-09-28, T-4 done: the killer is XCTest's per-test execution-time allowance (the runner's own restart, not another worktree's run), and the test it lands on was the process's heaviest because the URL redaction in `IOSClientDiagnosticBuffer.redactedMessage` was super-quadratic in a run of scheme characters (the export test 8.646-10.297 s -> 0.072 s, 0 redaction differences over 20,247 inputs)
- **Last updated:** 2026-09-28, T-2 review round 1 addressed: the kill is another worktree's run on the same default-lane simulator, and T-3 tracks the lease that did not serialize them

- **Last updated:** 2026-09-28, G-4 done: the outbound queue drops a superseded session summary revision and supersedes the session state a newer snapshot re-states with the one `session.rebaseline` that covers it, fencing one-shot frames a snapshot cannot restore (`gateway.resources` gains `outboundCoalescedFrames`/`outboundCoalescedBytes`, `connection.outbound-capacity` names `oldestTopic`/`nextTopic`); a phone-side `SessionPresentationStore` case feeds the coalesced frame sequence and proves it installs without a resynchronization
- **Last updated:** 2026-09-29, F-3 Done: the Gateway's protocol-mismatch refusal is now a typed close (4006 plus `{code, gatewayProtocol, minProtocol}`), so the phone stops retrying that profile instead of looping, and the failure names the older app or the older Mac (see the handoff)

- **Last updated:** 2026-09-29, F-3 review round 1 addressed: no compatibility bridge for a Gateway built before that close (Option B — those Macs keep retrying until they are updated), a background profile's stop message reaches the device detail, the LAN lane names a typed refusal instead of `lan_unreachable`, and the terminal client maps close 4006 to a non-retryable `protocol_mismatch`

- **Last updated:** 2026-09-29, T-6 Done: neither registry load flake was a product race — the large-streamed-write case spent its 5 s `waitUntil` guard on 3,188 provider chunks (its 51 KB arguments and assertions unchanged, chunk size pinned), and the discovery helper capped its wait for a running pass at 5 s (it now waits for the pass to end and keeps the deadline for its own retries); see the handoff
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
for agent child processes (G-14), viewing sessions without a runtime (G-6),
whether session search keeps a persisted index keyed by `fileIdentity` (new
durable state, new owner) or is rebuilt in bounded slices inside G-9's
scheduler with incomplete coverage until it catches up (G-8c), and two halves of
the Mac app status poll (G-8b): whether it may stop re-hashing an unchanged,
already-admitted Gateway payload on every poll — the fail-closed checks that the
payload tree is immutable and still matches its manifest fingerprint
(`GatewayPayloadStore.swift:274–283`, `:381`) would then run when the selection
stamp or the process fence changes and on explicit user actions, not once per
30 s poll — and whether it may, in the same window, also skip the `lsof`
listener-ownership check and the two `ps` display reads, because that check is
the admission's security evidence. Neither decision covers the live launchd pid
plus start-identity read: that stays in the fence.

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
| Phone client | `packages/ios-app/Core/Gateway/GatewayClient.swift`, `packages/ios-app/Core/Gateway/GatewaySocketTransport.swift` | O-1, O-4, C-3, C-4, C-6, G-12, E-3c |
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
- **Wave 4:** C-3, C-4, C-6, G-12, G-2, G-7, G-11, G-9, G-10a.
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
| Runtime load and eviction | Registry | `runtime.loaded`, `runtime.evicted` | G-5 |
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
| E-2 | Done | Bound the iOS profiler's memory or hand the row to the simulator-lifecycle plan | none | orchestrator-dispatched worker, 2026-09-28 |
| E-2b | Done | Record `time-profiler` with `xctrace record --attach <pid>` if a real traced run proves it samples the simulator app; re-measure export and parser peaks (see E-2 handoff) | E-2 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| E-2c | Done | Bound the `time-profiler` export under 2 GB for `--scenario all` (see E-2b handoff: simulator-device recording, or a size refusal plus shorter windows) | E-2b | orchestrator-dispatched deepseek-worker, 2026-09-28; the export of a host-wide recording is now refused above its budget (measured on real traces), the shorter-window half and a passing `--scenario all` run remain (see handoff) |
| O-2 | Done | Gateway transport records: upgrade phases, inbound silence with Tailscale peer path | O-1 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| O-3 | Done | Request span: one `rpc.completed` per slow RPC with every stage, wait and count | O-1 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| O-4 | Done | Phone connection records that survive an export, stall watchdog, exact scene records | O-1 | orchestrator-dispatched deepseek-worker, 2026-09-28; review rounds 1–4 addressed; focused suites and the iOS Gateway E2E blackhole runs pass |
| O-6b | Blocked | Impairment in the qualification scenario: blackhole, bandwidth cap, Gateway restart | O-6a | orchestrator-dispatched deepseek-worker, 2026-09-28 (fifth review response) |
| O-5 | Done | Gateway resource sampler and event-loop histogram | O-3 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| O-7 | Done | Incident triage tool: phone export plus Gateway log in, episodes by cause out | O-1, O-2, O-4 | orchestrator-dispatched deepseek-worker, 2026-09-28; review rounds 1-4 addressed (attribution, older-export records and attempts, Tailscale capture, scene splits, recovery-handshake and attempt ownership, relay-window coverage). Blocked because the incident export does not reproduce all four Context causes: cause 4 has no `gateway-stall` episode of its own (its only candidate is a slow span on a socket already closed), the run reads 121 episodes against Context's 77 reconnect episodes, `phone-stall=2` where one wrong-label cause was counted, and `gateway-capacity=0` because the only capacity event predates the export (see the handoff) |
| C-1 | Done | Projection work never blocks or parks reconnect; parked episodes self-resume | O-4, O-6b | orchestrator-dispatched deepseek-worker, 2026-09-28 (review round addressed; E2E re-run passed, run `20260928T193255Z-run.E6rrDl`) |
| G-1a | Done | Catalog owner and in-memory index fed by Gateway-owned changes | O-3, O-6a | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| G-1b | Done | Filesystem watcher and background reconciliation for external writers | G-1a | orchestrator-dispatched deepseek-worker, 2026-09-28 (the O-6a confirmation of the Done-when is owed by the orchestrator) |
| G-1c | Done | Move every catalog reader to the index; delete request-path walks and the full-parse fallback | G-1b | merged `hardening/integration`; `verifiedCut` unified into `reconciledCut`, G-9 keeps the periodic reconcile, `searchIdentities()` reads the index rows. Owning suite 237/237, merge gate 363/363; O-6a p99 is the orchestrator's quiet-host run |
| G-1d | Done | Catalog contract in the docs: `connection-resilience.md` and the README's catalog paragraphs now describe the index owner, its three feeds, reconciliation, JSONL authority and rebuild on loss; no doc describes a request-path walk | G-1c | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/g-1d`) |
| G-3 | Done | No audience, no projection: build and serialize snapshots only for subscribers | O-5, O-6a | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/g-3`; review round 1 addressed; CPU comparison and O-5's cross-check owed to the orchestrator) |
| G-3a | Done | Streaming progress for a session with no subscriber is no longer projected (`flushPendingProgress` and `message_end`'s finalized frame both return before `projectMessage`/`safeJson`); the row's measured stretch is the O-6a CPU profile's flush subtree 551.7 → 193.5 ms — see the handoff | G-3 | orchestrator-dispatched deepseek-worker, 2026-09-29 (branch `hardening/g-3a`) |
| C-2 | Done | "Connected" follows the transport (D-2); chat restoration shows its own loading state | C-1 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| C-5 | Done | Back off an unreachable non-selected Gateway profile; record pool attempts and episodes | O-4 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| G-10 | Done | Durable-write audit: no process-wide serialization of fsyncs, no fsync on reads | O-5 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| G-10a | Done | Connection owner: a read (e.g. knowledge.raindrop.read) must not fsync — skip an unchanged provider observation in ConnectionOwner.recordProviderObservation, preserving stateRevision/updatedAt semantics | G-10 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| C-3 | Done | Faster retry (D-4): about 5 s transport-open deadline, immediate retry on path change | C-1 | orchestrator-dispatched deepseek-worker, 2026-09-28 (the O-6b blackhole p95 and the 90 s E2E re-run are the orchestrator's quiet-host run) |
| C-4 | Done | Truer liveness (D-4): any inbound frame proves liveness | O-4 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| C-6 | Done | Cancel frame for disposable reads; a retried `session.open` joins the in-flight one | O-3 | orchestrator-dispatched deepseek-worker, 2026-09-28 (the O-6a slow-open confirmation and the qualification run are the orchestrator's) |
| G-12 | Done | Server-side deadlines, concurrency caps and heap-pressure shedding with typed retry hints | O-3, O-5 | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/g-12`; review round 1 addressed; the O-6a heap-limit-lowered run is the orchestrator's) |
| G-2 | Done | Cold open in bounded time from the index and a single-file fence | G-1c | orchestrator-dispatched deepseek-worker, 2026-09-28 (see handoff: 100–200 MiB cold opens hold at 951 ms max on a load-56 host and 494 ms on a load-10 one; the parse is 45–56% of a slow open; the quiet-host multi-iteration p99 confirmation is the orchestrator's) |
| G-7 | Done | Reconnect diet: send only what changed | O-1, O-6a | orchestrator-dispatched deepseek-worker, 2026-09-28; both review rounds addressed, R-1/R-4 own the real-reconnect measurement |
| G-11 | Done | Event-loop budget: find and bound every synchronous task over 50 ms | O-5, O-6a | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/g-11`): the Slot's publish-time full-transcript summary walk is now an incremental fold (largest CPU-profile run 86.9 ms → 4.8 ms); the dominant remaining stretches belong to in-flight G-8c (session-search) and G-1c (catalog/registry), so the combined O-6a max/p99 is re-measured by the orchestrator after they merge — see the handoff |
| G-9 | Done | One background-work scheduler that yields to requests; measure the libuv pool size | O-5, G-1b | orchestrator-dispatched deepseek-worker, 2026-09-28 (the libuv pool comparison and the O-6a latency confirmation are owed by the orchestrator's quiet-host run; the background `node_modules` clone in this worktree is private) |
| G-4 | Done | Outbound queue coalescing of superseded snapshots (one covering `session.rebaseline`) and summary revisions by key | G-3 | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/g-4`; review round 1 addressed: a superseded sequence is covered by the `session.rebaseline` that replaces it; round 2: only state the snapshot fully re-states and only its own runtime generation, a one-shot frame is a fence; round 3 after merging `hardening/integration`: the replacement path's client is asserted on the authority it installs, covered `session.snapshot`/`session.rebaseline` alike, and the round's fixtures speak protocol 6); the O-6b bandwidth-stream before/after numbers are owed to the orchestrator's quiet-host runs |
| G-5 | Done | Byte budget for live runtimes and an explicit heap limit | O-5 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| G-5a | Done | The Mac app admits the argv G-5's launcher execs: Stable admission, registration repair, Debug admission and `mac verify` require the launcher's exact command; a refused admission names its check; the menu keeps Pause when admission refuses; `protocol_mismatch` records the peer's version | G-5 | direct session on `main`, 2026-09-29 (see handoff) |
| E-3a | Done | LAN endpoint (D-5), Gateway side: pinned TLS listener bound to the private LAN address | O-1, O-2 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| E-3b | Done | LAN endpoint: advertise endpoints and pin in pairing and hello | E-3a | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| E-3c | Done | LAN endpoint, phone side: pin validation, staggered race, seamless fallback (race, pin and denial record land; HTTP routes and the two-leg E2E cases do not - see the handoff) | E-3b, C-3 | orchestrator-dispatched deepseek-worker, 2026-09-29 |
| E-3c2 | Done | Finish E-3c: HTTP routes (live view, media, uploads) use the winning lane's base with the same pin; the two-leg E2E cases (Tailscale leg blackholed 90 s → no visible disconnect; LAN leg blocked → Tailscale wins within stagger + one handshake; pin mismatch sends no credential) in `scripts/ios-gateway-e2e-test` (both halves land: the routes follow the winning lane's base and pin, and the E2E's legs — including an upload through the blackhole — pass) | E-3c | orchestrator-dispatched deepseek-worker, 2026-09-29 |
| E-3d | Done | LAN endpoint on by default in the release once E-3c's E2E cases pass; the setting is the kill switch | E-3c | orchestrator-dispatched deepseek-worker, 2026-09-29 |
| G-13 | Blocked | Restart and reconnect storm: startup budget and a qualification case | G-1c, O-6b | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/g-13`): `gateway.startup-budget` (5 s, with the slowest step) and `impairment.restart.startup_ms`/`.close_to_listening_ms`, read from the new process's own record; the case reports G-13's criterion with its numbers. Blocked, not Done: the criterion is a "Done when" and no run has met it — the measured misses are host-bound plus two named causes (the old process's 2 s `work-settle` grace and the storm upgrades serialized by `DeviceStore`'s credential mutex), which need rows of their own or a quiet-host R-1 run; see the handoff |
| G-8 | Done | Background work audit: delete or bound each unowned or repeating job | O-5 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| G-8a | Done | Discovery lane retries an atomically replaced `status.json` (bounded, like the watcher lane) so a replace is not `extension.artifact-rejected`; see G-8 handoff | G-1c | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/g-8a`; the atomic-replace check fails 4/4 before the fix and passes; the watcher lane's pending debounce also owns the retry now) |
| G-8d | Done | Bound the 750 ms ambient artifact discovery pass by change and make its 1,024-entry truncation impossible or visible; see G-8 handoff | G-8a | orchestrator-dispatched deepseek-worker, 2026-09-28 (same branch: an unchanged `status.json` costs one stat and no read, every entry is examined within a bounded number of passes, and a pass that still stops reports `extension.discovery-truncated`) |
| G-8b | Done | Bound the Mac app status poll's child processes and per-poll payload re-hash (user/security decision in "Decisions still open"); see G-8 handoff | G-8 | orchestrator-dispatched deepseek-worker, 2026-09-28; review round 1 addressed; back to Claimed because the app-level cadence measurement the row asks for is still owed (see handoff) |
| G-8c | Done | Persisted session-search index keyed by the catalog's verified file facts, so a start re-reads only what changed; the semantic pass and the index's own writes are time/slice bounded (see handoff) | G-9, G-1c | orchestrator-dispatched deepseek-worker, 2026-09-28; review round 1 addressed |
| E-1 | Done | Document Tailscale flap diagnosis and user-side checks; the evaluation day confirms | O-2, O-7 | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| T-1 | Done | Pre-existing test race: registry extension-artifact discovery tests treat an awaited `discoverExtensionArtifacts()` as a barrier; wait for a pass that settles (three tests, one a false green) | G-1a (Registry zone) | orchestrator-dispatched deepseek-worker, 2026-09-28 (the helper now waits out an in-flight pass and awaits one it starts; G-1c fixed the oversized-header sites and this branch fixes the two in "rejects foreign producer session headers…") |
| T-2 | Done | `GatewayConnectionEpisodeRecorderTests/blockedMainActorIsMeasuredAndReported` (O-4) was killed once ("Test crashed with signal kill") when run with four other suites on integration, then passed 3/3; find whether the 5 s main-thread block trips a hosted-test watchdog and bound the block so the test cannot be killed while still proving the stall record | O-4 | orchestrator-dispatched deepseek-worker, 2026-09-28; no hosted-test watchdog exists (a 5 + 10 + 20 s block probe passed); the kill came from another worktree's run on the same default-lane simulator (`E816D194…`), not from the block — see the T-2 handoff and T-3; the block is now the named `mainStallTestBlock` (5 s) in both phases |
| T-3 | Done | Default-lane iOS runs must serialize on `~/.tron/internal/ios-test/lease.lock`, but runs from three worktrees held the one owned simulator (`E816D194…`) at the same time and killed each other's host app (see the T-2 handoff); the lease was bypassed because `--lane NAME` was consumed by the lease holder and not passed to the command it started, so the command leased the named/other lane while provisioning the default lane's simulator (`ios-test-G7*` lanes: lease file, no marker); the lane now travels with the command and a command that inherits a lease for another lane is refused | none | orchestrator-dispatched deepseek-worker, 2026-09-28 |
| T-4 | Done | `GatewayLogExportTests/byteEnvelopeReservesTheChatTrace` is SIGKILLed when it shares a test process with `GatewayConnectionEpisodeRecorderTests` (main-stall test blocks the main thread twice for 4 s); each passes alone (bundles `20260928T203739Z-run.InevV5`, `20260928T201219Z-run.jNGHmH`). Find the killer and make both robust in one process | T-2 | orchestrator-dispatched deepseek-worker, 2026-09-28; the killer is XCTest's per-test execution-time allowance (XCTestCore reports `Restarting after unexpected exit, crash, or test timeout`) SIGKILLing the app (`Test crashed with signal kill`), and the test it lands on is the process's CPU-heaviest because `IOSClientDiagnosticBuffer.redactedMessage` matched URLs super-quadratically (3 ms at 512 characters, 654 ms at 4,096; the export test 8.646-10.297 s -> 0.072 s); see the T-4 handoff |
| T-5 | Done | `AppModelInvalidationTests/providerCatalogResponsesRemainKeyed` hit its 5 s watchdog once in the full iOS run on `419a67a53` ("blocked on a wait that ignores cancellation"); passes alone 3/3. Check whether it waits on a write-log index a C-6 cancel frame can shift (as F-1 found) and make it robust. **Blocked on validation only:** the scenario no longer indexes the write log by position (it finds each read by method and scope), but the owned iOS lane was leased by another worker for this whole session, so the suite was never compiled or run; see the handoff | F-1 | orchestrator-dispatched deepseek-worker, 2026-09-29 |
| F-2 | Done | O-6b `bandwidth` page leg fails on integration with `session.sync` conflict "Session synchronization is no longer owned by this token" (run `20260928T235606Z-multi-session-471100`); `--cases none` passes. Decide driver artifact (concurrent page mounts on one connection) vs Gateway regression (C-6/G-12 barrier handling) and fix at the owner. **Fixed in the driver** (F-2 second pass): the earlier "Gateway regression" reading came from matching the refusal to the wrong frame — the first `session.open`+`session.sync` on the fresh connection succeeds (104-byte answer, then a successful `session.presentation.set`), and the refusals are the six concurrent page lanes racing the Gateway's documented one-presentation-per-mobile-connection rule. The same conflict storm (264) is present in the `--cases bandwidth` run cited as passing, so the reconnect is not the trigger; the lane now abandons a superseded page with the phone's own `cancel` frame instead of synchronizing it. Repro `--cases blackhole,bandwidth` is green (run `20260929T073639Z-multi-session-e06f2e`: `link_use` 0.993, `max_in_flight` 6, zero `session.sync` conflicts); see the handoff | O-6b | orchestrator-dispatched deepseek-worker, 2026-09-29 (second pass on branch `hardening/f-2`) |
| F-3 | Done | A protocol mismatch reads as a generic transport failure on the phone: the Gateway closes 1008 without a machine-readable reason, so the phone retries forever and shows no "update this Mac" state (2026-09-29, a protocol-5 MacBook Pro profile left the Knowledge dashboard loading). Send a typed close reason for protocol mismatch; the phone stops retrying that profile and shows which side needs updating | E-3b | orchestrator-dispatched deepseek-worker, 2026-09-29 (branch `hardening/f-3`): the Gateway refuses an unspeakable hello with application close 4006 (`PROTOCOL_MISMATCH_CLOSE_CODE`) plus a JSON close reason carrying `{protocol_mismatch, gatewayProtocol, minProtocol}`; the phone classifies that close as non-retryable `protocol_mismatch` and its stop names the build to update, for the lifecycle and the dashboard pool, with the device detail's Status group showing the reason durably |
| T-6 | Done | Load flakes in `runtime-registry.integration.test.ts`: "keeps a large streamed write visible through snapshot recovery and canonical handoff" (fails intermittently on `main` too) and "does not reopen an unchanged ambient artifact for a live slot" (G-8a, failed once in a combined run, passes alone 3/3). Make both deterministic | G-8a | orchestrator-dispatched deepseek-worker, 2026-09-29 (branch `hardening/t-6`; neither was a product race: the write case spent its 5 s `waitUntil` guard streaming 3,188 provider chunks, and the discovery helper capped its wait for a running pass at 5 s — see the handoff) |
| C-7 | Done | Dashboard-pool event consumption stops after a failed initial connect (see the C-5 handoff): a successful reconnect brings the socket back but nothing consumes `client.events`, so a background profile stops receiving summaries, `system.stopping` and `transport.disconnected` until its entry is recreated | C-2 | orchestrator-dispatched deepseek-worker, 2026-09-28 (branch `hardening/c-7`; the connection epoch now owns its event reader) |

### Phase 2 — Release and one evaluation day

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| R-1 | Done | Release candidate: every synthetic exit criterion passes, merge to `main`, prepare Mac and iOS builds | all Phase 1 | orchestrator, 2026-09-29: merged to `main` with four known misses the user accepted in writing (see handoff); F-4..F-7 own them |
| F-4 | Blocked | Streaming under a 2 Mbit/s cap: pong waits ~24 s behind superseding stream state (2 misses per run in `bandwidth-stream`); pongs must never wait behind stream bytes | R-1 | orchestrator-dispatched deepseek-worker (branch hardening/f-4), 2026-09-30; `ws.bufferedAmount` cannot bound bytes already accepted into kernel/path buffers, so the required mechanism and qualification remain outstanding (see handoff) |
| F-5 | Blocked | Prompt admission p99 target 250 ms in `multi-session` | R-1 | orchestrator-dispatched luna-worker (branch hardening/f-5), 2026-09-30; safe early response implemented, but the final one-iteration candidate p99 was 258.191 ms (target miss; see handoff) |
| F-6 | Blocked | Event-loop delay p99 20 ms target; attribute with a CPU profile | R-1 | orchestrator-dispatched deepseek-worker (branch hardening/f-567), 2026-09-30; catalog metadata parsing now yields through G-9; diagnostic p99 34.630 ms/max 274.951 ms misses target and needs a qualifying quiet-host run (see handoff) |
| F-7 | Blocked | Warm `session.open` p99 300 ms target in `multi-session` | R-1 | orchestrator-dispatched deepseek-worker (branch hardening/f-567), 2026-09-30; available F-567 runs all exceed target (368–3,559 ms); prior 131.8 ms run was baseline, not candidate (see handoff) |
| T-7 | Done | The profiler prime's first `session.list` waits on a named catalog-readiness deadline (90 s) instead of the 40 x 250 ms measured-retry budget, which a 3,000-file fixture outlasts on a busy host | F-5, F-6, F-7 | orchestrator, 2026-09-30; `scripts/tron-profile-gateway-driver.mjs`, `test-tron-profile.py` OK |
| R-2 | Ready | User installs the Mac Release build and the iOS build; agent verifies the deployment | R-1 | E-3d owes one user action: prove the LAN kill switch on the installed release (`launchctl setenv TRON_GATEWAY_LAN_ENDPOINT off`, user restarts the Gateway, `lan.listener state=disabled reason=setting_off` appears) |
| R-3 | Ready | User runs Tron normally for at least 24 hours, then exports phone logs | R-2 | |
| R-4 | Ready | Analyse the day with the triage tool; check real-use exit criteria; open Phase 3 rows | R-3 | Read `lan.listener` transitions and `transport=lan` on `http.upgrade` to see whether the lane carried the day (E-3d) |

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
- **Owning files:** `packages/ios-app/Core/Gateway/GatewayClient.swift`
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
  `packages/ios-app/Core/Gateway/GatewayClient.swift`,
  `packages/ios-app/Sources/State/AppModel.swift` (`lifecycleRecordDiagnostic`,
  scene handling), `packages/ios-app/Core/Support/AppLog.swift`,
  `packages/ios-app/Core/Support/IOSClientDiagnostics.swift`.
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
  `packages/ios-app/Core/Gateway/GatewayClient.swift` (handshake deadline),
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
- **Owning files:** `packages/ios-app/Core/Gateway/GatewayClient.swift`
  (`startLivenessWait`), `packages/ios-app/Core/Gateway/GatewayConnectionPolicy.swift`,
  `packages/protocol-fixtures/gateway-connection-contract.json`,
  `packages/gateway/src/transport/connection-policy.ts` (parity only).
- **Do:**
  1. Track the last inbound frame time (messages, pongs, any data).
  2. Send the ping on every tick of the shared ten-second wakeup grid T1-NET
     fixed, and declare the link dead only when that ping's pong misses its
     deadline and no inbound frame of any kind arrived after the ping was sent
     (orchestrator deviation from this plan's first draft, "send a ping only if
     nothing arrived": the grid is a user-approved energy decision C-4 must not
     reverse, and D-4's queued-pong case is covered by the post-ping frame test
     alone).
  3. Dead-link detection stays within 18 s of the last inbound frame: the tick
     is never later than one interval after it and the deadline is 8 s after the
     tick.
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
  `packages/ios-app/Core/Gateway/GatewayClient.swift` (`expire`,
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
  any request-path walk. (The in-memory half is covered by this row's cases; the
  O-6a confirmation is owed by the orchestrator, which owns the probe.)
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
  4. Delete the read-triggered durable write: today `materializeCatalogSnapshot`
     starts `persistDurableCatalogIndex` (two fsyncs of the index) from
     `session.list` and `session.open`; after G-1c no read path appears in
     G-10's fsync list.
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

### G-10a — A read never fsyncs an unchanged connection observation

- **Goal:** the last read-triggered durable write leaves the read path:
  observing a connection that did not change writes nothing.
- **Owning files:** `packages/gateway/src/integrations/connection-owner.ts`
  (`recordProviderObservation`) and
  `packages/gateway/src/integrations/connection-owner.test.ts`. The caller is
  `packages/gateway/src/knowledge/connectors.ts` (`observe` →
  `readRaindrop`), which awaits the observation on every read attempt.
- **Do:**
  1. `recordProviderObservation` computes the four projected fields
     (`credentialAvailability`, `providerIdentity`, `providerDisplayName`,
     `health`) and returns without saving when all four already hold those
     values, so an unchanged observation does not bump `updatedAt` or
     `stateRevision`.
  2. Keep the admission checks, the mutex, and the await in the caller exactly
     as they are; only the unchanged write is skipped.
- **Failure modes to write first:** an unchanged observation still writes (the
  state document's mtime and `stateRevision` must not move); a changed
  observation is dropped, so a state transition is lost or a projection goes
  stale.
- **Checks:** `npx vitest run src/integrations/connection-owner.test.ts`, plus a
  read-path case over `knowledge.raindrop.read`.
- **Done when:** a read cycle with no state change reports no new durable write
  in the O-5 counters, and a changed observation still persists before its
  response.
- **User action:** none; ships in the release (R-2).

### G-12 — Deadlines, caps and load shedding

- **Goal:** overload is predictable: typed `busy` with a retry hint, never a
  one-minute wait.
- **Owning files:** `packages/gateway/src/transport/server.ts`,
  `packages/gateway/src/transport/gateway-service.ts`,
  `packages/gateway/src/sessions/runtime-registry.ts`,
  `packages/ios-app/Core/Gateway/GatewayClient.swift` (honour the hint).
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
- **Done when:** requests and bytes per reconnect meet the recorded target
  (the target list and the delivered request set are fixed by this task's
  checks; R-1 and R-4 own the real-reconnect request/byte measurement).
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
- **Do:** per connection, a newer `session.summary` replaces the unsent summary
  of its session, and a newer `session.snapshot` supersedes the unsent sequenced
  state of its own runtime generation that its own state fully re-states, up to
  its own `eventSequence`, sent as the `session.rebaseline` that covers them and
  carries the connection's installed `subscriptionToken`; a superseded sequence
  is never left uncovered, and a sequenced frame whose effect installing a
  snapshot does not perform (a failure receipt, a revision bump, an editor
  directive), or one of another runtime generation, is a fence the queue never
  drops across. Order
  relative to other events and synchronization barriers is preserved and the
  frame `ws` is already writing is never recalled. The 8 MiB cap stays as the
  backstop; `connection.outbound-capacity` names the topics of the oldest and
  next frames.
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
     protected. Record `runtime.loaded` and `runtime.evicted` with bytes. As
     implemented, the budget is **eviction pressure only**: an admission it
     cannot fit is served over budget and named on its `runtime.loaded` record
     (G-12 owns refusal under the real heap limit), and nothing is retired when
     retiring could not help — see the G-5 entry below.
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
  hello), `packages/ios-app/Core/Gateway/GatewayProfile.swift`,
  `packages/ios-app/Core/Gateway/GatewayProfileStore.swift`.
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
- **Owning files:** `packages/ios-app/Core/Gateway/GatewayClient.swift`,
  `packages/ios-app/Core/Gateway/GatewaySocketTransport.swift` (pin check in
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
| reconnect after path return p95 | 15.8 s in a 20 s blackhole run: one 15 s attempt was in flight when the path returned plus the phone's 2 s backoff after it. Pessimistic by construction: the relay never forwards an attempt that is still inside its handshake deadline when the path returns, so 13.8 s of that figure is the model's, not the phone's (a real TCP path would retransmit and connect in a second or two); the conservative baseline is kept deliberately. C-3's target is not met by `main` either way | | |
| Gateway restart with all clients | the profiler replaced the Gateway in 5.6 s (busy host); every one of the six clients reconnected from its own socket's close, the slowest 12.5 s; 14 refused connects; 20 requests from the restart on, 2 of them over 1 s | | n/a |
| requests / bytes per reconnect | | | |
| episodes by cause (triage) | n/a | n/a | |
| visible disconnects during Tailscale flaps | n/a | n/a | |
| persisted log volume per day | | (estimate) | |

### Impairment cases (O-6b)

One short smoke run of the final code proves every case runs and reports and
shows the shape of `main`; the full-length default baseline (90 s bandwidth
leg, 90 s blackhole) is owed on a quiet host, and the row is Blocked on it.
Read the numbers as one sample per case.

- Command: `scripts/tron-profile gateway --scenario multi-session --iterations 1
  --catalog-files 200 --catalog-mib 32 --mixed-seconds 30 --blackhole-seconds 20
  --bandwidth-seconds 30 --no-build` (report
  `20260928T133125Z-multi-session-67d44f` under
  `~/Library/Developer/Tron/profiles/gateway/`; host busy, 1-minute load 9–18).
- Blackhole (the mobile path delivers nothing for 20 s): the client kept its
  socket open and silent for 19.0 s after its last inbound frame and abandoned
  it on a counted pong miss (`abandonedOnMiss: true`), and its one attempt
  during the outage burned the phone's 15.0 s handshake deadline (the relay
  held that attempt with no answer, so the Gateway never saw it). Recovery from
  the path's return to a ready mounted chat was 15.8 s: the rest of that
  in-flight attempt plus the phone's 2 s backoff. This is the number C-3 has to
  move. The earlier 18.0 s silence was the leg's own clock, not a pong miss.
- Bandwidth cap (2 Mbit/s = 250,000 B/s): the numbers above are from the
  serialized leg (one page in flight, 39 kB of wire each, ping-to-pong
  105–171 ms against an 8 s deadline): the link was busy, but one page can never
  put more than one page ahead of a queued pong, and the Gateway's queue never
  held more than one frame (no `connection.outbound-capacity` record), so "zero
  pong misses, no close for capacity" was true by construction. The leg now
  keeps `bandwidthInFlight` (default 6) pages in flight at once, each on its own
  session, and reports the peak (`.max_in_flight`), the load it asked the
  Gateway to send (`.offered_in_flight_bytes`, `.offered_in_flight_wire_bytes`)
  and the mobile's longest ping-to-pong round trip (`.max_ping_to_pong_ms`).
  `validate_impairment` rejects a leg that filled less than half its cap, and the
  metering rule is gone (the meter's "delay" was the bytes the cap carried,
  which is `link_use` again). **Numbers for the new leg shape are owed** with
  the rest of the baseline.
  What this leg cannot do at the default 2 Mbit/s is stated plainly rather than
  claimed as a pass: six pages are about 234 kB of wire against 8 s × 250 kB/s =
  2 MB of wire, and six pages are under the 8 MiB per-connection backstop, so
  neither a pong miss nor a capacity close is reachable at this cap. The round
  trip and the offered load are what it reports; the case that can back the link
  up is `bandwidth-stream` below. `main` has no
  `connection.outbound-capacity` record inside the leg's window
  (`impairment.gateway_outbound_capacity_records: 0`).
- Bandwidth-stream (a cap below what the running sessions produce): the case is
  the fourth review's follow-up, because the page leg's cap could not reach a
  backlog. The first shape capped at 0.3 Mbit/s and did not reach one either:
  the fourth review measured 295,621 B/s of decoded state leaving seven streams
  as 11,901 B/s of wire against that cap, so `link_use` was 0.32 — the cap never
  bound and the arithmetic that said a full 8 MiB queue would sit behind a
  0.3 Mbit/s path ("320 kB of wire, 8.5 s") counted decoded bytes against a wire
  rate. The default is now 0.08 Mbit/s (10,000 B/s), below the measured wire
  production of 11,901 B/s, and the leg is rejected unless it kept at least 0.9
  of that cap full, held at least two mounted streams, and showed a backlog: its
  own round trip (each pong charged to the ping it answers, reset per leg)
  longer than the same run's uncapped round trip, a pong miss, or a close.
  **Numbers for this leg are owed** with the rest of the baseline.
- Restart (every connected client live): the profiler's stop, start and health
  check took 5.6 s; all six clients retried from the moment their own socket
  closed (14 refused connects in total) and every one was ready, the slowest
  12.5 s. The storm now spans the restart: 20 requests from the measured
  clients, the first 862 ms after the new Gateway answered health — the mobile's
  1.5 s remount — of which 2 took over 1 s. That is the number G-13 has to move.
  Requests are classified by outcome: the ones the new Gateway served are the
  storm (their start can precede the health stamp the profiler writes seconds
  later) and the ones that failed are counted separately as
  `impairment.restart.downtime_requests` instead of being dropped.
- `main` has no `connection.outbound-capacity` records inside the capped legs'
  windows (`impairment.gateway_outbound_capacity_records: 0`), so G-4 has
  no capacity evidence yet either way. The previous claim that the capped path
  "really does fill the Gateway's buffers" was not supported: at 2 Mbit/s the
  8 MiB per-connection queue backstop is reached only if a burst offers more
  than 8 MiB of pages at once, and the leg must stay under it to be passable
  after G-4. G-4's capacity evidence needs a leg whose queued frames are
  superseded state (one session streaming faster than the cap), not concurrent
  distinct pages; that case is owed, and `bandwidth-stream` is its shape —
  whether the default 30 s leg reaches the backstop is part of the owed
  baseline, not something the leg is tuned for.

## Handoff log

### 2026-09-29 — R-1 release candidate (orchestrator)

- Gates on `hardening/integration` after the final `main` merge (no conflicts): Gateway build + tsc clean; 710/710 across transport, config, client, session-archive and runtime-registry; `scripts/ios-gateway-e2e-test all` green (162 s) and `run-lan` green (108 s); full iOS unit run 1,976 passed, 2 failed — `ChatViewScrollHarnessTests/displacedRetainedResume` and `resourcePickerSourceSelection`, which fail identically on a clean `main` worktree (from `main`'s transcript work, not this plan).
- Candidate `multi-session` runs (3 iterations each, all cases): `20260929T111158Z-multi-session-b0aca7` (host load 3→1) and `20260929T113821Z-multi-session-6ff73f` (load up to 15). The alternating `main` runs (`…d0ed0e`, `…2e6140`) failed in iteration 1 on the pre-F-2 driver's `session.sync` conflict, so there is no same-host `main` pair; the provisional column stands.
- Met: `session.list` p99 94–127 ms (one 1.5 s iteration under load); cold large open p99 ~530 ms; catalog walks 0; blackhole recovery 17–70 ms; restart reconnect max 5.8–7.2 s with 0 requests over 1 s in the quiet run (G-13's criterion; 1 in one loaded iteration); pong misses 0 outside the stream case.
- Missed (user accepted in writing 2026-09-29, "Merge now, fix misses after"): bandwidth-stream ping-to-pong ~24 s / 2 misses per run (F-4); prompt admission p99 ~610 ms (F-5); event-loop p99 ~38 ms and max 217 ms quiet / 1.4 s loaded (F-6); warm open p99 ~335 ms (F-7).
- Installed for rollback: Mac app 0.1.0 (8); launcher still logs a refused stale external selection of `0.1.0-beta.7-source-1790559163986`.

### 2026-09-30 — F-567 qualification attempt (worker)

- Before isolated-test/code work — failure modes to cover: a multi-megabyte transcript can deliver many buffered readline records without a scheduler turn, delaying request callbacks; the new scheduler handoff must not drop, reorder or change catalog metadata/counts while parsing continues.
- Result: no product change. The required full-size CPU-profile run
  (`scripts/tron-profile gateway --scenario multi-session --no-build --iterations 1 --cases none --cpu-profile`)
  exited 6 in `prime`: `session.list` returned retryable `busy` (“The session
  catalog has not been read yet”) through the driver's 40 × 250 ms retry limit.
  Its fixture log records no first `catalog.reconciled` before the 11.5 s prime
  window closed. No F-5/F-6/F-7 metric was produced, so the rows remain Blocked.
- Evidence: failed run
  `~/Library/Developer/Tron/profiles/gateway/20260929T234124Z-multi-session-0d7ab5`
  (`driver-prime.log`, `fixture/gateway.jsonl`, prime CPU profile). A 400-file /
  96 MiB smoke completed at
  `~/Library/Developer/Tron/profiles/gateway/20260929T234418Z-multi-session-0dc352`,
  but the host was heavily loaded (1-minute load 66 on 18 CPUs, one simulator
  active), producing only one sample and invalidating it as qualification or
  before/after evidence. It is not used to claim any target.
- Finding: first full-size run makes the existing prime retry horizon shorter
  than this fixture's first catalog cut on this run. That is a harness/readiness
  boundary, not sufficient evidence to raise a timeout or alter production
  behavior. The prior R-1 artifacts' O-3 spans and delay histograms cannot
  identify a new fix's same-run effect; no change was made speculatively.
- Changes: plan status and handoff only.
- Deviations: blocked rather than claim the target without quiet-host numbers.
- For the next agent: after the fixture's catalog-readiness boundary and host
  contention are resolved, retry the exact full-size CPU-profile command on a
  quiet host, inspect `rpc.completed` stages/unaccounted time for prompt/open,
  `gateway.resources` event-loop records and the profile from the mixed window;
  implement only an owner-level cause supported by that evidence, then rerun
  against an equivalent baseline and candidate before marking any row Done.

### 2026-09-30 — F-567 measurement and owner fix (worker)

- Change: `buildCatalogSessionInfo` now yields every 256 transcript entries via
  G-9's existing background scheduler. The focused regression protects full
  row preservation; no second yield mechanism was added. Slow `rpc.completed`
  spans now name runtime-slot and command-lane/inventory admission waits,
  pending/completed durable receipt writes, prompt marker persistence, and
  response write.
- Evidence: full-size profile
  `~/Library/Developer/Tron/profiles/gateway/20260930T010618Z-multi-session-74bbd7`
  (dirty diagnostic run, 1 iteration, host load 3.55/7.27/19.18). Catalog
  reconciliation completed 3,000 files in 5.620 s, versus 22.479 s in the
  earlier diagnostic under load 18; this is indicative, not an equivalent-host
  comparison. The mixed-window event-loop p99/max was 34.630/274.951 ms and
  remains above the 20 ms p99 target; F-6 stays Blocked pending a quiet-host
  qualification. No per-task CPU attribution was obtained for this run.
- F-5: prompt-admission p99/max was 1,224.560 ms in this one-iteration run.
  Its retained `rpc.completed` record has `unaccountedMs=1061` and no receipt,
  marker, or lane stage breakdown, so the earlier 360/501/260 ms attribution is
  unverified. F-5 remains Blocked; no durability semantics were changed.
- F-7 remains Blocked. The 131.8 ms result came from baseline commit
  `3c5711a77951`, not this candidate. Available candidate runs report warm-open
  p99 2,152 ms (`003413Z`), 3,559 ms (`004726Z`), 368 ms (`005901Z`), and
  509.272 ms (`010618Z`), all above the 300 ms target.
- Validation: `npm run build`; focused `catalog-discovery.test.ts` and
  `command-receipts.test.ts` (30/30); the five-file rerun passed 317/318 tests.
  One pre-existing timing assertion in `request-span.integration.test.ts`
  failed because a 100 MiB cold-open sample completed in 86 ms, below its
  `>100 ms` fixture floor; `runtime-registry.integration.test.ts` and
  `session-archive.integration.test.ts` passed. `npx tsc --noEmit -p .`,
  `python3 scripts/check-documentation-policy.py`,
  `scripts/personal-info-guard.sh`, and `git diff --check` passed. A final
  qualification profile was not run: host load had risen to 22.66/18.77/17.96.
- Changes: catalog owner, focused regression, prompt request-span stages and
  this task status/handoff; no changes to thresholds or deadlines.

### 2026-09-30 — F-5 · Blocked · worker session (branch `hardening/f-5`)

- Change: only `session.prompt` responds after its operation resolves while its completed receipt remains in the per-command lane. Pending receipt durability remains before execution; same-command duplicates join the lane. The existing RPC work owner stays in Gateway drain through receipt completion, and a post-response receipt-write failure marks that owner suspect, logs `receipt.completed-persist-failed`, and leaves it blocking drain. Foreground prompts start marker persistence before response without awaiting fsync; the exact RuntimeSlot ownership write remains tracked, retried, and diagnostic on failure. Marker clear waits for an in-flight mark. Other receipt-backed methods retain completed-before-response semantics. `rpc.completed` breakdowns count the detached receipt/marker writes, and successful prompts at/above 250 ms persist the breakdown.
- Failure modes written before implementation: (1) crash after response leaves a durable pending receipt; a duplicate reports outcomeUnknown and never executes; (2) a duplicate during completion persistence waits and receives the stored result; (3) completion-write failure cannot alter the sent response and leaves a suspect drain owner; (4) drain retains ownership through the in-flight write; (5) marker failure stays observed, retried/blocked and diagnostic without an unhandled rejection; (6) clear cannot overtake its mark.
- Evidence: focused receipt tests pass 30/30, including early result + held duplicate lane, process-loss pending-fence recovery, and failed completion write retaining a suspect work-registry owner; receipt-backed prompt-span case 1/1; full `runtime-registry.integration.test.ts` 245/245 and six-file transport merge gate 135/135 pass. `npm run build` and `npx tsc --noEmit -p .` pass. The `request-span.integration.test.ts` cold-open case was also tried and failed only its existing timing floor (`84 ms`, expected `>100 ms`; same fixture-floor issue recorded in F-567 history).
- Measurement: same-host base `f820546ff4db` run `20260930T075051Z-multi-session-444352`: prompt admission p50/p99/max `53.878/449.884/449.884 ms`, host load `15.34/13.28/11.43`, one booted simulator. Candidate runs: `20260930T075356Z-multi-session-8ae30f` (before prompt-specific 250 ms log threshold) `25.960/291.491/291.491 ms`, load `3.45/9.69/10.38`; final code `20260930T080008Z-multi-session-865198` `26.773/258.191/258.191 ms`, load `1.99/4.30/7.52`. The 3,000-file/2,048 MiB fixture ran with `--no-build --iterations 1 --cases none`, plain Node 22.22.0. Results are indicative one-iteration measurements, not equivalent-load proof, and final p99 remains 8.191 ms over the 250 ms target, so the row stays Blocked. The final retained `fixture/gateway.jsonl` has no `session.prompt` `rpc.completed` records (only `session.list` records); therefore it supplies no prompt stage breakdown despite the threshold/logging change. No stage breakdown is claimed.
- Deviations/left: no separate marker-failure integration test was added; the existing RuntimeSlot owner/retry path was retained and the source was reviewed, while the receipt failure/drain cases are directly covered. Repeat qualification on a comparable quiet host and capture prompt `rpc.completed` evidence before marking Done.

### 2026-09-30 — F-567 independent-review fixes (worker)

- Fixed refresh/search deadlock: catalog waiters leave the request-competing
  signal while waiting; regression covers a live `RequestSpan` with scheduler
  contention and a 600-entry refresh.
- Corrected F-5 attribution to unverified and returned F-7 to Blocked; candidate
  warm-open p99 evidence is 368–3,559 ms. Focused catalog tests passed.
- Added a receipt-backed prompt-span integration case for pending/completed
  persistence stages and same-command lane wait; F-5/F-6/F-7 still need valid
  qualification evidence.
- For the next agent: rerun F-5/F-6 on a quiet host after checking `rpc.completed`
  `receipt.pending-persist`, `receipt.completed-persist`,
  `session.prompt.marker-persist`, `session.prompt.runtime-lane`,
  `receipt.command-lane`, and `receipt.inventory-admission`. A product-level F-5 change would require an
  approved durability design; do not remove/relax receipt or run-marker fsyncs
  to satisfy latency.

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

### O-2 · Done · 2026-09-28 · orchestrator-dispatched worker (branch `hardening/o-2`)

- Result: the Gateway transport writes the three records it lacked.
  - `http.upgrade`, one per WebSocket upgrade: `outcome`
    (`opened`/`abandoned`/`rejected`), `phaseReached`
    (`request`/`auth`/`handshake`/`hello`), the four phase durations
    `acceptToUpgradeMs`, `authMs`, `handshakeMs`, `helloMs`, and the O-1 peer key
    once hello named it. Debug when it opens at hello within
    `UPGRADE_SLOW_WARNING_MS` (1,000 ms); warning when abandoned, rejected or
    slower.
  - `connection.inbound-silent` (warning), one per silence episode, when a
    heartbeat tick finds no inbound frame for `INBOUND_SILENCE_WARNING_MS`
    (12,000 ms), carrying `peerPath` (`direct`/`relay`/`offline`/`unknown`) and
    `peerRelay`.
  - `connection.inbound-resumed` (info) on the next inbound frame, with
    `silentMs`.
- The Tailscale read is a new bounded `TailscalePeerPaths`
  (`packages/gateway/src/transport/tailscale-peer.ts`): the existing CLI
  candidates, a 2 s timeout, one read in flight, the result reused for 10 s,
  joined to the socket's remote address (IPv4-mapped IPv6 normalised). It never
  rejects, never delays a heartbeat, and `admin/diagnose.ts` now imports
  `readTailscaleStatus` and `classifyPeer` from it instead of keeping its own
  candidate loop, parse and path expression.
- O-1's leftover review finding is closed: `connection-resilience.md` no longer
  says client-side and server-side connection IDs are different namespaces to be
  matched by time. "Collect evidence before recovery" now joins by the O-1 key
  (`gatewayConnectionId` ↔ `connectionId`; `clientId`/`attemptId`/`epoch` ↔
  `peerClientId`/`peerAttemptId`/`peerEpoch`), with a time window only for
  pre-protocol-6 logs. The "Interpret the diagnostics" table gained rows for
  `http.upgrade` (abandoned, rejected, slow open), `connection.inbound-silent`
  and `connection.inbound-resumed`. The heartbeat bullet and the README's
  transport paragraph state the two silence records and the 12 s threshold.
- Failure modes written before the tests, one case each: peer abandons at each
  phase; Tailscale CLI missing, slow or failing; many sockets silent at once
  (one shared capture); silence ends during the capture; remote address not in
  Tailscale status (loopback/LAN); a phone that pings every 10 s must never be
  reported silent; a failed read must not spawn a process per socket; a
  blackholed path must be visible from the Gateway log alone. The review response
  added: a client that only answers server pings is never reported silent and
  never reaches the path reader; a peer that leaves during authentication is
  abandoned at the auth phase; a refused WebSocket handshake is recorded; a first
  frame that is not JSON is refused at hello; a CLI that never settles cannot
  hold the reader; a `null` peer value cannot reject a lookup; `offline` outranks
  a remembered direct address; a direct peer reports no relay.
- Evidence:
  - `npm run build` is clean (`~/.tron/workspace/files/hardening/o-2/build.txt`).
  - `npx vitest run src/transport/tailscale-peer.test.ts src/transport/logger.test.ts
    src/transport/server-heartbeat.integration.test.ts src/transport/server-http-lifecycle.integration.test.ts
    src/transport/server-capacity.integration.test.ts src/transport/server-http-admission.integration.test.ts
    src/transport/server-revocation.integration.test.ts src/transport/sync-protocol.integration.test.ts
    src/transport/server-startup.integration.test.ts src/transport/request-span.integration.test.ts
    src/admin/diagnose.test.ts` passes 95/95 in 11 files
    (`~/.tron/workspace/files/hardening/o-2/focused-vitest.txt`). New cases: 8 in
    `tailscale-peer.test.ts` (direct, relay, offline, mapped address,
    loopback/LAN unknown, missing/slow/malformed CLI, candidate fall-through,
    shared and reused read, reused failure), 3 in
    `server-heartbeat.integration.test.ts`, 3 in
    `server-http-lifecycle.integration.test.ts` (abandoned before hello, refused
    at the authentication phase, refused at the hello phase).
  - Eight more neighboring suites (blob, compression, live-view,
    terminal-delete, upload, session-archive, rpc-idle-admission,
    stall-diagnostics) pass 92/92.
  - Blackhole (the Done-when's evidence, fault proxy against a fixture Gateway):
    in `server-heartbeat.integration.test.ts` a hold proxy carries the client's
    socket between virtual seconds 40 and 72 while the socket stays open; the
    Gateway log alone shows exactly one `connection.inbound-silent` (warning,
    `peerPath=relay`, `peerRelay=sfo`, message `has sent nothing for 17000ms`)
    and one `connection.inbound-resumed` (info, `silentMs: 47000`), in that
    order, with the socket never closed. A second case gates the path read until
    after the socket speaks again: `silentMs` is exactly 27,000 ms and the
    silence record still precedes the resume record.
- Changes: `feat(gateway): record upgrade phases and inbound silence (O-2)`,
  `fix(gateway): close the O-2 review findings`, then the second and third
  reviewers' rounds (see the three review responses below).
- Tasks added: none.
- Kept on purpose: `http.upgrade` for the Mac app's constant local probes is
  debug, like `connection.opened`, so it stays in the memory-only buffer; an
  attempt that never got past hello is `abandoned` whichever side ended it, and
  the side is named in `reason` (`peer_closed` only for a peer that vanished;
  the Gateway's own endings are `hello_timeout`, `shutting_down`, `superseded`
  and `device_revoked`, each recorded before the socket is closed) rather than
  splitting that outcome. Readiness and shutdown refusals are `info` on
  `http.upgrade` (they are expected and clients retry), so a startup retry storm
  adds no warnings; the shutdown destruction of a socket that never reached
  hello keeps the default warning level, where it already was.
- Reviewer's round (changes-required, 2026-09-28) and this response:
  - **Blocker, fixed — a pong-only client was reported silent on every tick.**
    A client that only answers the Gateway's pings is idle between them and its
    last pong is always ~25 s old at the next tick, so the old age-only rule
    wrote a false `connection.inbound-silent` per tick and ran the Tailscale CLI
    on a 25 s timer. `observeInboundSilence` now opens an episode only when
    liveness was expected: a server ping is unanswered
    (`unansweredHeartbeats > 0` in this round; the second review showed that
    count includes ticks that skipped the ping — see below), or the client pings
    on its own (`lastClientPingAt`, set by the socket's `ping` handler) and has
    been quiet for the threshold. The pong-only heartbeat case now asserts no
    silence and no resume record and that the injected path reader is never
    called; a temporary revert of the guard reproduced 8 false records in that
    case.
  - **Major, fixed — a peer that left during authentication looked like a
    request-phase refusal.** The aborted credential read now records its cause
    (`retirePendingUpgrade("peer" | "timeout")`), and the `catch` writes
    `abandoned/auth/peer_closed` for a peer that left or
    `rejected/auth/authentication_timeout` for the deadline, with `authMs` set
    from the elapsed wait. `server-http-lifecycle.integration.test.ts` gained the
    case (real `DeviceStore`, credential mutex held, raw socket destroyed);
    against the pre-review commit it reproduces `rejected/request`.
  - **Major, fixed — one status read and one classifier, not a parallel copy.**
    `tailscale-peer.ts` now exports `readTailscaleStatus(run, timeoutMs)` and
    `classifyPeer(peer)`; `admin/diagnose.ts` imports both and lost its own
    candidate loop, its own parse and its own path expression. The bundle and the
    silence record therefore agree about the same peer: `diagnose` now reports
    `path=offline` for an offline peer whose last direct address is still in the
    document (asserted in `diagnose.test.ts`).
  - **Major (process), resolved by the orchestrator.** The "Done when" needs
    O-6b's blackhole run; the orchestrator explicitly accepted the fixture
    hold-proxy blackhole against a fixture Gateway as the evidence, and owns the
    confirmation in O-6b's qualification blackhole run (baseline/R-1). The row
    stays Done on that decision.
  - **Minor, fixed — the read's bound no longer depends on `execFile`
    settling.** The whole read races one wall-clock `TAILSCALE_LOOKUP_TIMEOUT_MS`
    (2 s) timer that also clears `inFlight`, so a child that ignores SIGTERM or a
    grandchild holding the pipe cannot suppress every later silence record. A
    `null` peer value is dropped at the parse boundary and the call site maps a
    rejecting reader to `unknown`.
  - **Minor, fixed — a handshake refused after authentication was invisible.**
    After the synchronous `handleUpgrade`, a null `handshakeAt` writes
    `rejected/handshake/handshake_refused` (`abortHandshake` answers 400 without
    a callback).
  - **Minor, fixed — a first frame that is not JSON is a hello refusal, not an
    abandon.** `rejected/hello/invalid_frame`.
  - **Minor, fixed — one record per upgrade.** The duplicate bound records
    (`connection.rejected`, `connection.capacity`, `http.authentication-timeout`,
    and the upgrade site's `http.request-capacity`) are deleted; `http.upgrade`
    carries the structured `reason` (counts stay in the message) and readiness /
    shutdown refusals stay `info`. `http.request-capacity` remains for HTTP
    requests. Rows updated in `observability.md` and `connection-resilience.md`.
  - **Minor, fixed — `helloMs` and the slow warning are documented correctly.**
    `helloMs` runs from handshake completion to processing the hello frame
    (including the peer's send delay), and the warning is the total from the TCP
    accept, not `authMs` or `helloMs` alone.
  - **Minor, fixed — `peerRelay` is empty unless a relay carries the path.** A
    direct or offline peer returns `""`, matching its doc comment and the
    observability row.
  - **Nit, fixed — `http.upgrade` carries `connectionId`** once the connection
    exists (so an abandoned upgrade joins its own `connection.closed`), the
    `acceptToUpgradeMs` keep-alive caveat is documented, and the redundant
    `httpSocketAcceptedAt` delete is gone (a WeakMap releases with the socket).
- Review-response evidence: `npm run build` clean; `npx tsc --noEmit -p .` clean;
  the 11-file focused set above passes **100/100** (new cases: pong-only client
  never reported silent, `peerRelay` empty for direct/offline, a hung CLI read,
  a null peer value, loopback/LAN without a CLI run, peer abandons during auth,
  refused WebSocket handshake, non-JSON first frame, offline peer in the bundle);
  the eight neighboring suites still pass 92/92;
  `check-documentation-policy.py` and `personal-info-guard.sh` pass.
- Second reviewer's round (changes-required, 2026-09-28, against commit
  `bbde19b8f`) and this response:
  - **Major, fixed — a skipped ping was counted as an unanswered one.** The
    round-1 guard tested `unansweredHeartbeats > 0`, but that counter counts
    ticks: a tick that skips its ping (the client spoke within the last
    interval) still increments it. A pong-only client whose own frame landed
    mid-interval carried a miss into the next tick and was reported silent, once
    per such episode, which also falsified the "a day with no path outage adds
    neither" pair claim. `Connection.pingOutstandingSince` now records the tick
    whose `socket.ping()` really went out and `noteInbound` clears it, so an
    episode needs a ping the Gateway actually sent. `server-heartbeat.
    integration.test.ts` gained the reviewer's shape (hello at second 0, one
    application frame at second 7, pong-only after): no silence record, no
    resume record, no path read, and the documented one-tick ping transition
    (`pingedTicks` `[2..8]`). Reverting the guard to the miss count reproduces
    one `connection.inbound-silent` "has sent nothing for 43000ms" and its
    resume.
  - **Minor, fixed — the resilience rows for the upgrade records were wrong.**
    `authentication_timeout` is `rejected/auth`, not `abandoned/auth`: the
    `outcome=abandoned` + `phaseReached=auth` row now covers `peer_closed` and
    `shutting_down` only, the `reason=authentication_timeout` row says the
    Gateway refused it, and the `outcome=rejected` row lists
    `authentication_timeout` (auth) and `unreadable_request` (request).
  - **Minor, fixed — closes the Gateway started were recorded as
    `peer_closed`.** The hello deadline writes `abandoned/handshake/
    hello_timeout` before it closes the socket; shutdown writes
    `abandoned/handshake/shutting_down` for a socket that never sent hello and
    `abandoned/auth/shutting_down` for a credential wait it destroys (registered
    per upgrade, ended at the shutdown destroy). `hello_timeout` joined the
    `UpgradeEnding` union, the observability `reason` list and both resilience
    rows; `server-http-lifecycle.integration.test.ts` gained one case for the
    deadline and one per shutdown path, and reverting the three call sites
    reproduces `peer_closed` in each.
  - **Nit, fixed — `observability.md` no longer lists deleted records** in the
    `http.upgrade` why column and says which side each cause names; the
    `connection.rejected` literal assertion was deleted from
    `server-http-lifecycle.integration.test.ts` (the `reason` field covers it).
  - **Nit, fixed — the status read kills a child that ignores SIGTERM.**
    `execFile` now gets `killSignal: "SIGKILL"`, so one ignored SIGTERM cannot
    leave a process per 10 s reuse window behind the shared reader.
  - **Rejected: none.** Every review item was addressed.
- Second-round evidence: `npm run build` clean; `npx tsc --noEmit -p .` clean;
  the same 11-file focused set passes **105/105** (five new cases: the
  mid-interval pong-only client, the blackholed pong-only path once its ping
  goes unanswered, the hello deadline, shutdown before hello, shutdown during
  authentication). The reviewer's own repros now pass against
  the rebuilt dist: `pong-after-message.mjs` prints no silence, no resume and 0
  path lookups, and `hello-deadline.mjs` prints
  `abandoned/handshake/hello_timeout`. Outputs, the focused run and the
  negative controls (guard reverted: one false `has sent nothing for 43000ms`;
  endings reverted: `peer_closed` in all three cases) are retained in the
  internal workspace under `files/hardening/o-2-round2/`.
- Third reviewer's round (approved, 2026-09-28, against commit `f03f413aa`) and
  this response:
  - **Minor, fixed — other Gateway-started endings before hello were still
    recorded as the peer leaving.** `disconnect` no longer labels a socket
    `peer_closed` when the Gateway opened the close (`closeInitiated`), and
    every Gateway-started pre-hello ending states its own cause at the close
    site: `closeFailedConnection` takes the ending, `superseded` for an identity
    socket the newcomer displaces, `device_revoked` for a socket `disconnectDevice`
    closes before it had introduced itself, and the ws library's own frame
    refusal (an oversized or malformed frame, `WS_ERR_*`) is
    `rejected/hello/invalid_frame` instead of an abandoned handshake. The stale
    comment in `disconnect` and the plan's "Kept on purpose" bullet were
    reworded. Three new cases: a pre-hello supersession (per-identity cap 1), a
    pre-hello revocation, and an oversized pre-hello frame; reverting the source
    makes all three report `peer_closed`.
  - **Nit, fixed — `pingOutstandingSince` was only compared with null.** The
    timestamp now dates the liveness signal in the silence record's message as
    `unansweredPingMs=25000`, or `none` when the client's own pings were what
    stopped; both shapes are asserted.
  - **Confirmed, no new test needed — the receive-only C-4 phone.** `pings a
    pong-only client on every tick, never retires it and never reports it
    silent` already runs that shape (answers every Gateway ping, sends nothing
    else after hello) for 200 virtual seconds, past the 60 s silence threshold,
    and asserts no `connection.inbound-silent`, no `connection.inbound-resumed`
    and zero path lookups.
  - **Rejected: none.** Both items were addressed.
- Third-round evidence: `npm run build` clean; `npx tsc --noEmit -p .` clean; the
  same 11-file focused set passes **108/108** (three new cases plus the two
  `unansweredPingMs` assertions). The reviewer's own repros pass against the
  rebuilt dist: `supersede-before-hello.mjs` prints `reason=superseded` and
  `oversize-before-hello.mjs` prints `rejected/hello/invalid_frame`; the round-2
  repros still print no false silence and `reason=hello_timeout`. The negative
  control (source reverted, tests kept) and the receive-only run are retained in
  the internal workspace under `files/hardening/o-2-round3/`.
- Deviations:
  - The record fields needed the writer's shape: `logger.ts` gained
    `phaseReached`, the four duration fields, `peerPath`, `peerRelay` and
    `silentMs`, plus one `durationField` helper that the existing `durationMs`
    and `unaccountedMs` lines now share. `Connection` gained `remoteAddress`
    (the Tailscale join; never logged) and the upgrade trace, both handed to
    `admit` by `handleUpgrade`.
  - The silence record's message gained `unansweredPingMs`, the age of the
    Gateway's unanswered ping at detection (`none` when the client's own pings
    were the liveness signal). The pre-hello frame refusal is told from a peer
    departure by the ws receiver's `WS_ERR_*` error code, not by its message
    text: a path failure carries a socket error code or none.
  - `helloMs` on an abandoned upgrade is the time the attempt spent in the hello
    phase before the socket went away (0 only when the handshake never
    completed), not a completed round trip.
  - `peerRelay` names the relay actually carrying the path, so it is empty for a
    direct peer (the review's finding): the peer's home DERP region is not the
    path in use, and `peerPath=direct` already says so.
  - The blackhole proxy holds bytes instead of dropping them: dropping part of a
    WebSocket frame would desynchronize the stream both ends share, while the
    path still carries nothing in either direction while holding.
  - `GatewayServer` gained a `peerPathReader` option so no test can reach the
    host's Tailscale CLI.
  - `logger.test.ts`'s 40 MB rotation case (a 15 s timeout) flaked twice on this
    host while the parallel hardening workers loaded it (load average 16-24):
    16.6 s on this branch, 14.8 s on an untouched worktree of the same commit's
    parent, 7.8 s and 2.8 s when the host was quieter. No group of changes here
    touches that path; treat it as a host-load flake, not a regression. The
    second round saw the same kind of flake in
    `request-span.integration.test.ts` (a wall-clock assertion, "expected 99 to
    be greater than 100", at load average 27): it passes in isolation and in the
    next run of the whole focused set.
- For the next agent: the fixture-proxy blackhole above is the evidence the
  **orchestrator accepted** for O-2's "Done when"; the confirmation in O-6b's
  qualification blackhole run is the orchestrator's, at the baseline/R-1 runs,
  not a worker's. O-7 can join on the peer key and use `peerPath`/`silentMs`;
  E-1's Tailscale flap guidance can cite the
  silent/resume pair. `http.upgrade` carries the `connectionId` whenever a
  connection exists, so an upgrade that died before hello still joins its own
  `connection.closed`; the peer key remains the join for phone records.

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

### E-2c · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: the refusal half is implemented on this branch. `scripts/tron_profile_attribution.py`
  refuses a host-wide `time-profiler` trace whose `xcrun xctrace export` cannot
  stay inside a 2 GiB budget (`EXPORT_PEAK_BUDGET_BYTES`), names the trace's own
  size and its projected tree peak, and starts no export; `attribution.json` and
  `attribution.md` carry the trace's bytes, projected peak and budget. Only
  host-wide recordings are checked: `attribute()` takes `host_wide`, which
  `scripts/tron-profile-ios` sets from the template's recording target and
  `scripts/tron-profile-device` passes false, because a capture of one attached
  process has no measured export-to-trace-size ratio. The default scenario
  windows were **not** shortened: measured on real default traces, the recorded
  span — not the window length — is what the budget binds, so shortening the
  defaults would degrade every untraced report to serve the traced path. The row
  stays Blocked because "under 2 GB for `--scenario all`" is not demonstrated as
  a passing run: the retained product-scenario traces were recorded with
  `--iterations 3` and project 5.5-6.6 GiB, and at the inferred cost of one
  warm-up plus one measured window `--iterations 1` still projects 2.8-3.3 GiB
  and is refused, so a passing traced product run needs a window short enough to
  change what the scenario measures. A real `--scenario all` traced run also needs the lane's
  DevicePerformance build plus ten scenarios, which did not fit this task's
  budget on a host at load average 15-40 with the lane leased elsewhere.
  Simulator-device recording was not re-probed: E-2b established it never starts
  (180 s without returning, then the recorder's 300 s abort).
- Evidence:
  - Accepted (real trace, real CLI):
    `python3 scripts/tron_profile_attribution.py <75.3 MiB control-cpu
    --iterations 5 trace> --template time-profiler --pid 33246 --windows
    .../windows.jsonl` exits 0 in 44 s; tree-RSS peak 1,308 MiB (xctrace child
    1,277 MiB) measured with `files/hardening/e-2/peak.py`; `attribution.json`
    holds `export {traceBytes 78,976,785, projectedPeakBytes 1,579,535,700,
    budgetBytes 2,147,483,648}` with 233 measured samples over 5 windows;
    artifacts `~/.tron/workspace/files/hardening/e-2c/control-cpu-accepted-attribution.{json,md}`.
  - Refused (real trace): the same CLI on E-2's 338.7 MiB idle-dashboard trace
    exits 2 in 0.3 s with a 6 MiB peak (no export started): "refusing to export
    idle-dashboard.trace: the trace is 339 MiB and its xctrace export is
    projected at 6.6 GiB, over the 2.0 GiB budget (20 bytes of tree peak per
    trace byte measured on host-wide recordings); record a shorter trace (a
    smaller --window-seconds or --iterations) on a quieter host".
  - Scoping (real trace): the 131.7 MiB streaming-reply trace is refused as
    host-wide (exit 2) and exported with the CLI's `--device-capture` (exit 0,
    98 s, tree peak 2,434 MiB) into a document with no `export` block; that
    2.38 GiB measured peak also confirms the refusal of that trace was right.
  - Calibration (whole-tree peak per trace byte, host-wide Time Profiler, all
    from `peak.py`): 55.5 MiB -> 998 MiB (18.0), four runs of 75.3 MiB ->
    1,308-1,370 MiB (17.4-18.2), 131.7 MiB -> 2,434 MiB (18.5), 338.7 MiB ->
    4,637 MiB (13.7). The constant 20 rounds the worst up with ~8% headroom; the
    parser's own peak never overlapped the export's, so the tree is what the
    budget has to cover. (E-2's and E-2b's handoffs label the last trace 342 MB
    and the first 57 MB; these are the same traces in MiB.)
  - Why a refusal is the only bound (each tested here):
    `--xpath '.../table[@schema="time-profile"]/row[position()<5]'` returned 0
    rows and still peaked at 1,231 MiB, so the export child builds the whole
    table whatever `--xpath` selects; `ulimit -v` and `ulimit -d` are rejected
    by the shell and `resource.setrlimit(RLIMIT_AS)` fails on macOS, so the
    child cannot be capped either.
  - What sizes the trace (toc duration + the run's `windows.jsonl`), all
    `--iterations 3` except control-cpu (5): idle-dashboard 4x30 s -> 131.0 s /
    338.7 MiB (2.59 MiB/s); streaming-reply 4x12 s -> 106.8 s / 302.8 MiB
    (2.83); tool-loop 4x15 s -> 80.6 s / 282.9 MiB (3.51); control-cpu 6x2 s ->
    13.6 s / 55.5 MiB (4.09). Host-wide rate 2.6-4.4 MiB/s (a fresh 15 s
    host-wide recording was 62.8 MiB at 3.8 MiB/s,
    `~/.tron/workspace/files/hardening/e-2c/host-trace-rate.json`). The budget
    admits a 102 MiB trace, i.e. a 25-40 s recorded span; `--iterations 1`
    records the discarded warm-up window as well, so the default windows do not
    fit even then (inferred from those traces' spans: 2.8-3.3 GiB projected),
    while the 2 s control windows do (55.5 MiB measured).
  - `python3 scripts/test-tron-profile-attribution.py` 12/12 (failure mode 10:
    the budget boundary refuses one byte over and accepts at it, no export is
    started on a refused trace, the refusal names the trace's size, and a
    device capture over the budget still exports without an `export` block);
    `python3 scripts/test-tron-profile-ios.py` 7/7.
- Changes: `fix(ios): refuse a time-profiler export that cannot fit the profiler's memory budget (E-2c)`
  — `scripts/tron_profile_attribution.py`, `scripts/tron-profile-ios`,
  `scripts/tron-profile-device`, `scripts/test-tron-profile-attribution.py`,
  `packages/ios-app/docs/development.md` and this plan; the review response
  below adds `fix(ios): scope the profiler export budget to host-wide recordings (E-2c)`
  over the same files.
- Tasks added: none.
- Kept on purpose: `--all-processes` recording, `attribution.TEMPLATES`, the
  default scenario windows and `--iterations` default 5 (see Result); the
  owning doc's "keep traced runs short (1-3)" advice is replaced by the budget
  the refusal enforces.
- Deviations: no simulator run and no new trace recorded. The measurements use
  real existing traces and the real CLI, the same route E-2 used; the recorded
  rate is from a fresh host-wide recording taken for this task. The device
  capture's exemption was measured on a real trace through the CLI's
  `--device-capture`, not through `tron-profile device`, which needs a phone.
- For the next agent: to close the row, run `scripts/tron-profile ios
  --no-build --scenario all --trace time-profiler --iterations 1` on a quiet
  host after the lane's build, expecting the six product scenarios to be
  refused at their default windows (a refusal keeps the trace and costs only
  that scenario's simulator time) and the four 2 s control scenarios to fit.
  Then decide whether a traced product window short enough to fit
  (`--window-seconds <n>`, so warm-up plus one window plus setup stay under a
  ~25-40 s recorded span) is still a measurement worth taking, or whether the
  row's goal moves to a simulator-device recording that samples the app alone;
  the measurements say the recorded span, not the window, is the budget's
  driver.
- Review response (the follow-up commit on this branch): the sizing evidence is
  relabeled as `--iterations 3` (four window lines, warm-up included) and the
  "`--iterations 1` fits" claim is replaced by the inferred warm-up-inclusive
  numbers (finding 1); the doc's example command is now the fitting control
  self-test, its "1-3" advice is replaced by the budget it is bounded by, and
  the refusal's remedy names `--window-seconds`/`--iterations` instead of
  `--iterations 1`; the check is scoped to host-wide recordings through
  `attribute(..., host_wide=)`, with `tron-profile device` exempt, the CLI given
  `--device-capture` for a re-summarized device trace, and the device section of
  the owning doc saying so (finding 2, measured on a real trace); the constant is
  20 on the measured whole-tree peak with the comment's wording corrected and its
  bound stated as observed (finding 3); the header line says "no traced
  scenario's export is projected above 2 GiB" (finding 4); the test keeps the
  refusal-before-export, the boundary and the size in the message and drops the
  constant-and-remedy literals, with the device exemption added (finding 5); the
  message, docs, handoff and evidence README use MiB/GiB only (finding 6); the
  post-recording timing is stated where a user decides `--iterations` and
  `--window-seconds` (finding 7); and this handoff's `Changes` line names the
  files both commits touch (finding 8).

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

### O-5 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: one `gateway.resources` record per closed 60 s window
  (`RESOURCE_SAMPLE_INTERVAL_MS`) states what the Gateway spends memory, CPU and
  I/O on, and promotes itself when a named step moves or a named threshold
  breaks. The sampler (`ResourceSampler` in
  `packages/gateway/src/transport/stall-diagnostics.ts`, the existing sampler
  owner) closes one window per sample: heap used/limit/share and RSS from
  `process.memoryUsage`/`v8.getHeapStatistics`, event-loop delay p50/p99/max
  from `monitorEventLoopDelay` read once and `reset()` with the window (so a
  momentary stall is not a permanent max; its 20 ms sampling period is subtracted
  from every reading, since the histogram records the whole interval between its
  own ticks), event-loop utilization from `performance.eventLoopUtilization`,
  live runtimes with their canonical transcript bytes and subscriber counts,
  `runtimesLoaded`/`runtimesEvicted`, snapshot builds and how many had no
  audience, frames/bytes/subscribers per topic, catalog walks with files and
  time (and `requestPathCatalogWalks`, the part a request waited on), completed
  fsyncs with their time, the sample's own `windowMs`, and outbound bytes.
  Owners report their
  own work through the narrow `ResourceRecorder` (`recordSnapshotBuild`,
  `recordTopicFrame`, `recordCatalogWalk`, `recordOutboundBytes`,
  `recordRuntimeLoaded`, `recordRuntimeEvicted`); nothing is discovered by
  scanning. Levels: debug for a quiet minute; info when a window's value moves to
  another named step (event-loop p99 in `EVENT_LOOP_P99_INFO_STEP_MS` = 20 ms
  bands and max in `EVENT_LOOP_MAX_INFO_STEP_MS` = 250 ms bands, both compared
  with the previous window; heap used moved `HEAP_USED_INFO_STEP_BYTES` = 256 MiB
  and RSS moved `RSS_INFO_STEP_SHARE` = 10% from the window the anchor names, the
  last one written at info or above or the first this process recorded, which
  starts both anchors) or when a runtime was
  published or evicted in it; warning
  past `HEAP_WARNING_SHARE` (0.70 of the V8 heap limit) or
  `EVENT_LOOP_P99_WARNING_MS` (100 ms). Counters are drained, bounded to eight
  named topics and eight named runtimes with `+N` for the rest, and every
  non-finite measurement is written as 0.
- Failure modes written before the isolated tests
  (`packages/gateway/src/transport/stall-diagnostics.test.ts`,
  `packages/gateway/src/util/durable-json.test.ts`,
  `packages/gateway/src/sessions/runtime-registry.integration.test.ts`): (1) a
  window's counters are dropped or reported twice; (2) the event-loop delay
  window is not closed per sample, so a momentary stall becomes a permanent max;
  (3) the histogram's own sampling period is reported as delay, so an idle loop
  reads over the exit target; (4) the heap share is computed against a wrong
  limit, so the warning never fires; (5) a named step crossing does not promote
  the level, so it stays in the memory-only debug buffer; (6) unbounded topics or
  runtimes grow the record past one line; (7) a non-finite measurement (an empty
  histogram, a failed probe) is written as NaN; (8) a runtime loaded and evicted
  inside one window is invisible to a comparison of live sets; and for the durable
  fsync counters: (9) an fsync is not counted, (10) the window is not drained so
  every later sample repeats it, (11) removing a file that was already gone counts
  as an fsync that never happened, and (12) a failed sync is recorded as a write
  that landed. The third round added (13) work recorded while the runtime
  inventory read hangs is reported in the window that closed before it, so a rate
  read from `windowMs` is wrong exactly then, and (14) a heap step compared band
  by band with the previous minute flaps at a band edge, writing a record every
  minute for a steady heap that a garbage collection moves.
- Evidence:
  - `npx vitest run src/transport/stall-diagnostics.test.ts src/util/durable-json.test.ts`
    passes 21/21 at the time of the first round and 24/24 after the third round's
    two tests, and
    `npx vitest run src/sessions/runtime-registry.integration.test.ts -t "answers the resource sample"`
    passes.
  - `npx vitest run src/transport/server-frame.test.ts src/transport/sync-protocol.integration.test.ts`
    passes 11/11, `src/transport/server-live-view.integration.test.ts` +
    `src/transport/server-heartbeat.integration.test.ts` passes 11/11, and
    `src/sessions/runtime-registry.integration.test.ts` passes 243/243 in 57 s
    (246/246 after the registry tests of the later rounds).
    `npm run build` is clean.
  - Volume: the quiet minute is debug and stays in the 2 MB memory-only buffer
    (about 1,440 records, roughly 0.5 MB a day, none on disk; the buffer is shared
    with every other debug record and is not kept for a day, as the observability
    doc now says). A named step that
    moved (info) or a crossed threshold (warning) reaches `gateway.jsonl`, so a
    normal day is a small number of records rather than 1,440. The worst case —
    every minute crossing a step — is 1,440 records × 0.5 KB, about 0.7 MB, which
    with the measured 300 KB/day baseline is about 1.0 MB: at the 1 MB budget
    rather than under it, and the cap would have to change if a day spent every
    minute doing it. Recorded in `packages/gateway/docs/observability.md` with the
    new rows and the measured-volume paragraph.
  - Third round: `npx vitest run src/transport/stall-diagnostics.test.ts` passes
    17/17; the same file plus `src/util/durable-json.test.ts` passes 24/24;
    `src/transport/server-frame.test.ts`, `sync-protocol.integration.test.ts`,
    `server-heartbeat.integration.test.ts` and those two pass 40/40;
    `src/sessions/runtime-registry.integration.test.ts` passes 246/246 in 57 s;
    `npm run build` is clean. Both new tests fail on the previous commit (the
    source stashed, the tests kept): the inventory-hang test read
    `windowMs=0 outboundBytes=1007 catalogWalks=2 durableWrites=9` where the
    window had closed with 1,000 bytes and 2 fsyncs, and the oscillation test
    promoted 59 of 60 minutes, alternating 256 MiB bands.
- Changes: the O-5 commits on `hardening/o-5`.
- "Done when" (the 5% cross-check against O-6a's report): **owed to the
  orchestrator**, not run here. O-5's own "Done when" is that cross-check, so the
  row's `Done` rests on the orchestrator's decision of 2026-09-28 to close it once
  every review finding was fixed, with the cross-check still owed after the
  quiet-host O-6a run: O-5 has not answered its "Done when" itself. O-6a's
  scenario is committed on `hardening/o-6a` (6be09c4ba) but that worktree carries
  uncommitted edits to `scripts/tron-profile-gateway`,
  `scripts/tron-profile-gateway-driver.mjs` and `scripts/test-tron-profile.py`,
  i.e. the scripts the scenario runs, so a run from there would measure a moving
  tree while its worker writes in it (and a 15-minute load run on a busy shared
  host would spoil the other in-flight measurements). How to close it after O-6a
  merges: run the multi-session scenario against a build of
  `hardening/integration`, then read the last `gateway.resources` records from the
  fixture Gateway's `gateway.jsonl` and compare, within 5%, only like-for-like
  quantities: `outboundBytes` against the sum over clients of the driver's
  inbound bytes per topic (both count one frame per recipient at enqueue and at
  receipt; `outboundBytes` are pre-compression, and blob HTTP bytes are outside
  both), and `rssBytes`/`heapUsedBytes` against the Gateway RSS the report
  measures. The per-topic entry is **not** comparable: the Gateway counts one
  serialized frame per broadcast with the highest recipient count it had, while
  the driver counts every byte each client received, so per-topic totals cannot be
  reconciled. `liveRuntimes` is likewise not the driver's client count.
- SIM-8 coordination (Do item 3): one owner for host memory. **Agreement, O-5's
  side:** `gateway.resources` records process memory only — heap used/limit/share
  and RSS — and deliberately does **not** record host free memory, swap or memory
  pressure. Host memory stays with SIM-8's connection-drop records and the
  existing `gateway.event-loop-delay` evidence (`StallSampler.hostMemory`,
  `formatStallEvidence`), which already carry free bytes, swap used and
  `memoryPressure`. `/private/tmp/tron-sim8` does not exist on this host and the
  simulator-lifecycle plan is read-only for this task, so the boundary is stated
  in the `gateway.resources` row of `packages/gateway/docs/observability.md`,
  which points at `gateway.event-loop-delay`'s evidence as the host-memory owner;
  the orchestrator still has to relay the agreement
  to that plan's SIM-8 row (`SIM-8` is Claimed by `sim-lifecycle`). If its owner
  needs the reverse (host memory in the resource record), the sampler already
  injects `sampleHost`-style dependencies and can take one.
- Deviations:
  - Nine files outside O-5's owning list were touched, all required by the Do list
    rather than chosen: `packages/gateway/src/util/durable-json.ts` gained
    `syncDurably`, the one counting fsync primitive, and every `.sync()` site in
    the Gateway now calls it (`sessions/run-markers.ts`,
    `sessions/catalog-metadata-index.ts`, `sessions/session-export.ts`,
    `knowledge/knowledge-store.ts`, `machine/upload-store.ts`,
    `display/display-artifact-store.ts`, `workspace/tron-workspace.ts`) because
    `durableWriteMs` is only the truth about durable I/O if no store fsyncs
    outside it; and `packages/gateway/src/gateway-main.ts` (three lines: one
    sampler per process, handed to the registry and the transport, since the
    registry needs it before the transport exists).
  - The registry gained `resourceInventory()` (one `stat` per live runtime a
    minute, from `slot.sessionFile`) and `publishRuntime()`, which counts a
    runtime load and tells the slot it was published; the slot gained
    `sessionAudience` (the subscriber set lives in the registry) and counts an
    eviction in `disposeRuntime()`, the one place a slot stops existing, but only
    after `markPublished()` — a start retired before publication was never live.
    A build
    with a pending synchronization barrier but no subscriber yet counts as
    unaudienced; the exact recipient count is also in the per-topic counters
    (`session.snapshot:frames/bytes/subscribers`), which the no-audience work
    should read as its criterion.
  - Catalog walks are counted inside `catalogStructureEvidence()` in
    `runtime-registry.ts`, the one method every walk goes through, including the
    request-path callers (`removeIndexedCatalogFile`, attention admission) that
    the shared `catalog.walk` stage never saw. The request-path part is counted
    apart (`requestPathCatalogWalks`) from the ambient span there, because those
    callers sit outside `catalog.walk`.
  - `resources.unaudienced-work` was removed after review. The task's Do list
    asks for that warning for snapshots built without an audience *after* the
    no-audience work lands; firing it at warning level before then wrote an
    expected condition to disk every window and changed the volume budget. The
    count stays in every `gateway.resources` record as
    `unaudiencedSnapshotBuilds`, and the record and its threshold belong to the
    no-audience row when it removes the empty builds.
- Kept on purpose: the record's field names and units follow the logging
  contract inside the message (`heapUsedBytes`, `eventLoopDelayP99Ms`,
  `durableWriteMs`, `outboundBytes`), as `gateway.event-loop-delay` already does,
  instead of adding a dozen fields to `LogRecord`/`LogMetadata`; `resources` is a
  window, so one occurrence is reported exactly once and a stopped sampler cannot
  replay an old count. `sessionAudience` is the slot's only audience fact: the
  transport owns subscriptions, the slot owns builds.
- Not implemented, proposed for another row: the Logging-contract table lists
  "Runtime load and eviction" with records `runtime.loaded` / `runtime.evicted`
  against "O-5, G-5". This task's section does not request them and the registry
  has no logger seam today, so the transitions are counted where they happen
  (`recordRuntimeLoaded` at publication, `recordRuntimeEvicted` at disposal) and
  reported as `runtimesLoaded`/`runtimesEvicted` with per-runtime bytes in the
  minute's record instead. **Settled by the orchestrator on 2026-09-28:** the two
  named records belong to G-5, whose Do item 2 already asks for them with bytes;
  O-5 keeps only the counters, and the Logging-contract row now names G-5.
- Withdrawn: none.
- For the next agent: the no-audience row reads `gateway.resources` for its
  before/after numbers, and its recipient count is the `session.snapshot` topic
  entry; it should add the `resources.unaudienced-work` warning (or a warning
  reason on the record) once empty builds are no longer expected. The heap
  shedding row uses `heapShare` for its 70% step; the durable-write row uses
  `durableWrites`/`durableWriteMs`, which now cover every store's fsyncs; the
  event-loop rows use `eventLoopDelayP99Ms`/`MaxMs` and `catalogWalkMs`.
- Review round (2026-09-28, independent reviewer): 3 blockers, 4 major, 5 minor
  findings and 2 nits, all addressed or explicitly deferred in the second O-5
  commit. Event-loop delay now
  subtracts the histogram's sampling period (20 ms, halved from 10 ms to halve
  the sampler's own wakeups) instead of reporting an idle loop as ~20 ms over the
  exit target; the durable counters moved to `syncDurably` and cover every store;
  catalog walks moved to the one walk method; info is a named step or a runtime
  transition rather than "a runtime loaded"; a real-histogram test, a
  transport-wiring test (fake clock, subscriber, in-flight guard, threshold
  level, outbound bytes) and a registry test were added; the `gateway.resources`
  volume paragraph now includes the 300 KB/day baseline; a sampler fault logs one
  `gateway.resources-failed` warning per run of failures; plan-task IDs are out
  of the code and the docs; `durableRemove`'s wrapper and the synchronous
  `existsSync` in `resourceInventory()` are gone. The row is `Review` because its
  "Done when" cross-check still needs O-6a.
- Second review round (2026-09-28, independent reviewer): 2 major, 5 minor
  findings and 3 nits, all fixed; no finding is rejected. The real-histogram test
  no longer asserts wall-clock bounds on a shared, paging host (idle p50 under
  half the sampling period instead of p99 under 5 ms, a 150 ms block at or above
  120 ms with no tight upper bound, and the next window under half the stalled
  max); it passed 20/20 consecutive runs with swap in use, where the old bounds
  failed about one run in eight. The day's records can now answer the two checks
  they could not: the RSS step is anchored to the last window written at info or
  above, so slow growth still promotes (0.02% a minute over 1,000 minutes
  promotes twice, covered by a new test), and event-loop max moves in
  `EVENT_LOOP_MAX_INFO_STEP_MS` = 250 ms bands, so a minute whose max reaches
  250 ms is saved even at a low p99. The heap step is absolute bytes
  (`HEAP_USED_INFO_STEP_BYTES` = 256 MiB) instead of a share of a multi-gigabyte
  limit, and the observability row plus its volume paragraph no longer imply the
  debug buffer keeps a day. A tick that finds the previous sample still in flight
  logs one `gateway.resources-failed` (`reason=previous sample still running`)
  instead of dropping the minute silently, every record carries its own
  `windowMs`, and the wiring test now asserts that skipped window instead of
  feeding its own snapshot counts. Evictions are counted only for published
  slots (`RuntimeSlot.markPublished()` called from `publishRuntime`), so a start
  retired before publication cannot make `runtimesEvicted` exceed loads; a
  registry test builds an unpublished slot through the production creation seam
  and proves its disposal is not counted. Request-path catalog walks are counted
  apart (`requestPathCatalogWalks`) at the one walk seam, using the ambient
  `currentRequestSpan()`, so the request-path criterion is readable from the
  record; a registry test proves a walk inside a request span reports `true` and
  one outside reports `false`. The fused JSDoc blocks are split back onto
  `resourceInventory()` and `publishRuntime()`, and `durableAtomicWriteJson`'s
  forwarding wrapper is inlined. Orchestrator decisions recorded here: the named
  `runtime.loaded` / `runtime.evicted` records belong to G-5 (the Logging-contract
  row now names G-5 alone) and O-5 keeps only the counters; the row is `Done`, and
  the 5% cross-check against O-6a is owed by the orchestrator after the quiet-host
  O-6a run.
- Cross-check owed by the orchestrator (not O-5 work): after a quiet-host O-6a
  run on `hardening/integration`, read the fixture Gateway's last
  `gateway.resources` records and compare `outboundBytes` with the driver's summed
  inbound bytes, and `rssBytes`/`heapUsedBytes` with the report's Gateway RSS,
  within 5% (method and its exclusions are in the "Done when" entry above). The
  SIM-8 relay is owed by the orchestrator too: the agreement is stated in the
  `gateway.resources` row and in the SIM-8 bullet above, but the
  simulator-lifecycle plan's own row still has to name host memory's owner.
- Third review round (2026-09-28, independent reviewer): 3 findings, all fixed;
  no finding is rejected. A window's counters and its fsync drain now close with
  `windowMs`, before `readRuntimes()` is awaited (`ResourceSampler.sample()` and
  `drainWindowCounters()`), so a sample whose inventory read hangs cannot report
  the work done during the hang inside a window that already closed — the pair
  that made a rate read from `windowMs` wrong exactly then. Work recorded while
  the inventory hangs opens the next window, and a sample that fails after the
  drain drops the counters it consumed instead of folding them into the next
  window, which is the rule the histogram and `windowStartedAt` already followed.
  The heap step is anchored like RSS — `HEAP_USED_INFO_STEP_BYTES` = 256 MiB of
  movement from the last window written at info or above — instead of comparing
  bands with the previous minute, so a steady heap that a garbage collection
  swings 40 MiB around the 256 MiB edge no longer writes a record every minute
  (that oscillation promoted 59 of 60 minutes on the previous commit). Two tests
  were added, both shown failing on the previous commit; the existing step test
  now expects the anchored reason. Plan wording corrected: the event-loop max
  step is "a minute whose max reaches 250 ms" (240 ms is still band 0), and the
  "Done when" entry says plainly that the 5% cross-check is O-5's own
  "Done when" and is deferred by the orchestrator's decision rather than
  answered.
- Review nits still open, not in this round's scope:
  `requestPathCatalogWalks`' wording says "the part a request waited on", but a
  request that joins a walk started in the background also waits and is not
  counted (its wait shows only in `rpc.completed` as `catalog.walk-join`); and
  the `gateway.resources-failed` "already reported" flag is shared by a skipped
  tick and a thrown error, so an in-flight sample that later throws is not
  logged.

### O-4 · Done (review rounds 1, 2, 3 and 4 addressed) · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/o-4`)

- Result: the code, tests and docs are written and committed. The first commit
  ran no check (the shared owned iOS test simulator was leased for the whole
  session by the E-2b worker), so nothing in it was compiled here. Round 1 of
  review then built and ran it (see the review response at the end of this
  entry) and returned changes-required; every finding is addressed, and both
  "Done when" items now have evidence: the focused suites pass and the iOS
  Gateway E2E blackhole run wrote one episode that explains every attempt with
  its gaps.
- Evidence (first commit, before any review): the first commit ran
  `python3 scripts/check-documentation-policy.py` (46 authored files) and
  `scripts/personal-info-guard.sh`, both passing; no test command could run in
  that session, because the shared owned simulator was leased for 25+ minutes by
  the E-2b worker and the environment rules forbid booting another or bypassing
  the lease. Round 1 then built and ran everything below, so that gap is closed.
- Evidence (round 1, follow-up commit `2bc68ad21`):
  `scripts/tron-ios-test build` succeeds; `scripts/tron-ios-test run` passes
  `TronMobileTests/AppModelReconnectTests`, `AppModelLifecycleTests`,
  `GatewayConnectionEpisodeRecorderTests` and `AppLogTests` (50 tests, 4
  suites), `AppModelPerformanceSignpostTests` (23), `SessionPresentationStoreTests`,
  `SessionMutationServiceTests` and `AppModelWorkspaceTests` (75), and
  `PushNotificationCoordinatorTests`/`WorkspaceBrowserOwnerTests`. Negative
  control: with the folded `stallGuard` closure restored, the new coordinator
  test fails (`reconnect.stalled` count 1) and the fix makes it pass.
  `scripts/ios-gateway-e2e-test prepare|build|run` passes
  `RealGatewayPiBoundaryTests` (round 1: 1 test, 0 failures, 28.6 s; round 2
  added the foreground leg and ran 1 test, 0 failures, 44.6 s).
  `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Changes: `feat(ios): phone connection records, stall watchdogs and exact scene
  records (O-4)` and `fix(ios): address the O-4 review round 1 findings`
  (`2bc68ad21`) on `hardening/o-4`.
- Failure modes written before the code (in the header of the new recorder test
  file): the stall watchdog ticks while backgrounded; an episode record spans a
  background transition; a second recorder on the same always-on log mixes its
  attempts into this episode or breaks attempt-before-episode order; a blocked
  main actor is never recorded or is recorded again after the episode ended; an
  attempt record loses an export field.
- What the change does, file by file:
  - New `GatewayConnectionEpisodeRecorder.swift` in
    `packages/ios-app/Sources/State/`: one `gateway.attempt` per finished
    attempt (`profile`, `attemptId`, `retry`, `stageReached`, `reason`,
    `interfaces`, `pathSatisfied`, `delayBeforeMs`, `foreground`,
    `gatewayConnectionId`, plus `durationMs`/`outcome`), one
    `connection.episode` when the outage ends (`startedAt`, `endedAt`,
    `attempts`, `causes`, `foregroundMs`, `maxGapBetweenAttemptsMs`, `endedBy` =
    `connected`/`background`/`stopped`), the `reconnect.stalled` watchdog
    (`RECONNECT_STALL_BOUND` = `reconnectStallBound`, 20 s, naming
    `pathUnsatisfied`, `connectionAdmissionTask`, `committedConnectionTask`,
    `reconnectTaskBusy`, `nonRetryable` or `other`), and `app.main-stall`
    (`MAIN_STALL_BOUND` = `mainStallBound`, 2 s, measured by a 1 s ping from off
    the main actor). Records from one episode are chained through one task so an
    attempt is always written before its episode. Recording only; it schedules
    nothing.
  - `GatewayLifecycleCoordinator.swift` feeds it: attempt records for the
    initial connect and every reconnect-loop attempt, `noteDisconnected` opens
    an episode at the loss, `enteredBackground` ends it (`background`),
    unauthenticated/non-retryable failures and `beginTransition` end it
    (`stopped`), and `reconnectStallGuard` answers which guard is holding.
    The two `scene.foreground`/`scene.background` delegate diagnostics are
    removed: scene transitions now have one owner.
  - `AppModel.swift`: the scene owner records `scene.resign-active`,
    `scene.foreground`, `scene.background` and `scene.active`, once each, with
    the transition's own timestamp (`sceneAt`); `operation.*` intervals still
    open at background are signed `outcome=backgrounded`; and
    `session.open.failure` now reports the Gateway's own code.
  - `PerformanceSignposts.swift`/`AppLog.swift`: `endOpenIntervalsAtBackground()`
    on `PerformanceSignposting` and its implementation (a default no-op keeps
    other recorders unchanged). An interval the scene retired is signed once, as
    `backgrounded`; a shorter one keeps its own single record at its end.
  - `GatewayClientDiagnostics.swift`: `GatewayDiagnosticFailure.answerCode`,
    which keeps a typed failure's own code (`conflict`, `busy`, `forbidden`)
    instead of collapsing it to `transport`.
- Diagnosis of the reported artifact (Do item 5): SwiftUI delivers `.inactive`
  on the way *into* the foreground as well as on the way out, and AppModel
  recorded `.inactive` as `app.backgrounded`; the resume then wrote
  `app.foregrounded` at `.active`, so an export showed a background immediately
  before a resume (the write was also asynchronous, so its log timestamp could
  trail the transition). The fix records the four real transitions once, at the
  moment they happen, with the scene's own timestamp; at a resume the pair is
  now `scene.foreground` then `scene.active`.
- Deviations:
  - The watchdogs tick on a separate injected `watchdogClock`
    (`packages/ios-app/Sources/State/GatewayConnectionEpisodeRecorder.swift`),
    which the coordinator passes as `.continuous`, while every bound is measured
    on the lifecycle clock. A watchdog tick on the manual test clock would be a
    sleeper in every existing reconnect test's `ManualClock`, which several of
    them count exactly (`recordedSleeps()`, `activeSleeperCount()`).
  - Cancelled attempts (scene retirement or a profile switch cancels the task)
    are not recorded as attempts: they reached no stage and their episode
    already ends with `endedBy=background`/`stopped`.
  - `GatewayReconnectSchedule` was left unchanged; `reconnectCanBeAccelerated`
    already means "waiting in a delay", which is what the guard needs.
  - Six edits sit outside the named owning files. `PerformanceSignposts.swift`
    gained the `endOpenIntervalsAtBackground()` requirement and
    `PerformanceInterval.trackedID`; the protocol it belongs to can only be
    declared there, and `AppLog.swift` (a named owning file) implements it.
    `GatewayClientDiagnostics.swift` gained `GatewayDiagnosticFailure.answerCode`,
    which only that enum can declare, and round 3 added the
    `GatewayFailure.answeredByGateway` marker to `GatewayProtocol.swift`, which
    only that type can declare. `SessionPresentationStore.swift` reads that
    marker to record `gatewayCode` only from an answer the Gateway sent, and
    clears the stored code only for the presentation attempt that owns it.
    `AppModel.swift` keeps the scene recorder it
    already owned. `TronMobileApp.swift` passes the scene phase the launch
    observed instead of a boolean, and `WorkspaceBrowser.swift` routes a
    transient-error retry to the lifecycle's transport-recovery request instead
    of a scene activation; both are the call sites of the AppModel API this task
    changed. `GatewayReconnectScheduleTests.swift` was not
    extended: the stall watchdog is owned by the new recorder, so its failure
    modes are covered by the new
    `GatewayConnectionEpisodeRecorderTests.swift` on a manual clock instead.
  - `gateway.attempt` records only the selected profile's lifecycle attempts.
    The task's field list says the `profile` is "selected or pool", but
    `DashboardGatewayConnectionPool.swift` is the C-5 zone and not an owning
    file. The orchestrator decided on review round 1 that O-4 keeps this
    deviation and that C-5 widens the pool using the same recorder type (the
    exact API is in the "For C-5" note); the observability row and this entry say
    so.
  - Do item 7 (rounds 2 and 3): a Gateway `conflict` on the open transaction is
    reworded to `sync_failed` by `SessionPresentationStore.swift` before
    `session.open.failure` is written. The record now reports both: `code` keeps
    the phone-side wording (`transport` only when the failure never reached the
    Gateway, which was the network-fault misreading Do item 7 exists to remove)
    and `gatewayCode` carries what the Gateway itself answered, read from the
    presentation owner that rewords it. Round 3 narrowed `gatewayCode` to the
    Gateway's own answers only: the client stamps the failure it decodes from a
    Gateway error response (`GatewayFailure.answeredByGateway`), and a code the
    phone minted locally (`disconnected`, `timeout`, `closed`, `replaced`,
    `backgrounded`, `invalid_response`, …) reads `gatewayCode=none`. The
    orchestrator decided this on review round 2; the public failure mapping is
    unchanged.
  - `Tests/Gateway/RealGatewayPiBoundaryTests.swift` carries the two blackhole
    E2E legs (a forced scene cycle and a foreground blackhole of a live socket);
    O-1 extended the same file for its correlation join.
- For the next agent (the remaining work is C-5's, not O-4's):
  1. O-4 is Done. The E2E evidence, run on 2026-09-28 with
     `scripts/ios-gateway-e2e-test prepare` then `build` then `run` (plain Node
     22.22.0, after `npm run build` in `packages/gateway`), is the
     `phone-connection-records` attachment of `RealGatewayPiBoundaryTests`
     (1 test, 0 failures, 44.6 s; round 2, run `20260928T111132Z-run.rCfJ0r`).
     Both blackhole legs are retained at
     `~/.tron/workspace/files/hardening/o-4-blackhole-phone-connection-records.txt`:
     the scene-cycle leg's forward attempt, blackholed failure
     (`stageReached=hello-receive reason=transport durationMs=5042`), recovery
     attempt (`delayBeforeMs=1770`) and one `connection.episode ... attempts=2
     causes=transport maxGapBetweenAttemptsMs=6812 endedBy=connected`; and the
     foreground leg's episode opened at the loss the phone saw
     (`startedAt=2026-09-28T11:12:15.838Z`), the first attempt recorded 5.0 s
     later, and one `connection.episode ... attempts=2
     causes=pong_timeout,transport maxGapBetweenAttemptsMs=7021
     endedBy=connected`. The foreground leg's own silent gap is about 1 ms (its
     retry is `immediate:`), so that leg evidences the episode's start and first
     cause, not a non-zero silent gap before the first attempt; the scene-cycle
     leg's `delayBeforeMs=1770` is what shows one.
  2. C-5 owns the pool's records; its API is in the "For C-5" note below.
  3. If the recorder tests pass but the coordinator-level expectations move
     (for example an extra `gateway.attempt` for a cold start), check
     `attemptStage` in `GatewayLifecycleCoordinator.swift` first: it derives the
     stage from the client's handshake diagnostic when the failure path already
     has one.

**Review response (round 1, follow-up commit on this branch).** An independent
review built the branch, fixed two compile errors in a throwaway copy, and ran
the focused tests; it returned changes-required. Every finding is addressed:

- Blocker: `recorder.stallGuard` folded `self?.reconnectStallGuard` into one
  optional, so a progressing episode answered `other` and any 20 s stretch
  logged `reconnect.stalled`. It now unwraps `self` first. Verified by
  regression: with the folded closure restored, the new
  `AppModelReconnectTests.backoffIsNotAStall` fails; with the fix it passes, and
  `unsatisfiedPathIsNamedAsTheGuard` reproduces `guard=pathUnsatisfied`. The
  coordinator therefore accepts an injected `watchdogClock` (production keeps
  `.continuous`), so a coordinator-level test can advance the bound without
  waking the lifecycle timeline.
- Blocker: the test target did not compile (`exerciseBlackholedReconnect` passed
  `self` into a `@MainActor` method; the recorder test listed `startedAt` after
  `gatewayConnectionID`). The blackhole helper is now a `@MainActor static`
  function returning the records, the attachment is added by the caller, and the
  recorder test arguments are in declaration order.
- Blocker: `reconnectAttemptsAndEpisodeAreRecorded` expected three attempts; the
  code records the initial connect plus three loop retries. The test now expects
  four, the fourth connecting, and the episode's actual
  `maxGapBetweenAttemptsMs=60000`.
- Major: the blackhole assertions counted the pre-blackhole connect and never
  checked the gaps. They now count only records written after the blackhole
  begins, require one `endedBy=connected` episode, and assert the reported
  maximum gap is at least the blackholed attempt's own duration.
- Major: pool-profile attempts stay unrecorded. The orchestrator decided O-4
  keeps the selected profile's lifecycle only; the observability row says so and
  this stays under Deviations. C-5 will reuse the recorder from
  `DashboardGatewayConnectionPool.swift`; the API it must call is in the
  "For C-5" note below. The misleading two-recorder test now names the property
  production exhibits (two recorders on one always-on log stay attributable and
  ordered) instead of claiming a two-profile failure mode.
- Major: `openEpisode` dated the episode's wall-clock start with `Date()` at the
  open, up to a transport deadline after the monotonic start. It now derives the
  wall-clock start from the monotonic instant, so `startedAt + durationMs`
  matches `endedAt`.
- Minor: both watchdogs are one task that keeps the recorder weakly and is
  cancelled in `deinit`, so a recorder freed with an episode open leaves nothing
  ticking.
- Minor: the in-flight marker is now the loop identity, cleared when that loop's
  attempt ends (before its backoff) and when the loop retires, so a replaced
  loop cannot clear its successor's marker or park the watchdog at `nil`.
- Minor: `beginTransition` and `enteredBackground` end the episode with its own
  profile and generation rather than the current selection.
- Minor: a Gateway restart (`system.stopping`, `countsAsTransportFailure: false`)
  opens an episode too, with `causes=restart`, so a restart whose first
  reconnect succeeds is still on the timeline.
- Minor: a connection that drops under projection after a successful handshake
  is recorded against that attempt as `<attemptId>#postConnect` with
  `stageReached=postConnect`, so one attempt cannot be read as two.
- Minor: `recordAttempt` now passes the attempt's handshake diagnostic on the
  failure paths that already have one, so `interfaces` is the attempt's own.
- Minor: Do items 6 and 7 have tests now
  (`AppLogTests.backgroundedIntervalIsSignedOnce`,
  `AppModelPerformanceSignpostTests.sessionOpenConflictReportsItsOwnCode`).
  `endOpenIntervalsAtBackground` only suppresses intervals it actually signed, so
  a short interval that later runs long still writes its one record; the dead
  `PerformanceResult.backgrounded` case and its branch are deleted.
  `GatewayClientDiagnostics.swift` is now listed among the files outside the
  named set (Deviations).
- Minor: the scene recorder is seeded from the real launch phase
  (`AppModel.start(scenePhase:)`), so a cold or backgrounded launch cannot report
  `from=active`; the workspace-browser transient-error retry calls
  `becameActive(recordsSceneTransition: false)` instead of writing a scene
  record for a scene that did not move; `WorkspaceBrowser`'s two call sites are
  the whole change.
- Nits: new bookkeeping properties are `@ObservationIgnored`; the duplicate
  `setProxyMode` is deleted in favour of the existing `control`, which is now
  static so the static blackhole helper can drive the proxy; `app.main-stall`
  is a warning (bound hit) rather than an error and the row says so; recorder
  test 1 no longer depends on two watchdogs sleeping (there is one).
- Nits rejected. `maxGapBetweenAttemptsMs` keeps its start-to-start meaning: the
  same review's blackhole assertion requires a gap that contains the blackholed
  attempt's own duration, which an idle-only gap cannot provide, and the row
  defines the field as the largest gap between the episode's start or two
  consecutive attempt starts. `silentForMs` on `reconnect.stalled` is where
  silence is measured. The SwiftUI `.inactive`-on-resume explanation stays
  labelled as inferred (nothing here reproduced it); the mapping is written so
  it is correct whether or not the platform delivers that phase.

**Review response (round 2, follow-up commit on this branch).** An independent
review built the branch, ran the focused suites (102 tests, all passing) and a
Swift 6 repro, and returned changes-required: `app.main-stall` could not detect
the failure it exists for, and the stall watchdog was blind to a loop parked in
projection. Both are fixed, with a real main-actor block test and a coordinator
test, and every other finding is addressed:

- Blocker (main-stall): the watchdog task was created from a `@MainActor` owner,
  so it ran on the main actor and its own wake-up queued behind the block it was
  measuring — it took its start time after the block ended and timed a hop of
  microseconds. The loop now runs in a `nonisolated static` function reached
  through a closure with no main-actor access (closure isolation is inferred from
  the body and travels with the closure even when it is typed `@Sendable`, so
  `Task.detached` alone was not enough — measured, not assumed). The gate test is
  replaced by one that blocks the main actor synchronously for 5 s with the
  production ping and clocks: it passes with the block it served (the assertion
  allows one watchdog interval and the detached loop's first wake-up, about 1 s
  each, of the 5 s block — about 3 s recorded) and fails with no record at all
  before the fix.
- Major (parked loop): the in-flight marker was cleared only in the generic
  failure catch, so a loop parked in projection read as "progressing" forever,
  and the bare state-mismatch `return`s left a dead loop's marker matching
  `reconnectLoopID`. The marker is now cleared as soon as the handshake is
  recorded and by a task-level `defer` when the loop exits for any reason, with
  the identity check that keeps a replaced loop from clearing its successor's
  marker. New test: a delegate whose `lifecycleRefreshAll` never returns, a drop
  under it, and `guard=reconnectTaskBusy` on `reconnect.stalled`.
- Minor: a post-connect failure is now dated at the drop and is not counted in
  the episode's `attempts` (it belongs to the attempt the previous episode
  already counted), with a recorder test for both.
- Minor: a transport loss now passes its own code as the episode's cause, so a
  disconnect whose first reconnect succeeds no longer writes `causes=none`.
- Minor: the E2E blackhole helper tears its lifecycle and client down on the
  success path, and it gained a foreground-blackhole leg (the O-6b shape: a live
  socket blackholed in the foreground, the loss seen by the phone through its
  liveness probe, the episode opened at that loss).
- Minor: the launch seed is taken before `start`'s first await and only while no
  scene transition has been recorded, so a transition during startup is not
  overwritten.
- Minor: `becameActive(recordsSceneTransition:)` is gone; the workspace browser's
  transient-error retry routes to `AppModel.recoverTransientTransportFailure()`,
  a lifecycle reconnect request, so no scene activation is minted for a scene
  that did not move.
- Minor: every interval open at background is marked; one that was shorter than
  the threshold then and passes it when its owner unwinds is signed
  `backgrounded` (warning) instead of the background cancellation's `failure` at
  error level, with a test.
- Minor: `session.open.failure` carries `gatewayCode` beside the reworded `code`,
  per the orchestrator's round-2 decision, and the test asserts both.
- Nits: the unrun-check paragraph is now attributed to the first commit; the pool
  deviation appears once; `TronMobileApp.swift` and `WorkspaceBrowser.swift` are
  in the deviations list; the `connection.episode` row says an episode can end
  with no attempt; and the two escaped `\(UUID().uuidString)` literals in
  `AppModelReconnectTests.swift` interpolate again, so the log path and
  UserDefaults suite are unique per test.

**Review response (round 3, follow-up commit on this branch).** An independent
review built the branch, ran the focused suites, compiled a Swift 6 main-stall
repro and checked every round-2 finding against the code; it returned
changes-required for one regression this branch introduced, plus two minor
findings, a minor test-evidence gap and three nits. Every one is addressed:

- Major: the workspace browser's transient-error retry had been routed to
  `lifecycle.requestReconnect(immediate: true, replaceExisting: true)`, which
  O-4's "Do not: change reconnect behaviour" forbids: in `.unauthorized` it
  flipped to `.reconnecting` and retried a token the Gateway had already
  rejected, and in `.connected` it replaced the live socket and published
  `.reconnecting`. The lifecycle now owns `requestTransportRecovery()`, which
  mirrors `becameActive()`'s non-scene branch exactly — reconnect only from
  `.offline`/`.reconnecting`/`.restarting`, nothing otherwise, no scene side
  effects, no foreground reconciliation, no retry of a rejected credential and no
  peer socket while a background retirement barrier runs — and
  `AppModel.recoverTransientTransportFailure()` calls it. Two focused tests
  (`transientTransportRetryLeavesUnauthorized`,
  `transientTransportRetryLeavesConnectedTransport`) assert the state, the
  attempt count, the socket count, the sleeper count and the absence of a scene
  record.
- Minor: the launch scene seed can no longer be overwritten by the phase the
  launch sampled, because every observed transition spends the seed, including
  one that matches the phase already recorded (which is the `becameActive()`
  before `start()` case).
- Minor: `gatewayCode` now carries only codes the Gateway itself answered. The
  client stamps a failure it decodes from a Gateway error response
  (`GatewayFailure.answeredByGateway`) at the transport boundary, the
  presentation store records the code only from a stamped failure, and it clears
  the stored code at the start of each opening attempt, so a retried `busy`
  cannot outlive its retry. `sessionOpenLocalFailureReportsNoGatewayCode` covers
  the local case and the existing `sessionOpenConflictReportsItsOwnCode` covers
  the Gateway's answer. A denylist of local codes was rejected: it would leave
  the same hole for every other phone-minted code (`retired`, `cancelled`,
  `possibly_sent`), while the stamp is set where the answer is decoded.
- Minor: the foreground blackhole leg now asserts the evidence that
  discriminates — the episode's first cause is the loss code the phone saw, which
  only `noteDisconnected` contributes — and the comment on its two coarse time
  bounds says they cannot separate "opened at the loss" from "opened by the
  first attempt".
- Nit: the main-stall test waits a bounded 500 ms after the episode ends before
  counting, so a watchdog that was never stopped would have landed its record.
- Nit: the O-4 entry's 2,988 ms figure is corrected (the test asserts at least
  `blocked − 2 × watchdogInterval` for a 5 s block, so 2,988 ms would fail it);
  and the `connection.episode` row says a post-connect failure is not a further
  attempt. (This round's claim that the off-owning-file sentence "now counts the
  files it names" was wrong: round 4 corrected the count to the six files and
  added `SessionPresentationStore.swift`.)
- Nit: the `lastProgressAt` comment names what is actually fed to it (the
  episode's open, attempt starts and the post-connect drop).

Evidence for this round: `scripts/tron-ios-test build` succeeds;
`scripts/tron-ios-test run` passes 304 tests in 12 suites (`AppModelReconnectTests`, `AppModelPerformanceSignpostTests`,
`AppModelLifecycleTests`, `GatewayConnectionEpisodeRecorderTests`,
`SessionPresentationStoreTests`, `ComposerDraftCoordinatorTests`,
`GatewayProtocolContractTests`, `GatewayClientTransportTests`,
`BoundedHTTPDataTransportTests`, `GatewayPairingTransportTests`,
`AppModelWorkspaceTests`, `AppLogTests`). Negative controls, run on this branch:
with `AppModel.recoverTransientTransportFailure()` restored to
`requestReconnect(immediate: true, replaceExisting: true)`, the two reconnect
tests fail exactly as the review predicted (`.unauthorized` → `.reconnecting`
with a second socket request; `.connected` → `.reconnecting` with a replaced
socket and a scheduled sleeper); with the presentation store's stamp gate
removed, `sessionOpenLocalFailureReportsNoGatewayCode` fails. Both files were
restored byte-for-byte before the passing run. The runs are retained under
`$HOME/Library/Developer/Tron/ios/test-runs/`: the passing round-3 run is
`20260928T115631Z-run.o3j4Ws`, the two negative controls are
`20260928T115442Z-run.4M4NoV` (2 failed) and `20260928T115532Z-run.zEOTyx`
(1 failed). Not run in this round: the iOS Gateway E2E
(`scripts/ios-gateway-e2e-test`), whose fixture directory is shared per user with
parallel workers; `RealGatewayPiBoundaryTests` does compile in the test build.
The round-4 review ran it on `ade1d4432` and it passed (1 test, 0 failures,
44.4 s; round 4's own record is below).
`python3 scripts/check-documentation-policy.py` and
`scripts/personal-info-guard.sh` pass.

**Review response (round 4, follow-up commit on this branch).** An independent
review of round 3 found no blockers or majors: one minor test gap, three nits
and one cleanup side effect it reported itself. Every finding is addressed:

- Minor: the two round-3 reconnect tests only asserted that the retry does
  nothing, so a `requestTransportRecovery()` that always returned `nil` would
  have passed them and every other suite. New
  `AppModelReconnectTests.transientTransportRetryRevivesParkedRetry` parks the
  lifecycle in `.reconnecting` behind its backoff sleeper, calls
  `AppModel.recoverTransientTransportFailure()`, and requires an immediate
  second socket request with no clock advance, no remaining sleeper, no extra
  recorded sleeper and no scene record. Negative control: with
  `requestTransportRecovery()` replaced by `return nil`, that test fails on its
  own (the second request never arrives) and the other 35 reconnect tests still
  pass.
- Nit: the launch seed had no test, including the round-3 flag-before-guard fix.
  New `AppModelLifecycleTests.launchSeedDoesNotOverwriteAnObservedTransition`
  activates the scene, then runs `start(scenePhase: .inactive)`, then resigns
  active, and requires the `scene.resign-active` record. Negative control: with
  the seed spent only when the transition changed the phase (the round-2 shape),
  the stale `.inactive` sample suppresses that record and only this test fails.
- Nit: `GatewayFailure.answeredByGateway` was a `Codable` property, so a wire
  frame could stamp or clear phone-local provenance, and a stamped failure
  stopped comparing equal to an otherwise identical wire literal. It is out of
  `CodingKeys` now: `GatewayResponse` decoding cannot read it and an encoded
  failure never carries it, matching the neighbouring not-Codable provenance
  types. The presentation store's per-attempt clear is scoped to `.presentation`
  like its set, so a `.reconnect` attempt neither stores nor clears a
  Gateway-answer code. New
  `GatewayProtocolContractTests.failureProvenanceStaysOffTheWire` decodes a
  response whose error frame carries `answeredByGateway: true`, requires the
  decoded marker to be `nil`, requires the stamped encoding to omit the key, and
  requires the local stamp to still distinguish a decoded answer from a literal.
  Negative control: with the synthesized keys restored, the wire marker is read
  as `true`, the encoded failure carries the key and the stamp stops
  discriminating; only this test fails.
  The clear-scope half is inspected, not reproduced: the only reader is
  `AppModel.openSessionPresentation`'s failure record, every presentation attempt
  clears then maybe sets the code, and a `.reconnect` attempt cannot write it.
- Nit (plan text): the off-owning-file sentence now counts the six files it
  names and includes `SessionPresentationStore.swift`; the missing space in
  "12 suites (" is fixed; the round-3 claim that the sentence "now counts the
  files it names" is corrected in place; and the round-3 evidence paragraph,
  which recorded the iOS Gateway E2E as not run, now points at the run below.

Evidence for this round: `scripts/tron-ios-test build` succeeds and
`scripts/tron-ios-test run` passes 200 tests in 6 suites (`AppModelReconnectTests`,
`AppModelLifecycleTests`, `GatewayProtocolContractTests`,
`SessionPresentationStoreTests`, `AppModelPerformanceSignpostTests`,
`GatewayClientTransportTests`), retained as
`$HOME/Library/Developer/Tron/ios/test-runs/20260928T125540Z-run.xsKDAH` (an
earlier identical pass before the last test-text trim is
`20260928T125222Z-run.nPYGdf`). The
three negative controls above are retained as
`20260928T124502Z-run.SCxZk3` (1 of 36 failed),
`20260928T124614Z-run.hdxuF2` (1 of 9 failed) and
`20260928T124842Z-run.MUA7h9` (1 of 17 failed); each source file was restored
byte-for-byte (verified by `shasum -a 256 -c`) before the passing run. The iOS
Gateway E2E was attempted again in this round with private fixture directories
(`TRON_IOS_E2E_STATE_DIR=/tmp/o4rev5-e2e`,
`TRON_IOS_E2E_DERIVED_DATA=/tmp/o4rev5-e2e-dd`): `prepare` built the Gateway but
the fixture exited immediately because the shared dependency tree's `node-pty`
prebuild cannot be loaded in the pinned Node (`ERR_DLOPEN_FAILED`,
`prebuilds/darwin-arm64/pty.node` Team ID mismatch; the same failure reproduces
with a bare `require('node-pty')` from `packages/gateway`). That fixture was
stopped with `scripts/ios-gateway-e2e-test stop` (no shared state deleted), and
the round-4 review's own E2E pass on `ade1d4432` (1 test, 0 failures, 44.4 s)
remains the run-of-record for this task. `python3
scripts/check-documentation-policy.py` and `scripts/personal-info-guard.sh` pass.

**For C-5.** Reuse `GatewayConnectionEpisodeRecorder`
(`packages/ios-app/Sources/State/GatewayConnectionEpisodeRecorder.swift`) from
`DashboardGatewayConnectionPool.swift`, one recorder per pool entry, and call:
`noteDisconnected(profileID:lifecycleGeneration:foreground:cause:)` when an
entry's connection is lost; `recordAttempt(GatewayConnectionAttempt(...))` with
`profileID` set to the pool profile, `lifecycleGeneration` set to the entry's
generation, `attemptID` set to the loop ID, and the attempt's own
`startedAt`/`delayBeforeMs`/`stageReached`/`reason`/`interfaces`/`succeeded`;
`endEpisode(.background)` / `.stopped` / `.connected` at the entry's terminal
transitions; and `stallGuard = { ... }` mapping the pool's own holding condition
onto `pathUnsatisfied`/`nonRetryable`/`reconnectTaskBusy`/`other`, returning
`nil` while an attempt is in flight or waiting in its backoff. Pass the pool's
`clock` and an `appLog`; leave `watchdogClock` at its default unless a test needs
its own grid. The observability rows already list `profile` and both record
events; widen them to name the pool owner in the same change.

### Orchestrator · 2026-09-28 · T-1 added from a flake investigation

- Result: an intermittent failure of "discovers oversized active lifecycle
  headers on the registered path and after runtime reconstruction" in
  `packages/gateway/src/sessions/runtime-registry.integration.test.ts` is a
  pre-existing test race, not a regression: it reproduces on `main` code under
  concurrent temp-directory I/O. `discoverExtensionArtifacts()` returns without
  work while the pass fired by `initialize()` is in flight (a single-owner,
  best-effort pass), so the test's awaited call is not a barrier. The same
  pattern exists in "rejects foreign producer session headers…" (a negative
  assertion, so a dropped pass is a false green) and "reconciles an
  exact-owned active artifact before the bounded ambient scan".
- Evidence: reproduction commands, counts on both trees, a probe trace and the
  proposed test-side fix are in the internal workspace at
  `files/hardening/t-1-investigation.md`.
- Tasks added: T-1 (after G-1a, which holds the Registry zone and edits the
  same test file).

### G-1a · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: the catalog has one owner. `session-catalog.ts` holds one in-memory
  row per canonical session file (the durable row plus the path-derived
  `delegated` flag), loads the durable document and reconciles once behind the
  listener, applies every Gateway-owned change at its commit point, and writes
  the durable form on a `CATALOG_PERSIST_DEBOUNCE_MS` (5 s) debounce and at
  shutdown. Readers are not switched: G-1c does that and deletes the old path.
- Evidence: `npx vitest run src/sessions/session-catalog.test.ts` 4/4 in 2.2 s;
  `npx vitest run src/sessions/catalog-metadata-index.test.ts
  src/sessions/catalog-discovery.test.ts src/sessions/session-catalog.test.ts`
  23/23 in 2.7 s; `npx vitest run src/sessions/runtime-registry.integration.test.ts`
  **247 passed / 247 in 99 s** (the whole owner file, after the accounting
  adjustments below). The new case `-t "matches a full scan after create, rename,
  fork and delete in the catalog index"` passes alone in 3.6–6.2 s.
  `npx tsc -p tsconfig.json --noEmit` clean; `check-documentation-policy.py` and
  `personal-info-guard.sh` pass.
  The new integration case compares the index against the Gateway's own full
  scan (`CatalogDiscovery.sessionInfos("all")`) after each of create, rename,
  fork and delete: paths, id, cwd, parent path, name, first message, message
  count, created/updated times, and `dev:ino`/size/end offset against a fresh
  `lstat`, with no index rows for deleted files and no duplicated IDs.
- Changes: new `session-catalog.ts` in `packages/gateway/src/sessions/`; the
  catalog owner wired into `packages/gateway/src/sessions/runtime-registry.ts`
  (constructor, startup, summary/rename/rekey/create/fork/delete hooks, shutdown
  ordering) and `packages/gateway/src/gateway-main.ts` (the record);
  `catalog-metadata-index.ts` gained the public durable read (`load`);
  `packages/gateway/docs/observability.md` gained `catalog.reconciled`; the integration tests
  noted above.
- Failure modes written before the owner (`session-catalog.test.ts`, one test
  each): a canonical file written while the index was not watching (a crash
  between the file write and the index update) is repaired by startup
  reconciliation; two files claiming one session ID stay two rows and the ID is
  reported as duplicated rather than merged; a rekey or append while a reader
  holds a row replaces the row instead of mutating it, so a held value cannot
  change; a durable document that is corrupt, or saved for another root, leaves
  the index to rebuild from canonical files instead of publishing foreign rows.
- Kept on purpose: the delegated topology rule moved to the catalog owner
  (`delegatedSessionParentPath` + `SUBAGENT_RUN_DIRECTORY`) so one owner
  classifies its own rows; the registry keeps the header/parent comparison that
  binds a projected parent. Every row still comes from
  `CatalogMetadataIndex.entryFromSummary`/`append`/`reconcile`, so the durable
  offset and tail boundary stay the write-proving evidence. The live slot
  summary is never adopted as row metadata: it carries presentation activity
  (dashboard `activeSince`, `latestDashboardActivityAt`) that canonical files do
  not, so the index would stop matching a full scan.
- Deviation (transitional dual owner): the owner deliberately reads and writes
  the same durable document as the reader path until G-1c deletes that path, so
  two writers can exchange a full-document snapshot. Both write full canonical
  cuts, so their content agrees once each has actually reconciled; the review
  round below found that second half was unenforced, and G-1c removes the second
  writer. Two existing counting tests were narrowed rather than deleted, both
  because background maintenance now calls the same methods they count: "reuses
  an on-disk catalog…" counts only the reader call's `append`s, and "rejects an
  unowned append that races durable-index reconciliation" settles the owner's
  background reconcile before injecting its append. O-3/O-5's "counts a walk a
  request waited on apart from background catalog walks" was first widened to
  `some` for the same reason; the review round below settled the owner instead
  and restored `every`.
- No catalog field changes for archive: archiving is a dashboard projection of
  the same canonical membership and the row contract has no archive field, so
  the plan's "archive" hook has nothing to apply.
- Flake watch (not this change's, recorded for the orchestrator): one full-file
  run timed out in `keeps a large streamed write visible through snapshot
  recovery and canonical handoff` (5.1 s) under the whole-file load; it passes
  alone (8.3 s) and the next full run was 247/247, so treat it as a load
  flake until the separate registry investigation says otherwise.
- For the next agent: G-1b owns the watcher, the per-path
  `CATALOG_EVENT_DEBOUNCE_MS` (250 ms) and the `CATALOG_RECONCILE_INTERVAL_MS`
  (30-minute) batched reconcile plus `catalog.watcher-reset`; the startup
  reconcile call site is the one to extend. G-1c switches `list`, `pageSource`,
  acquisition, attention, automation targets and storage maintenance onto
  `SessionCatalog.rows()` and deletes the old per-request walks together with
  the `CatalogMetadataIndex.reconcile` reader path. One flake to watch: the full
  integration file run had `keeps a large streamed write visible through
  snapshot recovery and canonical handoff` time out once at 5.1 s under the
  full-file load; it passes alone (8.3 s) and is not reproducible in isolation.

### G-1a · Done (review round 1) · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: an independent reviewer reproduced four defects the "matches a full
  scan" case does not reach; all four majors and eight minors are addressed, and
  none was rejected. The owner now writes the durable document only from a
  canonical cut, cannot publish a removed row back, never stamps a row with a
  size it did not count, stops a whole-catalog rebuild at shutdown, and reports
  what one reconcile covered and changed.
- Finding 1 (major, reproduced — shutdown wrote an empty or partial document):
  `SessionCatalog` now has `canonicalCut` (set only by a completed load or
  reconcile) beside the change/durable generations; `persistNow` writes only
  when both a canonical cut exists and a change is owed. A shutdown before
  `start()`, inside the load, or after a failed load with an incomplete scan
  leaves the prior document untouched. New cases: "keeps the prior durable
  document when shutdown precedes or interrupts the load" (dispose before start,
  and with the load's rows in hand), "rebuilds from canonical files when the
  durable document is corrupt or foreign" now restarts with the real source and
  asserts it rebuilds `id-a` instead of passing on an empty catalog.
- Finding 2 (major, reproduced — a removal could be published back): `remove()`
  runs its map deletion in the lane, and it records a per-path removal
  generation at the call. `reconcileIndex` captures its read epoch before its
  first read and `refreshPath` before its own, and both refuse to publish a row
  whose removal was announced after that epoch. New case: "does not publish a
  row back after a removal announced during its read", which also asserts a
  later pass proves membership from the folder again.
- Finding 3 (major, reproduced — a row could claim an offset past uncounted
  content): `CatalogMetadataIndexSummary` carries the `parsedSize` the counts
  were parsed from; the registry's `canonicalCatalogSummary` stats before and
  after the parse, retries while they differ, and `entryFromSummary` rejects a
  summary whose size no longer matches the file. `refreshPath` retries the tail
  append (bounded) before falling back to a whole-body parse, so a transient Pi
  append costs one tail read. New cases: "does not stamp a row with an offset
  past content it never counted" (owner level) and "refuses a summary the file
  outgrew between its parse and its stamp" (index level).
- Finding 4 (major — shutdown waited on an unbounded rebuild, and one
  unprovable file failed the whole cut): `CatalogMetadataIndex.reconcile` now
  reports `{ rows, unproven }` per file instead of `undefined` for the whole cut
  (only an unreadable document is still `undefined`), asks a caller-supplied stop
  check between batches and before each transcript parse (round 2 corrected this:
  the check read the index's own `closed`, which is set only after the catalog
  owner has already finished closing), and the owner retains its prior in-memory
  row for every unproven path, so a file with a partial final line no longer
  drops out of the index. `rebuild` checks the owner's `closed` between files,
  and the pre-G-1a acquisition path keeps its all-or-nothing admission by
  requiring `unproven.length === 0`.
  Updated/new cases: "reports a partial canonical final line per file without
  discarding its siblings", "reads reconciled files in one bounded batch at a
  time" (its 16-row batch gate still holds).
- Finding 5 (major, orchestrator-decision flagged): the timer is now a true
  debounce — each real change resets the quiet spell — capped by
  `CATALOG_PERSIST_MAX_WAIT_MS` (60 s) so a catalog that never goes quiet still
  reaches the document. The spurious writes are gone with the dirty flag:
  `publishRows` returns what actually changed, `publishRow` returns false for an
  unchanged row, and `refreshPath` no longer reports "produced" for an unchanged
  append copy. The plan's `CATALOG_PERSIST_DEBOUNCE_MS` (5 s) is unchanged. The
  write volume is not measured here: G-10 owns the durable-write audit and its
  `gateway.resources` counters, and this record reports its own counts.
- Finding 6 (minor): `files` is now `scan.candidates.length` and
  `{ added, removed, modified }` are counted from the published cut; `unproven`
  counts files the pass could not prove; `incomplete` and `failed` passes report
  instead of returning silently, at warning. The counts are record fields, which
  is why `LogMetadata` gained a bounded generic `counts` map (the logger bounds
  the number of entries, their names and their values). `observability.md`'s
  `catalog.reconciled` row states the new levels, fields and reason.
- Finding 7 (minor): the closed hook's `!persistedPathWasIndexed` branch now
  also calls `sessionCatalog.refresh(persistedPath)` beside
  `invalidateCatalogAcquisition()`.
- Finding 8 (minor): "counts a walk a request waited on apart from background
  catalog walks" settles the catalog owner before the request and asserts
  `every` walk in the window is request-path (and every earlier one is not),
  instead of accepting one flagged walk anywhere in the window.
- Finding 9 (minor): the corrupt-document half of the startup test now starts a
  real owner with the canonical source and asserts it rebuilds `id-a`; the
  failure-mode list at the top of the file gained modes 5–7 for the new cases.
- Finding 10 (nit): the `delegatedTopologyParentPath` pass-through is deleted
  and its four call sites use `delegatedSessionParentPath` directly; the joined
  `*/  private delegatedSessionTopologies(` line is split.
- Finding 11 (nit): `catalogRoot()` caches only a successful `realpath`, so a
  root that does not exist yet is re-resolved once it is created.
- Finding 12 (nit, deferred as the review allowed): `catalog.changed` (debug) is
  not emitted here. G-1b owns it: it adds the watcher that produces the change
  stream the record describes, and G-1a's readers are not switched yet, so a
  per-append debug record would have no consumer. This entry is the handoff.
- Evidence: `npx tsc --noEmit -p .` clean. `npx vitest run
  src/sessions/session-catalog.test.ts src/sessions/catalog-metadata-index.test.ts`
  26/26; `src/sessions/catalog-discovery.test.ts` 2/2;
  `src/transport/logger.test.ts` 13/13; `runtime-registry.integration.test.ts`
  focused runs: `-t "catalog"` 34/34, `-t "index"` 8/8, `-t "delete"` 6/6,
  `-t "dispose|shutdown|session close"` 6/6, and the five review cases 5/5.
  `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Residual risk for the orchestrator: a file this pass cannot prove and that has
  no prior row (a new file whose last line is incomplete) is still absent from
  the index until a later pass proves it; the reconcile record's `unproven`
  count is the signal, and the durable document keeps every row it already had.
  G-10 owns the document's measured write volume, and G-1b owns the watcher and
  the `catalog.changed` record.

### G-1a · Done (review round 2) · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: a second independent reviewer found one major defect that round 1 only
  partly fixed, plus six minors and two nits; none was rejected. Shutdown now
  stops a startup reconcile in the ordinary case (a usable durable document), the
  durable document has one writer, and the shutdown stop and the reader-side stop
  are the same caller-supplied check.
- Finding 1 (major, reproduced — shutdown still waited for the whole startup
  reconcile whenever the durable document was usable): the between-batch check
  read `CatalogMetadataIndex.closed`, which `runtime-registry.ts`'s
  `disposeSharedStores` sets only after `SessionCatalog.dispose()` has returned,
  so it was always false while the catalog owner was closing; only the
  no-document `rebuild` path stopped early. `CatalogMetadataIndex.reconcile` now
  takes a caller-supplied `CatalogMetadataReconcileStop` (asked between batches
  and before each transcript parse) and the owner passes `() => this.closed`. New
  case: "stops a startup reconcile within one batch when the owner is disposed" —
  64 files, a durable document and one whole-body parse per candidate: `dispose`
  returns after one bounded batch (≤ RECONCILE_CONCURRENCY summary reads) and the
  prior document is unchanged. With the pass-through removed the same case
  observes all 64 parses (the reviewer's own probe measured 3,042 ms and 160
  parses in the same shape).
- Finding 2 (minor, inferred — a second writer could restore the undercount):
  `persistDurableCatalogIndex` and its call in `materializeCatalogSnapshot` are
  deleted. The owner is the document's only writer, which its own `persistNow`
  always was; `SessionCatalogOptions.index`'s comment and
  `packages/gateway/README.md`'s acceleration-file paragraph now say so, and the
  integration fixtures that waited for the sidecar settle the owner instead
  (`settleCatalog`). New case: "writes the durable catalog document from its
  owner, not from a reader cut". Round 3 corrected that case: the deleted writer
  was fire-and-forget, so the case now flushes the reader's deferred chain before
  asserting instead of checking an immediate call count it could not observe.
- Finding 3 (minor — logger scope, no bounding test, redundant escaping): the
  `counts` field and `boundedCounts` in `transport/logger.ts` stay as the
  `catalog.reconciled` record's field contract; the orchestrator accepted that
  scope as an explicit decision when it dispatched round 3. New case:
  "bounds the named counters one record carries" covers the count cap, the name
  shape, non-finite and negative values and the persisted round trip; the cap now
  counts the counters the field accepts rather than the raw entry list, and the
  redundant `boundedDiagnosticID` call is gone (the shape check already rejects
  anything but letters and digits). Not closed: the level rule itself
  (`reconciled` at info, otherwise warning) lives in `gateway-main.ts`, a
  side-effecting process entry no test can import; the record's field values are
  covered by `session-catalog.test.ts`'s `SessionCatalogReconcileOutcome` cases
  and by the logger case above.
- Finding 4 (minor): "reuses an on-disk catalog across a second registry without
  a body scan and advances one appended row" settles the restarted owner right
  after `initialize()`, as its two sibling cases do, and asserts the exact
  `toHaveBeenCalledTimes(1)` append instead of a count taken inside the owner's
  window.
- Finding 5 (minor): the pre-G-1a acquisition path passes the same stop check as
  `({ unproven }) => unproven > 0`, because it discards its whole cut when one
  candidate is unprovable. New case: "stops a pass at the first file it cannot
  prove when its caller asks" (24 candidates, one unprovable: 16 rebuilds, not
  24).
- Finding 6 (nit): a removal marker is now deleted by its own lane work instead
  of being pruned when a reconcile starts, so the map no longer grows with every
  deletion for the life of the process; "does not publish a row back after a
  removal announced during its read" asserts the map is empty once that removal
  has settled.
- Finding 7 (nit): the `catalog.reconciled` row's "why" column no longer
  describes this branch's own earlier state.
- Evidence: `npx tsc --noEmit -p .` clean; `session-catalog.test.ts` 9/9,
  `catalog-metadata-index.test.ts` 19/19, `transport/logger.test.ts` 14/14,
  `runtime-registry.integration.test.ts` `-t "catalog|delete|index"` 44/44 plus
  the round-2 cases; `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Residual risk for the orchestrator: the durable document is now refreshed only
  by the owner's own changes (5 s debounce, 60 s ceiling) and by its startup
  reconcile, so a file written by an external writer (a Pi child, a copied file)
  reaches the document only when the owner next reconciles; until G-1b's watcher
  lands, a restart repairs those rows by re-reading their files. G-1b owns that
  gap.

### G-1a · Done (review round 3) · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: a third review approved G-1a and reproduced the round-2 major fix and
  the worker's negative control. It found one minor — a new case that could not
  fail against the bug it names — plus two inaccurate sentences in the round-2
  entry. Both are fixed here; no product code changed.
- Finding 1 (minor, reproduced): "writes the durable catalog document from its
  owner, not from a reader cut" asserted `expect(save).not.toHaveBeenCalled()`
  the moment `catalog("all")` returned, but the deleted reader-path write was
  fire-and-forget (`void this.persistDurableCatalogIndex(...)`) and reached
  `save` only after awaiting one summary per row, so the assertion could not
  observe it. The case now flushes that deferred chain before asserting (250 ms,
  the bounded flush the reviewer's 200 ms probe used to surface one call) and
  also asserts the read did not recreate the document it had removed.
- Finding 1 negative control: with `b06aff0c8`'s `runtime-registry.ts` hunk
  reversed in this worktree, the case fails with `Number of calls: 1` in three
  runs of three (`expected "save" to not be called`); with the fix restored it
  passes, alone and in the focused `-t "catalog|delete|index|durable|owner"`
  run. The reversed patch was reverted before this entry.
- Finding 2 (nit): the round-2 entry's claim that the case "observes that write"
  with a reader-path save re-added was false for the real old path, and its
  logger-scope sentence reported an orchestrator acceptance that had not been
  given. Both sentences are corrected in place above.
- Orchestrator decision (recorded at dispatch of this round, per the task's own
  text): the `counts` field and `boundedCounts` scope widening in
  `transport/logger.ts` is accepted as the `catalog.reconciled` field contract.
  G-10 still owns the measured write volume and its resource counters.
- Evidence: `npx tsc --noEmit -p .` clean; `runtime-registry.integration.test.ts
  -t "catalog|delete|index|durable|owner"` 69/69; the changed case alone passes;
  `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Residual risk unchanged from round 2: the owner is the document's only writer,
  so external writers (a Pi child, a copied file) reach it only at the owner's
  next reconcile until G-1b's watcher lands, and a Gateway-owned append that does
  not change the slot summary can leave a row's size and mtime behind until its
  next summary change.

### G-10 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-10`)

- Result: the fsync inventory is complete with path, rate and latency, and the
  one durable write that serialized unrelated work is fixed. `CommandReceiptStore`
  keeps `inventoryMutex` for accounting only: admission reserves the bytes and
  returns, the pending and completed receipt writes run in the command's own
  lane outside the mutex, and the accounting step that publishes the receipt's
  bytes is the same step that releases the reservation. Two concurrent
  mutations' receipt fsyncs now overlap. A write no longer excludes a
  reconciliation of the inventory from the directory either: the store credits
  the accounting a lane still owes instead of the file that write published, so
  a receipt is never counted twice and no write in flight can discard the
  totals. The rebuild counter of this round's first pass did discard them, and
  the next admission then rescanned the directory for every overlapping write;
  the second review response below deletes it. Two fsyncs are still started by
  reads; the
  catalog one belongs to the catalog owner and the connection-admission one to
  the connection owner, and both are named as this row's residuals (below).
- Failure modes written before the tests: (1) a receipt's fsync holds the
  process-wide inventory mutex, so a second command's durable write cannot start
  until the first finishes; (2) the byte reservation is released before the
  inventory carries the receipt, so a concurrent admission under-counts and the
  aggregate byte cap is exceeded on disk; (3) a receipt written but never
  accounted, or accounted without being written, drifts the inventory from disk;
  (4) a disposable read waits on an fsync; (5) a prune meets a temporary file of
  a receipt write that is still in flight and removes it, so the publication
  fails with ENOENT after the operation already ran and the receipt stays
  pending forever. Failure mode (5) was found by the independent review, not
  written before the code; its case and fix arrived in the review response.
- The fsync list (Do item 1). Every fsync in the Gateway goes through
  `syncDurably` in `packages/gateway/src/util/durable-json.ts`; the only
  `.sync()` call anywhere under `packages/gateway/src` is inside it, so no
  durable write bypasses the counters. `durableAtomicWriteJson` synchronizes
  twice (the document, then its directory entry after the rename);
  `durableRemove` synchronizes the directory once, and only when it removed a
  file. The table was incomplete when it was first written; the review response
  added the connection owner, the iOS device install documents and the startup
  configuration rows below.

  | Interactive path | fsyncs | When | Where |
  | --- | --- | --- | --- |
  | admitted idempotent mutation (`CommandReceiptStore.execute`) | 4: pending + completed, 2 each | per new command; a replayed duplicate reads the receipt and fsyncs nothing | `packages/gateway/src/transport/command-receipts.ts` |
  | prompt admission and terminal stamps (`RunMarkerStore`) | 2 | per accepted operation, and per changed terminal completion | `packages/gateway/src/sessions/run-markers.ts` |
  | attention set/complete (`SessionAttentionStore.commit`) | 2 | only when the projection changes; an unchanged set returns without writing | `packages/gateway/src/sessions/session-attention-store.ts` |
  | `push.registration.upsert` (`NotificationGrantStore.update`) | 2 | every registration, because the grant's `updatedAt` is refreshed | `packages/gateway/src/notifications/grant-store.ts` |
  | settings and model-config writes (`updateJsonLocked`) | 2 | per accepted write, before its response | `packages/gateway/src/util/json.ts` |
  | pairing, token issue and revocation (`DeviceStore`) | 2 per document (1 for a removal) | pairing and revocation mutations | `packages/gateway/src/security/device-store.ts` |
  | upload commit (`UploadStore.commit`) | 3: body, metadata, object directory | per committed attachment | `packages/gateway/src/machine/upload-store.ts` |
  | display artifact ingest (`DisplayArtifactStore`) | 2 per publication | per ingested artifact and per metadata change | `packages/gateway/src/display/display-artifact-store.ts` |
  | knowledge revisions (`KnowledgeStore`) | 2 | per retained or scrubbed revision; the storage migration is once at startup | `packages/gateway/src/knowledge/knowledge-store.ts` |
  | session export | 1 per written cut | once per export request | `packages/gateway/src/sessions/session-export.ts` |
  | archive and automation records | 2 | per mutation | `packages/gateway/src/sessions/session-archive-store.ts`, `packages/gateway/src/automations/automation-store.ts` |
  | recent-model recency (`RecentModelStore.record`) | 2 | fire-and-forget on a run start; a run never waits for it | `packages/gateway/src/providers/recent-models.ts` |
  | enrollment invitation refresh (60 s timer) | 2, or 1 when only the expired invitation is removed | when the 10-minute pairing code had expired | `packages/gateway/src/security/device-store.ts` (timer in `gateway-main.ts`) |
  | workspace first initialization | 3 | once, at startup; not on a request path | `packages/gateway/src/workspace/tron-workspace.ts` |
  | connection owner state (`ConnectionOwner.execute`, `markRuntimeReady`, `recordProviderObservation`) | 2 | per accepted connection command; per runtime admission that becomes ready; and on every provider admission observation, including the one a `knowledge.raindrop.read` awaits | `packages/gateway/src/integrations/connection-owner.ts` |
  | iOS device install status and config documents | 2 per document | per `device.install.config`, `device.install.target.bind` and `device.install` mutation, plus the install helper's own running and terminal status writes | `packages/gateway/src/admin/ios-device-install-service.ts` |
  | Gateway identity configuration | 2 | once at startup; a stored legacy `defaultWorkspace` field is normalized once | `packages/gateway/src/config.ts` |

  Rate and latency, measured on the 30 s multi-session smoke run below: one
  `gateway.resources` window reports `durableWrites=100`, `durableWriteMs=1740`
  over `windowMs=60200` — 1.7 completed fsyncs per second and 17.4 ms per fsync
  — in a window carrying 11 admitted prompts (8 setup + 3 measured), 16
  `session.open` and 8 `session.list`. Prompt admission is the largest single
  contributor at 6 fsyncs (4 for the receipt pair, 2 for the run marker), which
  is the serialization Do item 2 removes; the idempotent registration and the
  fire-and-forget recency write are each one durable write per interaction.
- Read-triggered fsyncs, each kept with its owner (two, after the review
  response):
  - Catalog index: `session.list` and the
    pre-subscription part of `session.open` reach
    `RuntimeRegistry.sharedCatalogMaterialization` →
    `materializeCatalogSnapshot` → `void persistDurableCatalogIndex(...)`
    (`packages/gateway/src/sessions/runtime-registry.ts`), which rewrites the
    8 MiB `catalog-metadata-v2.json` through `CatalogMetadataIndex.save` — 2
    fsyncs per exact catalog generation. No read waits on it, but a read starts
    durable work. It is not fixed here: those files are the Catalog zone held by
    G-1a, whose Do item 4 debounces that persist (`CATALOG_PERSIST_DEBOUNCE_MS`,
    5 s) and requires "never per read", and G-1c deletes the request-path
    materialization. **Orchestrator decision 2026-09-28:** record it as G-10's
    residual and mark the row Done rather than edit G-1a's files; the removal is
    added to G-1c's Do list explicitly.
  - Connection admission observation, added in the review response: the table
    above did not list it. `knowledge.raindrop.read` calls
    `KnowledgeConnectorService.readRaindrop`, whose `observe` closure awaits
    `ConnectionOwner.recordProviderObservation` (`observe` in
    `packages/gateway/src/knowledge/connectors.ts`, the owner in
    `packages/gateway/src/integrations/connection-owner.ts`) on every read
    attempt, which rewrites the connection state document and bumps `updatedAt`
    and `stateRevision` even when the observation is unchanged — 2 awaited
    fsyncs on the read. It is left as G-10's second residual: skipping an
    unchanged observation changes the revision semantics of the state document,
    whose only authority is the connection owner and which is not a G-10 owning
    file. **Orchestrator decision 2026-09-28:** G-10 stays Done with this
    residual named, and the fix — return without saving when the four projected
    fields are unchanged, with a case in
    `packages/gateway/src/integrations/connection-owner.test.ts` — is added as
    task G-10a below.
- Every other fsync in the list is a mutation, or a step a mutation owns, and no
  disposable read waits on one: `CommandReceiptStore.status` reads a receipt
  with `readJson` only and has no write path.
- Evidence:
  - `npx vitest run src/transport/command-receipts.test.ts` passes 22/22 in 1.9 s,
    including the two new cases. The new cases are discriminating: with
    `command-receipts.ts` stashed, "does not serialize one command's durable
    receipt write behind the inventory mutex" fails (`expected 1 to be 2`: the
    second writer never starts), and a variant of the new code that releases the
    reservation at admission makes "counts an unrecorded receipt's bytes while
    its write is in flight" fail (both commands admitted, the byte cap exceeded).
    The file's existing corrupt, empty, oversized, interrupted-write and
    exact-byte-boundary cases are the crash-safety checks and stay green in the
    same 22. The review response grew the file to 24 cases (see below).
  - `npx vitest run src/transport/rpc-idle-admission.integration.test.ts
    src/transport/session-archive.integration.test.ts
    src/transport/gateway-service-transcript.test.ts` passes 57/57 (16.5 s), and
    `src/transport/server-capacity.integration.test.ts` passes. `npm run build`
    is clean.
  - One flake observed, not attributable to this change:
    `src/transport/request-span.integration.test.ts`'s
    `expect(durationMs).toBeGreaterThan(100)` on the 100–200 MiB cold open
    failed once when it ran in the same vitest invocation as
    `server-capacity.integration.test.ts` (23/24 in 10 s), and passes alone both
    with this change (1/1 in 18.9 s) and on the previous commit. This change
    does not touch the open path.
  - Smoke measurement: `scripts/tron-profile gateway --scenario multi-session
    --iterations 1 --mixed-seconds 30 --catalog-files 300 --catalog-mib 64
    --no-build` finished in 2.2 min of scenario time and left
    `~/Library/Developer/Tron/profiles/gateway/20260928T123621Z-multi-session-bd19e6`;
    its `fixture/gateway.jsonl` holds the `gateway.resources` record above. The
    extracted record with `report.json` and `summary.md` is retained in the
    internal workspace under `files/hardening/g-10/`.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: the G-10 commits on `hardening/g-10`.
- "Done when" item 1 (two concurrent mutations' receipt writes overlap): proven
  by the new concurrency test with real `durableAtomicWriteJson` fsyncs on a
  temporary store, not by a full-size O-6a run — the orchestrator allowed this
  because the host is busy (the smoke run above is the same-scenario rate
  evidence). Item 2 (no read path in the fsync list): met for every site inside
  G-10's owning files; two read-triggered writers remain, the catalog index and
  the connection admission observation named above, with their removals owned by
  G-1a/G-1c and by G-10a.
- Tasks added: none. G-1c's Do list gains the persist removal (orchestrator).
- Kept on purpose: `push.registration.upsert` still rewrites its grant document
  on every registration (2 fsyncs). It is an acknowledged mutation, so it stays
  durable before its response; removing the repeated traffic is G-7's reconnect
  diet, not a durability change. `prune` stays inside `inventoryMutex` (it owns
  the entry and byte totals) and fsyncs nothing: it removes expired receipts
  and interrupted temporary files with `rm`, but never a temporary whose command
  still holds a lane, because that file is a publication in flight. The
  definitive-rejection path still
  removes the pending receipt without a directory fsync, because a rejected
  command leaves no durable evidence to preserve.
- Deviations:
  - The task names `packages/gateway/src/notifications/notification-service.ts`
    as an expected writer. It has no fsync site: its durable write is
    `NotificationGrantStore.update`, counted above. Nothing was changed there.
  - The measurement is a 30 s mixed window over a 300-file, 64 MiB catalog, not
    the full-size qualification run, so its rate is indicative rather than the
    R-1 number. The harness rejects a 16 MiB catalog ("16777216 bytes cannot
    hold the fixed sessions and 175 other files"), hence 64 MiB with 300 files.
  - `runtime-registry.ts` and `catalog-metadata-index.ts` were not edited, per
    the orchestrator's decision above.
- For the next agent: R-1 should read `durableWrites`/`durableWriteMs` from the
  fixture's `gateway.jsonl` for the release-candidate numbers — the counters are
  process-global and include the catalog index's read-triggered persist until
  G-1a/G-1c land, and the connection admission observation's until G-10a lands.
  A window whose level stays debug is memory-only, so the
  full-size run reports fewer resource windows than it has minutes. The
  `request-span.integration.test.ts` open-timing assertion above is host-load
  sensitive and is worth re-checking on a quiet host rather than at the same
  time as another large integration file.

### G-10 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker, review response (branch `hardening/g-10`)

- Result: one blocker and three minor findings closed, one nit closed, on the
  same branch as the audit. A receipt prune no longer removes the temporary of a
  receipt write that is still in flight: `pruneUnlocked` scavenges an owned
  temporary only when no lane holds its command key, and a lane exists from
  admission until every user of that command drains. The rebuild counter's
  pending-write window is now covered, the concurrency case is a liveness
  assertion instead of a 200 ms race, the fsync table gained the rows the review
  found missing, and the admission-time `preserveReceiptUntilDrain` flag moved
  back to after the pending write, so a failed write leaves no fence behind.
- Blocker closed: `pruneUnlocked` ran under `inventoryMutex` while receipt
  writes no longer did, so it could `rm` the `<key>.json.<pid>.<hex12>.tmp` of a
  write in flight; that write's `rename` then failed with ENOENT after
  `operation()` had already run, and the receipt stayed pending forever (an
  operator reconciliation fence for an applied mutation). The reproduction the
  review described is now the case "does not scavenge a temporary receipt whose
  command is still writing": the real `durableAtomicWriteJson` with only the
  completed `rename` held, a `prune()` in that window, and assertions that the
  command fulfils, that its receipt is `completed`, and that one file remains.
  With the lane check removed the case fails exactly as the review saw it:
  `ENOENT … rename '<key>.json.<pid>.<hex>.tmp' -> '<key>.json'`.
- Counter coverage: "does not double-count a receipt rebuilt from disk during
  its pending write" holds a pending receipt's publication, forces a rebuild in
  another admission's rescan (`prune(0)` over a backdated seed), and then asserts
  the exact-boundary admission is admitted, not busy: with the pending
  rebuild guard removed the store reports three entries for two receipts and
  rejects the third command with a false `busy`.
- Reconciled with review nit 5: `lane.preserveReceiptUntilDrain` is set after
  the pending receipt write succeeds rather than at admission. Pending receipts
  are never pruned by age and an admission that finds an existing receipt
  returns or throws before reaching the flag, so the earlier placement only had
  the effect of leaving the flag set on a lane whose pending write failed.
- Failure mode (5) in the list above and the three missing fsync rows are from
  this round, as is the connection-owner residual and its G-10a row.
- Evidence:
  - `npx vitest run src/transport/command-receipts.test.ts` passes 24/24
    (0.9–1.2 s) four times in a row. Negative controls: remove the lane check →
    only the new temporary case fails; remove the pending-rebuild guard → only
    the new double-count case fails; put the receipt writes back under
    `inventoryMutex` → "does not serialize…" fails by per-test timeout (15 s)
    instead of hanging.
  - `npx vitest run src/transport/rpc-idle-admission.integration.test.ts` passed
    2/2 in five consecutive runs, plus 2/2 once with `--no-cache`. Its first,
    cold run in this worktree failed one of the two cases; that failure was not
    reproducible and its assertion was not captured, so it is recorded rather
    than diagnosed. The review saw 2/2 on this file against the previous commit
    of this branch, and this round changes no admission, queue or session path.
  - `npx tsc --noEmit -p .` is clean. `python3 scripts/check-documentation-policy.py`
    and `scripts/personal-info-guard.sh` pass.
- Changes: the review-response commit on `hardening/g-10`.
- Residual scope, added as task G-10a in the second review response below: in
  `packages/gateway/src/integrations/connection-owner.ts`,
  `recordProviderObservation` returns without saving when the four projected
  fields are unchanged, so a `knowledge.raindrop.read` starts no fsync; case in
  `packages/gateway/src/integrations/connection-owner.test.ts`.
- Kept on purpose: the completed-write window of the rebuild counter still has
  no admission-level case (superseded by the second review response below,
  which deletes the counter, and by the third, which adds that case for the
  lane-credited design). Its only unguarded effect is a byte over-count of
  `completed - pending` for one receipt. The pending-write window is where the
  counter is observable (entries double-counted → false `busy`), and that case
  is present.
- Deviations: the review's finding-2 suggestion "the fix for finding 1 can share
  this setup" is implemented as a separate case, because finding 1's held write
  must hold *before* the `rename` (temporary on disk) while finding 2's must hold
  *after* it (receipt published, so a rescan can count it).
- For the next agent: the residual from the previous entry stands; the
  `request-span.integration.test.ts` host-load note above still applies.

### G-10 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker, second review response (branch `hardening/g-10`)

- Result: the major finding (one invalidation made nearly every admission rescan
  the receipt directory) is closed, with the review's minor finding 2 and nit 3.
  The rebuild counter is deleted. A rebuild now credits what an in-flight write
  of a lane still owes instead of discarding the whole inventory: each lane
  carries `unaccountedWrite` (true from the start of a receipt write until that
  write's accounting has run) and `creditedBytes` (`undefined` until the pending
  write is accounted, then the pending size and finally the completed size).
  `inventoryUsage` credits `creditedBytes` for a key whose lane holds an
  unaccounted write, and skips it while that value is `undefined`, so every
  accounting step can always apply its change. Only a prune that removed
  evidence invalidates the cached totals, and an admission runs at most one
  prune pass per interval, so one invalidation costs one rescan.
- Why the previous design was wrong: a command whose pending or completed write
  spanned a rebuild set `this.inventory = undefined` when its accounting ran.
  Under the load this row targets — several commands' writes overlapping —
  the next admission then rebuilt while those writes were still in flight,
  invalidating the totals again, so nearly every admission rescanned a
  directory of up to 32,768 receipts while holding `inventoryMutex`; the review
  measured 19–50 rebuilds against 1–2 for the same load on
  `hardening/integration`.
- Failure mode (6), named by the independent review with its reproduction
  rather than written before the code: one cache invalidation under overlapping
  receipt writes makes every following admission rescan the receipt directory.
  The case "rescans the receipt directory once per prune invalidation while
  writes overlap" plants a crash leftover after the first admission has
  already run its interval prune, holds four commands' pending writes, forces
  the invalidation with `prune()`, then runs one admission inside that window
  and one after the writes land, and counts the directory scans between them
  with `vi.mock("node:fs/promises", importOriginal)`. The store gets no
  production hook.
- Negative controls, each run on the same test file: with `command-receipts.ts`
  at the previous commit the new case fails with `expected 2 to be 1` and
  nothing else fails; a rebuild that trusts the file for a lane with an
  unaccounted write fails only "does not double-count a receipt whose pending
  write spans a directory rescan", with the false `busy`; releasing the
  reservation at admission fails only "counts an unrecorded receipt's bytes
  while its write is in flight", `[fulfilled, fulfilled]` instead of
  `[fulfilled, rejected]`.
- Nit closed: that reservation case holds its first pending write until the
  second admission settles instead of for a fixed 100 ms, so host load can no
  longer let it pass on a store that released the reservation at admission.
- Superseded: `inventoryRebuilds`, both "discard the totals" branches, the
  "the next admission rescans the directory" mechanism sentence in this row's
  result above, and the "kept on purpose" note about the completed-write window
  having no admission-level case. That window is now covered by the lane's
  `creditedBytes`, and the invalidation itself by the new case.
- Tasks added: G-10a (orchestrator decision 2026-09-28) for the
  connection-admission fsync residual named above.
- Evidence:
  - `npx vitest run src/transport/command-receipts.test.ts` passes 25/25
    (0.8–1.2 s) three times in a row.
  - `npx vitest run src/transport/rpc-idle-admission.integration.test.ts` passes
    2/2.
  - `npx tsc --noEmit -p .` and `npm run build` are clean;
    `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: the second review-response commit on `hardening/g-10`.
- For the next agent: G-10a is the read-triggered fsync this row leaves open,
  and the `request-span.integration.test.ts` host-load note in the first entry
  still applies.

### G-10 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker, third review response (branch `hardening/g-10`)

- Result: the third review's two minor findings and its plan nit are closed on
  this branch. A definitively rejected command no longer leaves its removed size
  behind as its lane's credit, so a duplicate that re-runs that command cannot
  be counted twice when its pending write spans a rebuild. The completed-write
  window now has the admission-level case the previous entries said it had no
  room for.
- Finding 1 (a stale `creditedBytes` after a definitive rejection): the
  rejection path removed the pending receipt from the disk and from the totals
  but left `lane.creditedBytes` at that receipt's size, so the next write on the
  same lane — a duplicate whose predecessor was rejected definitively, which
  re-runs the command — reported a credit for a receipt that no longer existed.
  A rebuild crediting it and that write's own accounting then counted the
  receipt twice: one extra entry and its bytes, observable as a false `busy`
  near the entry cap. Fixed by clearing `lane.creditedBytes` in the same mutex
  step that removes the receipt, which keeps a lane's credit equal to what its
  receipt contributes to the totals on every path (pending write, completed
  write, retained uncertain receipt, removed definitive rejection).
  - Case: "does not credit a definitively rejected receipt to the next write on
    its lane" — two duplicates of one command, the first rejected definitively,
    the second's publication held after its rename, a backdated seed reclaimed
    by `prune(0)` so the next admission rebuilds while that publication is on
    disk, then an admission with `maximumEntries: 3`. Without the one-line reset
    the store counts three entries for two files and the third command is
    rejected `busy`; 26 of the 27 cases still pass, so the case is
    discriminating.
  - The first entry's "a receipt is never counted twice" sentence is accurate
    again: the rejection path was the one window where it did not hold.
- Finding 2 (the completed-write window was untested): the second entry argued
  that the byte over-count could not flip an admission because the held write's
  reservation is counted at admission. That is wrong for a boundary that covers
  two maximum receipts: with
  `maximumAggregateBytes = 2 * COMMAND_RECEIPT_MAX_BYTES + 1024`, an admission
  in that window is admitted against the rebuilt pending credit and rejected
  against the same receipt counted at its completed size.
  - Case: "does not double-count a receipt rebuilt from disk during its
    completed write" — a 200 KB result's completed publication held after its
    rename, the seed reclaimed so the trigger's admission rebuilds inside that
    window, and the exact-boundary admission admitted. Removing
    `lane.unaccountedWrite = true` before the completed write fails only this
    case (`busy` at the boundary); the other 26 still pass.
  - Superseded: the first review-response entry's "kept on purpose" note that
    the completed-write window cannot have an admission-level case.
- Nit (plan wording): the two "proposed connection-owner row" sites now name
  G-10a, and "Tasks added: G-10a" stays only in the second review-response
  entry; the first review response names the residual's scope and points at the
  round that added the row.
- Evidence:
  - `npx vitest run src/transport/command-receipts.test.ts` passes 27/27 in
    1.0–2.0 s, four runs in a row.
  - Negative controls on the same file: with the `creditedBytes` reset removed,
    only "does not credit a definitively rejected receipt to the next write on
    its lane" fails; with `lane.unaccountedWrite = true` removed before the
    completed write, only "does not double-count a receipt rebuilt from disk
    during its completed write" fails. Both fail with the false `busy`.
  - `npx tsc --noEmit -p .` and `npm run build` are clean;
    `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: the third review-response commit on `hardening/g-10`.
- Tasks added: none.
- For the next agent: G-10a is the read-triggered fsync this row leaves open,
  and the `request-span.integration.test.ts` host-load note in the first entry
  still applies.

### G-8 · Done · 2026-09-28 · worker session (branch `hardening/g-8`)

- Result: background work audit. Every item in the row's "Do" list has a cause
  read from the code and measured from the live Gateway log
  (`~/.tron/logs/gateway.jsonl`) and the unified log, both read only. Four
  items become new rows (G-8a, G-8b, G-8c, G-8d); one is already bounded and
  needs no change. No running Gateway, app, state or process was touched. The
  "Do" names
  O-6a runs as a source; O-6a is Blocked on a quiet-host repeat, so no O-6a run
  exists yet and this audit used the live log and the code instead.
- Evidence:
  - **`extension.artifact-rejected`: 1,118 records** from 2026-09-24T12:35 to
    2026-09-28T12:53, 61 in the worst hour (2026-09-28T07) — 17.8% of the 6,284
    records in the log (15.9% by bytes). The warning is intermittent, not a
    constant once-a-minute re-report: across the 130 distinct owners the 988
    gaps between one owner's warnings have p25 86 s, median 151 s and p75
    300 s, and only 37 (3.7%) fall in 60–62 s. A cadence fixed by the 60 s
    dedup would put nearly all of them there, so the cause is a replacement
    race, not a permanently absent `status.json`. Cause, from code:
    pi-subagents rewrites an active run's `status.json` by atomic rename, and
    `RuntimeSlot.openOwnedExtensionArtifact` (`runtime-slot.ts:4033–4039`)
    returns `undefined` when the file's inode changes between `open` and
    `stat` (or the realpath is briefly gone).
    `RuntimeRegistry.discoverExtensionArtifacts` (`runtime-registry.ts:3675`,
    every 750 ms via `:597`) warns on that single racing read with no retry
    (`runtime-slot.ts:4374–4377`), and `warnExtensionArtifact` (`:4278`) dedups
    60 s per (opaque owner, reason), so repeated races become the record
    volume. The watcher lane (`refreshExtensionActivityFromArtifact`,
    `:4739–4762`) retries the same read three times first; the discovery pass
    also re-reads, unretried, every running owner that already has a watcher.
    The 30 s grace in `observeMissingExtensionArtifact` (`:4295`) never quiets
    this warning: a later successful read clears
    `extensionArtifactMissingSince` (`:4380`), and a one-off race never reaches
    the grace. The row's "why five owners retry replacement" is answered as
    "they do not retry it": five is the count of distinct live bindings warned
    in a busy minute, each for a momentarily unreadable artifact. 359 B per
    record is about 100 KB/day (359 B × ≈1,150 records over 4.2 days) of the
    1 MB/day budget. Re-measured 2026-09-28T13Z: 1,180 records of 6,357 (18.6%;
    16.6% by bytes), 133 owners, 1,047 per-owner gaps p25 86 s / median 147 s /
    p75 287 s, 3.8% in 60–62 s, worst hour 2026-09-28T12 with 70. **The cause is
    inferred**, not reproduced: no code reproduces the race, and the same
    `artifact-replacement-in-progress` string is also emitted for any
    unclassified error thrown in the refresh body (`extensionArtifactReadFailureReason`
    default, `runtime-slot.ts:287–292`, used at `:4576`) and for a `status.json`
    that does not exist yet before its first write (`realpathSync` ENOENT →
    `undefined`, `:4018–4024`, warned in the discovery lane at `:4377`). The log
    cannot tell these apart, and every one of the 1,180 records carries this
    reason. The evidence for the race is the gap distribution plus the code,
    and G-8a must prove it by reproducing it (below).
  - **Tailscale CLI every ~37 s: the Mac app's menu-bar status poll.**
    `log show` over `nesessionmanager` client attaches: 15 samples from
    05:26:05.957 to 05:35:23.317, deltas 29.1–36.3 s (mean 34.7 s; 12 of 15
    between 33.7 and 35.8 s); a second sample 05:46–05:59 the same day saw 35
    attaches at 35–45 s. A 45 s `ps -axo pid,ppid,comm` sample caught the
    child: `41014 71837 (Tailscale)`, parent 71837 =
    `/Applications/Tron.app/Contents/MacOS/Tron`; `sample 71837` for 40 s shows
    the app inside `Subprocess.run(executable:arguments:policy:)`
    (`Subprocess.swift:22`). Code: `EnvironmentSetup.makeLive`'s `pingServer`
    resolves the host through `resolveTailscaleHost` → `TailscaleProbe.probe()`
    → `Subprocess.run` of
    `/Applications/Tailscale.app/Contents/MacOS/Tailscale status --peers=false --json`,
    and `MenuBarController.install` runs `ServerStatusPoller` (interval 30 s),
    which calls `setup.pingServer` on every cycle. One CLI spawn per poll (a
    30 s sleep plus the ≈4.0 s of per-cycle CPU work measured below). `log show`
    shows each spawn makes Tailscale re-add its network-extension configuration
    ("Clearing/Adding C4C66EAF-… to the loaded configurations", "Adding a
    connection for client tailscale[pid]") — ≈2,490 spawns a day at the
    measured 34.7 s cadence.
  - **The same poll also runs the runtime admission check: four more children,
    which the first audit missed.** On every successful ping,
    `ServerStatusPoller.singleSnapshot` calls `admitStableRuntime` →
    `StableGatewayObserver.observe` (`StableGatewayObserver.swift:27–37`),
    which spawns `/bin/launchctl print` (`LaunchAgentRuntimeReader.swift:46`),
    `/bin/ps` twice (`ServerProcessProbe.swift:20`, `:42`) and `/usr/sbin/lsof`
    (`ServerProcessProbe.swift:8`). One 30 s cycle therefore starts **five**
    child processes, not one: ≈12,450 a day at the measured 34.7 s cadence
    (5 × 2,490). The largest per-cycle cost is not a child at all: `observe`
    calls `activePayload()` (`StableGatewayObserver.swift:59–72`) first, which
    runs `GatewayPayloadValidator.validateSelection` on the selected payload and
    `validate` on the bundled one, and each of those walks the whole tree
    (`immutableTree`) and SHA-256s every file (`payloadFingerprint` /
    `digestFile`, `GatewayPayloadStore.swift:381`, `:668–716`). Measured
    2026-09-28: the selected payload is 588 MB / 36,232 files and the bundled
    one 588 MB / 36,245 files, so every poll reads ≈1.2 GB off disk. `sample
    71837 15` (the Tron app process, never the Gateway) puts 5,311 of the
    process's 15,000 samples inside `StableGatewayObserver.observe` on the
    poll's cooperative thread (`ServerStatusPoller.snapshots` →
    `singleSnapshot` → `EnvironmentSetup.makeLive` closure #5); 2,956 of those
    sit in the selected payload's `validateSelection` (2,083 → `validate` →
    1,751 → `payloadFingerprint` → `digestFile`, reading files), 73 in
    `ExistingInstallDetector.serviceStatus`, and **1** in
    `ServerProcessProbe.listenerPIDs` (the `lsof` spawn). The `launchctl` read
    and the two `ps` spawns did not appear in the sample at all. `ps` CPU time
    on the same pid rose 7.98 s over 70 s (two cycles) ≈ 4.0 s of CPU per poll ≈
    2.7 CPU-hours a day — essentially all of the excess by which a ~34.7 s cycle
    exceeds its 30 s sleep. So the
    first audit's attribution of the poll work to `lsof` was wrong: the five
    children are the admission evidence and are cheap, while the redundant
    payload re-validation is the dominant cost. When admission fails,
    `singleSnapshot` runs `validateSelection` a second time on the
    `updateIncomplete` branch (`ServerStatusPoller.swift:72–78`).
  - **Mac app local probe connections: the same poll.** `ServerPing.ping` opens
    an authenticated WebSocket to `/v1/socket`, sends `system::ping` and closes
    it about 2 ms later. The 2026-09-24 08:57–10:59 window has 159 local
    admissions (114 in one hour; episodes admit → handshake → close 1001 in
    2–3 ms at 33.7–34.3 s intervals). Those records come from the older payload:
    the current transport logs local opens at debug level
    (`server.ts:1452–1455`, `isLocal ? "debug" : "info"`), so today's log has no
    local `connection.opened` records. Keeping the Mac app's local probes at
    debug is a constraint on O-2, not a budget G-8b can reclaim; the poll's cost
    here is the per-cycle authenticated socket, not its log volume.
  - **Session search: `session-search.warm` 21 records, 111,866–273,680 ms**
    (mean ≈ 164 s), against 26 `gateway.started` records in the same log — so
    the warm-up does not run on every start (21 of 26).
    `SessionSearchService.rebuild()` walks
    `sessions.catalog("user")` and `loadDocument()` parses every canonical
    session in full (225 sessions, 2.8 GB); `indexSemanticCorpus()`
    (`session-search-service.ts:387–412`) then loads every document again and
    re-embeds up to `MAX_SEMANTIC_WORK` = 20,000 entries on every start, bounded
    by counts only, with no time bound.
  - **Knowledge: already bounded, no change.** Per start, `knowledge-storage`
    3–11 ms and `knowledge-observation-recovery` 11–722 ms (25 of each).
    `knowledge-observation-admission-rejected` fired 5 times in 4 days, each
    `dropped=1, queued=0`, one accounting fact per overflow event;
    `KnowledgeObservationQueue.enqueue` already bounds entries, retained source
    bytes and queued settlements. Nothing recurs.
  - Other recurring jobs inspected and interval-bounded: server heartbeat and
    resource sampler (`server.ts:642`, `:690`), slot activity heartbeat 10 s
    (`runtime-slot.ts:5299`), idle eviction 60 s (`runtime-registry.ts:595`),
    enrollment 60 s (`gateway-main.ts:583`), notification drain 2 s
    (`notifications/notification-service.ts:222`), storage maintenance 10 min
    (`gateway-main.ts:655`), browser live-view expiry 1 s
    (`display/browser-live-view.ts:256`), the automation scheduler's next-scan
    timer (`automations/automation-scheduler.ts:764`), and the two Mac observers
    the poll drives: the admission check above and `DebugGatewayObserver`'s
    Tailscale probe (`DebugGatewayObserver.swift:64`). The latter runs on the
    installed Stable app's menu bar, not only in the debug profile: at install
    (`MenuBarController.swift:52`), on every menu open (`:200`) and after a menu
    action (`Actions/MenuBarActionHandler.swift:329`), observing the debug
    Gateway whenever its `lifecycle.json` reports ready and re-hashing the debug
    payload through `validateSelection` (`DebugGatewayObserver.swift:77`). It has
    no timer of its own, so it still does not recur uninvited. The two
    drain-only loops
    (`gateway-main.ts:485`, `:487`) run only while a restart drain waits. One
    `storage.maintenance-failed` record and no recurrence. This list is every
    Gateway `setInterval`, so the ambient artifact discovery pass below is the
    only other recurring job of consequence; once the discovery race is retried
    (G-8a), the ambient scan is bounded (G-8d) and the poll is bounded (G-8b),
    no audited job recurs uninvited.
  - **The 750 ms ambient artifact discovery pass is itself a large recurring
    job, and it silently truncates.** `RuntimeRegistry.discoverExtensionArtifacts`
    (`runtime-registry.ts:3675–3800`, timer at `:597`) runs every 750 ms. Each
    pass refreshes exact live bindings, then in the ambient phase `opendir`s the
    delegated provider root (`~/.tron/internal/subagents/async-subagent-runs`:
    2,462 run directories and 516 `status.json` files measured 2026-09-28),
    makes up to `MAX_EXTENSION_DISCOVERY_WORK` = 1,024 `open(status.json)`
    attempts (`:3741`; the counter increments per directory entry *before* the
    open, so an absent file still spends budget), reads and parses every file it
    opens (a legacy document up to `MAX_EXTENSION_ARTIFACT_BYTES`), and routes
    up to `rootBudget` candidates to every live slot (`:3789–3794`), where each
    routed read opens the file again (`RuntimeSlot.discoverExtensionArtifact`,
    `:4331` → `refreshSubagentActivityFromArtifact`). With 2,462 directories the
    1,024 cap is always reached, so ambient opens are at most ≈1,365 a second
    (≈118 million a day) around the clock — an upper bound, since it assumes no
    pass overruns the 750 ms cadence (the in-flight guard skips an overlapping
    pass) and it excludes the routed re-opens, up to 1,024 more per pass — and
    the `break` at `:3741` stops the `opendir` walk there: the remaining ~1,438
    directories are never examined by ambient discovery, in `readdir` order, and
    nothing logs or measures that
    truncation. Cause and counts are read from the code and the host, not
    profiled (the Gateway is not sampled; rule 9). New row **G-8d**. For context
    the Gateway process had used 373 CPU-minutes over 11.7 h, including all
    agent work, and its `resource.sample` records do not separate this pass.
- Changes: this file only (row status and this handoff); the two
  review-response commits add the corrected figures and the four rows below. No
  code change: the Gateway findings sit in `runtime-slot.ts` /
  `runtime-registry.ts`, and the Mac app poll needs a bounded-cadence decision.
  The repeatable commands and raw numbers are retained at
  `~/.tron/workspace/files/hardening/g-8-background-work-audit.md`.
- **Tasks added** (orchestrator adds them to the table with these conflict
  zones):
  - **G-8a — Retry the discovery read so an atomic replace is not a warning.**
    Conflict zones: **Registry** and **Slot** (holds both). Depends on G-1c.
    Owning files `packages/gateway/src/sessions/runtime-registry.ts` and
    `packages/gateway/src/sessions/runtime-slot.ts`. Cause: inferred from the
    code and the per-owner gap distribution, because the same
    `artifact-replacement-in-progress` reason also covers an unclassified read
    error and a not-yet-written `status.json` (`runtime-slot.ts:287–292`,
    `:4018–4024`). Give the discovery lane the watcher lane's bounded retry for
    a racing read (three retries, then the warning); keep the 60 s
    per-(owner, reason) dedup for a genuine replacement. Do not skip a directory
    that already has a live watcher: the 750 ms discovery pass is the backstop
    for a rename event the watcher missed, so skipping it could leave a stale
    running projection; if that option is taken anyway, the row must add a check
    that a deliberately missed watcher event is still caught by discovery.
    Check, as the negative control, with the real discovery timer: atomically
    replace `status.json` in a loop (write a temp file, rename it over the
    target) and assert no `artifact-replacement-in-progress` warning and no lost
    live activity — this check must **fail on current code** before the fix and
    pass after it, which is what proves the cause. Do not hand-set
    `extensionArtifactMissingSince` as
    `runtime-registry.integration.test.ts:5602` does, since production never
    supplies it. After the fix reaches the running app, confirm from the live
    log that the reason no longer appears; if residue remains, attribute it to
    the other two sources (unclassified read error, pre-first-write
    `status.json`) rather than assuming they are absent.
  - **G-8b — Bound the Mac app status poll's children and its payload
    re-hash.** Conflict zone: none of the Gateway zones; owns
    `packages/mac-app/Sources/Server/Health/` (including
    `StableGatewayObserver.activePayload`),
    `packages/mac-app/Sources/Server/Paths/GatewayPayloadStore.swift`,
    `packages/mac-app/Sources/Server/LaunchAgent/LaunchAgentRuntimeReader.swift`,
    `packages/mac-app/Sources/Server/ProcessControl/ServerProcessProbe.swift`,
    `packages/mac-app/Sources/NativeHost/NativeCapturePeer.swift` (to promote the
    stamp below) and `packages/mac-app/Sources/App/EnvironmentSetup.swift`. One
    30 s poll spawns five children (≈12,450 a day at the measured 34.7 s
    cadence): the Tailscale CLI (≈2,490/day, each a network-extension reload)
    plus `launchctl print`, two `ps` and `lsof` from the admission check, and
    opens a fresh authenticated WebSocket (≈2,490 sockets/day). It also
    re-validates and re-hashes both payload trees (588 MB + 588 MB, ≈1.2 GB read
    per cycle, ≈4.0 s CPU, `sample`-measured), which is the poll's dominant cost.
    Bound the children: reuse a resolved Tailscale address for a named window
    through the existing `network.json` cache (`readTailscaleIPFromSettings` /
    `cacheTailscaleIP`, `EnvironmentSetup.swift:219–221`), not a second cache,
    with explicit user actions keeping the live probe; and re-admit only when a
    runtime fence changes. The fence must be a **live launchd pid plus that
    process's start identity** — `LaunchAgentRuntimeReader.read` already spawns
    the `launchctl print` that yields the pid, and
    `ServerProcessProbe.processStartIdentity` exists today only for
    `DebugGatewayObserver.swift:113–114` — because `buildFingerprint` and
    `runtimeEpoch` are **build identity, not process identity**: `uuidgen` mints
    `runtimeEpoch` once per bundle
    (`packages/mac-app/scripts/bundle-gateway.sh`, `:560`); the launcher copies
    it from the manifest into the Gateway environment on every start
    (`packages/mac-app/scripts/tron-gateway-launcher.c`, `:1124`); and
    `ServerPingInfo` (`OnboardingModels.swift:118–123`) carries only build-level
    fields. A restart under the same payload (launchd `KeepAlive` at
    `packages/mac-app/Sources/Resources/Library/LaunchAgents/com.tron.server.plist`
    `:23`, or a manual `launchctl` restart) keeps both pinged fields, and the
    previous `Admission.processID` would check nothing, since it equals the pid
    this poll has just read; without the process fence the poll would keep the
    stale admission and publish its pid and uptime
    (`ServerStatusPoller.swift:92–93`) while never re-running the
    listener-equals-launchd-job check that is the admission's security evidence.
    Fence the on-disk selection with the stamp that already exists rather than a
    second one: promote `CaptureSelectionStamp` (`NativeCapturePeer.swift:27` —
    device, inode, mtime and bytes of `payloads/stable/current.json` and the
    manifest) to a shared, non-private type and reuse it, extending that one type
    if the bundled fallback root needs the same leg. A changed selection or a
    changed process runs the full validation, as do explicit user actions
    (pairing invite, menu-bar refresh, restart wait). The per-cycle
    authenticated ping stays: it is the liveness probe that decides Running, and
    a cached answer would report a dead Gateway as healthy, so its ≈2,490
    sockets/day are out of scope here. Gating the ≈1.2 GB re-hash behind the
    fence is a **user/security decision** recorded in "Decisions still open",
    because it makes the fail-closed immutable-tree and fingerprint check
    (`GatewayPayloadStore.swift:274–283`, `:381`) run less often; deferring the
    `lsof` listener-ownership check and the two `ps` display reads in the same
    window is the second half of that decision, and if it is taken the process
    fence above is what must hold. Both the cache and the fence windows change
    what the menu bar can report during the window (its address, and the
    admission's pid, uptime and payload verdict), so decide their length with the
    user. Evidence to keep: every child process per cycle, per-cycle CPU time
    from `ps`/`sample`, and the unified-log attach cadence, all before and after.
  - **G-8c — Bound the session-search warm-up; coordinate with G-9.** Conflict
    zones: **Catalog** and the G-9 scheduler files (holds both); depends on G-9
    (which moves session-search indexing into the scheduler) and G-1c (same
    catalog full parse, another owner). Owning files
    `packages/gateway/src/sessions/session-search-service.ts`,
    `packages/gateway/src/gateway-main.ts`. Scope: warm the lexical index from
    G-1's catalog index and change feed in bounded slices instead of
    `loadDocument()` per catalog session (225 sessions, 111–274 s measured),
    and bound the per-start re-parse/re-embed that `indexSemanticCorpus()` does
    today (every document loaded again, up to 20,000 entries re-embedded with
    no time bound). A full-text index cannot be warmed without transcript text,
    which G-1's catalog index does not carry, so a start can only be bounded by
    a persisted search index keyed by `fileIdentity` (new durable state with a
    new owner) or by a sliced rebuild in G-9's scheduler that leaves coverage
    incomplete until it catches up. That is a **user decision**, recorded in
    "Decisions still open". Done when a start warms the index without a
    full-corpus parse and within a stated time bound, and the search coverage
    digest is unchanged.
  - **G-8d — Bound the ambient artifact discovery pass by change, and make its
    truncation impossible or visible.** Conflict zone: **Registry**, the same
    file and timer as G-8a, so the two cannot run side by side; if the
    orchestrator prefers one dispatch, fold this scope into G-8a. Depends on
    G-1c. Owning file `packages/gateway/src/sessions/runtime-registry.ts`
    (`discoverExtensionArtifacts` and the 750 ms timer at `:597`). Scope: stop
    re-opening every provider-run `status.json` on a fixed 750 ms cadence when
    nothing changed — bound the ambient scan by change (directory or
    `status.json` mtime/identity from the `opendir` entry, or a provider feed)
    instead of a fixed rescan — and make the hard cap visible or impossible,
    since today the pass silently examines only the first entries of `opendir`
    order (`runtime-registry.ts:3741`) while the root keeps growing (2,462 run
    directories, 516 `status.json`, cap 1,024). Keep the exact-binding refresh
    first and the drain lane unaffected. Evidence: count `open`/`opendir` calls
    per pass before and after, and a check that every run directory with a
    `status.json` is examined within a bounded number of passes, or that the
    truncation is reported rather than silent.
- For the next agent: R-4's O-5 records should show G-8a and G-8c gone, and
  G-8d's file-open volume dropped with no silent truncation. G-8b is
  a Mac app change and cannot be seen in Gateway records alone — check it with
  the unified log's Tailscale client-attach cadence (about one per poll today)
  and a per-cycle child-process count, plus per-cycle CPU time from `ps`/`sample`
  (≈4.0 s before, payload re-hash measured).
- Review response (the follow-up commit on this branch): the item-1 cause is
  re-diagnosed from the per-owner gap distribution above (the old "warns once a
  minute for as long as its binding lives" is contradicted by the log) and G-8a
  now fixes the retry, with a check that races a real atomic replace (finding
  1); G-8b covers the admission check's four children and reuses the existing
  `network.json` cache (findings 2, 5); G-8c now depends on G-9, names the
  semantic re-parse, and records the persisted-index decision (finding 3); the
  share, byte and knowledge figures are corrected (finding 4); the O-6a gap is
  stated and the retained artifact gains the per-owner gap command (finding 6);
  the recurring-job list is complete (finding 7); the header and the rows'
  conflict zones are refreshed (finding 8).
- Second review response (this commit): the poll work is re-attributed from a
  fresh `sample` of the Tron app and a `ps` CPU delta — the ≈1.2 GB payload
  re-hash per cycle is the dominant cost and `lsof` is one sampled frame — in
  the handoff, in the retained artifact and in G-8b, whose scope now owns
  `GatewayPayloadStore.swift` and `StableGatewayObserver.activePayload`, keys
  re-admission on the pinged build identity plus a selection fence, and records
  the skip-the-re-hash decision (finding 1, majors). The 750 ms ambient
  discovery pass is added as a measured recurring job with its silent
  1,024-entry truncation, and becomes row G-8d (finding 2,
  major). The item-1 cause is now labelled inferred, names the other two sources
  of the same reason string, and G-8a requires the atomic-replace check to fail
  on current code first and a post-fix log confirmation (finding 3, minor).
  G-8a drops "skip a directory that already has a live watcher" as the default
  and requires a missed-watcher check if it is taken (finding 4, minor). The
  cadence arithmetic is corrected to ≈12,450 children/day at 34.7 s, the warm-up
  is stated as 21 of 26 starts, and the two Gateway file paths gain their
  directories (`notifications/`, `display/`) (finding 5, nits). The log figures
  were re-measured for this round (1,180 records as of 2026-09-28T13Z, matching
  the reviewer's read) and are stated beside the original snapshot rather than
  replacing it.
- Third review response (this commit): G-8b's re-admission key is corrected,
  because `runtimeEpoch` is build identity —
  `packages/mac-app/scripts/bundle-gateway.sh` mints it once per bundle at
  `:560`, `packages/mac-app/scripts/tron-gateway-launcher.c` copies it from the
  manifest into every start at `:1124`, and `ServerPingInfo` carries no
  per-process field — so a same-payload `KeepAlive` restart kept it. The row now
  requires a live launchd pid plus start identity in the fence, deletes "or the
  previous `Admission.processID`", and records skipping `lsof` and the two `ps`
  display
  reads between polls as the second half of the same user/security decision
  (finding 1, major). The row's title and scope drop "its socket": the
  per-cycle authenticated ping is the liveness probe and stays, so the row no
  longer promises a bound it does not specify and no longer says "take the other
  two bounds regardless" (finding 2, minor). `DebugGatewayObserver` is described
  as the Stable menu bar's debug-Gateway observer at install, on menu open and
  after actions, re-hashing the debug payload through `validateSelection`, not as
  a debug-profile-only probe (finding 3, nit). The selection fence reuses and
  promotes the existing `CaptureSelectionStamp` instead of adding a second one
  (finding 4, nit). The ≈1,365 ambient opens a second is labelled an upper bound
  on ambient opens that excludes routed re-opens and assumes the pass keeps the
  750 ms cadence (finding 5, nit); the retained artifact's figure matches.

### G-7 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-7`)

- Final review round (1 major, 2 minors, 3 nits) fixed; three of the four nits
  are comments or a documented one-time request. `hardening/integration` was
  merged in first and both behaviours kept where it conflicted with C-5.
- **Finding 1 (major) — an unchanged answer left the phone's snapshot stale.**
  `confirmUnchanged` makes the projection live again, but the reconnect's own
  revision advance happens before the answer lands, so the dashboard snapshot
  the view holds was taken while the projection was retired: every non-idle row
  read "resuming" and a waiting-for-user row lost its badge until its next
  summary, and an expanded archived container kept the server unavailable.
  Both `.unchanged` branches now do what a page read does when the answer
  revives a retired projection: `AppModel` runs `installSelectedDashboardCatalog()`
  and advances `archiveProjectionRevision`; the pool republishes the profile's
  state and its authoritative catalog. Neither touches the rows. Covered by
  `AppModelReconnectTests` "a reconnect whose catalog read is unchanged still
  rebuilds the dashboard's row projection" (row waiting for the user, both
  revisions, rows retained) and `DashboardStateOwnerTests` "a secondary
  reconnect answered unchanged republishes its catalog authority" (the retained
  token is named, and state plus authority come back for the replacement epoch).
- **Finding 2 (minor) — a cleared automation marker did not move the token.**
  `clearAutomationMarker` (the user's acknowledge-recovery action) and
  `reconcileStoredAutomationMarkers` dropped the session from the recovered-marker
  set without moving `catalogProjectionGeneration`, and a cold row reads its
  `phase` from that set alone, so the row went `interrupted`→`idle` with an equal
  token: every reconnect then answered `notModified` and the phone kept showing
  `interrupted`. Both now go through `noteRecoveredMarkerCleared`, which advances
  the generation and calls `sessionListChanged()` — the shape the cold-attention
  path already used. Covered by `session-archive.integration.test.ts` "moves the
  projection token when an acknowledged recovery clears a cold row's marker"
  (marker restored by a real restart, phase read before and after, token moved,
  `listChanged` observed).
- **Finding 3 (minor) — merge readiness.** `hardening/integration` merged;
  conflicts in this plan, `scripts/test-tron-profile.py` and
  `scripts/tron-profile-gateway-driver.mjs` resolved as the union (both
  behaviours). The v6 re-sweep found the two leftover `hello` fixtures the review
  named in `DashboardStateOwnerTests.swift` (lines 855 and 1010) and both
  `test-tron-profile.py` sites; nothing else in the merged tree still speaks v5.
  `AppModel.swift` and `DashboardGatewayConnectionPool.swift` auto-merged and keep
  C-5's pool work and this task's `.unchanged` branch.
- **Nit 4 — false comments.** Both comments claimed the identity lane spanned the
  identical-registration check. It does not: the check is read-only, runs outside
  `withMobileIdentityLane`, and is therefore not ordered with that device's lane
  operations, so an identical upsert racing a remove or revoke is answered from
  the snapshot the check read. Both comments now say that, and the duplicated
  block in `gateway-service.ts` is gone.
- **Nit 5 — the one-time re-send.** The acknowledgement records the revision the
  handshake advertised before the transfer, so a transfer that itself wrote the
  grant (first registration or rotation) is re-sent once by the next reconcile.
  Recorded in the target list
  (`~/.tron/workspace/files/hardening/g-7-reconnect-request-inventory.md`) and in
  `packages/ios-app/docs/development.md` instead of changing the upsert answer
  shape.
- **Nit 6 — a failed acknowledgement save blocked the removal.**
  `removeRegistration` returned before sending `push.registration.remove` when
  persisting the cleared acknowledgement failed, so a user who turned
  notifications off could stay registered. The in-memory document still drops the
  acknowledgement (a claim this phone could not persist is not trusted), the
  failure is still reported as `pending`/`stoppedPersistence`, and the removal is
  sent. Covered by `PushNotificationCoordinatorTests` "a failed acknowledgement
  save still tells the Gateway to remove the grant".
- Evidence: `npm run build` clean; `npx vitest run` passes on
  `session-archive.integration.test.ts` (41/41, including the new case),
  `notification-service.test.ts`, `gateway-notification-rpc.test.ts`,
  `gateway-restart.test.ts` (62), `session-list-pagination.test.ts` (12) and
  `automation-executor.test.ts` (8); `python3 scripts/test-gateway-protocol-contract.py`
  passes 3/3 and `python3 scripts/test-tron-profile.py` passes 45/45 after the
  merge. `scripts/tron-ios-test build --lane G7F` succeeded and `scripts/tron-ios-test run`
  passes for `AppModelReconnectTests`, `PushNotificationCoordinatorTests` and
  `DashboardStateOwnerTests` (130 tests).
- Negative controls: with `noteRecoveredMarkerCleared` reverted to a bare
  `interrupted.delete`, the new session-archive case fails on the first
  `listChanged` assertion and would then answer `notModified`; with the
  `AppModel` `.unchanged` side effects removed, the reconnect case fails on the
  archive revision and the row's activity; with the pool's `.unchanged`
  republication removed, the pool case times out waiting for the replacement
  epoch's authority.
- Changes: one merge commit for `hardening/integration` that also lands this
  review round, branch `hardening/g-7` (the merge is kept whole because the
  conflict resolutions and the fixes sit in the same files).

### G-7 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-7`)

- Review response: the review round after the first handoff entry below found a
  blocker and two major gaps. This entry records what the fixes actually are;
  the claims below about a connection-scoped revision, the no-op answer's shape
  and the kept command receipt are superseded by it.
- **Finding 1 (blocker) — the conditional answer covered only structural
  membership.** `session.list` now takes and returns a projection token:
  `RuntimeRegistry` publishes `projectionToken` = the Gateway runtime epoch plus
  the page-source generation (structural `listRevision`, `catalogProjectionGeneration`,
  scope, archive filter, archive revision), the pagination store carries it on
  every page, and an uncursored read that names the current token is answered
  `notModified` with no rows. The case the review reproduced — another client
  marks a cold row unread, which moves only `catalogProjectionGeneration`, then a
  conditional read returned `notModified` with no rows while the plain read
  showed `isUnread: true` — is now a case in
  `session-archive.integration.test.ts`: "answers an unchanged projection token
  without rows and re-reads after the projection moves". Its artifact records
  `firstRevision: 0`/`afterAttentionRevision: 0` with
  `token: <epoch>:0:0:...` and `attentionToken: <epoch>:0:1:...`, plus a restart
  whose token carries a new epoch. The same fix covers the phone's
  malformed-summary and metadata re-check recovery paths, which re-read through
  this conditional path.
- **Finding 2 (major) — the push acknowledgement could not see a runtime grant
  disable.** The Gateway now advertises `pushRegistrationRevision` in `hello`
  and `system.info`: a digest over the grants it stores (identity, installation,
  activity, disabled reason, relay origin) plus the relay origin they are valid
  for, refreshed on every notification-document write and stable across a
  restart that changed nothing. The phone stores it as
  `PushGrant.acknowledgedRegistrationRevision` and skips the registration only
  while it and `machineId:runtimeEpoch` both still match, so a relay rejection
  that disabled the grant (`notification-service.ts` `recordOutcome`) makes the
  next reconcile re-send and act on `requiresGrantRotation`. Tested at both
  layers: `notification-service.test.ts` "advertises a changed registration
  revision when the relay disables a grant" (the revision moves, the grant is no
  longer current, the re-send answers `requiresGrantRotation: true`) and
  `PushNotificationCoordinatorTests` "an acknowledged registration is not re-sent
  while the Gateway's grant revision is unchanged" (unchanged revision sends
  nothing; a moved revision re-sends and discards the disabled grant; a changed
  runtime identity re-sends).
- **Finding 3 (major) — the plan row's Done-when and the connection-scoped
  revision.** Decided with the supervisor: the token is runtime-scoped, so the
  phone keeps it across a reconnect and a replacement connection revalidates the
  rows it holds instead of reloading them ("reconnect resumes; it does not
  reload"). A profile switch still drops it (`invalidateLoads()`), pinned by
  `DashboardStateOwnerTests` "a retained projection token survives a reconnect
  and drops on a profile switch". The real-reconnect request and byte
  measurement is R-1's and R-4's, recorded in the row's Done-when.
- **Finding 4 (minor) — a lost removal answer.** `removeRegistration` clears and
  persists the acknowledgement before sending `push.registration.remove`, so a
  user who re-allows notifications re-registers instead of trusting an
  acknowledgement for a grant the Gateway may already have removed
  (`PushNotificationCoordinatorTests` "a lost removal response leaves no
  acknowledgement that a removed grant is current").
- **Finding 5 (minor) — the identical registration's command receipt.** Per the
  supervisor, G-7's Do item 2 is literal: an identical registration is answered
  before the receipt owner opens one, so it writes neither a receipt nor the
  document. An unchanged registration is naturally idempotent, so a retried
  request repeating the same `commandId` gets the same stored status;
  `gateway-notification-rpc.test.ts` "answers an identical registration without
  opening a command receipt" spies the receipt owner and asserts it is never
  entered. An admitted registration keeps its previous order — the per-device
  lane wraps the operation inside its receipt, so an accepted mutation is owned
  by the work registry before it waits for the lane (`gateway-restart.test.ts`
  "owns mobile mutations before they wait in the per-device lane"). G-7a was
  removed: it only held this decision.
- **Finding 6 (nit) — a late transfer completion.** `transfer` now takes the
  runtime identity and revision from the admitted context and passes them to
  `acknowledgeRegistration`, so a completion that lands after a reconnect
  records the runtime that answered rather than whatever is current.
- **Finding 7 (nit) — the version bump's search-and-replace mangled history.**
  The two "additive field ... leave protocol version 6 unchanged" sentences now
  say the additive field required no protocol version change, and the v5 update
  helper claim names what actually rejects a strictly v6 candidate (a payload
  manifest validated against the version the helper speaks, and the
  protocol-range probe).
- **Finding 8 (nit):** the diff outside the listed owning files is unchanged from
  the first entry's justification (the catalog loader's owners, plus the release
  rule that the protocol bump touches every fixture pinning the version).
- Evidence: `npm run build` clean; `npx vitest run` passes on six focused files:
  `session-archive.integration.test.ts`, `session-list-pagination.test.ts` and
  `server-revocation.integration.test.ts` (66 tests) and
  `notification-service.test.ts`, `gateway-notification-rpc.test.ts` and
  `gateway-restart.test.ts` (60 tests); the session-archive report at
  `packages/gateway/test-results/session-archive.integration.json` carries the
  new case's evidence. `scripts/tron-ios-test build --lane G7R2` succeeded and
  `scripts/tron-ios-test run --lane G7R2` for `AppModelReconnectTests`,
  `PushNotificationCoordinatorTests`, `DashboardStateOwnerTests` and
  `AppModelCatalogSyncTests` passes 151/151.
- Changes: `f8574146d` and `d38f0ec71` (Gateway), `ce4c3fb12` (phone), plus the
  docs and this entry, branch `hardening/g-7`.

### G-7 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-7`)

- (Superseded in part by the review-response entry above: the token is
  runtime-scoped rather than connection-scoped, the no-op registration answer
  carries the advertised revision, and an identical registration skips its
  command receipt. The findings and their fixes are recorded there.)
- Result: a reconnect sends the push registration only when the registration
  changed for this Gateway runtime, and revalidates its session catalog instead
  of reloading rows whenever the connection's own traversal already published
  the Gateway's current `listRevision`. The Gateway answers both no-ops without
  a durable write. Protocol bumped to 6 (this is the first Phase 1 task to change
  a message shape: `session.list` gained the optional `listRevision` parameter
  and the `notModified` response).
- Rolled-up request inventory and the recorded target list (Do item 1):
  `~/.tron/workspace/files/hardening/g-7-reconnect-request-inventory.md`. The
  2026-09-27 phone export is not in the repository, so R-4 owns the real-export
  comparison; the inventory is a code audit of every connect-time owner plus the
  O-6a mobile client's method surface. Target per reconnect: **1** first
  `session.list` page (0 rows when the same connection revalidates), **0**
  `push.registration.upsert` on the same Gateway runtime, **2**
  `notification.inbox.list` (one per filter), **1** each of `provider.list`,
  `model.list`, `settings.get`, `device.list` per (target, connection), **0–1**
  `system.info`, and one `session.open`/`session.sync`/`session.commands` trio
  only when a chat is mounted.
- Do item 2 (push registration): the phone persists
  `PushGrant.acknowledgedRuntime` = `machineId:runtimeEpoch` of the Gateway
  runtime that confirmed the exact grant, and `registerCurrent` returns ready
  without a request while the stored grant still matches the APNs token hash,
  route and relay origin and that identity is unchanged. A Gateway restart, a
  changed token/route/origin, a rotated grant, or a Gateway that advertises no
  `runtimeEpoch` always re-sends. The Gateway's `NotificationService.upsertGrant`
  now returns `undefined` from `NotificationGrantStore.update` (no credential
  document rewrite at all: grants, delivery receipts and revocation tombstones
  are untouched) when the request describes the stored grant and the retention
  pass changed nothing.
- Do item 4 (conditional `session.list`): an uncursored read may name
  `listRevision`. An equal revision is answered
  `{sessions: [], listRevision, notModified: true}` with no row projection,
  because the registry revision owns structural identity, archive membership
  (`archiveChanged` advances it) and the visible archived count. A cursored page
  is always bound to its lease's revision, and any other revision receives rows.
  The phone revalidates a retained revision only on the connection whose
  traversal admitted it: `SessionCatalogCoordinator.beginLoad` drops the revision
  when the load key changes, and any local membership change
  (`invalidateLoads`) drops it too. That is deliberate, not a shortfall: the
  Gateway broadcasts `session.summary` and never replays it, so a replacement
  connection's row fields converge only through a page read.
- Do item 3 (one owner each for `model.list`/`provider.list` per connection):
  already structurally satisfied, no code change. `AppModel.scheduleMountedOptionalReads`
  is the connect/foreground optional-read owner and is guarded by
  `mountedOptionalRefreshLifecycleGeneration`/`ConnectionID`, so the second
  caller (`lifecycleRestoreMountedPresentation`) cannot re-read in the same
  connection; a mounted chat open reads the session-scoped target, which is a
  different projection, and Settings/Onboarding keep the explicit user action.
  Verified by inspection; no new test asserts the count (the existing reconnect
  test asserts the request *set*).
- Evidence:
  - `--no-build`-free focused Gateway runs on Homebrew Node: `npm run build`
    clean; `npx vitest run src/transport/session-archive.integration.test.ts`
    passes **40/40** (11.7 s) including the new
    "answers an unchanged catalog revision without rows and re-reads after
    membership moves"; `npx vitest run src/notifications/notification-service.test.ts`
    passes **37/37** (3.5 s) including "answers an identical registration
    without rewriting the credential document". Both write their usual
    `test-results/*.json` artifacts.
  - `scripts/tron-ios-test build` succeeded, then
    `scripts/tron-ios-test run --only-testing TronMobileTests/AppModelReconnectTests`
    passed **37 tests in 1 suite** (0.27 s; run
    `~/Library/Developer/Tron/ios/test-runs/20260928T144407Z-run.cP95vO`),
    including the new "a catalog read revalidates its retained revision and a
    reconnect reloads rows".
  - Negative controls (the test fails with the production change reverted, so it
    targets a real bug rather than reasserting the code): with
    `notification-service.ts` stashed the new registration test fails on the
    byte-identical document assertion; with `gateway-service.ts` stashed the new
    list test fails on the missing `notModified` answer.
  - `python3 scripts/test-gateway-protocol-contract.py` passes 3/3 after the
    bump. Its artifact fixtures now derive the expected version from
    `config/GatewayProtocol.json` instead of a literal, so the next bump cannot
    leave them asserting a stale contract.
- Changes: `fd14c2712` (reconnect diet + protocol bump in the same series;
  bump commit `c16e4b279`), branch `hardening/g-7`.
- Tasks added: G-7a (removed by the review response above, which decided it).
- Kept on purpose: the command receipt (idempotency evidence) on a no-op
  `push.registration.upsert`. The plan's "no receipt write" is read as the
  notification service's own durable state — the credential document and its
  receipt/revocation overlays — because `transport/command-receipts.ts` is not a
  G-7 owning file and the architecture invariant requires a bounded idempotency
  receipt for every mutation. The review response above replaced this reading:
  the plan's wording is literal and an identical registration now skips its
  receipt too.
- Deviations (superseded by the review response above): the push registration
  no-op answer kept the existing `NotificationStatus` shape and the retained
  value was connection-scoped. The message-shape change that owns the version
  bump is the `session.list` conditional read, and the no-op answer does add the
  advertised revision to `hello`/`system.info` (not to the status shape).
- For the next agent: R-4 compares the recorded target list with a real
  evaluation-day reconnect and should also measure the bytes (the `session.list`
  page is the largest single item, so the `notModified` answer is the byte win).
  The archived-session container (`AppModel.loadArchivedSessions`, `archived:
  "only"`) still reads rows unconditionally; it is a small follow-up if R-4 shows
  it matters. `SessionCatalogCoordinator.confirmUnchanged` requires the retained
  revision to match, so a `notModified` answer for a revision the client did not
  retain is rejected as `invalid_response` instead of being trusted.

### G-3 · Claimed · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-3`)

- Result: a session snapshot is now built, serialized and broadcast only when
  its slot has a subscriber. With none, a state change runs the same summary
  publication and nothing else: no canonical branch walk, no transcript page, no
  frame. `broadcastSession` and the global `broadcast` count ready recipients
  before preparing a frame and return before `prepareBroadcastFrame` when there
  are none, so a frame nobody can receive is not encoded, measured or queued,
  and no `session.snapshot` topic entry is recorded for it. The O-5 warning
  `UNAUDIENCED_SNAPSHOT_WARNING` (`unaudiencedSnapshotBuilds > 0`) records a
  snapshot built although no ready socket held a subscription token for its
  session: the transport counts every snapshot frame's recipients where it
  decides delivery, so the slot's guard keeps that count out of a normal minute
  and a window that records one has lost an audience check. The shipping name for
  it is
  `unaudiencedSnapshotBuilds` in code, docs and the level reason; O-5's plan
  wording `resources.unaudienced-work` stays only in O-5's own handoff, which
  already says that threshold belongs to this row.
- Do item 1 finding (verified in code, not inferred): **no client consumes
  `session.snapshot` for a session it is not subscribed to**, as the plan
  expected. The transport already scoped session frames to
  `client.subscriptionTokens`, the iOS `SessionPresentationStore` installs a
  snapshot only into its own session's store and admits it by session identity
  (`Sources/State/SessionPresentationStore.swift` `reduceSnapshotEvent`), the
  dashboard reads `session.summary` and `session.listChanged` only, the Mac app
  has no `session.snapshot` consumer, and the CLI client reads it for the session
  it opened (`packages/gateway/src/client/terminal-chat.ts`, its `session.snapshot`
  branch). The subscriber record is therefore the whole audience fact, the
  transport is its only writer, and the transport
  subscribes a client before it installs that client's synchronization barrier
  (`server.ts` `beginSynchronization`), which is why a pending barrier is always
  also a subscriber here.
- Failure modes recorded for the guard's tests (see Deviations): (1) a subscriber
  arrives between a skipped build and the next change and is left without the
  state change — the sync/open path builds on demand and the next change
  rebuilds it, covered by the sync tests and the registry guard assertion; (2) a
  pending synchronization barrier with no subscriber is treated as no audience,
  so the catch-up misses the publication — the transport subscribes before the
  barrier, and `sync-protocol.integration.test.ts` covers the quarantine,
  overflow and recovery paths; (3) a summary field that only a snapshot build
  produced stops being published — `summary()` is computed independently, and
  the resource-inventory test renames a session with no subscriber and asserts
  its summary still reaches `sessionSummaryChanged`; (4) a
  no-audience broadcast is still serialized or counted as a frame — the early
  return is before `prepareBroadcastFrame` and before `recordTopicFrame`; (5) an
  unaudienced build in a window stays a quiet debug minute — the transport-path
  level test; (6) the no-audience warning fires for a build that had a recipient
  — the transport-path level test; (7) the slot's no-audience guard regresses or
  the registry's subscriber record and the transport's diverge, so a projection
  is built that no ready socket can receive — the build is recorded as
  unaudienced and warns, which is what this count exists to catch.
- Evidence:
  - Named checks: `npx vitest run src/transport/sync-protocol.integration.test.ts`
    passes 3/3 (6.1 s) and
    `npx vitest run src/transport/server-capacity.integration.test.ts` passes
    24/24 (9.6 s); `src/transport/server-frame.test.ts`,
    `src/transport/server-compression.integration.test.ts`,
    `src/transport/server-live-view.integration.test.ts` and
    `src/transport/server-heartbeat.integration.test.ts` pass 32/32 together, so
    subscribed clients receive the same frames and the same oversized-frame
    recovery as before.
  - `npx vitest run src/transport/stall-diagnostics.test.ts` passes 22/22; the
    wiring test proves one frame for the subscribed session, and the two level
    tests drive the production path (`broadcastSession`) to prove a build no ready
    recipient can receive warns and a build with a recipient stays at debug.
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts` passes
    249/249 in 72 s. Eleven snapshot-delivery tests in this file subscribe a test
    audience (thirteen with the compaction fixtures);
    the resource-inventory test proves both directions of the guard: with a
    subscriber the publication calls `slot.snapshot` once and broadcasts a
    `session.snapshot`; with none, a rename publishes the summary (asserted by
    name) and calls `slot.snapshot` no further. The new
    "keeps a transported subscription across a closed slot" case covers the
    review's re-acquire scenario: after an extension-requested shutdown the
    subscription survives and the re-acquired slot broadcasts snapshots again.
    The reviewer's flaky test ("records interruption intent before fast SDK
    settlement") passed in this full-file run.
  - `npx vitest run src/sessions/runtime-compaction.integration.test.ts` passes
    22/22; both of its registry fixtures subscribe an audience, so the compaction
    snapshots are delivered as before.
  - `npx vitest run src/sessions/projection.test.ts src/client/gateway-client.test.ts`
    passes (328/328 with the registry file); `npm run build` is clean.
  - O-6a smoke (short, `--no-build`, small catalog):
    `scripts/tron-profile gateway --scenario multi-session --no-build
    --catalog-files 400 --catalog-mib 96 --mixed-seconds 30 --iterations 1` exits
    0 in 1.9 min; report
    `~/Library/Developer/Tron/profiles/gateway/20260928T142710Z-multi-session-542686/report.json`.
    The one `gateway.resources` window the run persisted
    (`fixture/gateway.jsonl:75`, `windowMs=60957`) reports
    `snapshotBuilds=46 unaudiencedSnapshotBuilds=0` with
    `topics=session.snapshot:46/26714307B/1` and `liveRuntimes=8`, whose eight
    running runtimes are all `...KB/0` — every build had exactly the one client
    that wanted it and the eight unsubscribed running sessions built none. That
    window was written by the first commit of this branch, when the slot recorded
    the count itself; under the review response the same numbers come from the
    transport's recipient count at delivery, which is the count that can report a
    build reaching nobody. The
    window is not the audience warning: its level is the shared host's
    `eventLoopDelayP99Ms=2847` band. Debug windows stay in the O-5 memory-only
    buffer, so this mixed-window record is the on-disk counter evidence; the
    no-subscriber phase is covered by the registry guard assertion above.
  - **CPU, "Done when" second half: owed to the orchestrator.** The full O-6a
    baseline against `main` is still pending a quiet host (O-6a is Blocked), and
    this host was shared during the run (event-loop p99 2,847 ms in the window
    above), so a CPU number from it would measure the host. The comparison to the
    baseline belongs with O-5's 5% cross-check after the quiet-host run.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: the G-3 commits on `hardening/g-3`.
- Tasks added: G-3a (the progress projection for a session with no subscriber,
  review nit 8).
- Kept on purpose: T-GW-DUPSNAP's pending-`snapshotTimer` cancellation in
  `publishSnapshot` (an identical rebroadcast stays removed);
  `publishStateChange()`, `flushPendingProgress()` and the `eventSequence`
  increment on every publication, because the summary, the progress frames and
  the state-change waiters are not snapshot work and dropping them would change
  ordering or stall held-prompt flushing. The snapshot build is counted by the
  transport (`broadcastSession`) rather than by the slot: the recipients exist
  only there, a build the slot skipped is not a build at all, and one place for
  the count is what makes `UNAUDIENCED_SNAPSHOT_WARNING` reachable. The sampler's
  per-topic `session.snapshot:frames/bytes/subscribers` entry remains the reader's
  way to see who received what, and now counts only frames that had a recipient.
- Deviations: (1) the failure modes above were written down with the tests rather
  than before the first edit; each has a test. (2) The global `broadcast` gained
  the same recipient check as `broadcastSession`: `session.listChanged` and
  `models.recentChanged` were serialized for nobody in the same way, and one rule
  for both seams is smaller than two. (3) The warning is a reason on the
  `gateway.resources` record, as O-5's handoff allowed, rather than a second
  record line. (4) Thirteen test fixtures in
  `runtime-registry.integration.test.ts` and
  `runtime-compaction.integration.test.ts` now subscribe an audience because a
  test that reads published snapshots has to be a subscriber; no production
  behavior was relaxed for them. (5) Review round 1 kept the guard in the slot and
  made the transport the count's owner instead of moving the build into the
  transport behind a lazy payload: the lazy form would have made every fixture's
  `broadcast` double receive a function rather than a payload, and the fixtures
  record those payloads for assertions that read snapshot fields back, so the
  audience decision would have moved out of them while leaving silent
  `.toBeUndefined()`-style checks behind.
- Review response (round 1, on `c867597a2`): finding 1 (the warning could not
  fire) — the count now comes from the transport's own recipient count for every
  snapshot frame, recorded before its no-recipient return, so the case the review
  named is counted and warned, and the level is exercised through
  `broadcastSession` rather than a synthetic `recordSnapshotBuild(0)`. Finding 2
  (the navigation test passed vacuously) — it subscribes and asserts the
  recording is non-empty before the last assertion. Finding 3 (two audience
  owners) — the registry's close hook no longer deletes the subscriber set,
  because the transport owns subscription lifetime; the new closed-slot test
  reproduces the review's re-acquire scenario and failed before the fix. Finding 4
  (`buildSnapshot` side effects) — `publishSnapshot` calls
  `ensureAgentProjection()` before the audience check, so the projection settles
  exactly as often as before the guard. Finding 5 (row status) — the row and this
  heading are Claimed again, following O-3's precedent, because the CPU half of
  "Done when" is unmet. Finding 6 (the no-subscriber check proved little) — the
  test now renames the session with no subscriber and asserts the summary fires
  with the new name while `slot.snapshot` is not called again. Nits 7 and 8 — one
  name for the count in code, docs and reason string; the progress projection that
  is still built for an unsubscribed session is `G-3a` rather than part of this
  row.
- Review response (round 2, on `767180635`): finding 1 (the warning test drove a
  state production cannot reach) — the test now broadcasts a `session-1` snapshot
  while the only ready connection holds a `session-2` token, which is the
  zero-recipient state a regressed slot guard or a registry/transport
  subscription divergence produces; failure mode (7) and the Residual are
  restated as that tripwire and the false closing-socket window is dropped. The
  production counter is unchanged, because the transport already records every
  snapshot it is handed where it counts the recipients. Finding 2 (dead surface)
  — `recordSnapshotBuild` moved off the `ResourceRecorder` interface onto
  `ResourceSampler`, the only caller, and the registry fixture's mock of it is
  deleted. Nit 3 (failure modes written after the code) is recorded in Deviations
  (1) and unchanged, and finding 1 is the drift it produced. Nit 4 (stacked
  `Last updated` lines) — the header keeps one current line.
- For the next agent: G-4 (outbound queue coalescing) depends on this row and can
  assume a snapshot for a session with no subscriber is never built; the
  `unaudiencedSnapshotBuilds` warning is a regression tripwire, so a nonzero
  window means an audience check was lost rather than that G-3 needs tuning.
  G-3a owns the same rule for streaming progress frames, which are still projected
  for a session with no subscriber. Residual: the transport's
  `ready && subscriptionTokens.has(sessionId)` set and the registry's subscriber
  record can drift (a regressed guard, or a subscription node one owner kept and
  the other dropped), and a session in that state builds a snapshot no ready
  socket can take; the count above turns that into a warning instead of a quiet
  debug minute. It is a tripwire, not a description of a runtime window: no
  reachable production path builds for a session with no ready recipient, which is
  exactly why a nonzero window is a defect signal. Removing the drift itself would
  need the recipient count before the slot decides, which is the lazy-payload
  shape declined in Deviations (5).
  The orchestrator owes G-3's CPU comparison and O-5's 5% cross-check on a
  quiet-host O-6a run.

### O-6b · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: the multi-session qualification run has three impairment cases,
  selected with `--cases` (default `blackhole,bandwidth,restart`; `none` runs
  none), after each iteration's mixed window and on the clients it already
  connected:
  - **blackhole** (`--blackhole-seconds`, default 90): the mobile client's path
    is a loopback TCP relay the driver shapes. The relay stops forwarding in
    both directions, so an established socket goes silent (the Gateway sees
    silence, not a close), an attempt made during the outage is held with no
    answer until the phone's transport-open deadline gives up, and a phone that
    abandons a frozen socket says nothing to the Gateway, which therefore keeps
    it half-open. The client keeps its socket until one liveness window (18 s:
    ping interval plus pong deadline) passes with no inbound frame, then
    abandons it and retries on the phone's backoff. The path returns on its own
    timer; recovery is measured from that moment to a ready mounted chat, so an
    attempt still in flight then is part of the recovery.
  - **bandwidth** (`--bandwidth-mbps`, default 2): the relay holds one rate
    budget per direction over the raw TCP stream and pauses the sending socket
    when it is spent, so the Gateway's own socket buffers fill and its outbound
    queue grows. The workload keeps the link full for `--bandwidth-seconds`
    (default 90), mounting full bounded transcript pages back to back, and
    reports its own link use (delivered rate against the cap).
  - **restart:** the driver asks the profiler (its parent, which owns the
    fixture) for a Gateway restart while every connected client is live. The
    profiler stops the child and starts a fresh one on the same port and reports
    when the new Gateway was healthy and the downtime it took. Every client
    retries on the phone's backoff from the moment its own socket closes, so the
    refused connects and the reconnect times include the downtime; the exit
    criterion's three clients (a mounted phone, a listing dashboard, one more
    pair) are the measured ones and the other three reconnect too.
- Review response (second review, changes-required, 1 blocker + 5 major + 4
  minor + 1 nit; all addressed or rejected with a reason):
  - **Blocker — recovery timed from the wrong moment.** The path now returns on
    its own timer, separate from the attempt loop, and recovery is measured from
    that moment, so the in-flight attempt's remaining deadline is included.
    Retries use the phone's schedule (`ReconnectDelayPolicy`: 2 s × 1.7 to 15 s,
    ±20% jitter) instead of a fixed 250 ms. The stub test now returns the path
    during an 8 s attempt and requires recovery to exceed 4 s.
  - **Major — the cap did not shape the real link.** The frame-level `PathShaper`
    is deleted. Frames were charged after `ws` had decompressed them (23× fewer
    bytes than the payload), nothing produced backpressure, and both directions
    shared one queue. The relay shapes the byte stream, one budget per
    direction, and counts wire bytes (`delivered_bytes_per_second`,
    `sent_bytes_per_second`); `dropped_frames` is gone because a TCP path does
    not drop.
  - **Major — the blackhole was not one.** TCP and the upgrade still got
    through, attempts authenticated and were closed by the Gateway's hello
    deadline while `connect()` waited out its full 15 s, and `abandon()`
    terminated the socket, telling the Gateway at once. The relay now holds new
    connections without answering, an established socket stays half-open when
    the phone abandons it, and `connect()` fails the hello wait when its socket
    closes.
  - **Major — the restart storm was never measured.** Clients waited for the
    profiler's "done" file, so `failed_attempts` was always 0 and the downtime
    was in no metric. Each client now retries from its own socket's close,
    `reconnect_ms` is measured from that close, and `downtime_ms` (requested to
    healthy) is its own metric.
  - **Major — a close after the blackhole went uncounted.** `abandon()` left
    `closing` set, which muted the mobile's later unexpected closes (and its
    final check). `connect()` now clears `closing` and `awaitingPong`, and the
    bandwidth leg fails if a socket died without being counted. The stub closes
    the mobile's socket on a known open and the test requires the run to fail
    with that close.
  - **Major — the row was Done while the baseline was owed.** The row is
    Blocked, and the time budgets are revisited: the per-iteration driver
    watchdog is now the sum of the legs' own bounds
    (`driver_deadline_seconds`: 165 s mixed + 90 s no-subscriber + 270 s blackhole
    + 480 s bandwidth + 425 s restart = 1,430 s on the defaults), the bandwidth leg has
    its own bound, and `restartDeadlineMs` is 360 s, above the profiler's 300 s
    start deadline plus up to 30 s to stop the old Gateway. Found with those
    budgets: on a host this loaded the Gateway's own SIGTERM shutdown can
    outlast the fixture's 20 s wait, and a killed predecessor's agent-directory
    runtime lock is only reusable once it is stale (60 s), so the new child
    exited on the ownership conflict and failed the run. `FixtureGateway.restart`
    now waits that conflict out inside its 300 s start budget (and only that
    conflict).
  - **Minor — only three of six clients reconnected.** Every connected client
    reconnects now; `clients_ready` counts all of them and the run is rejected
    if one is left down. The README no longer claims the exit criterion counts
    three of six.
  - **Minor — capacity records attributed to G-12.** Renamed to G-4, and
    `gateway_outbound_capacity_records` counts only records inside the
    bandwidth legs' own time windows, not the whole retained log.
  - **Minor — "retries like the phone" was false.** True now (the phone's
    backoff), so the claim stays with the schedule named.
  - **Minor — test layout.** The harness is `StubGatewayHarness`; the window
    tests are back in `MultiDriverWindows` and the impairment tests in
    `MultiDriverImpairment`; the restart test drives the profiler's own
    `wait_with_restart` against a stand-in fixture (so that function is tested,
    not re-implemented); the metrics test derives its extremes from two
    iterations and drops the repeated assertion.
  - **Nit.** `IMPAIRMENT_CASES` is defined once and `MULTI["cases"]` derives from
    it; the unused `driver` entry left the impairment context.
- Failure modes written before the isolated tests: a blackhole that is not
  counted or whose recovery is timed from the attempt loop instead of the path's
  return; a path that lets an attempt made during the outage succeed, or drops
  one a returned path should carry; a cap that never delays a byte (untested) or
  loses a pong it should not; a restart case that treats the Gateway's own close
  as a failure, leaves a connected client down, reports a reconnect without the
  downtime's failed attempts, or waits forever for the profiler's answer; an
  unexpected close after an impairment leg going uncounted; a case that reports
  nothing being read as a pass.
- Evidence: `python3 scripts/test-tron-profile.py` passes 37 tests, six of them
  new or reworked for these cases (blackhole attempts and recovery including the
  rest of an in-flight attempt; the cap metering the path without losing the
  socket; the restart reconnecting every client through the profiler's own
  `wait_with_restart`; an unexpected close after a blackhole failing the run;
  a restart that leaves a client down; each case's metrics from two iterations).
  The close-after-blackhole test fails against the pre-fix driver (verified by
  reverting the `closing` reset). One short smoke run
  (`--iterations 1 --catalog-files 200 --catalog-mib 32 --mixed-seconds 30
  --blackhole-seconds 20 --no-build`) reports every case; its numbers are in
  Findings.
- Changes: `scripts/tron-profile-gateway`, `scripts/tron-profile-gateway-driver.mjs`,
  `scripts/test-tron-profile.py`, the multi-session qualification section of
  `packages/gateway/README.md`, this plan (Findings, this entry).
- Kept on purpose: `scripts/ios-gateway-fault-proxy.mjs` is unchanged. It is an
  HTTP-level fault proxy the iOS E2E harness owns (fixture-owned Server, control
  token, per-request modes) and its restart spawns a Gateway without the
  profile's probe, faux-model rate or retained log, so it cannot shape this
  scenario's raw byte stream; the driver's relay is a per-client TCP shaper and
  the profiler owns the restart.
- Blocked on: "the baseline for each case is in Findings". This host was at
  1-minute load 19–24 from other sessions' builds, so the short run above is the
  shape of the cases, not the baseline: with `--blackhole-seconds 20` the client
  gets one attempt before the path returns, so C-3's recovery p95 is one sample,
  and the bandwidth and restart numbers move with how much data fits the leg.
  To unblock: the orchestrator runs
  `scripts/tron-profile gateway --scenario multi-session` (defaults: 3,000 files,
  2 GiB, 120 s mixed window, 90 s blackhole, 2 Mbit/s cap, restart) on a quiet
  host and refreshes the Findings rows.
- For the next agent: C-4's `impairment.bandwidth.pong_deadline_misses` and
  G-13's `impairment.restart.requests_over_1s` are the numbers those tasks must
  move; G-4's capacity evidence is `impairment.bandwidth.unexpected_closes` plus
  `impairment.gateway_outbound_capacity_records` (only the bandwidth legs'
  windows). The defaults add roughly the legs' own bounds to a run that already
  takes about 20 minutes on `main`; if the quiet-host run shows the impairment
  cases dominate, shorten `--blackhole-seconds` or `--bandwidth-seconds`
  deliberately and record the new bound rather than raising the watchdog.
- Incident (reported for the orchestrator): the first smoke run of the first
  commit was started without `--no-build`, so the profiler's `build_gateway` ran
  `npm ci` through this worktree's `packages/gateway/node_modules` symlink and
  emptied the target — the `hardening/o-1` worktree's modules, which `o-3`,
  `o-4` and `o-5` also symlink to. It was restored immediately with the
  repository-pinned Node (`npm ci` in `tron-hardening-o-1/packages/gateway`, 186
  entries, matching `package-lock.json`); those worktrees were not otherwise
  touched. Later runs used `--no-build`.

### O-6b · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker (third review response)

- Result: the third review's findings are addressed. The row stays Blocked only
  on the full-length default run on a quiet host, which is the orchestrator's.
  - **Major — the bandwidth leg was too short and too light for the cap to
    matter.** It is now a fixed duration (`--bandwidth-seconds`, default 90,
    several ping intervals and longer than one liveness window) with the link
    kept full by full bounded transcript pages mounted back to back, and it
    reports `link_use` (delivered rate ÷ cap) as well as the meter's delay.
    `validate_impairment` now rejects a leg that filled under half its cap or
    whose meter held bytes back for under half the leg, so "zero pong misses,
    no close for capacity" can no longer be true by construction. A stub test
    fails a leg that stops after a few operations.
  - **Major — the restart storm was measured after the storm.** Every request a
    measured client makes from the restart on is recorded, the ready sequence's
    own mounts and lists included, and each is stamped `sinceRestoreMs` against
    the moment the new Gateway was healthy. Each client's storm loop starts at
    that client's own ready moment, not after the slowest one returned. A stub
    test delays the mobile's first open past 1 s after the restore and requires
    the storm to contain it (it measured nothing without the fix).
  - **Minor — the relay ignored the receiving socket's backpressure.** The
    relay now holds a `sinkBlocked` flag set when a write is refused and cleared
    on `drain`, and resumes the source only when the direction is not held, not
    blocked and within its budget; a chunk read while the direction is held
    waits and is written in order on release. The two classes moved to
    `scripts/tron-profile-relay.mjs` so the shaping can be driven directly: a
    flooding source paired with a sink that never drains now stops after one
    chunk (`scripts/test-tron-profile.py`, `RelayBackpressure`), where it used
    to write all 2,000.
  - **Minor — a real pong miss never triggered the blackhole's abandon.** The
    mobile chat is mounted on the shaped path and settles for one ping interval
    (`blackholeSettleMs`) before the outage, so the client is between pings;
    `silence_ms` is measured from the client's last inbound frame; and the wait
    allows the two ping ticks the client needs to count the miss (the miss is
    only noticed on the tick after the failed one). The leg reports
    `abandonedOnMiss`. The `blackholeSeconds` comment no longer claims the case
    exercises the Gateway's socket cap: nothing the phone sends during the hold
    reaches the Gateway.
  - **Minor — metric directions and a configuration value read as a metric.**
    `link_use`, `delivered_bytes_per_second`, `sent_bytes_per_second`,
    `metered_ms` and `impairment.restart.requests` are volume/throughput and now
    read "higher is better" (`metered_ms` is the cap's own work, not a target);
    `cap_bits_per_second` left the metrics for the report context, and
    `clients_ready` is gone because every client is ready or the run is
    rejected.
  - **Minor — the driver restated the phone's connection settings.** The ping
    interval, pong deadline and one shared handshake deadline now come from
    `packages/protocol-fixtures/gateway-connection-contract.json`, which the
    profiler passes as `connection` in the driver config; `connect()` bounds
    open and hello with one deadline, as the contract says. The phone's
    reconnect backoff stays a named copy of `ReconnectDelayPolicy.standard`
    (it is not in the contract fixture).
  - **Vit/Minor — stale text.** The duplicate `## O-6b · Done` section is
    deleted; `--bandwidth-operations` (which never existed) is now
    `--bandwidth-seconds`; the test count is current; `USAGE_EPILOG` says every
    connected client reconnects and `'none'` runs none; the dead
    `failed_attempts` conditional and the stale restart test name are gone.
    The driver's result file is written before the run is judged, so a run
    rejected for an unexpected close still carries its impairment legs.
- Deliberately not forwarded: a connection the relay held during the blackhole
  is never forwarded when the path returns. This is a **pessimistic model, not
  the phone's behaviour**: an attempt still inside its handshake deadline has
  not been abandoned, and real TCP would retransmit and connect within a second
  or two of the path returning. It is kept because it measures the worst case
  the case is about (an attempt that has to time out first), and it inflates the
  blackhole's recovery figure by the rest of that attempt's deadline — 13.8 s of
  the 15.8 s recorded here. `scripts/tron-profile-relay.mjs` states this.
- Owed to C-3 and C-4: this case models the phone from the contract fixture and
  a driver copy of `ReconnectDelayPolicy`, so both tasks must update the driver
  with the new handshake deadline, the pong-deadline change and a hook for the
  path returning (the driver has no path-change signal; recovery is timed from
  its own timer). The iOS-only changes will not reach this case otherwise.
- The per-iteration watchdog is again the sum of the legs' own bounds — 165 s
  mixed + 90 s no-subscriber + 270 s blackhole + 270 s bandwidth + 425 s restart
  = 1,220 s on the defaults, down from 1,430 s because the bandwidth leg is a
  90 s duration rather than a 300 s bound.
- Evidence: `python3 scripts/test-tron-profile.py` passes 39 tests (four
  reworked impairment cases, each verified to fail without its fix by reverting
  it; the new `RelayBackpressure` case fails without the backpressure fix —
  2,000 writes and a forwarded held chunk against one write and none). One
  short smoke run with `--bandwidth-seconds 30`. Numbers in Findings.
- Blocked on: unchanged — "the baseline for each case is in Findings", plus the
  full-length default run (`--bandwidth-seconds` 90, `--blackhole-seconds` 90)
  on a quiet host.

### O-6b · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker (fourth review response)

- Result: the fourth review's 1 major, 4 minor and 3 nits are addressed; the row
  stays Blocked only on the orchestrator's full-length quiet-host run.
  - **Major — the bandwidth leg could not show what C-4 and G-4 exist to fix.**
    It mounted one page at a time, so at most one page (39 kB of wire, about
    1.2 MB decoded) could ever sit ahead of a queued pong. It now keeps
    `bandwidthInFlight` (default 6) full bounded transcript pages in flight at
    once, each on its own session (the Gateway admits one `session.open` per
    session per connection, so the pages cannot share one), and reports
    `.max_in_flight`, the load the peak asked the Gateway to send
    (`.offered_in_flight_bytes` in the decoder's bytes — the unit the Gateway's
    8 MiB outbound queue is bounded in — and `.offered_in_flight_wire_bytes`)
    and the mobile's longest ping-to-pong round trip (`.max_ping_to_pong_ms`).
    `validate_impairment` rejects a leg that offered less than one pong deadline
    of its cap in flight (deleted by the fifth review below: it compared the
    decoder's bytes with a wire budget). Rejected as the reviewer's "the buffers fill" claim:
    the docs, comments and Findings said the leg "really does fill the Gateway's
    buffers" and now say what the numbers support. Recorded limit, not hidden:
    at the default 2 Mbit/s a pong *miss* is unreachable — the queue's bytes
    compress about 25–30x here, so 2 MB of wire backlog needs ~50 MB of queued
    pages, above the 8 MiB backstop — so this cap shows the round trip and any
    capacity close. **Correction (fifth review):** the "~0.3 Mbit/s" this entry
    named for a reachable miss is not below the streams' own 11,901 B/s of wire,
    so it reached nothing either; the case's default is 0.08 Mbit/s and the
    leg's own round trip is compared with the same run's uncapped one rather than
    with a constant.
  - **Minor — the `meteredMs` rule repeated `link_use`.** The rule is gone and
    `meteredMs` is deleted from the relay with it: `RelayDirection.forward` adds
    `chunk.length * 8000 / bps` for every chunk, so the meter's ms was the bytes
    the cap carried, which is `link_use` again, and the chunk that sets
    `readyAt` is written immediately — it was never "delay the cap added".
    `link_use` and the new offered-load rule are what hold the leg.
    **Correction (fifth review):** the offered-load rule is gone: comparing the
    decoder's bytes in flight with `pong deadline x cap` compared two units, and
    in wire bytes it is unreachable at the default cap. The leg now reports the
    load and is held only to the traffic it moved.
  - **Minor — the relay's never-forwarding reason was wrong.** It is now stated
    as a deliberate pessimistic model, not the phone's behaviour, in
    `scripts/tron-profile-relay.mjs`, the README bullet and the Findings row for
    the blackhole recovery (13.8 s of the 15.8 s is the model's).
  - **Minor — restart requests started before the health stamp were dropped.**
    The filter is gone: every request a measured client made is kept, with
    `duringDowntime` marking the ones that started before `restoredAtMs` (the
    new Gateway already served them inside the profiler's health check) and
    `sinceRestoreMs` negative for those. `impairment.restart.requests`,
    `.requests_over_1s` and `.request_ms_p99` count the storm; the new
    `.downtime_requests` counts the others. **Correction (fifth review):**
    labelling by the stamp still put the new Gateway's first, served requests in
    the downtime; the classification is by outcome now (served = storm, failed =
    downtime) and `.requests_over_1s` counts those first requests.
  - **Minor — the driver kept its own copy of the contract values.** The three
    literals are gone: the driver reads
    `packages/protocol-fixtures/gateway-connection-contract.json` itself (so a
    hand-run driver and a qualification run agree), and `config.connection`,
    which the profiler fills from the same file, is only the stub tests'
    override.
  - **Nit — an assertion that could not fail.** `all(sinceRestoreMs >= 0)`
    asserted what the filter guaranteed. It is replaced by an outcome check on
    every request (fifth review: `duringDowntime == (failed is not None)`) and
    by a new
    test that makes the profiler's health stamp late (the harness's stand-in
    fixture delays its answer) and requires the requests the new Gateway served
    in that gap to be present with a negative offset. Verified: with the old
    filter restored the new test fails and `leg["requests"]` is empty.
  - **Nit — the second-review entry's test count.** 39 → 37; 39 belongs to the
    third entry.
  - **Nit — the blackhole watchdog left out part of the leg.** `driver_
    deadline_seconds` now adds `blackholeSettleMs`, one measured deadline for
    the settle and the relay's own listen/handshake, and the outage.
- Smoke (short, `--cases bandwidth --iterations 1 --catalog-files 100
  --catalog-mib 24 --mixed-seconds 30 --bandwidth-seconds 10 --bandwidth-mbps
  0.5 --no-build`; host at 1-minute load 25): the first attempt found a real
  problem — with six concurrent page mounts on *running* sessions the Gateway
  refused the synchronization (`conflict`, "no longer owned by this token")
  because a running session's token rotates while its prompt streams, and the
  driver exited. `pageTargets` now prefers idle sessions (cold, then large,
  running only as a fallback), and the second attempt's syncs succeeded. It
  still exceeded the driver's sum-of-bounds deadline on this host (opens on
  `main` take seconds here), so it produced no baseline: the numbers stay owed
  to the quiet-host run.
- Evidence: `python3 scripts/test-tron-profile.py MultiDriverImpairment
  ImpairmentCases RelayBackpressure` passes 13 tests. Two new failure modes were
  written first and each has a negative control: a leg that runs one page at a
  time (`maxInFlight >= 2` fails with the lanes forced serial — 1, verified) and
  a run that drops the requests served before the health stamp (fails with the
  old filter restored — `requests` came back empty, verified). The
  offered-load rule had its own unit case (`offeredInFlightBytes` below one pong
  deadline of the cap rejects the run), replaced in the fifth review by the
  streaming leg's `link_use` gate. Numbers for the new leg shape are owed
  with the baseline.
- Blocked on: unchanged — "the baseline for each case is in Findings", plus the
  full-length default run (`--bandwidth-seconds` 90, `--blackhole-seconds` 90)
  on a quiet host.

### O-6b · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker (fourth review, decision taken)

- Result: on the orchestrator's decision, the second capped case is added rather
  than changing the plan's 2 Mbit/s page leg.
  - **New case `bandwidth-stream`** (`--bandwidth-stream-mbps`; the default is
    now 0.08, corrected by the fifth review below; `--bandwidth-stream-seconds`,
    default 30): the mobile mounts several chats
    on the phase's running sessions, whose transcripts stream superseding
    snapshots and keyed events, and the path is then capped below what they
    produce. The queue therefore holds replaced state — what G-4 coalesces — and
    whatever waits behind it, which the page leg's 2 Mbit/s cap can never reach
    (its one-page offer waits ~0.16 s against an 8 s deadline). The streams are
    attached before the cap is applied. It reports the streams held, their
    payload rate, delivered wire rate and `link_use`, `max_ping_to_pong_ms`,
    `pong_deadline_misses` and `unexpected_closes`; both capped legs' windows are
    what `gateway_outbound_capacity_records` counts.
  - **Deviation (recorded):** the plan's O-6b "Do" names one cap (default
    2 Mbit/s). It is kept, and this second case adds the low cap the
    orchestrator asked for. **Correction (fifth review):** the 0.3 Mbit/s this
    entry first used was *not* below the streams' production. The measured
    seven streams produced 295,621 B/s of decoded state and 11,901 B/s of wire,
    so `link_use` at 0.3 Mbit/s was 0.32 and the queue never grew. The "320 kB of
    wire = 8.5 s of a 0.3 Mbit/s path" arithmetic also compared decoded bytes
    (the 8 MiB queue) with a wire rate. The default is 0.08 Mbit/s (10,000 B/s),
    below the 11,901 B/s of wire the workload produces.
  - **Smoke (short, `--cases bandwidth-stream --iterations 1 --catalog-files 100
    --catalog-mib 24 --mixed-seconds 30 --bandwidth-stream-seconds 20
    --no-build`, host at 1-minute load 25):** the case held **8 streams** (7 the
    fifth review could find after the relay hello; see its entry),
    carried 5.94 MB of decoded state in 20 s (295,621 B/s of decoded state,
    11,901 B/s of wire), delivered 11,901 B/s
    (`link_use` 0.32 against the nominal 37,500 B/s
    cap the profiler rounded 0.3 Mbit/s to, not the 33,300 B/s this entry first
    stated), and the
    mobile's longest ping-to-pong round trip was **2,466 ms** against the
    **1,696 ms the same run's uncapped path answered** — five times the ~120 ms
    the path answers when idle, but also worse than this busy host's own
    uncapped maximum, which is why the fifth review replaced the fixed rule.
    That run's cap never bound, so its round trip is a host sample, not the
    leg's backlog. No pong miss and no capacity close. Reported as measured, not
    tuned to produce a miss. The same smoke was rejected by the mixed window for
    having no `promptAdmission` samples on this 100-file catalog and loaded host,
    which is why it has no baseline.
- Blocked on: the same full-length default run; the streaming case's numbers for
  the default 30 s leg, and whether it reaches a miss or a close there, are part
  of it.

### O-6b · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker (fifth review response)

- Result: the fifth review's 3 majors, 3 minors and 3 nits are addressed; the row
  stays Blocked only on the orchestrator's full-length quiet-host run.
  - **Major — the `bandwidth-stream` case never backed the link up.** The 0.3
    Mbit/s default was above the workload's own production (11,901 B/s of wire
    against 37,500 B/s of cap), so the queue never grew and the leg reported
    zero of everything. The default is now 0.08 Mbit/s (10,000 B/s), below the
    measured wire production, with the arithmetic in the profiler beside the
    constant; the leg is rejected unless it kept at least 0.9 of that cap full
    (`MINIMUM_BANDWIDTH_STREAM_LINK_USE`), and its round trip is compared with
    the same run's uncapped round trip instead of a 1 s constant. The
    "320 kB of wire = 8.5 s at 0.3 Mbit/s" and "2.5 MB/s" arithmetic is gone
    from the profiler, the README and the Findings above: it compared decoded
    bytes (the 8 MiB queue bound) with a wire rate, and the Gateway's `autoPong`
    answer is not queued in its application queue at all, so a delayed pong is
    the socket's buffered bytes, not a pong behind the queue.
  - **Major — the reported round trip was the client's lifetime maximum.**
    `RecordingClient.beginPongWindow()` now resets the maximum and the
    outstanding-ping list at each capped leg's start, and `pingsOutstanding`
    charges a pong to the oldest ping it can answer rather than to the newest
    (`pingSentAt`, which each tick overwrote, is deleted). Two failure modes
    were written first with their negative controls: with the per-leg reset
    removed the leg reported the mixed window's 1,503 ms as its own, and with
    the newest-ping attribution restored it reported 298 ms for a pong the stub
    delayed 1,500 ms.
  - **Major — a capacity close in a capped leg discarded the evidence and
    skipped the restart.** `impairmentLegs` now mutates the one `legs` object
    that is `result.impairment`, persists the result file after every case, and
    before each following case reconnects a client that a counted leg closed
    (re-mounting its chat on the shaped path); the close is carried to the run's
    verdict after the result is written. Negative control: with the old
    fail-on-close the restart case was skipped and the new test failed. The
    lane's "socket died without being counted" check also waits a tick for the
    close event, so a close that lands while the socket is only closing is
    counted rather than reported as a measurement bug.
  - **Minor — the `streams` count included a chat that was not mounted on the
    relay socket.** `relayFor` rebuilds the mobile's socket on the relay, and
    the streaming leg now re-mounts the chat there before mounting the streams,
    so `streams` counts subscriptions on the shaped socket (the fourth entry's
    "8" is 7 streams plus the mounted chat, now real; the fourth review found 7
    `session.open`s after the relay hello).
  - **Minor — the page leg's offered-load rule compared two units.** Decoded
    bytes in flight against `pong deadline x cap` (a wire figure) is not a rule
    that can hold, and in wire bytes it is out of reach at the defaults. The
    rule and `MINIMUM_BANDWIDTH_OFFERED_FACTOR` are deleted; the leg is held to
    the traffic it moved (half its cap) and reports `max_in_flight` and the two
    offered-load figures as measurements. The README now says plainly that at
    the default 2 Mbit/s neither a pong miss nor a capacity close is reachable
    (six pages ≈ 234 kB of wire against a 2 MB pong-deadline budget, under the
    8 MiB backstop) instead of claiming the result cannot be true by
    construction.
  - **Minor — the storm left out the first requests the new Gateway served.**
    `duringDowntime` is decided by outcome now (a request that failed is the
    downtime's; one the new Gateway served is the storm's, whatever its start
    offset), so the first and most contended requests count in
    `.requests_over_1s` and `.request_ms_p99`. Negative control: with the
    timestamp rule restored the new test found no served-before-stamp request in
    the storm.
  - **Nits.** The plan's smoke entry states the cap the profiler rounded
    (37,500 B/s nominal, not 33,300) and replaces "~120 ms idle" with the same
    run's 1,696 ms uncapped maximum, which is what the new comparison is against;
    `driver_deadline_seconds` adds each capped leg's unmounts (a visibility
    request and a close per mounted page, on the phone's own deadline); the
    `ImpairmentMetrics` assertions that restated input literals (`streams [8, 8]`,
    `unexpected_closes [0, 0]`, and the other passthroughs) are deleted.
- Evidence: `python3 scripts/test-tron-profile.py` passes 45 tests (18 in
  `ImpairmentCases MultiDriverImpairment RelayBackpressure`, 128 s). Three new
  failure modes with their negative controls: a leg that reports the window
  before it, a pong charged to the wrong ping, and a capped leg's close that
  discards the restart. The `validate_impairment` unit cases use the fourth
  review's own measurements (0.317 `link_use`, the 1,696 ms uncapped maximum) as
  the rejected leg.
- Blocked on: unchanged — "the baseline for each case is in Findings", plus the
  full-length default run (`--bandwidth-seconds` 90, `--blackhole-seconds` 90,
  `--bandwidth-stream-seconds` 30) on a quiet host. Whether the new 0.08 Mbit/s
  leg reaches a pong miss or a capacity close inside 30 s is part of that
  baseline; the leg is not tuned for it.

### G-5 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-5`)

- Result: live runtimes are bounded by bytes as well as by count.
  `LIVE_RUNTIME_BYTE_BUDGET` (1.5 GiB) in
  `packages/gateway/src/sessions/runtime-registry.ts` charges each live runtime
  `LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR` (3) times its canonical transcript bytes,
  measured at admission from the same one-`stat`-per-runtime inventory the
  resource sample reads (`resourceInventory`, now documented as shared by the
  sampler and the budget, and skipping a slot that is already disposed). The
  budget is **eviction pressure, not an admission gate**: an admission that does
  not fit retires idle runtimes **largest first** (the largest reclaims the most),
  under the existing protections (subscriber, run, lease, blocked ownership) and
  only when the runtime can be reloaded, until the projected total fits. Nothing
  is retired when retiring could not help — the opening charge is larger than the
  whole budget, or the excess is larger than every eligible runtime together —
  and an admission the retired set still cannot fit is served anyway, with its
  `runtime.loaded` record carrying `overBudget: true`. The projected total counts
  the starts already reserved for except the requested session's own reservation,
  which the opening charge already is; a start already pending for the requested
  session retires nothing at all. No admission is ever refused on this budget
  (G-12 owns refusal under the real heap limit); the runtime count and the
  explicit heap limit stay the backstop. Each transition writes one record from
  the registry: `runtime.loaded` at publication and `runtime.evicted` where the
  slot stops being live, both with `sessionId`, a `reason` (`open` | `create` |
  `automation` | `import` | `oversize` for a load; `bytes` | `idle` | `capacity`
  | `closed` | `disposed` | `deleted` | `shutdown` for an eviction),
  `transcriptBytes` and the `estimatedHeapBytes` the budget charged, as named
  `counts`, and `overBudget` on an over-budget load (the log line carries it in
  `counts` as `overBudget = 1`).
  `packages/mac-app/scripts/tron-gateway-launcher.c` passes
  `--max-old-space-size=4096` before the entrypoint, so the budget is under an
  explicit limit instead of Node's default.
- Failure modes written before the code (all covered by
  `packages/gateway/src/sessions/runtime-registry.integration.test.ts`): (1) a
  live runtime that grew past the budget is never reclaimed, because admission
  checks only the runtime count; (2) the smallest idle runtime is retired when
  the largest would have been enough, so extra sessions lose their state; (3) an
  opening session whose bytes fit nowhere is refused on the budget, so a loaded
  session it cannot reclaim makes every later open of a non-empty transcript
  unopenable; (4) a protected runtime (an audience) is retired under byte
  pressure; (5) the transitions are counted but never named, so no record says
  which session was loaded or evicted, what the budget charged it or why it went
  away; (6) two opens of one session at once charge it twice, so the pass evicts
  idle runtimes for room the first open had already taken; (7) a transcript
  larger than the whole budget evicts every idle runtime and can then never
  open; (8) an eviction is recorded for nothing, because retiring every eligible
  runtime still could not make the admission fit; (9) an evicted runtime
  reports the size it was loaded with instead of the bytes it gave back; (10) a
  slot disposed outside the registry is recorded as an extension-requested
  close.
- Tests (seven added, one existing; all in the owning integration file):
  largest-first retirement and the over-budget admission use a **real**
  transcript grown with a sparse `truncate` (the previous mocks fed the budget
  sizes production never supplies), the small session is acquired first so a
  smallest-first, iteration-order or least-recently-used pass all fail, the
  same-session race is driven through a `resourceInventory` spy plus a held
  `RuntimeSlot.create` mock so the second pass runs while the first open's
  reservation exists, and the live set is asserted through the public
  `resourceInventory()` instead of a private `slots` cast. Each new test was
  shown failing on the source without its fix:
  - same-session double charge: `AssertionError: expected true to be false //
    Object.is equality` on the previous registry source (the second pass retired
    the 470 MiB idle runtime).
  - nothing retired when retiring cannot help: the same `expected true to be
    false` on `idleSlot.isDisposed` with the eligible-set check removed.
  - the eviction's reclaimed bytes: `AssertionError: expected 645 to be
    838860800 // Object.is equality` with the pass's charge refresh removed.
  - `disposed` not `closed`: the reason mismatch for a slot disposed outside the
    registry.
- Evidence:
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts -t
    "budget"` passes 9/9 (six budget cases) in ~2 s on the changed tree, and the
    whole owning file passes 257/257 in 51 s.
  - `npx tsc --noEmit` is clean on the changed tree.
  - Launcher: the compiled launcher plus
    `packages/mac-app/scripts/test-tron-gateway-launcher.sh` (fixture asserts
    `$1 = --max-old-space-size=4096` before the entrypoint, exit 13 otherwise)
    pass end to end with the pinned Node 22.22.0 on `PATH`, so the flag reaches
    the child argv in every launch case. It stays the check for the launcher half
    of this task.
- Checks: `runtime-registry.integration.test.ts` (the row's named owner) covers
  the budget, the largest-first order, the protected-runtime case, the
  over-budget admission and its record, the same-session double charge, the
  no-pointless-eviction case, the charged-zero admission and the records.
- Docs: `packages/gateway/README.md` (Session invariants) states the budget as
  eviction pressure, the factor, the largest-first order, the cases that retire
  nothing, the admitted-over-budget load, the same-session reservation
  exclusion, the explicit `--max-old-space-size` and the records;
  `packages/gateway/docs/observability.md` has rows for `runtime.loaded` and
  `runtime.evicted` with their levels, triggers, `reason` values, `overBudget`,
  `counts` and rationale.
- Volume: the two records are per transition (one per session load and one per
  eviction — tens a day on a normal day, a few hundred worst case), far inside
  the 1 MB/day budget; the per-minute `gateway.resources` volume is unchanged.
- Review round 2 (2026-09-28, changes-required, 2 major + 3 minor + 2 nits;
  all addressed):
  - **Same-session double charge.** The second open's byte pass charged the
    requested session twice — its reservation and its opening charge. The
    projected total now leaves out the requested session's own reservation, and
    a pass whose requested session already has a start pending retires nothing;
    the mutation test above pins it.
  - **The budget refuses an open.** Removed by orchestrator decision: the budget
    is eviction pressure, G-12 owns refusal under the real heap limit. Nothing
    is retired when retiring cannot help, an admission it cannot fit is served
    and its `runtime.loaded` record carries `overBudget: true`, and the whole
    refusal path (`requireRuntimeByteBudget`, `byteBudgetFits`) is deleted with
    its `busy` message. README, observability rows and this entry say so.
  - **Pointless eviction.** Before retiring anything, the pass sums the eligible
    candidates and retires nothing when the excess is larger than that sum; the
    eligibility closure re-checks that room is still needed (`projectedBytes() >
    LIVE_RUNTIME_BYTE_BUDGET`), like `evictIdle`'s `needsCapacity()`. Only the
    eligible-set check has a negative control; the closure's re-check is
    defensive (it can only be reached through a concurrent pass) and has no test
    of its own.
  - **Bytes the eviction actually reclaimed.** The pass refreshes
    `publishedRuntimeBytes` from its own stat, so a runtime that grew after its
    load is recorded with what it gave back (the records test asserts 800 MiB,
    not the few KB it was loaded with).
  - **Dead budget calls.** The `create` and automation paths no longer call the
    byte pass or a budget check with `incomingBytes: 0`; a session with no
    transcript adds no bytes, so the pass is only reached by an admission with a
    real charge (open, import), and the rule lives in the pass's comment.
  - **Attribution nits.** The slot cleared on the next open after some other
    owner disposed it is recorded as `disposed` instead of claiming `closed`. The
    rekey double count went away with the pass's covered set: no pass adds the
    charge of a runtime published after its inventory read, because the budget no
    longer refuses on that snapshot.
  - **Handoff evidence.** The garbled budget-message failure text is replaced by
    the real negative-control outputs above.
- Review round 1 (2026-09-28, changes-required → fixed; superseded where round 2
  removed what it protected): (1) the publication race was closed by the
  per-runtime charge and its mutex add-back, with the concurrent-publication
  case — round 2 deleted the refusal that made the gated snapshot necessary, and
  with it that case; (2) the oversize admission is passed through
  before any eviction, with the oversize case; (4) a zero-charge admission is
  passed through too — the supervisor chose A1 + B1 (preserve the product; the
  explicit heap limit is the hard backstop; name the oversize load). (5) the
  tests now use real sizes and public accessors. (6) `resourceInventory` skips a
  disposed slot and the pass excludes the requested session, which also makes
  the old `break`/`continue` check unreachable and it was deleted rather than
  replaced. (7) the records carry `reason` and put their bytes in `counts`.
  (8) the `runtime-slot.ts` edit (an out-of-scope extra `await stat()` in the
  Slot conflict zone) is reverted; the registry owns the eviction record from
  its own charge. (9) the pass is wrapped in the `session.runtime-budget` stage.
  (10) the private `slots` cast is gone; the assertion uses
  `resourceInventory()`, not `activeSessionIds()`, which reports only busy slots
  and cannot name two idle-or-live runtimes.
- "Done when" (a sequence of large idle sessions in O-6a never exceeds the
  budget): O-6a confirmation and the factor measurement are owed by the
  orchestrator with the quiet-host runs; factor 3 is provisional. The budget is
  enforced on the admission path and proven by the integration cases above; if a
  quiet-host O-6a run shows the real heap-per-transcript-byte figure is off, the
  factor is the one number to move.
- Kept on purpose: the budget is a named constant next to its only user rather
  than a config surface (the plan names `LIVE_RUNTIME_BYTE_BUDGET`; a deployment
  override would be speculative); the count still caps the runtime number while
  the budget caps bytes, so both checks stay where each belongs; `resourceInventory`
  stayed the one place that stats live runtimes, so the sampler and the budget
  cannot disagree about a runtime's size; `importFromJsonl` is charged the source
  transcript's bytes, which is what the fork copies.
- Deviations: `runtime-registry.ts` kept the retirement body of `evictIdle` as a
  new private `retireIdleRuntime` so the byte pass reuses the same commit logic
  (mutex check, slot eligibility fence, bookkeeping) instead of a second copy,
  and now threads an eviction `reason` through it; `gateway-main.ts` gained the
  log wiring. No new files. `runtime-slot.ts` is untouched by the final change.
- Withdrawn: the `runtimeEvicted(sessionId, transcriptBytes)` dependency on
  `RuntimeSlot` — the record moved to the registry with finding 8. The slot no
  longer stats its transcript at disposal; the registry records the size the
  budget charged at publication, refreshed by the byte pass from the stat it read
  before an eviction it makes (documented in the observability row).
- For the next agent: G-12 (heap-pressure shedding) owns refusal under the real
  heap limit, which this task deliberately does not do: the byte budget retires
  idle runtimes and admits an over-budget load with `overBudget` on its
  `runtime.loaded` record. G-12 should reuse `LIVE_RUNTIME_BYTE_BUDGET`, the
  projected total and the `busy` shape the runtime count uses rather than a
  second budget; the pass is `acquireMissing` and `importFromJsonl` only.
- Open risks (residual, for the orchestrator's review): (a) the estimate is
  linear in transcript bytes, so a session whose heap is dominated by something
  other than its transcript (a huge single entry, an image-heavy compaction)
  can be charged less than it holds; (b) with the refusal gone, nothing holds the
  live set under the budget when every eligible runtime is protected, so an
  over-budget set persists until an idle runtime becomes eligible — the
  `overBudget` load record is what makes that visible; (c) a real
  oversize transcript cannot be built in the fixture without a >512 MiB
  parseable file, so the `oversize` load reason is proven by inspection of the
  same condition the oversize case exercises, and an O-6a run with a real 2 GB
  catalog is where it would be seen; (d) `makeRoomForRuntimeBytes` reaches the
  whole live set with one `stat` per runtime per admission (bounded by the
  runtime count, 128), which is the same cost `gateway.resources` already pays
  once a minute.


### G-10a · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-10a`)

- Result: the last read-triggered durable write left the read path.
  `ConnectionOwner.recordProviderObservation` now computes the four projected
  fields (`credentialAvailability`, `providerIdentity`, `providerDisplayName`,
  `health`) before touching the instance and returns, still inside its mutex and
  after the admission checks, when all four already hold those values. An
  unchanged observation therefore saves nothing: no `updatedAt`/`stateRevision`
  bump, no document rewrite, no fsync. `knowledge.raindrop.read` reuses its
  existing `/user` verification to publish this observation on every attempt, so
  the second and later reads in a stable state now do no durable I/O at all.
- Failure modes written before the code (worker procedure step 4), with the
  pre-change reproduction:
  1. **An unchanged observation still writes.** A second, identical observation
     must leave the state document byte-identical with the same mtime and
     `stateRevision`, and add no fsync to the O-5 `durableWrites` counter.
     Reproduced before the change: the new case failed at
     `expect(drainDurableWriteStats().count).toBe(0)` with `expected 2 to be +0`
     (`src/integrations/connection-owner.test.ts`), and the read-path case failed
     the same way through `knowledge.raindrop.read`.
  2. **A changed observation is dropped, so a state transition is lost or a
     projection goes stale.** An availability/identity change must still persist
     `health`/`credentialAvailability`/`providerIdentity` and remove
     `providerDisplayName`; a display-name-only change must still refresh the
     label; and an identity change that leaves `health` and the availability
     equal (for example `unavailable`+`unknown` to `unavailable`+`mismatch`) is
     still a different admission state. Not reproducible before the change (the
     old code never skipped), so it is guarded by the two negative controls
     below instead.
- Evidence:
  - `npx vitest run src/integrations/connection-owner.test.ts` passes 4/4
    (0.4–0.9 s). The new case
    "skips an unchanged provider observation and persists every changed one"
    asserts the skip through the sampler's own drain, the document mtime, the
    raw file text and `stateRevision`, then asserts each changed observation and
    its derived `health` in the persisted document, with `durableWrites == 2`
    (document + directory fsync) for each write.
  - `npx vitest run src/knowledge/connectors.test.ts` passes 40/40 (5.1 s). The
    new read-path case "starts no durable write when a read observes the same
    provider admission" drives the real path
    (`KnowledgeConnectorExtension.invoke("knowledge.raindrop.read")` with a
    ConnectionOwner-backed instance), drains `drainDurableWriteStats()` — the
    exact function the O-5 `gateway.resources` sampler drains
    (`packages/gateway/src/transport/stall-diagnostics.ts`, line 344) — around the
    second read and asserts 0, then changes only the provider's `/user` display
    name, drains again, asserts 2 and asserts the new label in the connection
    snapshot. The rest of the file covers the unchanged error, credential and
    shape paths.
  - Boundary checks: `npx vitest run src/extensions/tron-modules.test.ts
    src/knowledge/connectors.test.ts` passes 44/44 (10.0 s), and
    `npx vitest run src/integrations/mcp-adapter.test.ts
    src/knowledge/multi-account-connectors.test.ts` passes 15/15 (2.3 s) — that
    pair covers MCP `setup`, `markRuntimeReady` and `admitRuntimeBinding` plus
    the multi-account connector surface, all of which read the same projection.
    The file's pre-existing first case (admission, mismatched identity, policy
    revision, disconnect) is the unchanged golden path for the observation and
    stays green.
  - Negative controls (each one term of the new guard removed, then restored):
    deleting `instance.providerDisplayName === admittedDisplayName` fails the
    rename assertion with `expected +0 to be 2`; deleting
    `instance.providerIdentity === observation.providerIdentity` fails the
    equal-health identity transition. Both are discriminating; the pre-change
    run is the control for failure mode 1.
  - `npm run build` is clean (tsc, no output).
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: the G-10a commits on `hardening/g-10a`.
- "Done when" items: (1) a read cycle with no state change reports no new
  durable write in the O-5 counters — met by the read-path case, which counts
  through the sampler's drain function around a real `knowledge.raindrop.read`
  that only re-observes the current projection; (2) a changed observation still
  persists before its response — met by the same case (a changed display name
  persists with 2 fsyncs before `invoke` resolves) and by the
  `connection-owner.test.ts` transitions. No qualification run was made for this
  row: the O-6a scenario has no provider credential and never performs a
  `knowledge.raindrop.read`, so it cannot exercise this path (the same
  counter-level substitution the orchestrator allowed for G-10's concurrency
  item).
- Kept on purpose: the admission checks (instance, exact setup revision, policy
  enabled, not disconnected), the mutex and the caller's `await` in
  `packages/gateway/src/knowledge/connectors.ts` are unchanged; only the write
  of an unchanged projection is skipped. `execute`, `markRuntimeReady` and
  `disconnect` still persist every accepted command, so "acknowledged mutation is
  durable before its response" is untouched. An absent legacy
  `credentialAvailability`/`providerIdentity` is compared as `unknown`, which is
  what the presentation projection already reports for it
  (`ConnectionOwner.snapshotOf`), so such an instance is also not rewritten for
  an `unknown` observation.
- Deviations: none from the task's Do list. Beyond it, the `providerIdentity`
  comparison was made load-bearing by adding the equal-health identity
  transition case, and the rename case was moved ahead of the mismatch case so
  that it is caught by the display-name term alone rather than by a preceding
  identity transition (the first ordering let a guard without that term pass).
- Tasks added: none.
- For the next agent: R-1 should read `durableWrites`/`durableWriteMs` from the
  fixture's `gateway.jsonl`; the connection owner now contributes fsyncs only
  when a connection command, a runtime admission or a changed observation
  writes, so G-10's fsync table row for
  `ConnectionOwner.recordProviderObservation` should be read as
  "only when the projection changes". Two review notes from this round are worth
  keeping: `stateRevision` on an instance is not a liveness heartbeat anywhere in
  the Gateway or iOS (iOS only validates `stateRevision >= 0`), and
  `markRuntimeReady` is MCP-only, so no other owner depends on this write.

### G-4 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-4`)

- Result: a connection's outbound queue is bounded by the state still worth
  sending, not by how long the link took, and the client can still accept what
  arrives. `OrderedOutboundQueue` carries a per-frame wire `topic` plus either a
  coalescing `key` (a `session.summary`, which states its own revision and
  carries no sequence) or the `sessionId` and per-session `eventSequence` of a
  sequenced frame. A newer summary removes the newest unsent summary of its
  session. A newer `session.snapshot` supersedes **every** unsent sequenced
  frame of its session up to its own `eventSequence` — snapshots, progress,
  process activity, messages — and only together with the frame that covers
  them: the survivor is re-encoded as `session.rebaseline` carrying the whole
  snapshot and the connection's installed `subscriptionToken`, which
  `SessionRebaselineAdmission` installs as fresh authority across the dropped
  sequences. A snapshot for a session this connection holds no token for, or a
  sequenced frame with no replacement, supersedes nothing, so the queue never
  creates a sequence gap it cannot cover. The replacement takes the survivor's
  place at the queue's tail, so what a client receives is a subsequence of what
  was enqueued in enqueue order, and the frame `ws` is already writing is never
  recalled. Dropped frames release their payload and byte reservation at the
  completed-frame boundary and are decremented from `acceptedFrames`, so the
  `connection.closed`/`connection.write-error` completed/accepted counts keep
  describing frames the connection owed its peer. The 8 MiB/4,096-frame backstop
  is unchanged, and `connection.outbound-capacity` names `oldestTopic` (the
  frame the socket was writing or waiting on) and `nextTopic`/`nextBytes` (the
  frame that did not fit). `gateway.resources` gained
  `outboundCoalescedFrames`/`outboundCoalescedBytes`, reported where each
  superseded frame is dropped.
- Review round 1 (construction: `changes-required`) addressed:
  - Blocker — the first version dropped sequenced frames and left an
    `eventSequence` gap, which `SessionSnapshotEventAdmission`/
    `SessionPresentationStore.admitEnvelope` reject with a resynchronization;
    the tests asserted the gap (`[1, 2, 8]`, `progress 5, snapshot 6`) instead of
    what the client accepts. The orchestrator chose the rebaseline-carrying
    construction above over narrowing G-4 to unsequenced frames; the queue now
    sends the survivor as `session.rebaseline`, and only with the installed
    token.
  - Blocker — process activity was keyed by `processId`, so a later activity for
    the same process dropped a frame whose `removedProcessIds` no later frame
    carries. `session.processActivity` is no longer keyed at all; a mixed
    frame's removals survive, and the seq-1-per-activity fixture that hid this is
    gone.
  - Major — the row's only "Done when" item had no evidence. The transport-owner
    cases below are the evidence this row owns; the orchestrator's O-6b
    `bandwidth-stream` before/after numbers (0 `connection.outbound-capacity`
    records on the capped leg, `outboundCoalescedFrames` > 0 in the capped
    window) are owed by the orchestrator's quiet-host runs, not by this branch.
  - Minors — invariant 4 and the outbound paragraph of `packages/gateway/README.md`
    now state the coverage rule; `connection.closed`/`connection.write-error`
    counters exclude superseded frames (`packages/gateway/docs/observability.md`); `outboundBytes`
    is documented as bytes accepted into a connection queue (bytes actually
    handed to a socket are accepted minus `outboundCoalescedBytes`); the new test
    blocks carry no `any` casts; the "8 MiB backstop" comment in the capacity
    fixture now names the connection's own backstop (64 KiB there).
- Failure modes written before the code (queue level): a superseded frame whose
  sequence is pending behind a synchronization barrier; a replacement larger
  than the remaining budget and a replacement larger than the cap; coalescing a
  frame already being written; interleaved progress and snapshot frames; a frame
  that supersedes nothing queued (backstop must still fire); a sequenced frame
  with no covering replacement; a session's frames never dropped by another
  session's snapshot.
- Evidence:
  - `npx vitest run src/transport/server-capacity.integration.test.ts
    src/transport/sync-protocol.integration.test.ts` passes 36/36 (focused run
    of the two named check files). Queue level: the newest unsent summary is
    replaced and the frame being written never is; a snapshot supersedes its
    session's unsent sequenced frames only when it carries a rebaseline and
    never another session's; a replacement that only fits because the state it
    supersedes is dropped is accepted; the backstop still fires for state
    nothing supersedes; a replacement larger than the queue fails closed.
  - Real-broadcast evidence with a held socket (the shape O-6b's cap produces):
    6 × 24 KiB `session.snapshot` broadcasts plus a progress frame and a process
    activity against a 64 KiB `maximumOutboundBytes` deliver exactly
    `[session.snapshot(seq 1), session.rebaseline(snapshot seq 8)]` — the
    in-flight frame is never recalled, the survivor carries
    `subscriptionToken: "token"` and the snapshot whose `eventSequence` covers
    every dropped sequence, `queuedFrames: 2`, no
    `connection.outbound-capacity` record, the socket still OPEN, and 6 frames /
    ~5 × 24 KiB coalesced. Without coalescing the fourth 24 KiB snapshot closes
    the peer.
  - Keyed/summary case: only the unsent superseded summary revision is dropped
    (`outboundCoalescedFrames: 2` for two supersessions of one session);
    sequenced frames no queued snapshot covers, including the removal-carrying
    activity, are all delivered in order.
  - Backstop case: three distinct sessions' 24 KiB snapshots against the same
    64 KiB cap still produce one `connection.outbound-capacity` record with
    `oldestTopic=session.snapshot nextTopic=session.snapshot nextBytes=…`, a 1013
    close, `closeInitiated`, and no further admission.
  - Barrier case (`sync-protocol.integration.test.ts`): with the open response
    held, three quarantined 24 KiB snapshots and a progress frame flush after
    response + ack; the queue holds the two responses plus the one
    `session.rebaseline` instead of overflowing the 48 KiB cap,
    `synchronizationBytes` is 0, no capacity record is written, and the suffix
    arrives as the rebaseline carrying `opened.result.syncToken` and snapshot
    `eventSequence: 6`.
  - Phone side (`packages/ios-app/Tests/Gateway/SessionPresentationStoreTests.swift`,
    "a coalesced session rebaseline installs the state a gap would
    resynchronize"): the store is fed exactly the frames the coalescing queue
    emits — the in-flight `session.snapshot` then the `session.rebaseline` with
    the live token and the survivor snapshot six sequences later. It installs
    the survivor (the branches that cannot reconcile keep the previous authority
    and schedule a resynchronization instead of assigning it), and a second
    store fed the same state one exact-next frame at a time reaches the same
    authoritative snapshot, the same `visibleTranscript` and the same
    `mountedTranscriptCoverage`, and the control that sends the same newer
    snapshot as the plain exact-next topic installs nothing at all — that gap is
    what the rebaseline form replaces. (`scripts/tron-ios-test run
    --only-testing TronMobileTests/SessionPresentationStoreTests`: 66/66.)
  - Negative control (`~/.tron/workspace/files/hardening/g-4/negative-control.txt`):
    the coalescing identity removed from `outboundFrameIdentity`, then restored;
    both new integration cases fail with `queuedFrames: 0` — the queue retired on
    its backstop, which is the capacity close G-4 prevents.
  - `npm run build` clean; `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Review round 2 (construction: `changes-required`) addressed:
  - Blocker — the rebaseline dropped every unsent sequenced frame of its session,
    including frames whose effect no snapshot installation performs: the phone's
    `session.operationFailed` receipt (`ComposerDraftCoordinator.failOperation`
    restores the draft and retires the submission), `session.extensionError`,
    the `session.closed` notice, the `session.resourcesChanged`/
    `structureChanged`/`contextChanged` revision bumps that reload commands, and
    extension editor directives. The queue now supersedes only topics a snapshot
    restates (`SNAPSHOT_STATED_TOPICS` in `server.ts`) and only the run of that
    session's frames after the newest fence: dropping stops at the first frame
    whose effect installing a snapshot does not perform, and that frame and
    everything behind it are delivered in order.
  - Minor — the sequence comparison ignored `runtimeGeneration`, so a
    generation-2 snapshot could drop generation-1 frames and leave a gap the
    phone resynchronizes over. Frame identity now carries
    `runtimeGeneration` (read from the payload) and only frames of the
    snapshot's own generation are superseded; frames of another generation are
    fences.
  - Minor — `recordOutboundBytes` counted the original snapshot's bytes, not the
    `session.rebaseline` the queue queued. `OrderedOutboundQueue` now reports the
    bytes it accepts (new `accepted` callback), so accepted minus coalesced is
    exactly what reached the socket; the per-connection rebaseline encode is
    stated in `packages/gateway/README.md` (only the connection's installed
    `subscriptionToken` differs).
  - Nit — the observability row, the `outboundCoalesced*` doc comment and the
    `gateway.resources` row no longer say "same key" (supersession is by session
    and sequence).
  - Evidence: `server-capacity.integration.test.ts` 34/34, the round's focused
    set (`server-capacity` + `sync-protocol.integration` + `stall-diagnostics` +
    `server-compression` + `server-live-view` + `session-sync`) 84/84 and
    `server-connection-memory` + `server-heartbeat` + `server-revocation` +
    `server-frame` 37/37; `npm run build` clean. New cases: "keeps a one-shot
    receipt and everything behind it when its snapshot covers the run after it"
    (a stalled link broadcasting snapshot 1, progress 2,
    `session.operationFailed` 3, progress 4, snapshot 5 delivers
    `session.snapshot:1`, `session.progress:2`, `session.operationFailed:3`,
    `rebaseline:5` with the receipt's own `data.message`, `outboundCoalescedFrames: 1`,
    and accepted minus coalesced equal to the bytes handed to the socket) and
    "supersedes only the frames of the surviving snapshot's own runtime
    generation" (delivers `session.snapshot:1`, `session.progress:2`,
    `session.toolProgress:3`, `session.snapshot:4`). Negative controls, each run
    alone and reverted: disabling the fence drops the receipt (`queuedFrames` 4 →
    2 and the delivered-frame assertion fails); disabling the generation check
    delivers `[session.snapshot:1, rebaseline:4]`; recording the original
    snapshot's bytes for the rebaseline fails the byte identity (99936 accepted
    against 49926 handed to the socket). Phone side: `SessionPresentationStoreTests`
    67/67 with "a coalesced rebaseline still carries the one-shot receipt its
    snapshot cannot restore" (the receipt's
    `sessionPresentationStoreDidFailOperation` fires, the rebaseline installs the
    same authority, visible transcript and coverage as the exact-next path, and
    the control without the receipt installs the same authority with no failure).
- Review round 3 (orchestrator merge check, after merging
  `hardening/integration`) addressed:
  - Blocker (reproduced, 3/3) — `session-archive.integration.test.ts` ›
    "settles a forking command in its origin" failed with a `running`
    `tron.chat-invocation.v1` entry. Mechanism, measured at the enqueue: the
    forking replacement's first snapshot (seq 3) is already being written when
    the replacement publishes seq 4 and seq 5, so the queue supersedes the
    unsent seq 4 and delivers the survivor — snapshot seq 5, the settled state —
    as the `session.rebaseline` that covers the dropped sequence, exactly the
    round-1 construction. The case read only `session.snapshot` frames, so it
    asserted on the *stale* seq 3 and could not see the state the client
    installs. Fix at the reading owner, not by relaxing it: a new
    `deliveredAuthorityFrames` helper returns the authoritative state the client
    received however the queue delivered it (its own `session.snapshot`, or the
    snapshot nested in the `session.rebaseline` covering the superseded
    sequence), and both the delivery wait and the "no running invocation"
    assertion now use it. The assertion is unchanged and still bites: with it
    reading the *oldest* delivered authority instead of the newest, the case
    fails on the same `running` entry, and with the coalescing disabled
    (`G4_DEBUG_NO_COALESCE`) the same case passes over plain snapshots 3/4/5 —
    no sequence gap is hidden, because the covered form is what makes the
    dropped sequence admissible to the client at all. Measured at that point in
    the case: with coalescing the client holds 1 plain snapshot (seq 3, still
    running) and 2 authority states, the second the rebaseline's settled seq 5;
    without it, 3 plain snapshots (seq 3/4/5).
  - Blocker — the round's new fixtures still spoke protocol 5 after `G-7`
    bumped the lockstep protocol to 6, so their hello was refused and six cases
    timed out. `server-capacity.integration.test.ts`'s `info()`/hello and
    `sync-protocol.integration.test.ts`'s `info()`/hello now advertise and send
    6; both files pass.
  - Evidence: the round's seven required files green in one run on the merged
    branch (`npx vitest run` of all seven, default timeouts): 388/388 —
    `session-archive.integration` 41, `server-capacity.integration` 34,
    `sync-protocol.integration` 4, `stall-diagnostics` 22,
    `server-heartbeat.integration` 10, `server-http-lifecycle.integration` 20,
    `runtime-registry.integration` 257. During the round the last two files
    timed out on single cases under this host's load (load average 20-57 from
    parallel workers) at vitest's 5 s default, against the Gateway's own 5 s
    hello deadline and against 5 s of pinned-runtime work; both are byte-for-byte
    `hardening/integration` files and pass unmodified once the host is quiet, so
    that was the host, not G-4. `npm run build` clean.
- Changes: `perf(gateway): coalesce superseded outbound frames (G-4)` and its
  review-round commits on `hardening/g-4`.
- "Done when" items: (1) "O-6b's bandwidth-cap case never closes a socket for
  capacity" — proved at the transport owner with a real Gateway, a real socket
  and the broadcast paths, where the same bytes close the peer without
  coalescing and do not with it; the O-6b `bandwidth-stream` qualification run
  itself is the orchestrator's quiet-host measurement (the fixture-level
  signals are `connection.outbound-capacity` = 0 for the capped mobile
  connection and `outboundCoalescedFrames`/`outboundCoalescedBytes` > 0 in the
  capped window's `gateway.resources` record). (2) The queue stays bounded and
  the record names topics — met by the cases above.
- Kept on purpose: the 8 MiB/4,096-frame backstop, the one-frame-at-a-time
  writer, the per-broadcast prepared encoding, the barrier quarantine (coalescing
  never touches quarantined events; it acts only on the queue), the revocation
  fence and the `whenIdle` close path, and the Gateway's own overflow
  `session.rebaseline` (which carries no `payload.eventSequence` and is therefore
  never superseded). Frames of the session state a snapshot re-states (progress,
  tool progress, process/extension activity, compaction, an earlier rebaseline)
  are dropped only by a newer snapshot of the same runtime generation that covers
  their sequence; one-shot frames (failure receipts, resource/structure/context
  revision bumps, extension editor directives, close/error notices) are fences,
  and the queue keeps them and everything behind them in order, which is what
  makes a dropped delta reconstructible and a dropped effect impossible.
- Deviations:
  - `OrderedOutboundQueue.enqueue` takes `OutboundFrame`
    (`{encoded, bytes, topic, key?, sessionId?, sequence?, runtimeGeneration?,
    rebaseline?}`); the
    queue's unit cases use `queuedFrame()`/`sequencedFrame()` helpers.
  - `outboundFrameIdentity(connection, value, prepared, maximumBytes)` needs the
    connection for the installed `subscriptionToken` and re-encodes the survivor
    through `prepareOutboundFrame` inside `stage("frame.serialize")`, so the
    rebaseline's bytes are measured where they are serialized. The per-topic
    `gateway.resources` block still attributes the frame to the topic that
    published it, not to the wire topic of the superseded survivor.
  - `OrderedOutboundQueue` gained an `accepted(bytes)` callback, so the
    `outboundBytes` counter is recorded where the queue accepts a frame instead
    of in `sendOutcome`; the value is the bytes actually queued, which for a
    coalescing replacement is the rebaseline's own.
  - `server-capacity.integration.test.ts`'s fanout case was renamed and its
    expectation changed: it used to require that every `session.summary`
    revision reaches every client in global order. G-4 supersedes that
    expectation (the plan names summaries as coalescing candidates), and the
    phone's catalog admission is revision-monotonic per session
    (`DashboardStateOwners.apply` returns `.stale` when
    `summaryRevision <= current`, so a dropped intermediate revision leaves no
    stale row). The case asserts the properties that remain: what a client
    receives is a subsequence of the broadcast order, each session's revisions
    never go backwards, every session's last revision (8) is delivered, and the
    fence response still follows every frame.
- Tasks added: none. R-1/R-4 should still watch for a phone-side consequence,
  but the gap this row used to create is gone: a superseded sequence now arrives
  covered by a rebaseline the phone installs.
- For the next agent: the `bandwidth-stream` O-6b case is the acceptance run
  for this row; read `connection.outbound-capacity` counts and
  `outboundCoalesced*` from the fixture's `gateway.jsonl`. The coalescing
  identity lives in `outboundFrameIdentity` in
  `packages/gateway/src/transport/server.ts`: a new whole-state topic added
  later needs one row in `SNAPSHOT_STATED_TOPICS`, not a second queue feature,
  and anything sequenced is superseded only through a replacement that covers
  it. A new sequenced topic whose effect installing a snapshot does not perform
  needs no change: the queue fences it by default.

### Orchestrator · 2026-09-28 · G-3 merged

- Result: G-3 merged after two review rounds; row set to Done. Its CPU-drop
  comparison against the `main` baseline is owed by the orchestrator with the
  quiet-host O-6a runs (same as O-3's accounting check and O-5's 5%
  cross-check).

### C-4 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/c-4`)

- Result: a probe whose pong is queued behind inbound data no longer retires the
  epoch. Liveness pings stay on the one shared ten-second wakeup grid T1-NET
  fixed, and a `pong_timeout` retires the epoch only when no inbound frame of any
  kind arrived after that ping was sent. The test runs inside `livenessFailed`
  before its first await, so a frame delivered while the deadline settles cannot
  be split from the verdict; only `pong_timeout` is excused, an excused probe
  re-arms the wait on the next grid tick, and a genuine send failure still retires
  the epoch. Dead-link detection stays within 18 s of the last inbound frame: no
  tick is later than one interval after it and the deadline is 8 s after the tick.
  Only a fully delivered frame counts, so a frame whose last byte arrives past
  that deadline (about 1 MiB below 1 Mbit/s) leaves a busy link with no proof at
  all.
- Evidence: `GatewayClientTransportTests` passes, 52 test functions and 0
  failures, on the branch rebased onto `hardening/integration`
  (`scripts/tron-ios-test run --only-testing TronMobileTests/GatewayClientTransportTests`,
  result bundle `~/Library/Developer/Tron/ios/test-runs/20260928T145512Z-run.MQ7T8b`)
  and over three consecutive runs of the same changed files before the rebase
  (`…143958Z-run.57fiey`, `…144021Z-run.B8c5Wt`, `…144034Z-run.3gKjfH`). Each run
  reports "52 tests in 1 suite" while the result summary counts 53 passing cases,
  because `connectFailureRecordsTransportOpening` runs two argument cases. Three new
  manual-clock cases: a pong queued behind a large inbound frame does not retire
  the link and the wait returns to the next grid tick
  (`inboundDataAnswersQueuedPong`); silence after data retires the link inside the
  18 s bound (`silenceAfterDataRetiresWithinBound`); a late clock wake probes once
  and returns to the grid (`lateClockWakeProbesOnce`). The T1-NET cases the draft
  had replaced are restored unchanged (`socketsPingOnOneSharedGrid`,
  `slowPongKeepsPingGrid`, `inboundTrafficDoesNotSuppressLivenessProbe`). Adjacent
  owner suites pass: `AppModelReconnectTests`, `AppModelLifecycleTests`,
  `AppModelTerminalLifecycleTests`, `SessionMutationServiceTests`,
  `GatewayUpdateControlPlaneTests`, `GatewayDiagnosticsServiceTests` — 111 tests,
  0 failures on the rebased branch (`20260928T145557Z-run.PYErZK`, and the same
  set before the rebase as `20260928T144054Z-run.xEFEGC`);
  `SettingsTrustCoordinatorTests`,
  `SessionImportCoordinatorTests`, `CustomModelConfigurationCoordinatorTests`,
  `PackageConfigurationCoordinatorTests`, `ProviderAuthCoordinatorTests` — 97
  tests, 0 failures (`20260928T144534Z-run.2AKmot`). The Gateway needs no change
  and its owner suites are green on the branch rebased onto
  `hardening/integration`: `npx vitest run src/transport/connection-policy.test.ts
  src/transport/server-heartbeat.integration.test.ts` — 2 files, 11 tests passed,
  O-2's inbound-silence cases included. `python3
  scripts/check-documentation-policy.py` and `scripts/personal-info-guard.sh`
  pass.
- **Real-harness confirmation, draft code.** `scripts/ios-gateway-e2e-test all`
  passed (1 test, 0 failures, 0 skipped, 55.3 s; result bundle
  `$TMPDIR/tron-ios-gateway-e2e-501/results/20260928T134641Z-run.qqg0Cq/FocusedE2E.xcresult`,
  phone records attachment `phone-connection-records`) against a private fixture
  Gateway through the fault proxy while the draft still probed on a quiet window:
  exactly one `connection.episode` cause chain, `causes=pong_timeout,transport`,
  for the blackhole leg (resolved `endedBy=connected` 6.9 s after the loss) and no
  other `pong_timeout` in the run. The final probe schedule is `main`'s grid plus
  the post-ping frame test, which only removes retirements, so that leg's path is
  unchanged; the run itself was not repeated on the final form because the shared
  simulator lease never came free before this handoff. Treat the leg as draft
  evidence until the O-6b confirmation below covers the final form.
- **O-6b confirmation is owed to the orchestrator.** O-6b's bandwidth-cap case is
  still in a sibling worktree, so this branch proves the "zero pong-deadline
  misses while data flows" claim with the manual-clock cases above. That run must
  use a cap low enough that one frame takes longer than one ping interval to
  arrive (the default 2 Mbit/s cap is too fast), and it must also show zero
  `connection.heartbeat-timeout` over a streaming window longer than 75 s: the
  55 s real-harness run cannot cover that window. That 75 s check is the uplink
  proof, not a claim that the Gateway pings a quiet phone: the phone's own grid
  pings have to reach the Gateway on the uplink for the Gateway's three-miss
  heartbeat to spare the socket. The plan's original "a receive-only phone is
  pinged on every tick" premise ended with the 2026-09-28 orchestrator decision
  that C-4 keeps T1-NET's shared grid and pings from the phone, and
  `connection-resilience.md` states the current behavior: a foreground phone
  pings every 10 seconds, so the Gateway never pings it.
- The excuse path leaves its own evidence for that run: an excused probe writes a
  debug-level `liveness` record with `outcome=excused` in the phone's connection
  ring (`packages/gateway/docs/observability.md`, `gateway.connection`), so a run
  that shows zero `pong_timeout` retirements can still show the cap delayed a
  pong and the link stayed up.
- Changes: one commit on `hardening/c-4` on top of `hardening/integration`. The
  four commits the review saw (`2a6335059..fb67f3a3f`) were collapsed: two of them
  implemented the superseded quiet-window design, so keeping them would have left
  a design the branch does not ship in its own history. The reviewed revision is
  kept as the local tag `c4-review-work` for comparison.
- Tasks added: none as a row; the O-6b confirmation stays with the orchestrator.
- Kept on purpose: `withTimeout`'s `onTimeout` hook stays for the handshake
  deadline, and the liveness probe does not pass it because its verdict has to
  wait for the deadline to pass in silence — the loop asks the epoch owner whether
  the wait continues instead. `MonotonicClock.gridOrigin` and `gridTick` stay for
  every socket's liveness ping and for presentation-lease renewal.
  `notePong` and the receive path keep `lastInboundAt` as the single liveness
  clock; no new epoch state was added.
- Deviations: C-4 does not suppress a ping when a frame arrived during the
  interval, which the plan's C-4 "Do" item 2 originally asked for. The
  orchestrator decided on 2026-09-28 that T1-NET's shared ten-second grid is a
  user-approved energy decision C-4 must not reverse and that D-4 is met by the
  post-ping frame test alone: the ping stays on the grid, a frame answers the
  probe, and detection still lands within 18 s of the last inbound frame. The
  "Do" text records the same deviation.

### C-4 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (review round 1 addressed)

- The review's verdict was changes-required, with one blocker, two major and
  several smaller findings. Its two design-level findings were decided by the
  orchestrator; the rest are fixed in the entry above.
  - **Blocker (Gateway inbound silence) and major (T1-NET reversal), decided
    2026-09-28: do not reverse T1-NET.** The draft moved the liveness probe onto a
    quiet window measured from the last inbound frame, which would have made O-2's
    merged `connection.inbound-silent` plus `connection.inbound-resumed` fire
    about twice per 25 s tick on a healthy streaming phone: the phone pings every
    ten seconds only because of the shared grid, so a phone that only receives
    would have looked silent. Liveness pings therefore stay on the grid, the phone
    keeps pinging on its own, O-2's own-ping trigger stays valid, no edit lands in
    `packages/gateway/src/transport/server.ts`, and no energy traces are needed
    because the wakeup schedule did not change from `main`.
    `MonotonicClock.gridTick`/`gridOrigin` and the lease-renewal alignment stay as
    they were. D-4 is met by the post-ping frame test alone.
  - **Major (C-4 was marked Done without the O-6b evidence):** the row stays Done
    as O-2's does, with the owed run recorded in the entry above. That run now
    also has to use a cap low enough that one frame takes longer than one ping
    interval, and to show zero `connection.heartbeat-timeout` over a streaming
    window longer than 75 s.
  - **Minor (docs claimed more than the code guarantees):**
    `connection-resilience.md`, `architecture.md` and `development.md` now say that
    only a fully delivered frame is proof and name the slow-frame bound (about
    1 MiB below 1 Mbit/s).
  - **Minor (a receive-only phone depends on the Gateway heartbeat):** the premise
    no longer holds, because the phone pings on the grid again. The part that
    survives — a pong returns on the downlink behind the Gateway's own queued data
    — is now stated in `connection-resilience.md`, and the 75 s streaming window
    moved into the O-6b confirmation above.
  - **Nit (check and retirement in two actor calls):** done. The "arrived since
    the probe" test now runs inside `livenessFailed` before its first await and
    applies only to `pong_timeout`; a probe it excuses keeps the wait running on
    the grid instead of ending its task.
  - **Nit (handoff contradicted itself):** the two numbers describe one run, not
    two — `connectFailureRecordsTransportOpening` runs two argument cases, so the
    test line says 52 tests while the result summary counts 53 passing cases. The
    entry above says so and cites one bundle per run.
  - **Nit ("a phone whose link carries inbound data sends no frame of its own"):**
    reverted with the rest of that paragraph; the doc says again that a foreground
    phone pings every ten seconds.
  - The draft's own handoff called one 5 s watchdog expiry in
    `inboundDataAnswersQueuedPong` a non-reproducing flake. It was a real defect in
    the draft's tests, not host noise: the manual clock was advanced to the probe's
    deadline before the probe had registered its deadline sleep, so the deadline
    landed eight seconds later than the test expected. The new cases gate on that
    registration before moving the clock; the breadcrumb is in the test comments.
- Evidence: the runs in the entry above, including the Gateway owner suites on the
  rebased branch, which prove O-2's inbound-silence behavior needs no edit.
- Findings rejected: none; only the premise of the receive-only-phone finding no
  longer applies.

### C-4 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (review round 2 addressed, verdict approve)

- The second review found no blockers and no majors: five minor findings and one
  nit. All are fixed, with a negative control per behaviour fix.
  - **Minor (the handoff stated the superseded design as current fact).** The
    "Why a quiet phone is still safe" paragraph is deleted. The O-6b confirmation
    keeps the zero `connection.heartbeat-timeout` check over a window longer than
    75 s but justifies it as the uplink proof: the phone's own grid pings have to
    reach the Gateway on the uplink for the three-miss heartbeat to spare the
    socket. The entry records that the plan's "a receive-only phone is pinged on
    every tick" premise ended with the orchestrator's 2026-09-28 decision.
  - **Minor (`architecture.md` overstated when the socket is closed).** The
    "deadline and cancellation retirement close the captured socket" sentence is
    limited to the handshake. The liveness deadline instead waits for its
    cancelled ping, which `GatewayPingCompletion.cancel` settles on its own
    whatever CFNetwork does; the liveness `withTimeout` call site now carries
    that reason as a comment.
  - **Minor (the excuse path left the O-6b run no evidence).** An excused probe
    now writes a debug-level `liveness` record with `outcome=excused`
    (`reason=pingTimeout`, `durationMs=8000`) before returning the wait to the
    grid. The level keeps the record in the process-local connection ring and out
    of the incident store, so the bandwidth-cap run can show that a cap delayed a
    pong while the link stayed up, not only that nothing retired. The
    `gateway.connection` row in `packages/gateway/docs/observability.md` records
    the outcome, and the "phone liveness" section of
    `packages/gateway/docs/connection-resilience.md`, `architecture.md` and
    `development.md` name the record beside "successful pings are not logged";
    `inboundDataAnswersQueuedPong` and the late-wake case assert it.
  - **Minor (the first final-form real-harness run failed unexplained) and minor
    (O-6b still owed):** no source change; both stay with the orchestrator, as the
    review asked. The signal from the finding above is what that run asserts on.
  - **Nit (two stated behaviours were unprotected).** `lateClockWakeProbesOnce`
    now wakes the probe 50 s late with a frame queued behind that probe, so the
    late wait exercises the excuse path and pre-C-4 code fails it. The new
    `pingFailureAfterInboundDataStillRetires` proves that only `pong_timeout` is
    excused: a `disconnected` ping failure after inbound data still retires the
    epoch. `ScriptedGatewaySocket.releasePing(throwing:)` fails a suspended probe
    at a chosen instant, which is what makes that case reachable.
- Evidence, all on the branch:
  - `scripts/tron-ios-test run --only-testing TronMobileTests/GatewayClientTransportTests`
    — 53 tests in 1 suite, 0 failures on the final form: `20260928T154414Z-run.qfjQTZ`,
    `20260928T155433Z-run.QcVUWH` after the negative controls were reverted, then
    two more on the committed revision, `20260928T160033Z-run.13mFm5` and
    `20260928T160105Z-run.wNHx7v`.
  - Adjacent owner suites `GatewayLogExportTests`, `GatewayDiagnosticsServiceTests`,
    `AppModelReconnectTests`, `GatewayProtocolContractTests` — 91 tests in 4
    suites, 0 failures, `20260928T155617Z-run.fRFIvl`.
  - `npx vitest run src/transport/connection-policy.test.ts
    src/transport/server-heartbeat.integration.test.ts` — 2 files, 11 tests
    passed. `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Negative controls (source reverted, tests kept; each bundle names the exact
  failing assertion):
  - The excuse branch removed (pre-C-4 behavior) makes
    `inboundDataAnswersQueuedPong`, `silenceAfterDataRetiresWithinBound` and the
    late-wake case fail with the 5 s watchdog (`20260928T154644Z-run.4SCqPO`).
  - Only the excused record removed, the excuse kept, fails
    `inboundDataAnswersQueuedPong` on `liveness.count == 1` and the late-wake case
    on the same count (`20260928T154832Z-run.iI73YT`, 6 issues in 2 tests).
  - Only the `failure.code == "pong_timeout"` test dropped makes
    `pingFailureAfterInboundDataStillRetires` fail with the watchdog: an excusable
    shape that must still retire (`20260928T155245Z-run.4qliCk`).
- Findings rejected: none.

### C-5 · Done · 2026-09-28 · worker session (branch `hardening/c-5`)

- Result: a background profile the pool cannot reach backs off to one attempt
  every five minutes instead of retrying on the 15-second curve forever, and the
  pool now records its own attempts and episodes with O-4's recorder (one
  recorder per entry, the same one the selected profile's lifecycle uses). The
  user sees the existing **No path to this Mac** presentation for a profile that
  never opens a transport; no new state was added.
- Evidence:
  - `scripts/tron-ios-test build` succeeds; `scripts/tron-ios-test run
    --only-testing TronMobileTests/DashboardStateOwnerTests` passes 53/53 in
    about 12 s, retained as
    `$HOME/Library/Developer/Tron/ios/test-runs/20260928T133032Z-run.bsekbk`, and
    `…/20260928T133058Z-run.X9c4bw` passes 19/19 for `SessionSearchTransportTests`,
    `SessionSearchCoordinatorTests` and `GatewayConnectionEpisodeRecorderTests`
    (the pool's other owners).
  - The done-when case, on the pool's injected manual clock:
    `unreachableSecondaryProfileBacksOff` drives a profile whose every attempt
    gets a socket whose hello write fails, and measures the wait before each
    attempt: `[1, 2, 2, 8, 32, 128, 300, 300, 300]` seconds. The first three
    consecutive never-opened attempts retry at the 2-second base interval, every
    later wait is strictly longer than the one before it, and from the cap each
    attempt is 300 s (`POOL_MAX_RETRY`) apart — nine attempts over about twenty
    simulated minutes, where the previous 15-second curve made about seventy.
    The same test asserts the profile's published states include the
    **No path to this Mac** label.
  - `unreachableSecondaryProfileRetriesAtOnce` parks an escalated entry and shows
    a foreground `reconcile` (the pool's activation boundary, which AppModel
    calls from `becameActive`) and a satisfied path hint each start the next
    attempt without the clock advancing.
  - The recorder evidence, with an injected `AppLog`:
    `poolAttemptsAndEpisodesAreRecorded` requires `gateway.attempt` records
    `profile=remote attemptId=initial stageReached=transport-open reason=timeout
    foreground=true`, then `stageReached=connected delayBeforeMs=3000
    gatewayConnectionId=5bf6a9a2-0000-4000-8000-0000000000c5`, and exactly one
    `connection.episode attempts=2 causes=timeout endedBy=connected
    foregroundMs=3000 maxGapBetweenAttemptsMs=3000`.
    `retiringPoolNamesItsEndedBy` requires `endedBy=background attempts=1
    causes=timeout` at scene retirement and `endedBy=stopped` at a projection
    retirement (one test, two cases). `parkedPoolEntryNamesItsStallGuard`
    requires one `reconnect.stalled` with `guard=pathUnsatisfied`.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: `feat(ios): back off unreachable pool profiles and record their
  attempts (C-5)` and this plan commit.
- Tasks added: C-7 (below).
- Kept on purpose:
  - "Show the profile as unreachable" reuses the existing `.noPath`
    presentation: `packages/ios-app/docs/architecture.md` and
    `development.md` define Offline as "recovery is stopped", which this profile
    is not, and the plan's "What must not change" allows no new visible state.
    The unreachable threshold reads the entry's existing
    `GatewayConnectionFailureClassifier.consecutiveNeverOpened` counter, so the
    profile that backs off is the profile the dashboard already labels no-path
    and no second counter exists.
  - The pool's curve is not jittered (`jitterFraction: 0`): the cap has to be a
    floor on spacing for "at most one attempt per 5 minutes" to hold, and pool
    profiles are few. The selected profile's lifecycle keeps its 80–120% jitter.
  - `retire(endedBy:)` takes the reason from its caller: the scene suspension
    that parks every entry passes `.background`, and the projection retirement of
    a profile switch, removal, pairing or teardown pass `.stopped`; profile
    removals and explicit Retry end them as `.stopped` through `stop`.
- Deviations: the initial connect now uses `connectForLifecycle` +
  `activateEvents` (the pair the lifecycle already uses) instead of `connect`,
  so the first attempt's record carries the hello's `gatewayConnectionId`.
  `reconcile` additionally resumes a parked retry, which is how "retry at once on
  foreground" reaches a pool entry without adding a call site in AppModel
  (Phone lifecycle zone). `secondaryReconnectHasNoAttemptBudget` was rewritten
  to pump the clock through the new curve; it now fails each of its first eleven
  sockets by write so its attempts are driven by the same helper.
- For the next agent:
  1. C-7: after a *failed initial connect*, the `start` task's
     `for await delivery in client.events` loop has already exited, and the
     reconnect loop only re-establishes the socket. A successful reconnect
     therefore brings a live socket that consumes no events, so that pool entry
     stops seeing `session.summary`, `system.stopping` and
     `transport.disconnected` until it is recreated. This is pre-existing (not
     introduced by C-5) and it is why the drop-and-record leg of
     `poolAttemptsAndEpisodesAreRecorded` was replaced by
     `retiringPoolNamesItsEndedBy`: the pool's `noteDisconnected` calls in
     `handle("transport.disconnected")` and in the catalog-lease failure path
     are correct but cannot be exercised from a pool whose first connect failed.
  2. The pool's `stop()` ends an episode only when one is open; a profile removed
     while connected writes no episode, which is intended (the connection turned
     out to be fine).

**Review response (C-5 round 1, follow-up commit on this branch).** An
independent review built the branch, ran the focused suites and probed the pool
on a manual clock against the integration baseline. It returned
changes-required: one blocker, one major, three minor findings and one nit, all
reproduced. The regressions were real and every finding is addressed:

- Blocker (the curve never escalated): `isUnreachable` read
  `GatewayConnectionFailureClassifier.consecutiveNeverOpened`, which is display
  state. That counter stops counting as soon as any attempt of the outage opened
  a transport — `handle("transport.disconnected")` records
  `failedAttempt(nil, code: "transport")`, and a hello timeout or a 503 sets
  `episodeOpenedTransport` too — and below the threshold each wait called
  `reconnectSchedule.reset()`, which pinned the wait at the 2-second base. The
  review measured `[5, 2, 2, 2, …]` for a secondary Mac that dropped after
  connecting and `[1, 17, 17, …]` when hello was never answered, where the
  baseline grew to 15 s. The pool now owns `Entry.consecutiveFailedAttempts`,
  incremented by every failed attempt and cleared only by a successful one, and
  `isUnreachable` reads it. Below the threshold the entry follows the standard
  progression (2 s, ×1.7, 15 s cap, unjittered); at the threshold it keeps the
  nominal delay it reached and grows by ×4 to `POOL_MAX_RETRY`, so the switch
  never shortens a wait. `GatewayReconnectSchedule.adopt(delayPolicy:)` is the
  switch. The three shapes are now tests, each of which fails on the previous
  commit: `secondaryDropThenClosedPortKeepsBackingOff` (dropped then closed
  port: waits `[2, 4, 6, 10, 40, 158, 300, 300]`),
  `handshakeFailuresBackOffWithoutPinning` (socket opens, hello never answered:
  served waits `[2, 4, 6, 24, 93]` after the 15-second deadline) and
  `busyUpgradeFailuresBackOffWithoutPinning` (503 answered at the upgrade).
- Major (`reconcile` skipped a parked backoff): the acceleration loop is
  deleted. `AppModel.reconcileDashboardConnections()` runs from
  `lifecycleRefreshAll` and from mounted-session restoration, not only on a
  foreground activation, so a selected-profile reconnect could have started
  extra secondary attempts. `enteredBackground()` already calls `retire()`,
  which removes every entry, so a real foreground cycle reconnects at once;
  `retire()`'s comment now says so, and
  `unreachableSecondaryProfileRetriesAtOnce` proves the path with
  `retire()` + `reconcile` (its path-return leg still goes through
  `notePathHint`). No `AppModel` change was needed, so no Phone-lifecycle zone
  was entered.
- Minor (`gateway.attempt` could not name its owner): `GatewayConnectionAttempt`
  carries `owner` (`.selected` from the lifecycle coordinator, `.pool` from the
  pool) and the record writes `owner=…` before `attemptId`; the observability row
  documents the field and why the profile ID alone cannot carry it.
- Minor (docs promised the old rule): `connection-resilience.md`,
  `architecture.md` and `development.md` now describe the corrected curve. The
  "no-path classification does not change retry timing" sentence is true again
  rather than deleted: the classifier drives presentation only, while the pool's
  own attempt count drives the curve.
- Minor (one main-stall ping per open pool outage): pool recorders are created
  with a no-op `mainStallPing`, so only the selected profile's recorder reports
  `app.main-stall`; the `app.main-stall` and `reconnect.stalled` rows say which
  recorder reports them, their volume, and that a pool outage still reports its
  own `reconnect.stalled`.
- Nit (a silent `guard connectionID == identity.id` in the initial connect): a
  connection that is gone or no longer the client's active one now throws a
  retryable `replaced` failure, so the attempt is recorded and the entry keeps a
  reconnect loop instead of parking `.connecting` with nothing scheduled.

Evidence for this round: `scripts/tron-ios-test build` succeeds and
`scripts/tron-ios-test run` passes 100 tests in four suites
(`DashboardStateOwnerTests` 56/56, 53 before the three new regression tests,
`GatewayConnectionEpisodeRecorderTests`, `GatewayReconnectScheduleTests`,
`AppModelReconnectTests`; `SessionSearchTransportTests` passed in the same run),
retained as `$HOME/Library/Developer/Tron/ios/test-runs/20260928T141009Z-run.AYeMxS`;
the same 56/56 was first seen at
`$HOME/Library/Developer/Tron/ios/test-runs/20260928T140631Z-run.PhjqNw`.
Negative control, run on this branch: with `isUnreachable` restored to the
classifier counter and the below-threshold `reset()` restored, the three new
tests and the rewritten `unreachableSecondaryProfileBacksOff` fail exactly as
the review's probes predicted (every retry pinned at the base interval, and no
wait ever reaching `POOL_MAX_RETRY`), while the other 52 tests pass: retained as
`$HOME/Library/Developer/Tron/ios/test-runs/20260928T140440Z-run.w03pO4`. The
file was restored byte-for-byte (`shasum -a 256 -c`) before the passing run.
`python3 scripts/check-documentation-policy.py` and
`scripts/personal-info-guard.sh` pass.

Deviations added this round: `GatewayReconnectSchedule.adopt(delayPolicy:)` in
`packages/ios-app/Core/Support/ReconnectDelayPolicy.swift` (a shared support
type, outside the pool zone; a policy swap has to keep the nominal delay the
standard phase reached, and a fresh schedule would restart at the base
interval), and the `owner` field on `GatewayConnectionAttempt` plus its
`owner=` detail in `packages/ios-app/Sources/State/GatewayConnectionEpisodeRecorder.swift`
and the `.selected` argument in `GatewayLifecycleCoordinator.swift` (only the
recorder can add the field the record needs). Superseded: the C-5 handoff's
"Kept on purpose" claim that the threshold reads the existing classifier counter
and that no second counter exists, and its Deviations claim that `reconcile`
resumes a parked retry.

**Review response (C-5 round 2, follow-up commit on this branch).** A second
independent review built the branch, ran the four focused suites (100 tests) and
probed the pool on a manual clock; it returned changes-required with one major
finding, three minor findings and two nits. Every one is addressed:

- Major (a network lost during an attempt left the entry parked for ever):
  an attempt that failed while the path was gone still waited out its backoff,
  and the check at the end of that wait returned without clearing
  `reconnectTask`/`reconnectWaiting`. The return hint then woke a wait that no
  longer existed, `scheduleReconnect` refused to start because a task still
  appeared to exist, and the entry stayed **Reconnecting** with no attempts and
  no `reconnect.stalled` until a scene cycle — worse in C-5 because each stuck
  window is now up to five minutes. The loop's `defer` is now the single owner of
  that handover: a loop that ends while its own `reconnectLoopID` is still the
  entry's marker clears `reconnectTask` and `reconnectWaiting` with its markers,
  so no exit path can leave a dead task behind, and `stallGuard` reads the
  waiting case through `reconnectLoopID` too, so a dead task can never read as
  progress. The review's probe became a regression test first:
  `lostNetworkParksPoolRetryUntilPathReturns` loses the path while attempt 2 is in
  flight (there is no wait to cancel at that moment, which is how the park
  happens), lets that attempt's wait run out with the path still gone, requires
  no third request and one `reconnect.stalled guard=pathUnsatisfied`, then
  requires a real path return to retry at once. Negative control: with the
  `defer` handover and the `reconnectLoopID` condition reverted to the reviewed
  state, that test fails exactly as the review's probe did (`stalls=0`, no
  attempt after the return, timeout) and
  `satisfiedPathNoticeDoesNotCutPoolBackoff` fails with `requests.count → 6`;
  56 of the 58 pool tests pass in the same run.
- Minor (any "network available" notice cut the five-minute wait short): a
  satisfied hint now ends a wait only when the entry's own last known path was
  unsatisfied — a real unsatisfied-to-satisfied change. The last
  `scheduleReconnect` (an entry no loop holds, i.e. stopped or parked) still
  restarts at once, which is what "retry at once on path change" and a foreground
  reconcile need. A repeated notice — every scene activation, every monitor
  update on an unchanged path — leaves the wait alone, so the cap is a floor and
  the volume estimate holds. `connection-resilience.md` says so. New
  `satisfiedPathNoticeDoesNotCutPoolBackoff` pins it, and
  `unreachableSecondaryProfileRetriesAtOnce` now parks the escalated wait with an
  unsatisfied hint and resumes it with the return hint instead of proving the leg
  with a notice that changed nothing.
- Minor (a profile switch was recorded as backgrounding): `retire(endedBy:)`
  takes the reason — `background` by default for the scene suspension, `.stopped`
  from `AppModel.lifecycleRetireProjection`, which runs on a profile switch,
  `forget`, pairing and teardown. `retiringPoolNamesItsEndedBy` is the old
  `retiringPoolEndsOpenEpisode` parameterized over both reasons, so both
  `endedBy=background` and `endedBy=stopped` are asserted; the old API could not
  express the second case at all. See Deviations for the zone this touches.
- Minor (the escalated outage's label): confirmed as the review allows — reusing
  the existing **No path to this Mac** state for never-opened outages is enough
  and no label was added for an escalated outage. The plan's "What must not
  change" names D-2 and D-5 as the only intended visible changes, `noPath` is
  already the presentation for an outage whose `transport-open` record never
  opened a transport, and an escalated outage that did open one (a drop, a hello
  timeout, a 503) keeps **Reconnecting**, which is what
  `connection-resilience.md` promises. Any change to that label is D-2/C-2's
  decision, not a new C-5 state.
- Nit (a test did not simulate production): `secondaryDropThenClosedPortKeepsBackingOff`
  now drops the admitted socket with
  `sockets[0].failPendingReceivers(URLError(.networkConnectionLost))` — the
  client's own receive failure, which creates the `transport.disconnected` event —
  instead of a server-sent frame. Its retry curve is unchanged.
- Nit (one main-thread hop per second per open pool outage): the
  `reconnect.stalled` row and the volume paragraph in
  `packages/gateway/docs/observability.md` now state that a pool entry's recorder
  asks the main actor for its stall guard once per second while its outage is
  open (its main-stall ping is the no-op) — about 86k hops a day for one
  unreachable profile, in CPU time and no bytes beyond the retry records.

Evidence for this round: `scripts/tron-ios-test build` succeeds and
`scripts/tron-ios-test run` passes 102 tests in four suites
(`DashboardStateOwnerTests` 58/58, `GatewayConnectionEpisodeRecorderTests`,
`GatewayReconnectScheduleTests`, `AppModelReconnectTests`), retained as
`$HOME/Library/Developer/Tron/ios/test-runs/20260928T155517Z-run.xS3QHC` and
re-run on the committed tree as
`$HOME/Library/Developer/Tron/ios/test-runs/20260928T155919Z-run.sM7lTA`; the
neighbourhood of the `lifecycleRetireProjection` call site this round changes
passes 31 tests in `AppModelLifecycleTests`, `AppModelPairingAttemptTests` and
`GatewayProfileStoreTests`
(`$HOME/Library/Developer/Tron/ios/test-runs/20260928T155734Z-run.DVqBbb`).
Negative control, run on this branch with the three behaviour fixes reverted to
the reviewed state: the two new regression tests fail and the other 56 pool tests
pass (5 issues in 2 tests), retained as
`$HOME/Library/Developer/Tron/ios/test-runs/20260928T154506Z-run.QS22mb`; the two
source files were restored byte-for-byte (`shasum -a 256 -c`) before the passing
run. `python3 scripts/check-documentation-policy.py` and
`scripts/personal-info-guard.sh` pass.

Deviations added this round: `packages/ios-app/Sources/State/AppModel.swift` is
the Phone lifecycle zone and C-5's zone is the pool; the fix for the mislabelled
episodes needs the reason at the pool's call site, so this branch also changes
one call in `lifecycleRetireProjection` to pass `.stopped`. No task held that
zone when this landed (O-4 Done; C-1, C-2, C-3, G-7 and E-3c Ready), so no
parallel writer was disturbed; if a Phone-lifecycle task lands first, the merge
keeps this line. Superseded: the C-5 handoff's "Kept on purpose" claim that
`retire()` is the pool's background boundary, and the round-1 note's claim that
`unreachableSecondaryProfileRetriesAtOnce`'s path-return leg goes through a
satisfied hint alone (that notice is now the finding-2 case that must not cut a
wait).

### Decisions · 2026-09-28 · user (relayed by the orchestrator)

- G-8b: approved. The Mac app status poll may stop re-hashing an unchanged,
  already-admitted Gateway payload on every poll, and may skip the `lsof` and
  `ps` display reads between polls. The fail-closed payload checks run when the
  selection stamp or the process fence (live launchd pid plus start identity)
  changes, and on explicit user actions.
- G-8c: approved. Session search keeps a persisted index keyed by
  `fileIdentity` (new durable state with one owner, rebuildable from canonical
  JSONL), so a start warms it without a full-corpus parse.
- Rows G-8b and G-8c move from Needs scoping to Ready.

### O-7 · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/o-7`)

- Blocked on: the Context causes reproduce only partly on the real incident
  export. The first pass marked this Done on a synthetic export; review round 1
  ran the tool on the ten real device exports in
  `~/.tron/logs/device-exports/`; review round 2 ran it on the incident's own
  export and found that the tool **misclassified** it. The incident export is
  `~/Library/CloudStorage/SynologyDrive-SynologyDrive/tron-diagnostics-3.jsonl`
  (22:50:04–05:49:39 UTC, 1,000 records, readable; of the two files there only
  `tron-diagnostics.jsonl` is still a `dataless` placeholder). None of the ten
  `device-exports` files covers the Context period: the latest starts 05:58:47.
  Round 3 corrected the last two misreports (the reconnect's own refresh read
  as a Gateway stall, and a silent gap taking the blip's attempt) and the
  relay-window over-reach; round 4 replaced round 3's 60-second recovery cycle
  with the reconnect handshake itself (the socket's own open against the
  published loss, the flicker bound between two stretches, and the connection
  id the app published), which the four causes read the same through; the four
  causes now read as the table below says, where cause 4 has no episode of its
  own on this export. The row stays Blocked because the tool still reports 121
  episodes for 77 Context reconnect episodes with `phone-stall=2`, and because
  the correlation key is untested against real O-1 data. Round 4's measured
  finding was that the round-3 cycle was time proximity, not the handshake: it
  read the two 20:23:09 flickers correctly only because an unrelated outage
  happened 57 s earlier, and it would have missed a genuine stall on a socket
  that had served for seconds (the incident export's 04:20:48 case is one).

- Result: `scripts/tron-triage` (front door) and `scripts/tron_triage.py` read
  one or more phone exports and the Gateway log with its rotations, join the two
  sides by the O-1 key (a time window when the logs predate protocol 6), and
  print one row per outage with its cause and the records behind it. `--json`
  prints the `tron.triage-report.v1` report and `--out PATH` writes it.
  `--tailscale-window` captures the Tailscale network-extension log with
  `log show` over the export's range as extra path evidence, and
  `--tailscale-peer NODEKEY` bounds that read to the phone's Magicsock peer.
  Inputs are opened
  read-only; the only write is the `--out` report.
- Evidence:
  - `python3 scripts/test-tron-triage.py` passes 51/51 (13 cause, join,
    Tailscale and input-contract cases plus 10 `ReviewRegressionTests`, 9
    `ReviewRoundTwoTests`, 2 `ReviewRoundThreeTests` and 6
    `ReviewRoundFourTests` cases) in about 8 s
    under both Homebrew Python 3.14 and `/usr/bin/python3` 3.9. Each review case
    has a negative control: reverting one mechanism fails exactly that case (see
    the rounds below), and round 4 pinned the five clauses of the recovery rule
    one test each. Each test runs the real front door against sanitized
    fixtures that reproduce one cause from Context, and the combined run keeps
    its report at `TRON_TRIAGE_TEST_REPORT`
    (default `$TMPDIR/tron-triage-report.json` plus a `.txt` of the table).
  - **"Done when", first pass (superseded): a synthetic export**. The handoff
    reported running the tool against the live Gateway log (read-only) plus a
    hand-written `synthetic-phone-export.jsonl`. That run proved the plumbing,
    not the rules: the episode times and the causes were typed into the fixture,
    so reproducing Context with it was circular. The ten real exports were on
    local disk the whole time (`~/.tron/logs/device-exports/`), and review round
    1 used them instead.
  - **"Done when", review round 2: the real incident export.**
    `scripts/tron-triage ~/Library/CloudStorage/SynologyDrive-SynologyDrive/tron-diagnostics-3.jsonl --gateway-logs ~/.tron/logs`
    (read-only, 1,000 phone records, ~10,950 Gateway records) reports 121
    episodes — `unknown=91, phone-background=23, path=5, phone-stall=2,
    gateway-stall=0, gateway-capacity=0` after review round 3 (round 2 read
    `unknown=90, phone-background=23, gateway-stall=3, path=3`). Adding
    `--tailscale-window --tailscale-peer NODEKEY` (the real `/usr/bin/log show`,
    181 path lines for that peer) moves 9 more episodes to `path`:
    `unknown=82, path=14, phone-background=23, phone-stall=2, gateway-stall=0`.
    The capture is bounded by what the unified log still holds, so the line and
    window counts drift between runs: the report now records the relay windows
    themselves, and the run of 2026-09-28T16:26Z is kept at
    `~/.tron/workspace/files/hardening/o-7-incident-export-tailscale.json`
    (plain run: `o-7-incident-export.json`) for regeneration without the log.
    The four Context causes against the tool's output:

    | Context cause | The tool on the incident export |
    | --- | --- |
    | 1 — path flaps, one relay window each (01:27, 01:35, 02:40, 03:24, 03:53, 04:56, 05:38 …) | With `--tailscale-window --tailscale-peer`: 14 `path` episodes, each naming the relay window that covers it (`02:39:52`, `03:24:21`, `03:52:15`, `04:55:27`, `05:00:56`, `05:37:18`, `05:45:21`, `05:48:59`) or the phone's own `transport-open` timeout that never reached the Mac. The Context-named episodes still inside the log's retention are `path`; the 01:27–01:36 windows have aged out of the unified log, which is why this round's path count is lower than round 2's 22. Without the flag 5 episodes are `path`, all from the phone's own `transport-open` timeouts at 05:43+ (round 4's re-run with the flag reads 12, the capture having aged 35 lines further) |
    | 2 — "Reconnecting" over a live socket 04:05:25–04:11:46 | Two `phone-stall` episodes cover the span: `04:05:25.843–04:10:44.428` and `04:10:48.871–04:11:44.466`, evidence `published state stayed reconnecting … while the Gateway answered session.list on de22b6dd-3d5e-4f5f-949f-fdf55d0f187b in 4513ms` (the socket is named since round 3; it opened 04:05:25.813). Inside the span the report also shows the 4.4 s stretch the app really spent backgrounded (`phone-background`) and the last 1.9 s before the 04:11:46 app restart |
    | 3 — silent gaps 03:24:45–03:30:30 and 04:56:31–04:58:46 | Both are episodes with those spans: `03:24:45.005–03:30:30.618` (345.6 s, attempts 0) and `04:56:31.269–04:58:46.887` (135.6 s, attempts 0), each with the "no attempt recorded (gap of 345s/135s)" line. Their cause is `unknown` with and without the Tailscale capture: the relay windows that overlap them closed 248 s and 111 s before they ended, so they are listed as context and not as the cause |
    | 4 — the Gateway is slow under load | **No `gateway-stall` episode on this export after round 3.** Round 2's 3 were all the reconnect's own refresh: each was a sub-20 ms label flicker whose "slow span" was the `session.list` the reconnect had just issued on the socket it opened 36–117 ms *before* the loss, with the phone's retained `connectionID` (38, 62, 81) unchanged across the flicker — no connection was lost. Rule 4 now reads the reconnect's own socket from the handshake itself (`recovery_connection`: opened inside the episode, opened within `RECOVERY_HANDSHAKE_SECONDS` of the loss, opened after the previous stretch began when that stretch ended within `FLICKER_BOUND_SECONDS`, or named by the phone's unchanged connection id on both sides of the flicker), and all 9 RPC-based `gateway-stall` episodes across the eleven real exports became `unknown`; the only `gateway-stall` left anywhere is the genuine 18 s `gateway.event-loop-delay` at 09-26 04:33:45 in one device export. Round 4 checked the 12 episodes where a slow span straddled the loss across the eleven exports: 7 rest on a socket that opened 36–117 ms before the loss (the handshake), and 5 on a socket that had already closed before the loss (abandoned work). None of them now depends on an unrelated outage starting within a minute. The Gateway's measured slowness still appears as the 1443 ms `gateway.event-loop-delay` at 04:07:00.678 inside the 04:05 `phone-stall` episode, the 52.4 s `connectionClosed` `session.open` at 04:11:55, and the phone's own 15 s transport-open timeouts after 05:43 |

    The tool is not yet Done on this export: 121 episodes against Context's 77
    reconnect episodes (the phone publishes more state flicks than Context
    counted), `phone-stall=2` where C-2 expects one cause per wrong label,
    `gateway-stall=0` where Context's cause 4 has no episode of its own any
    more (round 2's three were the reconnect's own refresh, and the export's
    only other candidate at 04:20:48 is a slow span on a socket that had
    already closed), and `gateway-capacity=0` because the only capacity event in Context
    (22:20:37) predates the export's first record (22:50:02) — that one is not a
    failure to reproduce.
  - **"Done when", review round 1: the ten device exports** (kept, they still
    run — the numbers below are round 3's). Over the ten exports (197 episodes,
    joined `window=197` because these builds predate O-1 and carry no
    `gatewayConnectionId`): `unknown=173, phone-background=11, path=7,
    phone-stall=5, gateway-stall=1, gateway-capacity=0`. The single
    `gateway-stall` is the genuine event-loop delay of 09-26 04:33:45; round 2
    read 7, of which 6 were the reconnect's own refresh (round 3, finding 1),
    and read `unknown=166, path=8`. Round 1 read the same ten as `183 episodes:
    unknown=107, gateway-stall=59, phone-background=9, path=8, phone-stall=0`;
    each round's attribution fixes moved the difference. The 09-28 export is
    still 24 episodes (`unknown=20, phone-background=3, phone-stall=1`) and
    still overlaps the incident day's 05:58 abnormal close, so it is not the
    "Done when" run.
  - **Round 4 re-ran both real runs after the handshake rule replaced the
    cycle.** The incident export reads exactly as round 3 recorded it above
    (`121 episodes`, `unknown=91, phone-background=23, path=5, phone-stall=2,
    gateway-stall=0`), and the ten device exports still total 197 episodes with
    `unknown=173, phone-background=11, path=7, phone-stall=5, gateway-stall=1`
    — the one `gateway-stall` is still the genuine 18 s event-loop delay of
    09-26 04:33:45. With `--tailscale-window` the same export now reads
    `121 episodes, path=12, unknown=84, phone-background=23, phone-stall=2,
    gateway-stall=0`: the capture holds 146 path lines against round 3's 181,
    because the unified log has aged further, which is the drift the retained
    round-3 report exists to stop. That report is deliberately not overwritten.
  - `scripts/tron-triage …2026-09-28T07-37-42-420Z.jsonl --gateway-logs
    ~/.tron/logs --tailscale-window --tailscale-peer NODEKEY` ran the real
    `/usr/bin/log show` (`captured: true`, 12 path lines for that peer) without
    touching the input. The first pass's "`captured: true`, 0 path lines" was
    the bug: the compact timestamp had no UTC offset and every line was
    dropped (finding 4). The real node key is not committed: the tool's help,
    its comments, the fixtures and this handoff use the placeholder
    `fakeNodeKey` (review round 2, finding 7).
  - `python3 scripts/check-documentation-policy.py` (46 authored files) and
    `scripts/personal-info-guard.sh` pass.
- Changes: eleven commits on `hardening/o-7`: `feat(triage): add the incident
  triage tool (O-7)`, `docs(triage): name the triage command first, close label
  windows at scene and episode boundaries (O-7)`,
  `feat(triage): pair the inbound-silence evidence with its resume record (O-7)`,
  `docs(triage): give the capture and evidence bounds their reasons (O-7)`,
  `fix(triage): attribute a cause only to the episode's own connection (O-7)`,
  `fix(triage): split an outage at the scene boundary and keep the loss's own
  evidence (O-7)`, plus round 3's three (recovery cycle, attempt ownership,
  relay-window coverage) and round 4's
  `fix(triage): read the recovery socket from the handshake, not a 60 s window
  (O-7)`.
- **Review round 1 (changes-required → addressed).** The review's blockers and
  majors, and what each one changed:
  1. *Blocker — rule 4 took any slow span in the padded window as the cause.*
     Rule 4 now requires a slow span's own issue-to-completion interval
     (`completion - durationMs … completion`) to overlap `[start, end]`, an
     event-loop delay to fall inside the episode rather than the +30 s pad, and
     an episode to use one join: when the key joins any record, a record naming
     another connection is not this episode's evidence (Gateway-wide records
     still count). On the 09-28 export this moved 12/12 `gateway-stall` to
     4, with the rest `unknown`/`phone-background`.
  2. *Blocker — the row was Done although "Done when" was not met, and the
     handoff claimed the incident exports were unavailable.* They are on local
     disk (`~/.tron/logs/device-exports/`, ten files). The synthetic-export run
     is marked superseded, the real-export result is recorded above, and the
     row is Blocked.
  3. *Major — older exports' records were not recognised.* `scene_phase` now
     reads `app.backgrounded`/`app.foregrounded`, `scene.*` and the retained
     client's `gateway.lifecycle kind=scene.*`, so both the background window
     closer and `phone-background` fire (3 episodes on the 09-28 export).
     `label_over_live_socket` gained a time-window fallback for exports with no
     `gatewayConnectionId`, and the dead `reconnect.connected` branch became
     `gateway_id_of` recognising the retained client's `kind=reconnect.connected`.
     `is_covered` also stopped merging two label windows that merely sit within
     the 5 s pad, which had been swallowing the background-parked episode.
  4. *Major — `--tailscale-window` produced no evidence.* The compact timestamp
     is parsed as local time, the real Magicsock forms are matched (`via=derp`
     relay, `now using <addr>` direct), `--tailscale-peer NODEKEY` filters to
     the phone's peer, and the tests use a fixture `log` executable with real
     sanitized lines instead of a `runner` hook in production code.
  5. *Major — the path rule ignored an attempt's profile.* `attempt_belongs`
     keeps an episode's declared profile (or client), so the settings pool's
     transport-open timeout no longer makes a main-profile episode `path`.
  6. *Major — the wrong-label rule over-reached.* `socket_answered` requires the
     request to have been issued at/after the label and completed inside the
     episode, and the label must be this episode's own transition, so a request
     issued before the loss is not proof the socket was live.
  7. *Minor — attempt counting.* `phone_attempts` prefers the O-4
     `gateway.attempt` record, dedupes the transport store's rows by
     `(clientID, sequence)` (the loop's `attemptId` is shared by every retry),
     and `attempt_reached_mac` requires the arrival before the attempt's own end
     rather than anywhere in the pad.
  8. *Minor — the phone-only export fixture invented a `connectionId`.* The test
     uses the real `AppLogRecord` shape (null `connectionID`) and asserts
     `joinedBy=window`.
  9. *Minor — test-only `runner` parameters.* Removed; the Tailscale tests drive
     a fixture executable through `TAILSCALE_LOG_TOOL`.
  10. *Nits.* The doc's `.1` rotation is now `.1`–`.7`;
     `unjoinedConnectionRecords` is renamed `connectionRecordsOutsideEpisodes`
     (the count is records outside every episode); `offline(_:)` no longer
     splits a label window.
- **Review round 2 (changes-required → addressed).** This round ran the tool on
  the incident's own export for the first time, which changed the rules:
  1. *Blocker — a background blip closed the window, so the Context causes came
     out `phone-background` and the silent gaps vanished.* `label_windows`
     became `outage_segments`: a scene transition splits a published outage
     instead of ending it, the window reopens on the foreground while the state
     is still an outage, a stretch that contains no time is dropped, and
     `background_parked` reads the stretch's own phase, so only the time really
     spent in the background is `phone-background`. A stretch knows its
     `outage_boundary`, so a stretch after a blip still judges its label against
     the socket that was live when the outage was published. On the incident
     export this produced the 04:05:25–04:11:46 `phone-stall` pair and both
     measured silent gaps.
  2. *Blocker — `gateway-stall` was still the reconnect's own refresh.* Rule 4
     now needs the work to have been running when the loss happened
     (`completion - durationMs < loss <= completion`) on a connection that is
     not the recovery's: a socket the Gateway opened inside the episode, or one
     already closed before it, is the reconnect's. `annotate_episode` also stops
     taking the recovery socket as the episode's key. 26 `gateway-stall`
     episodes became 3, each a sub-20 ms label flicker with a span that
     straddled its own loss. (Round 3 found those 3 were still the reconnect's
     own refresh, on a socket opened just before the flicker rather than inside
     it; see that round below.)
  3. *Major — the export's attempt records were ignored.* `operation.gatewayConnect`
     (the pre-O-4 app-level attempt) is read as an attempt: end timestamp plus
     `durationMs`, counted in `attempts` and printed as context. It names no
     profile or stage, so it is never the path clause's evidence and never
     opens a derived outage — on the incident export 122 consecutive failures
     while the main connection was up would otherwise become one giant episode.
     Episodes that really have no attempt now say so; the 02:40 episode reports 2.
  4. *Major — this handoff's blocker reason and next steps were wrong.* Fixed in
     the entry above: the incident export path, the `gateway-capacity=0`
     explanation (the only capacity event predates the export), the softened
     round-1 claim, and the hand-back to a worker instead of R-4.
  5. *Minor — `--tolerance-seconds` did nothing above 30 s.* The evidence read
     and the time-window join now share one margin, `max(pad, tolerance)`, and
     the report prints it as `evidenceMarginSeconds`.
  6. *Minor — a `gateway.resources` warning in the pad counted as the cause.*
     It now has to fall inside the episode, like an event-loop delay (rule 5's
     capacity records too).
  7. *Minor — the user's real Tailscale node key was committed.* The help text,
     the regex comments, the fixtures and this handoff use `fakeNodeKey`.
  8. *Minor — CI never ran the triage tests.* The orchestrator approved adding
     `scripts/test-tron-triage.py` to `.github/workflows/ci.yml`: the python
     syntax list and a `python3 scripts/test-tron-triage.py` step. The suite is
     self-contained (temp-dir fixtures, no network, no local export) and takes
     about 4 s. **Deviation:** `.github/workflows/ci.yml` is outside O-7's
     owning files; it was added on explicit instruction.
  9. *Nits.* The plan's stale "O-7 incident triage tool Done" header line is
     gone; the doc line about an `unknown` foreground silent gap now holds,
     because those gaps are reported as `unknown` episodes.

  Negative controls (revert one mechanism, the named test fails): a scene transition
  ending the window instead of splitting it fails
  `test_a_background_blip_does_not_hide_the_silent_gap_after_it` and
  `test_a_blip_does_not_stop_the_live_socket_from_being_the_cause`; a
  `background_parked` that ignores the stretch phase fails the same two; the
  round-1 rule-4 span test fails
  `test_the_socket_the_reconnect_opened_is_not_the_cause` and
  `test_a_slow_span_that_began_after_the_loss_is_not_the_cause`; the recovery
  key fails `test_the_episodes_key_is_the_connection_it_lost`; ignoring
  `operation.gatewayConnect` fails
  `test_an_app_connect_operation_counts_as_the_episodes_attempt`; a fixed
  30 s pad fails `test_the_tolerance_widens_how_far_evidence_reaches`; and an
  unbounded resource warning fails
  `test_a_resource_warning_in_the_pad_is_not_the_cause`. Review round 3's six
  controls (each verified by reverting exactly that mechanism and re-running the
  named case): start-time attempt ownership fails
  `test_a_background_blip_does_not_hide_the_silent_gap_after_it`; the
  relay-window coverage bound fails
  `test_a_relay_window_that_closed_before_the_episode_ended_is_context`; the old
  invented attempt fields fail
  `test_an_app_connect_operation_counts_as_the_episodes_attempt`; an evidence
  line without the answering socket fails
  `test_a_blip_does_not_stop_the_live_socket_from_being_the_cause`; and dropping
  `relayWindows` from the report fails
  `test_relay_window_classifies_a_path_episode`. Round 4 replaced the
  recovery-cycle floor, so its control is gone with it; round 4's own controls
  (each verified the same way) pin the five clauses of the new recovery rule and
  the attempt dedupe: dropping the opened-inside clause fails
  `test_a_socket_the_declared_episode_opened_before_its_loss_is_the_recoverys`;
  dropping the handshake bound fails
  `test_the_first_flickers_recovery_socket_is_not_the_second_flickers_cause`
  (rewritten without the unrelated outage the old rule depended on); dropping
  the flicker bound fails
  `test_a_socket_the_previous_stretch_opened_is_the_recoverys`; dropping the
  unchanged-retained-id clause fails
  `test_a_flicker_on_the_apps_own_unchanged_connection_is_not_a_stall`; dropping
  the closed-before clause fails
  `test_a_slow_span_on_a_socket_closed_before_the_loss_is_abandoned_work`; and
  counting the operation row beside a matching stage row fails
  `test_a_stage_row_and_its_connect_operation_are_one_attempt`. Against the
  round-3 module the rewritten round-3 case and three of the round-4 cases fail
  (both 20:23:09 flickers `gateway-stall`, the stall-after-recovery `unknown`,
  and the one connect counted as 3 attempts).
- **Review round 3 (changes-required → addressed).** Round 3 re-ran the tool on
  the incident export and on all ten device exports. Findings and what each one
  changed:
  1. *Blocker — `gateway-stall` was still the reconnect's own refresh.* Rule 4
     excluded only a socket opened *inside* the episode, so it missed the socket
     the previous stretch's reconnect had opened milliseconds earlier: all 3
     incident episodes and 9/9 RPC-based `gateway-stall` episodes across the
     eleven real exports rested on the `session.list` the reconnect had just
     issued on a socket opened 36–117 ms before the loss, with the phone's
     retained `connectionID` unchanged across the flicker (38, 62, 81). A
     socket the Gateway opened since the reconnect cycle began is now the
     recovery's (`Episode.recovery_floor`, `RECOVERY_CYCLE_SECONDS`;
     `recovery_connection` — round 4 replaced this rule with the handshake
     itself, see that round below). Every one of the 9 became `unknown`; the only
     `gateway-stall` left is the genuine 18 s event-loop delay of 09-26
     04:33:45. The handoff's cause-4 row and its "0/3 rest on the recovering
     socket" claim are corrected above.
  2. *Major — the 03:24:45 silent gap reported `attempts=1`.* The export's
     `operation.gatewayConnect` at 03:24:45.020 (`durationMs=6237`) began 6.2 s
     earlier, in the blip, and ended 15 ms after the app returned to the
     foreground; the fallback counted attempts by end time with 5 s of slack and
     so hid the gap statement. Attempts are now assigned by the stretch they
     began in (`Attempt.start()`, `attempt_owner`), with the end-time fallback
     for an attempt whose start falls in no stretch (the first episode's own
     failing connect, and seven connects that began in connected time just
     before a published loss). Both measured gaps report `attempts=0` with
     their gap line, and the blip owns the 03:24:45.020 record. The real record
     is back in the blip fixture.
  3. *Major — `--tailscale-window` turned silent gaps into `path`.* Any overlap
     with a relay window made the whole episode `path`, so the 03:24:45 gap
     (window closed 03:26:22, gap ended 03:30:30), the 04:56:31 gap (window
     closed 04:56:55) and the 01:36 hour-long gap were all reported as path
     faults although the path was back and no attempt was recorded.
     `relay_window_explains` now requires the loss to fall inside the window and
     the episode to end inside it or within the app's own recovery delay
     (`RELAY_WINDOW_SLACK_SECONDS`) of its close; a window that only overlaps is
     reported as context with the reason it does not cover the episode. Both
     gaps are `unknown` with their window as context, and the Context cause-1
     episodes are still `path`.
  4. *Minor — the cause-1 evidence could not be regenerated.* The report now
     writes the relay windows (`inputs.tailscaleWindow.relayWindows`), and the
     run of 2026-09-28T16:26Z is kept at
     `~/.tron/workspace/files/hardening/o-7-incident-export-tailscale.json`
     (`o-7-incident-export.json` for the plain run). The handoff no longer
     claims "the same Context windows": the unified log has since dropped the
     01:27–01:36 windows, and this round's path count (14) is lower than round
     2's 22 for that reason.
  5. *Minor — the `phone-stall` evidence named socket `unknown`.*
     `label_over_live_socket` now returns the connection and the request that
     answered, and the evidence reads `answered session.list on
     de22b6dd-3d5e-4f5f-949f-fdf55d0f187b in 4513ms`.
  6. *Nit — the `operation.gatewayConnect` context line invented fields.* It
     printed `stageReached=unknown reason=none foreground=None` for a record
     that carries none of them (`Attempt.context_detail` now prints only the
     fields the record has).
  7. *Nit — the plan header's stacked "Last updated" line.* No new line is
     added; this round amends the existing O-7 line, and the merge with
     `hardening/integration` still collapses it with the rest.
- **Review round 4 (changes-required → addressed).** Round 4 re-ran the tool on
  the incident export and on the ten device exports, and found that round 3's
  fix was coincidence plus a new false negative:
  1. *Blocker — the recovery socket was keyed to any episode within 60 s.* The
     round-3 rule started a "recovery cycle" at any other episode that began
     within a minute and ignored every socket opened since. It read the two
     20:23:09 flickers correctly only because an unrelated outage happened 57 s
     earlier (moving that outage to 61 s before turned both back into
     `gateway-stall`), and it would have missed a genuine stall on a socket
     that had served for seconds (a socket opening 1.9 s after an earlier outage
     and serving 38 s before a real loss came out `unknown`). The rule is now
     the handshake that produced the socket rather than time proximity:
     `recovery_connection` reads a socket as the recovery's when the Gateway
     opened it inside the episode, when it opened within
     `RECOVERY_HANDSHAKE_SECONDS` (0.5 s; the measured cases are 36–117 ms) of
     the published loss, when it opened after the previous stretch began and
     that stretch ended within `FLICKER_BOUND_SECONDS` (1 s; the measured gaps
     are 4–9 ms), or when the phone's own connection id on both sides of the
     flicker is unchanged (`retained_connection_unchanged`).
     `Episode.recovery_floor`, `link_flicker_stretches`' 60 s cycle and
     `RECOVERY_CYCLE_SECONDS` are gone; both real exports read exactly as they
     did in round 3 (the incident export `gateway-stall=0`, the ten device
     exports `gateway-stall=1`, the genuine event-loop delay). The `:1059`
     fixture is rewritten without the 20:22:12 outage it used to depend on.
  2. *Minor — one attempt was counted twice.* `all_attempts` added the
     `operation.gatewayConnect` rows to the stage rows without deduplicating,
     so an export that writes both shapes for one connect counted it twice (13
     pairs on the incident export; episode 115 read `attempts=2` for one
     connect, 119 read 16 for 9). An operation row whose end is within
     `ATTEMPT_DUPLICATE_END_SECONDS` (50 ms) of a stage row with a matching
     duration is now that attempt's other name, and an operation row with no
     such neighbour still counts.
  3. *Minor — the end-time fallback was described wrongly.* The docstring and
     the round-3 entry said it applies "only [to] an attempt that began before
     every episode"; it applies to any attempt whose start falls in no stretch
     (8 on the incident export, 7 of them outside the first episode). Both now
     say that.
  4. *Nit — the doc overstated the join-key exclusion.* `annotate_episode`
     drops a join key only for a socket opened inside the episode; the
     `connection-resilience.md` sentence that lumped the cycle-opened socket in
     with it is rewritten with the rule above.
- Failure modes written before the code (one test each): a relay-path outage
  attributed to the phone because the Gateway's silent-socket record was not
  joined; a transport-open timeout read as a Gateway stall, and a live main
  connection or the retry that followed read as that attempt's arrival;
  "reconnecting" over a live socket reported as `unknown` or as a real loss;
  a silent gap with no attempt dropped or attributed to the path; a
  background-parked episode attributed to the path; a slow span and a capacity
  refusal reported as `unknown`; a protocol-5 export reported as unjoined
  instead of joined by window; a phone-only artifact reporting zero Gateway
  records; a run that writes to an input; an unreadable line crashing the run.
  Two more came out of building the incident run: an outage that ended in the
  background swallowing every later outage into one window (fixed: a scene
  entering the background and a `connection.episode` record both close a
  label window), and a neighbouring episode swallowed by the 60 s join
  tolerance (fixed: episode coverage uses a 5 s pad, the join tolerance only
  joins). Review round 1 added one written failure mode per finding — a slow
  span that ended after the episode, another connection's slow span in a
  key-joined episode, the app's real scene records, the settings pool's
  second-profile attempt, a request issued before the loss, and one attempt
  recorded by both phone shapes — as `ReviewRegressionTests`. Review round 2
  added one per finding, built from the incident export's own record
  sequences, as `ReviewRoundTwoTests` (each with its negative control; see
  that round below). Review round 3 added the two flicker shapes — the socket
  the previous stretch's reconnect opened, and the second flicker sharing the
  first flicker's recovery socket — as `ReviewRoundThreeTests`, put the real
  03:24:45.020 record back into the blip case, and added the relay-window
  cases to `TailscaleWindowTests`; the attempt-context and phone-stall evidence
  assertions joined the cases they belong to. Review round 4 rewrote that
  flicker case without the unrelated outage and added `ReviewRoundFourTests`:
  a genuine stall on a socket that served 38 s after an earlier recovery, a
  flicker whose own published connection id never changed, two stretches of one
  burst 4 ms apart, a declared episode whose loss was published on the socket
  its own recovery opened, and one connect the stage row and the
  `operation.gatewayConnect` row both recorded.
- Tasks added: none.
- Kept on purpose:
  - The report's cause is the plan's rule order, not a vote: `path` first, so a
    transport-open timeout wins over a background or Gateway cause unless the
    episode is parked in the background. A backgrounded phone parks recovery,
    and its own timeouts are `reason=background`; the path clause is skipped
    there, which is the only place the rules as written would have called a
    designed suspension a path fault.
  - `unknown` is a real outcome and is reported with the gap statement, not
    silently reclassified: a zero-attempt foreground gap with no overlapping
    slow span stays `unknown` with the gap line in its evidence. The first
    pass's live-log run classified the two measured silent gaps `gateway-stall`
    only because a slow `session.list` completed inside the +30 s pad; the span
    overlap bound in review round 1 removed that, which is the point of the
    bound. After round 2 the two measured gaps are `unknown` (or `path` when
    the Tailscale capture covers the loss) episodes with the gap line, which is
    what the doc says an operator should read there.
  - A published outage is one episode per scene phase, and a phase that
    contains no time is dropped: on the incident export that turns 80 windows
    into 121 episodes, because the phone publishes a burst of 5-300 ms label
    flicks around every real loss. The `unknown` count is dominated by them.
  - The 60 s join tolerance is the documented fallback for protocol-5 logs and
    is a flag; key joins always win and the report says which join each episode
    used.
  - A phone-only artifact is still triaged: when no log directory exists the
    export's own embedded Gateway rows are used and the report says
    `source: "export-projection"`.
- Deviations:
  - The rule order in the task text was read to mean `path` first, with the
    transport-open clause limited to a foreground (not background-parked)
    episode; see "Kept on purpose" for why, and the test that pins it.
  - The transport-open clause needs the Gateway record's peer key to decide
    whether an accept was this attempt's: a Gateway record whose key contradicts
    the attempt, or that has no key at all while the attempt has one, is not
    this attempt's arrival. Against an O-1 Gateway log this is exact; against a
    protocol-5 Gateway log it deliberately treats "no evidence this attempt
    arrived" as the path's fault, which is what the phone's own transport-open
    failure says.
  - `--tailscale-window` reads the extension log as text and is a heuristic
    (a relay line opens a window, a direct line closes it) that is reported as
    evidence, not as proof; the authoritative path signal is O-2's `peerPath`.
    `--tailscale-peer` bounds it to one Magicsock node key, because the
    extension serves every tailnet peer.
  - `attempt_belongs` filters by the episode's declared profile (or client). A
    label-window episode the phone publishes through `connection.state-changed`
    declares neither, so its attempts are not filtered; on the real exports the
    transport store's rows carry no profile either, so the filter is a no-op
    there and exact for O-4 exports.
  - The task named `new tron-triage in scripts/` as an owning file: the command's
    only other entry point, `scripts/tron`, was left unchanged, so the command is
    `scripts/tron-triage` (like `scripts/tron-profile`).
- For the next agent (a worker on O-7, then the orchestrator):
  1. **The incident export is
     `~/Library/CloudStorage/SynologyDrive-SynologyDrive/tron-diagnostics-3.jsonl`**
     (22:50:04–05:49:39 UTC, 1,000 records, md5 unchanged since the incident).
     It is the only export that covers the Context period: the ten files in
     `~/.tron/logs/device-exports/` start after it (the latest at 05:58:47).
     Run both with and without `--tailscale-window --tailscale-peer NODEKEY`
     (the node key is the user's; pass it on the command line, do not commit
     it; the unfiltered run read the same 181 lines here because the extension
     log held one peer). Round 3 got the four Context causes out of it as the
     table above says — cause 4 has no episode of its own any more, because its
     three flickers were the reconnect's own refresh — and round 4 kept that
     outcome with the handshake-based rule, so it no longer depends on an
     unrelated episode starting within a minute. The row stays Blocked: 121
     episodes against Context's 77 reconnect episodes,
     `phone-stall=2` against one cause per wrong label, and
     `gateway-capacity=0` because the only capacity event in Context
     (22:20:37) predates the export. A second reviewer should judge whether the
     episode split (one per scene phase) is the right reporting unit or whether
     a burst of sub-second label flicks should merge into one outage.
  2. Round 1's rule-order question is settled for now: a zero-attempt
     foreground gap with a Gateway slow span that merely overlaps it is
     `unknown`; `gateway-stall` needs the span to have been running when the
     loss happened, on a connection that is not the recovery's. C-1 and O-4's
     `reconnect.stalled` should turn these gaps into `phone-stall` before the
     release; decide it there rather than widening the pad. A flicker the app
     re-publishes on the connection it already has (the retained
     `connectionID` unchanged) is reported `unknown` for the same reason: the
     tool records the loss the export published, and nothing was lost.
  3. The correlation key is still untested against real O-1 data: every export
     on this machine predates it (`gatewayConnectionId` absent). R-4 measures
     the "at least 95% of episodes attributed to one cause" exit criterion on
     the evaluation day's export, which is the first O-1 export.

### Orchestrator · 2026-09-28 · O-7 accepted

- Result: O-7 merged and set Done after five review rounds. On the real
  7-hour export it attributes the path outages to `path` (with
  `--tailscale-window`), the 04:05–04:11 label over a live socket to
  `phone-stall`, and both silent gaps as zero-attempt episodes; a
  `gateway-stall` episode requires Gateway work in flight at the loss on a
  socket other than the recovery's. Context cause 4 (slow Gateway) shows up in
  the old export as slow spans, not as a disconnect episode of its own, so no
  `gateway-stall` episode is the correct reading, not a defect. Episode count
  (121 vs 77) is the tool splitting outages at background blips by design.
  R-4 confirms on the evaluation day's O-1-keyed exports.
### G-8b · Claimed · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-8b`)

- Result: the Mac app status poll no longer pays the fail-closed Stable
  admission or the Tailscale CLI per 30 s cycle. The poll stream reuses one
  admission while a runtime fence is unchanged — launchd's live pid plus that
  process's start identity, plus the payload selection stamps
  (`PayloadSelectionStamp`, promoted out of the native capture peer's private
  `CaptureSelectionStamp` into `GatewayPayloadStore.swift`, which both the app
  and the native host target already compile). A changed pid, a changed start
  identity, a changed `payloads/stable/current.json`, or a changed active
  manifest re-runs the full probe. Only an admission is reusable: a refusal is
  re-proved on the next cycle, and a fence that cannot stamp an existing
  selection pointer or manifest re-probes, so one transient listener/`ps`
  failure or an update restart landing between the ping and the fence read
  cannot pin `needsRepair` for the process's lifetime. A reuse also requires the
  same authenticated ping identity and republishes the fence's own elapsed time,
  so the menu's uptime keeps moving instead of freezing at the first probe's
  value. The per-cycle authenticated ping stays: it is the liveness probe that
  decides Running. Explicit user actions still run the full probe:
  `singleSnapshot(setup:)` is
  unchanged for menu presentation, the restart wait and startup, and pairing
  keeps its own ping/admission pair. The poll's ping closure
  (`statusPollPingServer`) reuses one live Tailscale resolution for a bounded
  window (300 s, `TailscaleHostResolution`) and refreshes the owner-only
  `network.json` cache only when the resolved address changed; a failed ping
  re-resolves after 30 s and never sooner. `pingServer` itself stays the live
  `resolveHost` path, so pairing, restart, update, log/feedback capture, the
  health wait, install and startup resolve live.
- Failure modes recorded before the tests were written:
  - poll admission reuse: (1) reuse outlives a new pid or a new start identity;
    (2) reuse outlives a selection or manifest change; (3) an unreadable fence
    authorizes reuse; (4) reuse skips the per-cycle ping; (5) reuse outlives the
    authenticated ping identity it was proved against; (6) a transient refusal
    is reused; (7) a reuse freezes the displayed uptime.
  - Tailscale window: (8) the window reuses past its interval; (9) a failed ping
    never re-resolves, or re-resolves every cycle; (10) an address the disposable
    cache cannot answer is reused without a probe; (11) a newly resolved address
    is not persisted, so the menu would present a different host than the poll
    pings.
  - explicit recording and poll wiring (review round 2): (12) a failure an
    explicit check finds is overwritten by the next cycle's reused admission;
    (13) the poll stream uses the live ping or a fresh probe per cycle.
- Review round 1 (2026-09-28) addressed: the fence read now carries `ps
  -o etime=,lstart=` in one spawn and the poll republishes that elapsed time
  instead of the cached admission's (the menu's uptime no longer freezes and
  jumps back); a refusal is never reused and the fence returns `nil` when an
  existing selection pointer or active manifest cannot be stamped; a reuse also
  requires the same authenticated ping identity; the windowed Tailscale ping
  moved from `pingServer` onto the poll's own `statusPollPingServer`, which is
  what the row requires — before it, menu-open and pairing inherited the window;
  `RuntimeFence.read` is now exercised against a real temporary payload store.
- Review round 2 (2026-09-28) addressed: one `StableProbeCache` now belongs to
  the `ServerStatusPoller` instance and is shared by its 30 s stream and its
  explicit probes; `explicitSnapshot()` always runs the full probe and records
  the outcome (admission stored, refusal cleared), and `menuWillOpen` and
  `MenuBarActionHandler.refreshStatus` go through it, so a failure an explicit
  check finds is no longer overwritten by the next cycle's reused admission.
  Negative control: with the record step removed, the new poll-cycle test saw the
  cycle after the explicit refusal report Running from the cache (captured before
  the fix). The poll stream's own wiring is now driven by a test (one cache per
  poller, the bounded ping only, one full probe across two cycles), and
  `RuntimeFence` stamps the bundled manifest unconditionally alongside the active
  one, so replacing the app bundle moves the fence even when the selection names
  a version whose payload does not validate and `GatewayPayloadResolver` admits
  the bundled payload.
- Evidence:
  - Suites: `TronMacTests/ServerStatusPollerBoundedAdmissionTests` (10 tests,
    was `SingleInstance`-free and deterministic),
    `TronMacTests/StableGatewayObserverTests` (10 tests) and
    `TronMacTests/TailscaleHostResolutionTests` (5 tests) pass with the three
    neighbouring suites on the Debug test host. Review round 2 re-ran
    `build-for-testing` then `test-without-building -only-testing:`
    `ServerStatusPollerBoundedAdmissionTests`, `StableGatewayObserverTests`,
    `ServerStatusPollerTests`, `TailscaleHostResolutionTests` and
    `MenuBarControllerTests` on the tree with `hardening/integration` already
    merged → `Test run with 34 tests in 5 suites passed`,
    `TEST EXECUTE SUCCEEDED`. Negative controls were executed, not inferred:
    with the record step removed the new poll-cycle test saw the cycle after the
    explicit refusal report `.running` from the cache, and with the bundled
    stamp frozen the fence test saw the fence stay equal while the bundled
    manifest was replaced. Review round 1 re-ran:
    `xcodebuild build-for-testing … -derivedDataPath build/DerivedData` (3m13s,
    TEST BUILD SUCCEEDED; the first attempt failed on an unwrapped optional and
    the re-run succeeded) then `test-without-building -only-testing:` the six
    suites → `Test run with 45 tests in 6 suites passed after 185.851 seconds`,
    0 failures. The suites map one-to-one onto failure modes 1–11.
  - Children per 30 s cycle: **5 → 2**, from the code's spawn sites — the
    app-level confirmation (a running app's `ps` CPU delta per cycle and the
    unified-log Tailscale attach cadence) is still owed, see below. Measured on
    this host against the live
    `com.tron.server` job (read-only) with a harness around the production
    readers: the new fence read (`launchctl print` + one `ps -o etime=,lstart=`)
    takes
    11.6 ms median over 10 reads, while the launchd read, two `ps` display reads
    and `lsof` the old cycle also ran take 95.9 ms. Child CPU for ten fence
    reads plus both primitive reads was 0.08 s (≈7 ms per cycle). The Tailscale
    CLI goes from one spawn per cycle (≈2,880/day at 30 s; ≈2,490/day at the
    audit's measured 34.7 s cadence) to one per 300 s window (≈288/day). A
    changed fence costs one extra full probe (6 children) on that cycle only.
  - Per-cycle CPU removed: one `validateSelection` on the user's real selected
    payload (588 MB) measured 12.09 s wall / 11.47 s CPU in the same harness;
    the G-8 audit attributed ≈4.0 s of per-poll CPU to both trees with `sample`
    on a quieter host. What remains per cycle is two spawns, one ping socket,
    one launchd read and one small cache read.
  - Window behaviour executed, not inferred: a harness compiling the production
    `TailscaleHostResolution` with production wiring prints probe counts
    1 / 1 / 2 / 2 / 3 across t0, t0+10s, t0+301s, a failed ping at t0+311s and a
    failed ping at t0+341s, two probes over two cycles when the cache cannot
    answer, and `resolveLive` preferring live over cache while rejecting
    loopback.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
  - Commands and raw numbers retained at
    `~/.tron/workspace/files/hardening/g-8b-status-poll-bound.md`.
- Changes: `packages/mac-app/Sources/Server/Health/ServerStatusPoller.swift`
  (`StableProbe`, `StableProbeCache`, the bounded cycle, the runtime fence
  closure, and `statusPollPingServer` as the cycle's own ping), new
  `TailscaleHostResolution.swift`, `RuntimeFence` in
  `StableGatewayObserver.swift` (non-optional stamps; `read` returns `nil` when
  an existing selection pointer or manifest cannot be stamped),
  `LaunchAgentProcessFence`/`readProcessFence` in
  `LaunchAgentRuntimeReader.swift`, `ProcessFenceRead` in `ServerProcessProbe.swift`
  (start identity and elapsed time in one `ps` read),
  `PayloadSelectionStamp` in
  `GatewayPayloadStore.swift` (replacing the peer's private copy in
  `NativeCapturePeer.swift`), `EnvironmentSetup.swift` (windowed poll ping,
  shared `resolveLive`), `packages/mac-app/docs/architecture.md`, the two new
  test files, `ServerStatusPollerTests.swift` (override seams for the new
  suites), `StableGatewayObserverTests.swift` (the fence read against a real
  temporary payload store, and the one-spawn `ps` fence read), and this plan.
- Kept on purpose: the per-cycle authenticated ping (the liveness probe that
  decides Running); `singleSnapshot(setup:)` as the unconditional full probe for
  user actions, so no unowned file changes; the owner-only `network.json` cache
  as the only place the address lives, with the window holding only the last
  probe time; `resolveHost`'s live probe for restart, update and command status.
- Deviations: the stamp lives in `GatewayPayloadStore.swift` rather than a new
  file because that file is already in both targets, so the shared type needs no
  `project.yml` change. The 300 s reuse window and the 30 s failed-ping interval
  are the named constants chosen here; the user approved the reuse and the plan
  asked for the windows to be named. Building the Debug test host needed a
  locally staged payload (`bundle-gateway.sh --allow-unconfigured-push
  --skip-install`); no `npm ci` ran and the shared node_modules install was not
  touched.
- For the next agent: the app-level confirmation is still owed and is what
  keeps this row out of Done — a running debug app's `ps` CPU delta per 30 s
  cycle and the unified log's Tailscale client-attach cadence, before and after.
  It needs the app to run, which this session must not do; run it once these
  fixes are on integration, then set the row Done. `packages/mac-app/build/DerivedData` and the staged
  payload are in place, so `scripts/tron mac generate` plus
  `xcodebuild build-for-testing` and `test-without-building` reproduce the
  focused run cheaply. G-8d remains the other half of the ambient discovery
  cost.

### G-1b · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-1b`)

- Result: the catalog owner now watches its folder and reconciles as its
  backstop. `SessionCatalog.start()` starts a recursive `fs.watch` (FSEvents on
  macOS) on the canonical sessions root plus a `CATALOG_RECONCILE_INTERVAL_MS`
  (30-minute) pass; a path event is a hint, debounced
  `CATALOG_EVENT_DEBOUNCE_MS` (250 ms), that re-reads one file's durable tail and
  publishes one row through the same lane every Gateway-owned change uses. A
  watcher that was observing and stopped is replaced and the folder's own cut is
  re-read; a root that cannot be watched yet is retried
  (`CATALOG_WATCH_RETRY_MS`, 5 s) while the index keeps serving the rows it has.
  The row's Done-when is met in memory (the integration case below); the O-6a
  confirmation of it is owed by the orchestrator, which has the probe and the
  request-path walk counts.
- Evidence, mechanism (real watcher, real catalog, real Gateway wiring):
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts -t
    "publishes an external append"` **1 passed, 616 ms**: against a live
    `RuntimeRegistry` (the code path the fixture Gateway runs), a child
    transcript created and then appended to by a writer the Gateway does not own
    reaches its catalog row (`delegated`, then `messageCount` 1 and the file's
    exact size) in ≤ 1 s, and the O-5 sampler's `recordCatalogWalk` recorded no
    catalog structure walk in that window.
  - `npx vitest run src/sessions/session-catalog.test.ts` **19 passed / 19 in
    6.5 s**, twice; `session-catalog.test.ts` + `catalog-metadata-index.test.ts`
    + `catalog-discovery.test.ts` **40 passed / 40 in 6.7 s**. The case "advances
    a row for an external append within a second without walking the catalog"
    runs the production watcher with the interval backstop disabled
    (`reconcileIntervalMs: 0`), so only the watcher can publish the append.
  - `src/sessions/runtime-registry.integration.test.ts` full file **248 tests: 1
    failed** — the known load flake "keeps a large streamed write visible
    through snapshot recovery and canonical handoff" (5081 ms against its 5 s
    `waitUntil`; passes alone in 4.65 s, and alone on the pre-G-1b code in
    4.67 s, so its ~0.3 s margin is the cause, not this change). `-t "catalog"`
    35/35, `-t "index"` 8/8. `npx tsc --noEmit -p .` clean;
    `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Blocked on the O-6a half of "Done when" ("in O-6a, child-file appends reach
  the index within 1 s without any request-path walk"). Three bounded
  `scripts/tron-profile gateway --scenario multi-session --iterations 1
  --catalog-files 200 --catalog-mib 32 --no-build` runs were made (2 × 30 s and
  1 × 120 s mixed windows; last run
  `20260928T144239Z-multi-session-fcce82`, `finished in 3.3 min`, no
  "uncommitted tracked changes" warning). Review round 1 established that those
  runs were made on the wrong tree and that their method cannot measure the bound
  at all, so they are kept here only as history: the run's own `report.json`
  source block names the `hardening/integration` worktree path, branch
  `hardening/integration`, revision `b18919961`, whose
  `src/sessions/session-catalog.ts` and 07:13 `dist` contain no
  `watchCatalogFolder` (`grep -c` = 0 in both). The measured fixture Gateway
  therefore had no watcher, and a frozen durable document was that tree's
  expected behaviour. The "one `catalog.reconciled` per two starts" reading was
  wrong for the same reason: the priming Gateway stopped 3.5 s after it started,
  before its reconcile finished, and the single `200 added` in 8274 ms belongs to
  the second, measured start. The sampler read only the durable document, which
  is written at most every `CATALOG_PERSIST_MAX_WAIT_MS` (60 s), so no run of
  that shape can show a 1 s bound. The "unexplained persist-cadence signal" and
  the proposed T-2 row that rested on it are withdrawn, and the corrected
  procedure is recorded in the round-1 entry below; no T-2 row was added.
- Changes: `packages/gateway/src/sessions/session-catalog.ts` (the watcher, the
  cadences, `catalog.changed` / `catalog.watcher-reset` reports);
  `packages/gateway/src/sessions/catalog-discovery.ts` (exports
  `isIgnoredCatalogDirectory` so the watcher and the walk apply one path rule);
  `packages/gateway/src/sessions/runtime-registry.ts` (two option
  pass-throughs in the `SessionCatalog` construction and the startup comment
  only — the minimal call site G-3's parallel work can rebase over);
  `packages/gateway/src/gateway-main.ts` (the two records);
  `packages/gateway/docs/observability.md` (`catalog.reconciled`'s "when" and
  rows for the two new events);
  `packages/gateway/src/sessions/session-catalog.test.ts`;
  `packages/gateway/src/sessions/runtime-registry.integration.test.ts` (one
  case).
- Failure modes written before the watcher (numbered 9-16 in the test file): an
  event the platform never delivered (the next interval pass publishes the row);
  a file replaced with a new inode at the same path (identity and counts come
  from the replacement, not the old tail); a child transcript before its parent
  (one delegated row, and the parent does not double it); the root moved or
  unavailable (one outage record, last-good rows served, watched once it exists);
  a burst of events (one debounced read per path, no walk, no read left armed);
  a watcher that stopped (one `catalog.watcher-reset`, a replacement watcher, a
  whole-folder reconcile); an event the platform could not name (the index is
  re-derived once); an event for a path discovery ignores or a file that is not a
  transcript (no row, no read). Review round 1 added modes 17-22, listed with its
  findings in the entry below.
- Kept on purpose: the read phase's batch bound is the index's existing one
  (`CatalogMetadataIndex.reconcile` reads `RECONCILE_CONCURRENCY` = 16 candidates
  per awaited batch, ≤ the plan's 50, covered by G-1a's "reads reconciled files
  in one bounded batch at a time"), so this row adds the cadence that drives it
  rather than a second batching layer over the same reads; G-9 moves the pass
  into the scheduler. `catalog.reconciled` keeps its existing shape and owner.
- Deviations: the watcher backend is an injectable option (`watchCatalog`,
  defaulting to the recursive `fs.watch`) because several failure modes cannot be
  forced on a real FSEvents stream (a dropped event, a start failure, a watcher
  that stops, a burst of events, an unnamed event); every case the real backend
  can produce uses the production watcher. An overflow is not a separate reset
  reason: `fs.watch` does not surface FSEvents' must-scan flag, so a dropped
  event is the interval's job (`catalog.reconciled`'s counts are the signal) and
  an unnamed event re-reads the whole folder once. The reconciler was not
  changed, so the durable document keeps its one writer.
- For the next agent: G-1c switches `list`, `pageSource`, acquisition, attention,
  automation targets and storage maintenance onto `SessionCatalog.rows()`; the
  watcher already keeps those rows current for external writers, so the request
  path's walks can be deleted without a new feed. G-9 owns moving the interval
  pass and the watcher restart into the scheduler. Note for the orchestrator's
  own runs: `--no-build` requires `npm run build` in `packages/gateway` first.

### G-1b · Blocked (review round 1) · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: an independent reviewer found the O-6a evidence had been gathered on
  the integration tree, which contains no watcher, plus four real gaps that only
  the production FSEvents backend shows. Every finding was addressed; none was
  rejected. The wrong diagnosis and the row proposed from it are withdrawn, the
  watcher now covers folder events and deletions, and its restarts are spaced
  instead of immediate. The row stays **Blocked**: the two O-6a runs now made on
  this build are recorded below, and the in-memory half of the measurement is
  still owed because the observer it needs is not usable in this scenario.
- Finding 1 (blocker, reproduced): the O-6a run
  `20260928T144239Z-multi-session-fcce82` ran against
  the `hardening/integration` worktree at `b18919961`, where
  `src/sessions/session-catalog.ts` and its 07:13 `dist` have no
  `watchCatalogFolder` (0 matches in both), so no watcher existed and the frozen
  durable document proved nothing; the priming Gateway stopped 3.5 s after it
  started, before its reconcile finished. The "unexplained persist-cadence
  signal" narrative and the proposed T-2 row are deleted from the entry above,
  which now records the real cause and the method's own limit (a durable document
  capped at `CATALOG_PERSIST_MAX_WAIT_MS` = 60 s cannot show a 1 s bound). The
  corrected procedure is in the Blocked note above; the re-run itself is owed,
  and the attempts made here are recorded below.
- Finding 2 (major): a non-transcript event path was dropped, so a folder moved
  into the root and a folder renamed inside it were invisible for up to 30
  minutes, and the root's own move produced no record and no reconcile at all.
  `watchEvent` now resolves such a path against the folder: a directory has its
  own `.jsonl` files re-read (debounced per path, with one whole-folder pass when
  a folder holds more than `CATALOG_EVENT_DIRECTORY_LIMIT` = 64 transcripts,
  which also bounds the per-path map), an absent path debounces one whole-folder
  cut, an existing non-transcript file stays a no-row event, and the root's own
  name with the root gone is the watcher's outage rather than a cut — no cut of a
  missing folder is membership evidence. The folder's own name *with the folder
  there* is ignored instead: macOS reports it once when the watch attaches, and
  treating it as a reason to re-read the whole folder cost one spurious
  full-folder pass per attach (the first version of this fix did exactly that,
  and the real-backend case below caught it). A real-trace probe confirmed that macOS
  reports the root's own rename as `change "sessions"`, that a folder moved in
  reports only `rename <folder>`, and that inner events stop until the root is
  back. New real-backend cases: "publishes a folder moved into the root and the
  folder an in-root move renamed" and "keeps its rows while the root itself is
  away, and a later cut republishes them" (modes 17 and 18); the second asserts
  that a pass over the folder that is not there publishes nothing and that the
  rows survive an append the watcher could not see.
- Finding 2b (major, found by the tests this round added): absence evidence had
  to be gated on the folder still being there. A root that is moved away takes
  every path inside it with it, so (a) the finding 3 rule would have dropped the
  rows one event at a time for a folder that is merely elsewhere, and (b) the
  periodic pass (and the startup pass) would have published a "complete" cut of
  zero candidates and emptied the durable document. `SessionCatalog` now has one
  `catalogRootIsDirectory()` check used by all three: `refreshPath` refuses
  absence evidence without it, `reconcileIndex` reports `incomplete` and
  publishes nothing, and the watcher's root event is an outage. Cases: "keeps its
  rows while the root itself is away, and a later cut republishes them" (real
  backend; mode 18) and "records one outage for the root's own event when the
  folder is gone" (mode 22, the injectable backend, because the platform cannot
  be made to deliver that event on demand).
- Finding 3 (major): rows came only from commit-point hooks, so the watcher
  published files the Gateway had not committed and nothing removed them when the
  Gateway rolled them back (`rm(importedPath)` after a failed import,
  `removeUncommittedForkArtifacts`). `refreshPath` now treats `lstat` ENOENT on
  the exact path as removal: the row is dropped and the document rewritten. Other
  errors still keep the row, so this deliberately extends G-1a's rule: an absent
  exact path *is* membership evidence, while an unreadable path is not. Case:
  "drops the row for a canonical file deleted outside the Gateway" (mode 19),
  which also asserts the durable document lost the row, and "keeps a row for a
  path it can see but cannot read" for the other half of the rule.
- Finding 4 (minor): the `catalog-index.failure` false alarm falls out of
  finding 3 — an absent path is not read at all, so `append` and `summaryFor` are
  never called for a file that is gone. Mode 19 asserts both spies were not
  called.
- Finding 5 (minor): the per-path debounce had no ceiling, so a path written
  more often than the quiet spell was re-armed forever. It is capped by
  `CATALOG_EVENT_MAX_WAIT_MS` (1 s) the way persistence is, so a continuously
  appended transcript is re-read about once a second. Case: "re-reads a path whose
  events never stop arriving" (mode 20).
- Finding 6 (minor): `ensureWatching` re-checks `this.watcher` after the
  `catalogRoot()` await (two concurrent callers could each attach a watcher and
  double every event); `onReset` is bound to its own handle, so a reset from an
  already-replaced watcher cannot stop its successor; a stop schedules the
  replacement on the retry cadence instead of attaching in place; and
  `watchOutageReported` is cleared only once a replacement has survived one retry
  interval, so a watcher that dies at every attach produces one record and a
  bounded restart rate. Case: "spaces the restart of a watcher that dies right
  after every attach" (mode 21); the error case now asserts the replacement is not
  immediate.
- Finding 7 (minor): the reset message and the observability row claimed every
  reset is followed by a whole-folder reconcile, which was false for
  `unavailable`. The owner now reconciles once when a replacement attaches after
  a reported outage, on top of the one reconcile the first stop of an outage
  makes over a readable folder, so the gap the outage opened is read even when
  the attach is what restored the folder. The message and the doc row say that.
- Finding 8 (minor): `catalog.changed` fired on every single-row publish,
  including every Gateway-owned persist, into the shared 4,000-record / 2 MB debug
  buffer. It is now the watcher's change stream only — a Gateway-owned change is
  attributable to the commit that made it — with `outcome` extended by `removed`
  for the finding 3 deletion, and the doc row states the scope and the bound (up
  to about four records per path a second, one per quiet spell, with the ceiling
  only bounding how long a read waits when events never stop). That also
  makes it the in-memory signal the O-6a re-run needs. The `catalog.changed` case
  now asserts a Gateway-owned `refresh()` reports nothing and that a watcher
  deletion reports `removed`.
- Finding 9 (minor): the burst case emitted one event per path, so coalescing was
  never exercised. "coalesces a burst of events into one read per path" now sends
  40 events for each of 25 paths (1,000 events) and asserts exactly one
  `summaryFor` per path, no `scan`, and no duplicate IDs (mode 13).
- Finding 10 (nit): the assertions on a private timer map are gone — the burst
  case counts reads through the source instead — and the integration case reads
  the catalog owner through a documented `catalogOwner()` helper beside
  `settleCatalog()`. No public reader exists before G-1c, and the index's rows
  *are* the observable effect that case asserts.
- Finding 11 (nit): the plan header carried six `Last updated` lines; it is one
  line again.
- Changes in this round: `packages/gateway/src/sessions/session-catalog.ts` (the
  folder-event path, the deletion rule, the per-path ceiling, the watcher
  lifecycle and the watcher-only change stream);
  `packages/gateway/src/sessions/session-catalog.test.ts` (modes 17-21, the
  rewritten burst and ignore cases, the `catalog.changed` case);
  `packages/gateway/src/sessions/runtime-registry.integration.test.ts` (the
  `catalogOwner()` helper); `packages/gateway/src/gateway-main.ts` and
  `packages/gateway/docs/observability.md` (message and rows).
- Checks: `npx vitest run src/sessions/session-catalog.test.ts` **26 passed / 26
  in 9.4 s and again in 11.1 s** (was 19); `npx vitest run
  src/sessions/runtime-registry.integration.test.ts -t "catalog"` **36 passed**;
  `-t "publishes an external append"` **1 passed**;
  `src/sessions/catalog-metadata-index.test.ts` +
  `src/sessions/catalog-discovery.test.ts` **21 passed**; `npx tsc --noEmit -p .`
  clean. The real-backend cases run the production watcher; the injectable
  backend is used only for events FSEvents cannot be made to produce (modes 9,
  13-16, 21, 22).
- Residual risk for the orchestrator: none known for the watcher itself. The
  pre-existing hazard a missing root used to create for the startup and periodic
  passes (a "complete" cut of zero candidates emptying the durable document) is
  closed by finding 2b's guard, which is why an outage now needs no special case
  to stay safe. `catalog.reconciled` reports such a pass as `incomplete`, so an
  operator sees it.
- O-6a on this build (new evidence, three attempts): the build here is
  `33b25f3ab` in this worktree (`npm run build`, `dist` carries the watcher), and
  the runs' own `report.json` source blocks say so (`"worktree"` = this
  worktree, `"dirty": false`), with the fixture's `driver-config` naming this
  worktree's `packages/gateway` — the attribution problem finding 1 found is
  gone.
  - `20260928T152251Z-multi-session-0efe51` and
    `20260928T152602Z-multi-session-5c6047` (`--catalog-files 200 --catalog-mib
    32 --mixed-seconds 60`, `finished in 2.2 min` and `1.8 min`, exit 0): the
    watcher build runs the scenario at scale. The second run's fixture log holds
    exactly one `catalog.reconciled` (200 added, 1648 ms, at startup), no
    `catalog.watcher-reset` and no `catalog-index.failure`, so no outage and no
    failed index read occurred across ~90 s of continuous external appends. Its
    probe counted `no_subscriber.catalog.walks` 15 and `catalog.walks` 49 for the
    mixed window: those are the pre-G-1c request path's own walks (the criterion
    G-1c's Done-when measures), not walks the appends caused — the append-caused
    count is 0, which the integration case asserts directly.
  - Two further attempts (`20260928T152836Z-multi-session-9e118c` and
    `20260928T153500Z-multi-session-3afd47`) tried to read the in-memory
    `catalog.changed` stream with an observer that pairs like the phone and polls
    `system.logs.export`. Neither produced a sample: both runs failed at the
    scenario driver, and their `fixture/gateway.jsonl` error mix is catalog churn
    in name only:

    | `rpc.error` | `9e118c` | `3afd47` |
    |---|---|---|
    | `session.sync` conflict, "Session synchronization is no longer owned by this token" | 244 | 242 |
    | `session.presentation.set` conflict | 11 | 10 |
    | `session.open` conflict | 2 | 2 |
    | `session.open` busy / `catalog_changed` | 1 | 0 |

    Both drivers died on that `session.sync` conflict
    (`driver-iteration-1.log`), for one client ID that matches every record. The
    two runs without the observer, on the same build
    (`0efe51`, `5c6047`), logged **0** `rpc.error`. So the extra paired mobile
    client is what took session synchronization ownership away from the driver;
    `catalog_changed` churn is 1 record out of 258 and 0 out of 254, and is not
    what failed either run. The observer's own connection was also the one that
    sent nothing (16.5 s in `9e118c`, 27.7 s in `3afd47`) and was closed at
    outbound-queue capacity in both: a sixth mobile-role connection that never
    pings and exports ~1 MB of diagnostics every 15 s.
  - What the owed re-run needs instead: the in-memory signal has to come from the
    fixture process itself. `scripts/tron-profile-gateway-probe.mjs` is already
    preloaded there and already counts catalog walks in-process; the natural
    instrument is one more counter it can read without any extra connection
    (a row-publish tally or the newest `catalog.changed` timestamps), recorded
    with the appender's write times. Until that exists the row stays on the
    orchestrator's owed confirmation, and the durable-document sampler from the
    earlier entry stays retired: it cannot show a 1 s bound.
- Not addressed, deliberately: `watchRetryMs` remains a plain `setTimeout`; G-9
  owns moving the watcher restart into the scheduler, and the retry is now the
  only restart path, so a failing watcher restarts at most once per interval.

### G-1b · Done (review round 2) · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Result: the one major was a real production cost and is fixed, with a
  production-FSEvents failing-first case and its negative control; both minors
  and the two documentation/evidence corrections are in. The row is **Done** on
  the orchestrator's decision — the O-6a confirmation of the Done-when is owed by
  the orchestrator, which owns the probe file.
- Finding 1 (major): an absent non-transcript path no longer reconciles the whole
  folder. `resolveAbsentEvent` re-reads only the indexed rows at or under the
  path (`indexedBeneath`) through the same per-path debounce and does nothing
  when no row matches, so an atomic write's temporary name, a scratch file and
  the Gateway's own quarantine rename cost no walk; `transcriptsBeneath` walks by
  hand instead of `readdir({recursive: true})`, skipping the ignored folders and
  stopping at `CATALOG_EVENT_DIRECTORY_LIMIT`; `debounceUnnamedEvent` is capped
  by `CATALOG_EVENT_MAX_WAIT_MS` like the per-path debounce.
  - Failing-first, production FSEvents backend: "costs no whole-folder pass for a
    non-transcript name that is gone" (tmp rename, scratch create/delete,
    quarantine rename and removal) and "drops the rows under a folder removed
    with its transcripts, without a whole-folder pass" (`rm -rf` of a run
    folder). Negative control: with `8a52a73b2`'s `session-catalog.ts` and these
    tests, the first sees **2** `scan` calls and the second **1**, both green
    with the fix. Modes 22-23 added to the test file's list.
  - "re-derives the whole index once a second for unnameable events that never
    stop" (mode 23) is the ceiling's failing-first case: with the old
    `debounceUnnamedEvent` the 5 s `waitFor` times out (the quiet spell is
    re-armed every 100 ms), and it passes with the ceiling.
- Finding 2 (minor): the `catalog.changed` bound is corrected in all three
  places — the doc row, the cadence comment and the round-1 entry above — to the
  real one: up to about four records per path a second, one per quiet spell,
  with `CATALOG_EVENT_MAX_WAIT_MS` bounding only how long a read waits when
  events never stop. No throttle was added: the true rate is now stated rather
  than capped by a second mechanism over the same reads.
- Finding 3 (minor): the round-1 entry's failed-run evidence was replaced with
  the measured mix (244/242 `session.sync` conflicts, 11/10 presentation, 2/2
  open, 1/0 busy `catalog_changed`), the driver logs that died on the `sync`
  conflict, the two no-observer runs' **0** `rpc.error`, and the observer
  connection's own silent/capacity closes. The stale "complete and merge-ready"
  line in the base entry is replaced.
- Finding 4 (Done-status blocker, no code change): `npm run build` and `npx tsc
  --noEmit -p .` are clean at HEAD; the in-memory append-to-row bound stays
  covered by the integration case and the interval-disabled watcher case. The
  O-6a probe (`scripts/tron-profile-gateway-probe.mjs`) is outside this row's
  owning files, so the orchestrator owes that confirmation.
- Finding 5 (nit): the dead "Bounded batches" loop and its descriptor comment in
  the burst case are deleted; the 25 writes are one `Promise.all`.
- Durable-document persist cadence (evaluated, **no G-1e row**): a watcher row
  reaches the durable document at most every `CATALOG_PERSIST_DEBOUNCE_MS` (5 s)
  and at latest `CATALOG_PERSIST_MAX_WAIT_MS` (60 s) after it changes, but the
  canonical JSONL stays authoritative and every startup reconciles against the
  folder's own cut (`reconcileIndex` re-derives each candidate; `persistNow`
  skips an unchanged generation), so a stale document is repaired, not lost. That
  makes the cadence a property of the acceleration document, not a defect — the
  only reader that suffered from it was the retired durable-document sampler.
- Checks: `npx vitest run src/sessions/session-catalog.test.ts` **28 passed /
  28 in 10.9 s** (was 26); `session-catalog.test.ts` +
  `catalog-metadata-index.test.ts` + `catalog-discovery.test.ts` **50 passed /
  50**; `npx vitest run src/sessions/runtime-registry.integration.test.ts -t
  "catalog"` **36 passed**; `npx tsc --noEmit -p .` clean; `npm run build`
  clean in 38 s. Negative controls run as above and then reverted.
- For the orchestrator: `npm run build` has now been run in this worktree, so its
  `dist` carries the watcher's current source for an O-6a run. Merging `hardening/integration` into this branch
  conflicts only in this plan file (integration has newer rows/entries);
  integration's `session-catalog.ts` is unchanged from the merge base, so the
  source merge is clean.

### Orchestrator · 2026-09-28 · E-2 and E-2c closed

- Result: the iOS profiler can no longer take 10 GB: the parser is bounded
  (E-2), host `--attach` cannot sample simulator processes (E-2b), and a
  host-wide time-profiler trace whose export would exceed 2 GiB is refused
  before export with its size and the remedy (E-2c). A traced product scenario
  must use a short `--window-seconds` to fit; that is the accepted cost. E-2
  and E-2c set to Done.

### E-1 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/e-1`)

- Result: `packages/gateway/docs/connection-resilience.md` gains a "Tailscale
  flaps" section: the Gateway records a flap leaves (`connection.inbound-silent`
  at `peerPath=relay`/`offline` with `peerRelay`, paired with
  `connection.inbound-resumed` and its `silentMs` when the socket survives the
  flap and unpaired when it does not, joined by the O-1 key), the
  triage tool's reading (`scripts/tron-triage` reports the `path` cause from the
  Gateway's silent record, from an attempt's `transport-open` timeout that never
  reached the Mac, or — with `--tailscale-window --tailscale-peer NODEKEY` for
  logs predating those records — from the covering relay window, while a window
  that closed before the outage ended stays `[context]`), the incident's worked
  example, and the user-side checks (iPhone Tailscale app and settings, Wi-Fi
  private address, router client steering). Docs only: no code, record or test
  changed, so no observability row is owed.
- Evidence: `python3 scripts/test-tron-triage.py` passes 51/51 in 4.8 s
  (`TRON_TRIAGE_TEST_REPORT`); the run and its table are retained at
  `~/.tron/workspace/files/hardening/e-1/e1-triage-report.json{,.txt}`; the cases
  behind the documented shapes are `test_relay_silence_joined_by_key_is_the_path`
  (Gateway `peerPath=relay` evidence, `silentMs=68000`),
  `test_relay_window_classifies_a_path_episode` (`relay path window` cause
  evidence) and `test_a_relay_window_that_closed_before_the_episode_ended_is_context`
  (the "does not cover this episode" context wording). The worked example's
  numbers are Context's measurements and O-7's real incident-export run (14
  `path` episodes with the capture against 5 without; both silent gaps `unknown`
  with their windows named as context). `scripts/tron-triage` also run read-only
  against `~/.tron/logs/device-exports/…2026-09-28T07-37-42-420Z.jsonl` (kept,
  device id elided, at
  `~/.tron/workspace/files/hardening/e-1/device-export-tailscale-run.txt`): 24
  episodes, `path=0`, and with `--tailscale-window` the header reads `captured,
  12 path line(s)` with no window covering an episode — the context behavior the
  section describes. `python3 scripts/check-documentation-policy.py` (46 authored
  files) and `scripts/personal-info-guard.sh` pass.
- Changes: `docs(gateway): document Tailscale flap diagnosis (E-1)`;
  `docs(gateway): correct Tailscale flap timing (E-1 review round 1)`.
- Tasks added: none.
- Kept on purpose: the existing `connection.inbound-silent` row in the
  diagnostics table keeps its shape and gains the pointer to the new section
  (round 1 changed only its closing "repeated …" clause); the records
  themselves, their observability row and the triage tool are O-2's and O-7's
  and were not re-documented.
- Deviations: none.
- For the next agent: R-4 counts the evaluation day's flaps with
  `scripts/tron-triage … --tailscale-window --tailscale-peer NODEKEY` (the
  section says what to read); E-3 is what removes the effect at home.
- Review round 1 (changes required; all findings addressed in the follow-up
  commit): the flap section now states the phone drops the socket within about
  18 s of the path going quiet and the Gateway only after three missed 25 s
  heartbeats, names the disconnecting shape (unpaired
  `connection.inbound-silent`, then the phone's close as `connection.closed` or
  the Gateway's `connection.heartbeat-timeout` at ~75–100 s, with the phone's
  liveness `ping_timeout`), gives the silent record's 12–37 s detection window,
  says "repeated silences at `peerPath=relay`/`offline`" in the diagnostics row,
  and replaces the stale-app→`relay` claim with the disabled-extension symptom
  (`transport-open` timeouts, no Gateway `http.upgrade`). Minor: deleted the
  paired-record claim from `observability.md`'s budget paragraph (a silence that
  ends in the socket's close leaves only its silent record) and dropped the
  "keeps its wording" line above. Checks re-run: `test-tron-triage.py` 51/51
  (14.2 s), `check-documentation-policy.py` (46 files), `personal-info-guard.sh`
  — pass. The disconnecting shape is read from the code and the contract
  constants (phone liveness retirement, the 25 s heartbeat tick and the close
  path), not reproduced: O-2's blackhole test uses a client that never gives up.
### T-2 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/t-2`)

- Result: no hosted-test watchdog kills a synchronously blocked main thread. A
  probe test that blocked it 5 s, then 10 s, then 20 s in one test passed after
  35 s, and the only watchdog in this tree is the repo's own `withTestWatchdog`
  (`packages/ios-app/Tests/Support/TestWatchdog.swift`), which this test does not
  use and whose expiry is the "Test exceeded its 5.0 seconds watchdog" text seen
  in other suites. The kill came from another worktree's run launching the same
  host app on the same simulator: `20260928T160853Z-run.0UFrCv` (worktree
  `tron-hardening`, default lane) recorded `owner.json` at 1790611733 and ran its
  tests 1790611737.6–1790611779.1, and `20260928T160908Z-run.Y9hYTh` (worktree
  `tron-hardening-g-7`, default lane, same simulator) started its tests at
  1790611753.8 inside that window. The killed attempt is the stall test's, which
  starts ~10.8 s into its suites and so lands within a second of the second app's
  launch. The test's block is the named constant `mainStallTestBlock` (5 s) in
  both phases.
- Evidence: combined set (5 suites, 161 tests) green 5× before the change
  (`20260928T170751Z-run.KpSLNJ`, `20260928T171235Z-run.d1TwFp`,
  `20260928T171323Z-run.yMiBKP`, `20260928T171429Z-run.T3Ig4q`,
  `20260928T171524Z-run.dKkmIF`; stall test 8.02 s) and green twice on the final
  block (`20260928T182458Z-run.tPLyAI`, `20260928T182539Z-run.DhgWVH`: 5/5 in the
  suite, stall test 10.52 s; the intermediate 4 s form also ran 4× green —
  `20260928T173926Z-run.QJjdCa`, `20260928T174026Z-run.TuYhxq`,
  `20260928T174123Z-run.KvlTxr`, `20260928T174222Z-run.Ri2Zsd`). Probe:
  `20260928T171741Z-run.FF4ms5`. The killed run is
  `~/Library/Developer/Tron/ios/test-runs/20260928T160853Z-run.0UFrCv`
  (`summary.json`: "Test crashed with signal kill.", 160 passed of 161;
  `test.log`: the run restarts at 09:09:37.574). Two more pairs have the same
  shape: g-7's `20260928T160029Z-run.9dbW2W` (tests 1790611233.8–1790611262.0,
  "Test crashed with signal kill before establishing connection") with c-4's
  `20260928T160033Z-run.13mFm5` (1790611236.9–1790611241.9), and g-7's
  `20260928T164851Z-run.Yqb7gv` (1790614134.9–1790614194.9, includes "Test
  crashed with signal kill.") with g-4's `20260928T164907Z-run.EmmlGW`
  (1790614150.0–1790614154.6). All six runs name lane `default` and simulator
  `E816D194…`, and the locker refuses a second holder of one lock path (checked
  by hand: exit 73), so at least one run in each pair never took the lane's
  lease. Those three pairs are the only overlaps in all 87 recorded runs of
  2026-09-28, and in each pair the later run survived while the one already
  running failed. T-2's own post-change runs do not overlap any other run's
  window.
- Changes: the commit on this branch touches only
  `packages/ios-app/Tests/Support/GatewayConnectionEpisodeRecorderTests.swift`
  besides this plan.
- Tasks added: T-3 (after T-2: default-lane runs across worktrees shared one
  simulator despite the lease).
- Kept on purpose: the production ping and production clocks (the test exists to
  prove the off-main-actor watchdog measures a real block), and the assertion
  that the record's `durationMs` is at least `blockedMs - 2 × watchdogInterval`.
- Deviations: the second phase's block grows 2.5 s → 5 s while the first keeps
  its 5 s, so the test blocks 10 s instead of 7.5 s. A 2.5 s block gives a
  would-be surviving watchdog only a ~50% chance of a tick inside the window it
  needs, so that negative control could pass vacuously; at the same constant it
  always lands one. The first phase keeps the third interval on purpose: two
  intervals are the derivation (`mainStallBound` + the tick grid + the loop's
  first wake-up) and the third is the margin the literal 5 s always had, because
  that wake-up delay is not interval-bounded under CPU starvation.
- For the next agent: the lease that should have serialized these runs is T-3's.
  Until it is fixed, a lone "Test crashed with signal kill" (or "…before
  establishing connection") is contention first: compare the run's
  `owner.json`/`summary.json` window with every other run's on the same
  simulator before blaming the code under test.

### T-3 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/t-3`)

- Result: the lease was bypassed by argument loss, not by the inherited
  `TRON_IOS_TEST_LOCK_HELD`. `scripts/tron-ios-test` consumed `--lane NAME` when
  selecting the lane and then re-executed itself through the lease holder as
  `$0 $command ${selectors}`, without the lane. The child re-derives every lane
  path from its own arguments, so it leased `<lane root>/ios-test-NAME/lease.lock`
  and then provisioned, ran and released the **default** lane's simulator: a
  named-lane run never serialized with the runs on the simulator it used. The
  five `~/.tron/internal/ios-test-G7*` lanes left behind by one worktree hold a
  `lease.lock` and no `simulator.json` at all, which is that signature; the
  `G7R2` lease's release second (16:09:25 UTC) is 1 s after the overlapping run
  `20260928T160908Z-run.Y9hYTh` finished its tests (16:09:23.8), and that run's
  `owner.json` says `lane: default` although it was started with `--lane G7R2`.
- Changes: `scripts/tron-ios-test` passes `--lane "$LANE_LABEL"` into the command
  the holder starts, and refuses (74) a command whose inherited lease
  (`TRON_IOS_TEST_LEASE_LOCK`, exported by `scripts/ios-test-lock.py` beside the
  existing lease descriptor) is not this lane's own lock, so a descendant that
  inherits `TRON_IOS_TEST_LOCK_HELD=1` can no longer run on another lane's
  simulator. `packages/ios-app/docs/development.md` says both.
- Follow-up after review round 1 (same branch, second commit): the guard compared
  the two lock paths as strings, and the locker tidies `--lock` through
  `pathlib`, so a state directory spelled with a trailing slash, `//` or `./`
  (the common macOS `$TMPDIR` shape) was refused 74 for every leased command. It
  now compares the files with `-ef`. The regression case
  `RunnerFixture.test_a_state_directory_spelled_differently_is_still_this_lanes_lease`
  covers all three spellings and fails 3/3 against the string comparison.
- Evidence: pre-fix reproduction (2026-09-28 11:47 local, while a default-lane
  `build` held `~/.tron/internal/ios-test/lease.lock`, pid 84994):
  `scripts/tron-ios-test run --lane CT22 --only-testing …` leased
  `ios-test-CT22/lease.lock` (pid 85645) while its child ran
  `bash scripts/tron-ios-test run --only-testing:…` with no `--lane` and
  provisioned `--marker ~/.tron/internal/ios-test/simulator.json --name`
  `Tron iOS Tests`; the default marker's mtime moved 11:46:37 → 11:47:36 while
  `ios-test-CT22/simulator.json` stayed at 01:09:39, and the run's `owner.json`
  said `lane: default` (`20260928T184738Z-run.clWKCo`, exit 74 "test products are
  missing", no products in the probe's derived-data dir). Post-fix, the same
  command: child argv carries `--lane CT22`, provision uses
  `--marker ~/.tron/internal/ios-test-CT22/simulator.json`, the CT22 marker moves
  to 11:51:19 while the default marker stays at 11:47:36, `owner.json` says
  `lane: CT22` (`20260928T185125Z-run.HJ8Zmj`), and both devices are `Shutdown`
  afterwards. Logs: `~/.tron/workspace/files/hardening/t-3-evidence/`.
- Evidence: `python3 scripts/test-ios-test-infrastructure.py
  RunnerFixture.test_a_lane_named_on_the_command_line_is_the_lane_that_provisions
  RunnerFixture.test_an_inherited_lease_that_covers_another_lane_is_refused
  RunnerFixture.test_a_state_directory_spelled_differently_is_still_this_lanes_lease`
  — 3/3 pass; each fails without its fix (with the lane not forwarded, the guard
  refuses 74 naming both locks; the string comparison refuses all three
  spellings). The existing `RunnerFixture` cases are the guard's positive
  control: every normal `run` there goes through the holder and now proves its
  inherited lease. Whole file after the follow-up: 89 tests, 179 s, OK.
- Tasks added: none.
- Deviations: the guard is a new env contract (`TRON_IOS_TEST_LEASE_LOCK`); it
  was added because the row named `TRON_IOS_TEST_LOCK_HELD` inheritance as a
  candidate bypass, and the guard closes that class as well as the found one.
- Open: the same `--lane`-argument-loss shape is *not* present in the two other
  re-exec sites (`scripts/ios-gateway-e2e-test`, `scripts/tron-profile-ios`
  pass `"$0" "$@"` and use `TRON_IOS_TEST_STATE_DIR`). For pairs 1 and 3 of the
  three recorded overlaps the named-lane artifact is missing (only `G7R`, `G7R2`,
  `G7RV`, `G7F` and `G7N` exist, and none matches 16:00:29 or 16:48:51 UTC), so
  the mechanism above is proven for pair 2 and sufficient for the class; the
  guard now refuses that run whether the lane was lost by argument or by
  inheritance.
- Note for future reproductions: the first pre-fix reproduction above ran on the
  shared default-lane simulator while another session's `build` held that lease,
  so it moved the default marker's mtime. Use `RunnerFixture` or a throwaway
  named lane instead.
- For the next agent: a `~/.tron/internal/ios-test-NAME` directory holding only
  `lease.lock` means a named-lane command ran in the default lane; treat it as
  evidence of a lane/lease mismatch, and check `TRON_IOS_TEST_LEASE_LOCK` when a
  command is refused (74) with "inherited iOS test lease covers".


### C-6 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/c-6`)

- Commits: `14d9ba665` (gateway transport: cancel frame, joined opens), `e31d21592` (iOS: cancel frame + `rpc.cancelled`), `02038e7f4` (records, docs, plan row), `57ac20dce` (cancellation stage naming), on `hardening/c-6` merged with `hardening/integration` at `d3aecb11e`.
- Result: protocol 6 gains `{type:"cancel",id}` (no response). The Gateway aborts
  that request's controller, a cancelled request writes one `rpc.cancelled`
  record instead of `rpc.completed` (debug under `SLOW_RPC_WARNING_MS`, warning
  at or above it) carrying `stage` (innermost open stage or wait) plus the span
  breakdown, and a second `session.open` for the same connection and session
  joins the attempt already in flight: one invocation answers both requests with
  the same result. The shared attempt is abandoned only when its last waiting
  request leaves, and a cancel for an already-answered, already-cancelled or
  never-admitted id changes nothing. The phone sends the frame for the nine
  disposable reads in `GatewayDisposableReadPolicy` when a request times out or
  is cancelled after it may have been sent, and logs `rpc.cancelled`; mutations
  and prompts are never cancelled.
- Evidence: `cd packages/gateway && npx vitest run
  src/transport/sync-protocol.integration.test.ts` — 5/5 pass. The new case
  (`disposable read cancellation`) proves, in order: the retry joins (one
  `session.open` invocation for two requests), cancelling the first leaves the
  shared attempt running (`aborts == []`), cancelling the last waiter aborts it
  (one fake-service abort), neither cancelled request is answered, the records
  carry `stage=session.open.attempt` / `stage=session.open.join`, an unknown-id
  cancel and a cancel after a delivered response add no record, and the next
  open for that session starts fresh work and answers normally (no leaked
  reservation or barrier). The join itself is also asserted in the existing
  overlapping-open case (`startedCounts == 1`, identical result payloads).
  Merge gate green on the merged branch: `npx vitest run
  src/transport/session-archive.integration.test.ts
  src/transport/server-capacity.integration.test.ts
  src/transport/sync-protocol.integration.test.ts
  src/transport/stall-diagnostics.test.ts
  src/transport/server-heartbeat.integration.test.ts
  src/transport/server-http-lifecycle.integration.test.ts` — 132/132;
  `npx vitest run src/sessions/runtime-registry.integration.test.ts` — 257/257;
  `npx vitest run src/transport/server-frame.test.ts
  src/transport/request-span.test.ts src/transport/logger.test.ts` — 32/32;
  `npx tsc --noEmit -p .` clean. iOS: `scripts/tron-ios-test run --only-testing
  TronMobileTests/GatewayClientTransportTests` — 54/54 pass, including "a
  timed-out disposable read sends a cancel frame, a mutation does not" (asserts
  the exact `{"type":"cancel","id":…}` frame, that no frame follows a
  `session.prompt` timeout, and one `rpc.cancelled` record); retained result
  bundle `~/Library/Developer/Tron/ios/test-runs/20260928T194314Z-run.MOPcKv/`
  (`20260928T200449Z-run.RGHCPR/` for the 55-test review-response run).
- Deviations: `rpc.cancelled` replaced `rpc.completed` for a cancelled request
  rather than joining it: one abandoned read is one record, and O-3's span
  breakdown rides on it. Cancelling a `session.open` that another request still
  waits for keeps the synchronization the attempt installed (the waiter delivers
  that exact result); if the last waiter leaves without a delivered answer, the
  request that owns the barrier releases it, so an abandoned open cannot make the
  retry fail as `conflict`. The registry's shared runtime start is deliberately
  not aborted with the wait: a retry (or another connection) joins the load
  already in progress, which is the "shared work continues while a waiter
  remains" half of the task; `packages/gateway/docs/observability.md` gains the
  `rpc.cancelled` row and the `stage` field, the protocol section of
  `packages/gateway/README.md` the frame, and the phone's `rpc.cancelled` row
  sits in the iOS AppLog table.
- Failure modes written first: cancel after the response was sent (no-op, no
  record), cancel of an unknown id (no-op), join while the first open is
  committing its subscription (the joiner waits for the attempt and replays its
  payload), connection close with joined waiters (all requests abort, the shared
  attempt aborts with the retired socket, the flight is released).
- Review response (round 3, all findings): `57ac20dce`, `3c7d5386a` (Gateway),
  `a502094f7` (iOS). A cancelled open hands its barrier to the shared attempt
  whenever a waiter remains instead of releasing it under the retry, so a retry
  that outlives its first request still gets the answer and synchronizes it. A
  cancel for an answered `session.open` whose barrier the client never
  synchronized revokes that barrier, unless another delivered response carries
  the same token (each barrier tracks the request IDs that delivered its token),
  so a retry in that window is answered instead of conflicting. `cancel`
  obeys only `DISPOSABLE_READ_METHODS` (the phone's nine reads, named in the
  README); a mutation, prompt or `session.sync` cancel is ignored. The phone
  queues its cancel behind the request's own send, so it cannot name a request
  the Gateway never admitted. Accepted deviation (finding 4): the registry's
  shared runtime start, catalog load and attention reconciliation keep running
  after the last waiter leaves, so a retry or another connection joins that work
  instead of starting a second one. Evidence: the extended
  `sync-protocol.integration.test.ts` case (join, revoke-only-unclaimed-barrier,
  cancel-a-non-disposable-read, both-delivered-responses) fails on each reverted
  fix (retry answered `conflict`, barrier never revoked, prompt never answered);
  `GatewayClientTransportTests` 55/55, with its new ordering case failing (3
  send invocations, cancel frame first) when the Swift fix is reverted. Merge
  gate green on this branch merged with `hardening/integration` at `3d90561d4`.
- Open: the `Done when`'s O-6a slow-open case is the orchestrator's qualification
  run; this branch proves the mechanism it depends on (no duplicate-open failure,
  no request-path work after the last waiter cancels) in the integration case
  above.

### G-9 · Done · 2026-09-28 · worker session (branch `hardening/g-9`)

- Result: one `BackgroundWorkScheduler` (`packages/gateway/src/background-work.ts`)
  runs registered jobs one slice at a time, yields with `setImmediate` between
  slices, and starts nothing while a request is in flight or the loop's delay p99
  is at or above `BACKGROUND_PAUSE_P99_MS` (50 ms), re-checking every
  `BACKGROUND_PAUSE_RECHECK_MS` (100 ms). A rejecting slice is reported
  (`background.slice` at warning) and never stops the scheduler or the jobs after
  it. Moved under it: the session catalog's periodic reconcile (it registered
  itself through `SessionCatalogOptions.backgroundWork`, defaulting to the
  process-wide `backgroundWork` instance, so `runtime-registry.ts` was not
  touched), command-receipt pruning, and the attachment/display-artifact
  maintenance pass. Admission no longer prunes the receipt directory: only the
  capacity boundary still forces one exact pass before it refuses. `gateway-main.ts`
  starts the scheduler and owns both records; `requestsCompetingForLoop()`
  (`transport/request-span.ts`) is the in-flight-request signal, and it counts
  only requests that are on the loop: a receipt-backed mutation parks its own
  span (`offLoop`) for the length of its operation.
- Evidence:
  - `npx vitest run src/background-work.test.ts` — 7/7 (the failure-mode list is
    in the file header: a slice while a request is in flight, a slice at the p99
    bound, two slices at once/no yield, a rejecting slice starving later jobs,
    one `background.backlog` per starved spell rather than per re-check, and
    `stop()` leaving a wake armed). Each case asserts the exact counts it
    forbids: 0 slices against 1, an armed immediate against none, one backlog
    record against two.
  - `npx vitest run src/sessions/session-catalog.test.ts` — 29/29 (the periodic
    pass now arrives from the scheduler: "repairs an event the platform never
    delivered at the next interval pass"), `src/transport/command-receipts.test.ts`
    — 27/27, `src/transport/request-span.test.ts` +
    `src/transport/request-span.integration.test.ts` — 22/22.
  - Merge gate on this branch merged with `hardening/integration` at `47630104f`:
    the six-file transport set — 132/132; `src/sessions/runtime-registry.integration.test.ts`
    — 257/257; `npx tsc --noEmit -p .` clean.
  - Scheduler driven in a real Gateway (short O-6a smoke, `UV_THREADPOOL_SIZE=4`,
    `scripts/tron-profile gateway --scenario multi-session --no-build --iterations
    1 --catalog-files 300 --catalog-mib 200 --mixed-seconds 30 --cases none`):
    the fixture Gateway logged `catalog.reconciled` (300 files in 38.0 s) and ran
    to completion in 2.6 min. Report:
    `~/Library/Developer/Tron/profiles/gateway/20260928T202515Z-multi-session-16b386/report.json`.
    That one record is the **startup** pass, not a scheduler slice: the 30-minute
    job cannot fire in a 2.6-minute run, and `background.slice` is debug (memory
    only), so the fixture log holds no `background.*` record at all. The smoke
    shows the pass runs in a real Gateway; it does not show a slice.
- Not met, deliberately:
  - **The libuv pool measurement (Do 3).** The smoke ran on a host at 1-minute
    load 179 on 18 CPUs; the report's own warning is "host busy: 1-minute load
    179.0 on 18 CPUs", with `session.list` p99 16.4 s, `session.open` cold p99
    31.2 s, event-loop delay p99 403 ms and max 1,247 ms over a 30 s window —
    two to three orders of magnitude above the exit criteria, so a 4-vs-8-vs-16
    comparison would measure the host, not the pool. `UV_THREADPOOL_SIZE` is
    unchanged in `packages/mac-app/scripts/tron-gateway-launcher.c`, because a
    value set from that run would be an unmeasured change.
  - **Session-search indexing.** Step 2 also names it; it is not in this change.
    It is G-8c's task (the plan gives it the scheduler registration seam).
  - **The "Done when" (O-6a latency targets hold while reconciliation runs).**
    O-6a is Blocked on a quiet host, so no valid run exists; this branch proves
    the mechanism (the schedule, the pause conditions, the records, the moved
    jobs, and a reconcile that yields to the pause between bounded batches) and
    the smoke above proves the pass runs in a real Gateway. The confirmation is
    owed by the orchestrator, which owns the probe, together with the pool
    comparison (4/8/16 on one quiet host, comparing `latency.session_list.p99`,
    `latency.prompt_admission.p99` and `gateway.event_loop.delay_p99`).
- Deviations: the in-flight-request signal is the live `RequestSpan` count in
  `packages/gateway/src/transport/request-span.ts` rather than a counter in
  `transport/server.ts`: one span is exactly one admitted request (constructed at
  admission, finished in the same `finally` that writes `rpc.completed` or
  `rpc.cancelled`), and the transport zone is held by E-3a. The catalog's startup,
  watcher-event and watcher-replacement passes are not registered slices: they run
  the owner's own pass, whose every bounded batch yields to the scheduler's pause
  (the durable-row batches of `CatalogMetadataIndex.reconcile` and one file per
  batch in the rebuild path), so they are paced like a slice but produce no
  `background.slice` record. The catalog takes the
  scheduler as an injectable option defaulting to the process-wide instance, so
  `runtime-registry.ts` needed no change while G-1c held it. Jobs are registered
  by name; a second registration of one name replaces the first, and the replaced
  owner's unregister no longer deletes the replacement.
- For the next agent: G-8c registers session-search indexing through
  `backgroundWork.register({ name, intervalMs, slice })` (returned function
  unregisters); a slice with more than one bounded batch awaits
  `backgroundWork.yieldToLoop()` between batches. The scheduler starts after the
  listener is serving, so a job registered before that runs from its first due
  time. `background.slice` is debug (memory only) and `background.backlog`
  warning, each carrying the job in `step`; both have rows in
  `packages/gateway/docs/observability.md` and the contract is in
  `packages/gateway/README.md` ("Background work"). Nothing is running: the
  profile fixture Gateway exited and the retained evidence stays under the run
  directory above.
- Review fixes (second round, same branch): the pause no longer counts a request
  that is waiting away from the loop (a receipt-backed mutation parks its span in
  `GatewayService.mutation`), which stops one `session.bash` or `session.compact`
  from pausing background work indefinitely; a reconcile pass yields to the same
  pause between bounded batches; a replaced job's unregister no longer deletes the
  replacement; both background records carry the job in `step`; and startup skips
  `backgroundWork.start()` when a signal already set `stopping`. Merge gate on
  this branch merged with `hardening/integration` at `81ea9c8d4`: the six-file
  transport set 132/132, `npx tsc --noEmit -p .` clean, and
  `src/sessions/runtime-registry.integration.test.ts` 256/257 — the one failure
  ("keeps a large streamed write visible through snapshot recovery and canonical
  handoff", 5 s `isBusy` wait) reproduces on this branch with all six source files
  reverted to the reviewed commit, so it is the host (1-minute load 32-53 on 18
  CPUs), not these changes; the case passes alone in 4.2 s. Evidence: the new
  `src/transport/request-span.integration.test.ts` case fails when the parking is
  removed (assertion `requestsCompetingForLoop() === false` while a held
  `session.rename` waits); `src/background-work.test.ts` 9/9 and
  `src/transport/request-span.test.ts` 10/10.

### E-3a · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3a`)

- Result: the Gateway can serve a second, TLS-only listener on the Mac's private
  LAN address, off unless `--lan-endpoint on` / `TRON_GATEWAY_LAN_ENDPOINT=on`
  (default false; E-3d flips it). New `src/transport/lan-endpoint.ts` owns the
  listener: it binds only an RFC 1918 or IPv6 ULA address the host has (never a
  wildcard, link-local or Tailscale's fd7a:115c:a1e0::/48, which is inside the
  ULA range), on the main listener's port, rebinds when the preferred address
  changes, and disables itself when none is left. The key and self-signed
  certificate live at `~/.tron/gateway/lan-endpoint/` (0600 in a 0700
  directory), are created once on first use, and a half-present, unreadable or
  mismatched pair disables the endpoint without overwriting it (a paired phone
  pins the public key). `config.ts` resolves the private addresses
  (`isPrivateLanAddress`, `resolveLanAddresses`) and the setting; `server.ts`
  wires only: the LAN server's socket/request/upgrade events enter the existing
  `admitHttpConnection`, `handleHttp` and `handleUpgrade`, so admission,
  capacity, heartbeat, revocation and hello are the same code. The lane serves
  the socket route and the authenticated routes only: `POST /v1/pair` answers
  404 there, and `/health` on the lane answers `{ status }` alone. Every
  `http.upgrade` record now carries `transport` (`lan` / `tailscale` /
  `primary`), and each bind, rebind or disable writes one `lan.listener` record
  with `state`, `family` and `port` — family and port, never the address.
- Evidence: `npx tsc --noEmit -p .` clean. `npx vitest run
  src/transport/lan-endpoint.integration.test.ts` 6/6 (real TCP/TLS/WebSocket
  sockets; the fixture's LAN address is loopback, since that is the only
  address a test may bind, and the cert chain is verified against the file):
  create-once 0600 pair reused across a restart; three bad-pair cases each
  disabled and untouched; first-of-two addresses bound, rebound to the second
  with the old address's socket retired, then one disable record for the empty
  list; one `bind_failed` record for an unbindable address; the Gateway's lane
  bound on `::1` at the main listener's port serving a `wss` hello whose
  `http.upgrade` says `transport=lan` (vs `primary` on the plain listener),
  minimal lane `/health`, 401 on an authenticated route without a credential and
  404 for lane pairing; setting off binds nothing; shutdown retires the lane's
  sockets. `npx vitest run src/config.test.ts` 28/28 (predicate, ordering,
  setting parse).
- Deviations: `transport` is a new `LogMetadata` field in
  `src/transport/logger.ts`, so the lane's legs are attributable in
  `http.upgrade` without changing that record's message shape; `lan.listener`
  keeps its detail (`state`/`family`/`port`) in the message as the bounded
  diagnostic records do. Both have rows in `packages/gateway/docs/observability.md`.
- For the next agent (E-3b/E-3c/E-3d): E-3b adds the accessor it needs for
  advertising (`LanEndpoint`'s bound address, family and port are private state
  today, deliberately: nothing reads them yet) and the `lanPin` from
  `tls-certificate.pem`; the lane's port is the main listener's, so a wildcard
  `--host` would collide (fail-closed, one `bind_failed` record); the
  qualification scripts that start a fixture Gateway need `--lan-endpoint on`
  before E-3c's race cases can exercise the lane.

### E-3a · review fixes · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3a`)

- Result: an independent review's two majors and three minors are fixed on the
  same branch (no merge). (1) A certificate serial is now minimal DER
  (`derInteger` drops a leading zero octet and re-adds one only for the sign), so
  the ~1 draw in 512 that started with a zero octet no longer produces a
  certificate OpenSSL refuses — which used to stop the Gateway starting, or
  disable the lane for good with `certificate_unreadable`; a freshly created pair
  is also read back through `validateCredentials` before it is written, and the
  TLS context is created inside `bind`'s try so a refused credential is a
  disabled record rather than a thrown `start`. (2) Both listeners now take their
  header, request-idle, connections-checking and TLS handshake bounds from one
  `HTTP_LISTENER_LIMITS` object in `server.ts`; the lane previously kept Node's
  60 s header and 120 s handshake defaults, so an unauthenticated peer on the
  Wi-Fi could hold lane slots that come out of the same 128-connection budget.
  (3) `stop` sets a `stopped` flag, joins the single in-flight reconcile and
  closes a listener a late bind produced, so nothing this endpoint bound stays
  listening after `stop` resolves. (4) The accepted socket's time is carried to
  the `TLSSocket` on `secureConnection` (matched by peer address and port, since
  `tls.Server` does not expose the wrapped socket), so `acceptToUpgradeMs` on the
  lane measures the TLS handshake instead of reading 0. (5) The committed
  merge-base marker `||||||| 3d90561d4` is deleted from this file.
- Evidence: `npx tsc --noEmit -p .` clean; `npx vitest run
  src/transport/lan-endpoint.integration.test.ts` 10/10 and `src/config.test.ts`
  28/28. Each new case fails on the pre-review code for its own reason (a drawn
  serial is refused by OpenSSL; the lane's unauthenticated sockets outlive a 30 s
  bound; `acceptToUpgradeMs` is 0; `stop` leaves the listener bound), and the two
  lane cases fail again when the shared-limits wiring is reverted. Merge gate
  with `hardening/integration` at `218abab28`: 132/132 across the six transport
  files and 257/257 in `src/sessions/runtime-registry.integration.test.ts`. The
  merge resolution in this file kept both sides of the handoff log and wrote no
  conflict marker.
- Deviations: the lane's bounds are declared by `LanListenerLimits` in
  `lan-endpoint.ts` and valued by `HTTP_LISTENER_LIMITS` in `server.ts`;
  `LanEndpointHandlers` gained `onSecureConnection`; `selfSignedCertificate`'s
  serial stays 16 random bytes.
- Left: the lane bounds case waits out the real 15 s header bound (about 16 s of
  the file's 19 s), because Node enforces it with its own timers; it observes the
  408 rather than a client close, since a paused TLS socket never surfaces the
  server's FIN.

### C-1 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/c-1`)

- Result: reconnect runs beneath the projection, parked episodes self-resume and
  their reason is recorded; the review round is addressed and the E2E case
  passed with its `phone-connection-records` attachment.
- Changes (the first commit is the C-1 implementation; the second is the review
  round):
  - `GatewayLifecycleCoordinator.swift`: a replacement attempt ends at the
    authenticated handshake plus event activation. `beginDeferredProjection`
    hands mounted restoration, refresh and terminal reattachment to one
    presentation-owned task beneath that socket; the socket's loss cancels it
    and settles the reconciliation aggregate it was reconciling, so a cancelled
    projection cannot leave `isReconcilingForeground` true. `PARKED_RETRY_BOUND`
    (30 s) arms `parkedRetryTask` when the last path hint said unsatisfied; a
    foreground activation probes the same way. Parking is the only owner of the
    state it publishes, and the non-retryable, unpaired and authorization stops
    are refused before the unsatisfied-path branch, so a stop the user must clear
    keeps its Retry surface. Every early return names its refusing guard once
    (`reconnect.skipped`); `reconnect.parked`/`reconnect.parked-resume` name a
    park and its resume.
  - `AppModel.lifecycleRecordDiagnostic` records those three kinds (the
    production sink dropped them before), and `observability.md` documents them
    as `gateway.lifecycle` kinds rather than separate events.
  - Deleted: the superseded post-connect stage/attempt-ID shape
    (`handshakeRecorded`, `attemptStage`/`attemptID` parameters, the recorder's
    `isPostConnect` branch, `postConnectStage`/`postConnectAttemptID`) with its
    test, `BlockedRefreshProjection`, and the now-unused `episodeDate` helper.
  - Tests: the two connected-export tests wait for the presentation-owned
    diagnostics readiness; a non-retryable stop is tested against the
    notification route poll (isolated coordinator test and one through AppModel);
    park, resume and refusal are tested through the real AppModel into the phone
    diagnostic log. `StallingRestoreProjection.stallNextRestore()` is one-shot:
    a sticky arm stalled the reconnect's own restoration, and the lifecycle
    teardown then waited on it forever (that is what timed out the first E2E
    re-run after the second-outage assertion had passed).
- Evidence:
  - `scripts/tron-ios-test build`; `AppModelReconnectTests` 42/42;
    `GatewayLogExportTests`, `GatewayConnectionEpisodeRecorderTests`,
    `SessionPresentationStoreTests`, `AppModelLifecycleTests`,
    `AppModelCatalogSyncTests` 129/129.
  - `scripts/ios-gateway-e2e-test prepare/build/run` (plain Node 22.22.0, run
    `20260928T193255Z-run.E6rrDl`): `testStreamsReconnectsAndSettlesExtensionTools`
    passed in 174.6 s (summary `result=Passed`). Its `phone-connection-records`
    attachment (copied to
    `~/.tron/workspace/files/hardening/c-1-phone-connection-records-20260928T193255Z.txt`,
    with `c-1-e2e-summary-20260928T193255Z.json`) shows the 90 s outage as eight
    attempts (`retry=1..8`, `stageReached=hello-receive`, ~5.04 s each, delays
    0/1946/3981/6204/8557/12401/12904/13737 ms), one `connection.episode`
    `attempts=8 maxGapBetweenAttemptsMs=18776 endedBy=connected`, recovery on the
    attempt that followed the path's return, zero `reconnect.stalled`, and the
    second blackhole answered by attempt `51F65C01` (failure then success) while
    `StallingRestoreProjection` was still stalling.
- Deviations:
  - `becameActive` and the parked bound pass `ignoresPathHint: true`: one probe
    attempt is spent, and a failed probe re-parks with a fresh bound.
  - `reconnectStallGuard`'s `pathUnsatisfied`/`reconnectTaskBusy` cases are no
    longer reachable for a park (the pool still uses `pathUnsatisfied`); the enum
    is C-5's owning file.
  - Two of the plan's five failure modes have no new C-1 test: "background during
    an in-flight attempt" is covered by
    `AppModelReconnectTests.backgroundBeforeFirstHelloResumesSelectedProfile`
    (the scene backgrounds while the startup attempt's hello is in flight, its
    late cache completion is fenced and foreground resumes once), and the single
    `enteredBackground` cancellation owner means a reconnect-loop attempt adds no
    new path; "two profiles" belongs to the dashboard pool's owner (C-5,
    `DashboardStateOwnerTests`) because C-1's reconnect admits only the selected
    profile.
  - `beginRestarting` (pre-existing) still publishes `.restarting` and then
    `.reconnecting` from its 90 s watchdog before `requestReconnect` can refuse
    on a non-retryable stop, which leaves the same "no Retry" state the review's
    third finding described. It is not reachable from the reviewed path (it needs
    a `system.stopping` event while recovery is stopped) and was left out of this
    task's scope: propose it as a follow-up row.
  - The E2E harness's run-phase ceilings remain raised
    (`scripts/ios-gateway-e2e-test`: 600 s overall, 300 s of silence).
- What is left (the next agent, not this one):
  1. Optional follow-up: whichever owner takes the `.restarting` watchdog should
     make it refuse a non-retryable stop instead of publishing a recovery state.
  2. Do not run the harness's install step through a symlinked
     `packages/gateway/node_modules`: its `npm ci` empties the shared install. The
     lane is shared with `scripts/tron-ios-test`, so a `run` waits for whichever
     process holds the lease.

### C-1 · 2026-09-28 · final review round (same lane)

- Both findings fixed in one commit on top of the integration merge:
  - The reconnect loop's retryable-failure path parks when the last hint still
    reads unsatisfied, so the bound's (or a foreground's) failed probe re-parks
    with a fresh bound instead of ending the episode silently.
  - `parkRecovery` refuses while `connectionAdmissionTask`, `committedConnectionTask`
    or `pairingAttempt` is in flight; each of those owners calls the new
    `parkUnsatisfiedPathWhenIdle` when it releases the attempt, so the refusal
    cannot become a silent gap of its own (pairing included, which the review's
    prescribed guard alone would have missed).
- Evidence: `AppModelReconnectTests` 45/45 (3 new: bound probe fails -> second
  park, fresh bound, second attempt, zero `reconnect.stalled` over 20 s;
  foreground probe fails -> same; a path hint cannot park over the initial
  connect, state stays `.connecting` and no bound is armed), `AppModelPairingAttemptTests`
  8/8 (1 new: a path hint cannot park over the pairing that owns the connect),
  `AppModelLifecycleTests` 9/9, `GatewayConnectionEpisodeRecorderTests` 4/4,
  `GatewayLogExportTests` 17/17 alone.
  - Not C-1: `GatewayLogExportTests`' `byteEnvelopeReservesTheChatTrace` is
    killed (SIGKILL, no assertion) whenever it shares a process with
    `GatewayConnectionEpisodeRecorderTests`, whose main-stall test blocks the
    main thread for two 4 s phases (T-2). Each suite passes alone, and it also
    fails in that pair with every new C-1 test disabled, so the coordinator fix
    is not the trigger; the pair passed before this merge. Retained bundles:
    `~/Library/Developer/Tron/ios/test-runs/20260928T203739Z-run.InevV5` (crash)
    and `20260928T201219Z-run.jNGHmH` (log export alone, green).
- Negative controls: reverting each hunk failed its own tests (probe tests; the
  two path-hint tests) and passed the other's, then the fix was restored.
- Gateway gate after merging `hardening/integration`: the six transport
  integration files 131/131, `runtime-registry.integration.test.ts` 257/257,
  `npx tsc --noEmit -p .` clean.

### C-7 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/c-7`)

- Result: one event reader per pool connection epoch. `Entry.eventTask` reads that
  epoch's `client.events`; `startEventConsumption` starts one wherever an attempt
  connects (the initial connect and the reconnect loop's success path), and
  `retireConnectionEpoch` cancels and clears it with the connection it clears,
  as `stop()` does. An entry whose first attempt failed had no reader at all —
  its `start` task ended in the failure branch before the stream — so a
  successful reconnect left a live socket whose `session.summary`,
  `system.stopping` and `transport.disconnected` nobody read; an entry whose
  first attempt succeeded kept one reader across epochs, which could take a
  successor's deliveries under the identity of the connection it was started
  for. `packages/ios-app/docs/architecture.md` states the ownership beside the
  pool's connection paragraph. No new record, so no observability row is owed.
- Failure modes (one isolated test, `failedInitialConnectReconnectConsumesEvents`):
  (1) after a failed initial connect nothing consumes the reconnected socket's
  events; (2) a reader outlives its epoch on the client's shared stream; (3) a
  retired reader's slot is never cleared, so its successor connection has none.
- Evidence: `scripts/tron-ios-test build` succeeds;
  `scripts/tron-ios-test run --lane CT22 --only-testing TronMobileTests/DashboardStateOwnerTests`
  passes 61 tests in one suite
  (`$HOME/Library/Developer/Tron/ios/test-runs/20260928T202434Z-run.c7QcxS`; 60
  before this branch's new test). Negative control with only the reconnect-path
  reader removed (the pre-fix shape): exactly that one test fails, at its
  summary leg (`condition timed out`, `DashboardStateOwnerTests.swift:633`), and
  the other 60 pass (`…/20260928T202818Z-run.qBKuHY`); the source was then
  restored byte-for-byte (`shasum -a 256 -c`, `837be616…`) to the tree the
  passing run was built from. The default lane was occupied by another
  session's run (a sibling checkout holding its own `ios-test-paused` lock) on
  the default-lane device `E816D194…`, which killed the first attempt's host app
  (`signal kill before establishing connection`,
  `…/20260928T202253Z-run.fa56So`); the passing and control runs used the idle
  `CT22` lane. `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Merge gate: merged `hardening/integration` (`47630104f`, C-6) before the
  final commit. On the merged tree: the same iOS suite passes 61/61
  (`…/20260928T203528Z-run.VHRooM`); the six gateway transport integration files
  pass 132/132, `runtime-registry.integration.test.ts` passes 257/257 (a first
  run flaked on a 10 s hook timeout under host load; the test passes alone and
  the file passes whole on the retry — this branch's gateway tree is identical
  to `hardening/integration`'s, so no gateway code of this task is involved),
  and `npx tsc --noEmit -p .` passes.
- Changes: `fix(ios): consume events for every pool connection epoch (C-7)` and
  this plan commit.
- Tasks added: none.
- Deviations: the initial connect's inline `for await` loop moved into
  `startEventConsumption` (the same code, its own slot) so that both connect
  paths own their reader the same way, and `retireConnectionEpoch` retires the
  reader with the connection it clears. `retry()`, `notePathHint`, the C-5 curve
  and the stall guard are untouched.
- For the next agent: C-2 owns what the pool publishes as `state` after a
  reconnect; the reader no longer affects it.

### G-11 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-11`)

- Result: bounded the Slot's own synchronous stretch: `RuntimeSlot.summary()`
  re-walked every entry of the session file on each publish, and now folds only
  the entries appended since the last fold (a whole-file walk stays the fallback
  when the entry set is replaced rather than appended to). Every other stretch
  over 50 ms measured here lives in a file an in-flight task holds and is listed
  below with its owner.
- Evidence: two `scripts/tron-profile gateway --scenario multi-session
  --no-build --iterations 1 --cases none --catalog-files 100 --catalog-mib 512
  --mixed-seconds 30 --cpu-profile` smokes on this host — before
  `~/Library/Developer/Tron/profiles/gateway/20260928T201020Z-multi-session-4ca8a6`,
  after `…/20260928T202752Z-multi-session-470c21` (both reports retained at
  `~/.tron/workspace/files/hardening/g-11/{before,after}-report.json`). The summary stretch's largest
  CPU-profile run falls 86.9 ms → 4.8 ms (top five before
  86.9/63.9/19.6/17.3/14.7 ms, after 4.8/4.5/3.8/3.7/3.5 ms) and no `summary`
  run reaches 50 ms. Focused case `folds summary facts from appended entries and
  rebuilds when the entry set is replaced` in
  `runtime-registry.integration.test.ts` fails on both reverted halves (a fold
  pinned to its first boundary; a fold that does not rebuild after the file is
  replaced) and the file passes 258/258. Merge gate on this branch merged with
  `hardening/integration` at `47630104f`: 132/132 across
  `session-archive`, `server-capacity`, `sync-protocol`, `stall-diagnostics`,
  `server-heartbeat` and `server-http-lifecycle` integration/unit files,
  `runtime-registry.integration.test.ts` 258/258, `tsc --noEmit` clean. The
  after smoke's aggregate event-loop numbers are not comparable: the host ran at
  load 208 with other workers' xcodebuild/vitest, and the search warm-up
  dominates both runs (before mixed max 564 ms/p99 81 ms, no-subscriber max
  6537 ms/p99 2221 ms, `gateway.event-loop-delay` 6355 ms and 1277 ms; after
  mixed max 1779 ms/p99 186 ms, no-subscriber max 25.5 s/p99 1091 ms, records
  14.6 s and 16.8 s).
- Changes: one commit on `hardening/g-11` (`packages/gateway/src/sessions/runtime-slot.ts`,
  its integration test, this plan).
- Tasks added: none. Stretches this branch did not fix, with owners:
  session-search — `SessionSearchService.rebuild` → `SessionSearchIndex.replace`
  (65.1 s of the after profile's 87.1 s of ≥50 ms runs; top before-profile runs
  821/663/650/597/565 ms) plus `currentBudget` (8.6–15.5 s over 32–35 runs) and
  the invalidator's synchronous `SessionSearchIndex.remove` called from
  `publishRevisionedSummary` → `summaryChanged` → `publishSummary` (491 ms in one
  run) — **G-8c** (in flight; the orchestrator handed it both search stretches on
  2026-09-28); `catalog-discovery.buildCatalogSessionInfo` with
  `catalog-metadata-index.applyCatalogMetadataEntry` (138 ms ×2, 61 ms),
  `runtime-registry.buildCatalogPageSeeds` (95 ms) and `parseStrictSessionJSONL`
  via `readSearchCut` (54 ms) — **G-1c** (in flight); `flushPendingProgress` →
  `projectMessage` of the streaming message (82 ms per 150 ms window) —
  **G-3a**; `buildSnapshot` → `projectTranscriptPage`'s O(branch) projection per
  publish (62 ms) and `ensureAgentProjection` (63 ms) — **G-2**. Not
  Gateway-owned: `structuredClone` in the SDK's `agent.transformContext`
  (239 ms ×2), the SDK stream interface's `\r?\n` split (266 ms ×3),
  `toToolDeclaration` (121 ms), `spawn` (164 ms), module compile (~600 ms). The
  O-3 spans show the same block from the request side: `session.open` 23.6 s with
  `catalog.walk=23547 ms` and `session.list` 8.3 s with
  `catalog.metadata-materialize=8124 ms`.
- Kept on purpose: `summary()` still calls `getEntries()` (an O(n) filtered copy
  of milliseconds) so the fold can see appended entries; `persistCanonicalCustomEntry`'s
  per-receipt O(branch) `existing` scan stays below the 50 ms bound in this
  scenario and belongs to a durable-write path, not a publish (G-10/G-10a).
- Deviations: the task's section expected the owning files to be
  `runtime-slot.ts`/`runtime-registry.ts`; the measured top stretches are
  session-search and catalog/registry, both held by in-flight tasks, so only the
  Slot's stretch was fixed here and the rest are listed above (supervisor
  decision, option b, 2026-09-28). The `Done when` (O-6a event-loop max ≤ 250 ms,
  p99 ≤ 20 ms) is therefore not claimable from this branch alone: the
  orchestrator re-measures the combined max/p99 after G-8c and G-1c merge.
- For the next agent: the two search stretches to bound are the warm-up's
  per-document `replace` (yield between batches of the term/trigram inserts) and
  the invalidator's synchronous `remove` (mark the session dirty and let the
  refresh path delete off the publish path). `summaryContentFold` assumes
  `getEntries()` stays append-ordered and falls back on a shorter array or a
  changed boundary id; an owner that reorders entries in place must invalidate it.

### G-8c · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-8c`)

- Result: the session-search index is persisted state keyed by the catalog
  owner's verified file facts, so a start reuses every session the catalog still
  reports unchanged and parses only what changed. G-11's profile findings are
  fixed in the same change: one document's posting insert is sliced and the
  summary-publication invalidator no longer runs SQLite work inline.
- Scope decision (user, 2026-09-28): persisted index keyed by `fileIdentity`,
  rebuildable from canonical JSONL, one owner. The reuse key is the catalog's
  verified `{fileIdentity, size, mtimeMs}` triple — `dev:ino` alone does not
  change on an append, so identity alone cannot prove a transcript unchanged.
  A row is stamped with the facts observed **before** its transcript read, so a
  stamp is never newer than the content it indexes (an unusable stamp only
  causes an extra parse later).
- Evidence for "Done when" (a start warms without a full-corpus parse, within a
  stated bound, coverage digest unchanged):
  - `npx vitest run src/sessions/session-search-service.test.ts` passes 14/14,
    including "reuses the persisted index for an unchanged corpus and re-parses
    only what changed": start 1 parses 2 of 2 (`indexPassStats()`
    `{reused:0, parsed:2}`), start 2 over the same index reads **0** transcripts
    (`{reused:2, parsed:0}`) and returns the **identical `corpusRevision` and
    `coverage`**, and after one file's facts move, start 3 re-reads exactly that
    session (`["two"]`, `{reused:1, parsed:1}`).
    "parses the corpus when no catalog cut can prove a row unchanged" is the
    negative control: with no verified cut, both starts parse (1 read each).
  - `npx vitest run src/sessions/session-catalog.test.ts` passes 30/30, including
    the new "publishes search identities only after a verified cut, and omits a
    duplicated ID": before any cut the seam answers `undefined` (so nothing is
    reused on the strength of a durable load), after a verified cut it names
    `dev:ino`/size/mtime as the file reports them, follows an append, and omits
    an ID two files claim.
  - Stated bounds (named constants in `session-search-service.ts`): warm-up and
    reindex slices hand the loop back every `SEARCH_SLICE_MS` (20 ms) of work;
    the start waits at most `SEARCH_WARMUP_CATALOG_WAIT_MS` (30 s) for the
    catalog's first verified cut and then parses whatever it cannot prove; the
    optional semantic pass stops at `SEARCH_SEMANTIC_WARMUP_BUDGET_MS` (120 s)
    with explicit `partial` coverage; the index insert yields every
    `INDEX_WRITE_SLICE_MS` (20 ms).
  - Before/after event-loop stretch, `npx vitest run
    src/sessions/session-search-stall.test.ts` passes 2/2 with its report at
    `$TMPDIR/tron-search-stall-report.json` (kept at
    `~/.tron/workspace/files/hardening/g-8c-search-stall.json`): a 3,000-passage
    document's insert takes 2,371 ms of work in 57 slices, longest held stretch
    **41.8 ms** — G-11's profile measured **565–821 ms** held by one document's
    insert — and a summary publication's invalidation holds the loop **0.13 ms**
    against **2,666 ms** for the inline `SessionSearchIndex.remove` the old
    invalidator ran (G-11: 491 ms). The case asserts the ratio (stretch × 5 <
    whole insert; invalidation × 10 < inline remove), because absolute
    milliseconds move with host load. The insert's remaining stretch is the two
    global posting-byte aggregates; the per-session byte query became a row read
    (`posting_bytes`).
  - `npx tsc --noEmit -p .` clean; `npm run build` clean;
    `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
  - Merge gate on this branch after `hardening/integration` (C-6) was merged in:
    132/132 in `session-archive.integration.test.ts`,
    `server-capacity.integration.test.ts`, `sync-protocol.integration.test.ts`,
    `stall-diagnostics.test.ts`, `server-heartbeat.integration.test.ts`,
    `server-http-lifecycle.integration.test.ts`, and 257/257 in
    `runtime-registry.integration.test.ts`.
- Changes: `session-search-index.ts` (persisted rows + schema stamp, reuse
  columns, `posting_bytes`, `sessionFacts()`, async sliced `replace`, sliced
  budget pricing); `session-search-service.ts` (reuse pass, dirty marking
  instead of inline `remove`, sliced warm-up, semantic budget, counters);
  `session-catalog.ts` (`verifiedCut`, `searchIdentities()`);
  `runtime-registry.ts` (one delegating read-only method);
  `gateway-main.ts` (`session-search.warm` counts); new
  `util/event-loop-yield.ts`; docs `session-search.md`, `observability.md`;
  tests `session-search-index.test.ts`, `session-search-service.test.ts`,
  `session-catalog.test.ts`, new `session-search-stall.test.ts`.
  Superseded and deleted: `SessionSearchIndex.clear()` and the two tests that
  asserted a per-process discard ("reopens a populated disposable index empty"),
  plus the doc sentences that promised it.
- Deviations: the registry is the Registry zone (G-9 in flight); the orchestrator
  approved one additive read-only method block built on
  `sessionCatalog.rows()`/`sessionIdentities()` rather than the
  `catalogStructureEvidence` seam G-1c deletes, and will resolve the merge with
  G-1c. The catalog gained `verifiedCut` + `searchIdentities()` (Catalog zone,
  held by this row). The semantic pass still re-reads changed text to re-embed
  (vectors are not persisted); it is now time-bounded, and persisting vectors is
  the follow-up if the evaluation day shows semantic warmth matters.
- Not met / left: no measurement against the real 225-session / 2.8 GB corpus on
  a start that follows use (that needs the user's running Gateway or O-6a, both
  out of scope here); the numbers above are the focused fixtures. The queued
  `dirtyOverflow` path (over 256 changed sessions) leaves stale rows in place
  until the next start; every candidate is re-validated against its canonical cut
  before publication, so those rows under-report rather than misreport.
- Pre-existing flake seen while validating (not from this branch):
  `session-catalog.test.ts`'s shared `afterEach` removes each temp root while a
  previous test's catalog watcher may still be writing, so `rm` fails with
  `ENOTEMPTY`; the failing test varies. Evidence: the unmodified
  `hardening/integration` copy of that file failed the same way on the first of
  three loaded-host runs (2 tests) and passed 29/29 on the next two; this
  branch's copy failed once and passed on its other runs. Nobody owns the
  teardown yet; whoever picks it up should dispose each fixture's catalog in
  `afterEach`.
- For the next agent: G-9 moves the warm-up and the dirty reindex into its
  scheduler (`SEARCH_SLICE_MS` / `INDEX_WRITE_SLICE_MS` become that scheduler's
  slice); the `posting_bytes` column and `sessionFacts()` are the seams to reuse.
  A start after real use should show `counts.parsedSessions` far below the corpus
  size in `session-search.warm`.

- Review round 1 (2026-09-28) addressed:
  - major 1: a replace deletes the session's old rows in bounded batches
    (`INDEX_DELETE_BATCH_ROWS` = 25 passages per statement) and yields between
    them, and the pre-flight byte total reads `sum(sessions.posting_bytes)`
    instead of summing every posting; the warm-up's stale-row removals are
    sliced too. `session-search-stall.test.ts` now replaces an existing session
    in a populated index - the shape a dirty refresh always has: a 3,000-passage
    replacement over a 6,000-passage index took 3.1-6.6 s of work in 170-194
    event-loop ticks with a longest held stretch of ~0.3-0.6 s (host scheduling
    floor subtracted), against ~1.0 s for the whole-session cascade delete it
    replaced (491 ms in G-11). Report: `$TMPDIR/tron-search-stall-report.json`.
  - major 2: only a `readSearchCut` cut read from the canonical file may carry
    the catalog's facts; a slot-backed cut (`runtimeGeneration`) leaves the row
    unstamped so the next start re-derives it, pinned in
    `session-search-service.test.ts`.
  - minor 3: `replace()` and `remove()` share one private write lane, so an
    overlapping writer queues instead of joining or failing a transaction,
    pinned in `session-search-index.test.ts`.
  - minor 4: the persisted stamp carries a derivation version beside the table
    shape, with bump notes on `terms()`, `trigrams()`, `extractSearchText` and
    the branch digest (the stamp value changed, so existing rows are discarded
    once).
  - minor 5: the schema stamp is written only after `recreate()` has created the
    tables, so the constructor can no longer mark an old-shaped file current.
- Open: an open session's tree navigation followed by a restart is proven at the
  service seam with a stubbed registry, not yet end-to-end with a real registry
  and a real navigation. The budget check's stall claim has no timing assertion:
  at test-sized indexes the commit's fsync floor exceeds the whole-index scan.

### G-1c · Claimed · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-1c`)

- Result: the source-level slice is implemented and compiles; the owning suite is
  **red**, so this is a deliberate WIP commit for the resumed session, not a
  mergeable one. Budget (90 min) ran out inside the test-rework slice.
- Landed (runtime-registry.ts, -698/+165 lines):
  - `catalogIndex(scope)` is the request path's only membership source: one
    immutable in-memory cut of the owner's rows, user scope dropping `delegated`
    rows, ambiguity from `duplicateSessionIds()` plus live-only collisions.
  - `materializeCatalogSnapshot` (list/`catalog`/`pageSource`/search cut) and
    `catalogAcquisition` (open, attention, automation, `workspaceForSession`,
    `requirePersistedUserSession`, archive, delete) read that cut and do no I/O.
  - `attentionEntryStillAdmitted` and the cold-open fence check the index plus
    the target file's own stat and header only; `attentionLiveOnlyStillAdmitted`
    asks the index; `sessionIDsForStorageMaintenance` returns indexed IDs plus
    live slots; delete and archive take the index for membership and re-prove the
    one file at their commit.
  - Startup recovery (`recoverCanonicalAttention`, `recoverKnowledgeObservation`)
    reconciles against the owner's rows.
  - Readers join the owner's first cut (`awaitCatalogCut`, resolved by the
    owner's first `catalog.reconciled`/`failed`/`incomplete` report) so a read
    adds no walk of its own.
  - Deleted: `validatedStructuralIndex`, `loadDurableCatalogIndex`,
    `scanCatalogMaterialization`, `sharedCatalogStructureEvidence`,
    `sharedCatalogSessionInfos`, `sessionInfos`, `withCatalogEvidence`,
    `catalogIdentitiesForScope`, `catalogFactsDigest`,
    `catalogEvidenceMatchesScope`, `hasRelevantUnstableFiles`, `sameStringSet`,
    `dynamicAmbiguousSessionIDs`, `diskAmbiguousSessionIDs*`,
    `catalogEvidenceMatchesIndexedUserScope`, `removeIndexedCatalogFile`,
    `fallbackCatalogAcquisition`, `sdkCatalogIdentityFingerprint`,
    `buildCatalogAcquisition(evidence)`, `publishCatalogAcquisition`,
    `resolveCatalogAcquisition` and the acquisition promise/mutex/admission
    cache, the cold-open final validation walk, and the `CatalogStructuralIndex`
    and `CatalogAcquisitionAdmission` types with their digest fields.
  - `catalogStructureEvidence()` is now the owner's scan seam only: the one
    counted whole-folder walk.
- Evidence: `npx tsc --noEmit -p .` clean; `npm run build` clean.
  `catalog-discovery.test.ts` 2/2 and `session-catalog.test.ts` 29/29 pass
  (the one run that paired them failed two `session-catalog.ts` cases under
  parallel-file load; they pass alone, unchanged by this branch).
- Red: `runtime-registry.integration.test.ts` **187 passed / 70 failed / 257**
  (JSON report at `/tmp/g1c-full.json`). The failures are the rework this row
  still owes, in five clusters:
  1. ~20 cases spy on removed internals (`sessionInfos`,
     `validatedStructuralIndex`, `fallbackCatalogAcquisition`,
     `sharedCatalogStructureEvidence`). Their intent survives and each needs the
     index-shaped assertion (read performs no walk; the owner's first cut is the
     only walk).
  2. Reader-path capacity/fallback/stability cases (`bounds recursive catalog
     directories…`, `initializes storage without requiring catalog
     presentation…`, `bounds discovered session count and bytes…`, `caps
     canonical session path normalization concurrency`, the `fallback`/`unstable`
     families) asserted `busy`/`catalog_changed` from a reader walk. Capacity and
     instability are now the owner scan's and belong on `catalogReconciled`/
     `reconcile()` expectations.
  3. Cases that inject canonical files after `initialize()` need the
     `settleCatalog` helper (now: force one owner `reconcile()` then `settled()`),
     which is in this WIP.
  4. `counts a walk a request waited on apart from background catalog walks`
     must invert into this row's own evidence: a request-path walk count of
     **0** while the owner's cut is joined.
  5. Duplicate/delegated-topology semantics: `int8`-free cases such as
     `recognizes only the exact delegated-session producer topology`, `keeps a
     child mutation-protected when its parent ID is duplicated` and
     `admits scaled short headers within the aggregate validation budget` show
     the index cut currently publishes rows a whole-tree header pass would have
     withheld (a `delegated`/`duplicate` mismatch to close in the cut, not in the
     test).
- Still owed after the suite is green: delete `CatalogDiscovery.sessionInfos`,
  `buildCatalogSessionInfos` and the `maximumRetainedBytes` budget that only
  those walks used, with `catalog-discovery.test.ts` and the integration case at
  `runtime-registry.integration.test.ts:3483` pruned; the O-5 request-path-walk
  counter evidence and the O-6a smoke (`--no-build`, `--mixed-seconds 30`); the
  `session.list` p99 number (orchestrator's quiet-host run); and G-1d's doc
  wording.
- Deviations: readers join the owner's first cut rather than serving a
  pre-reconcile durable cut ("marked stale in the span"); that keeps a restart's
  first list correct and is recorded here for review.

#### G-1c · review round 1 response · 2026-09-28 · orchestrator-dispatched deepseek-worker

- Fixed (all reproduced on the built branch):
  - Blocker 1: `SessionCatalog.hasCompleteCut()`/`whenPublished()`; storage
    maintenance throws retryable `busy`, attention/archive prune and Knowledge
    recovery skip, when the published rows are not a complete cut. Probe
    `probe.mjs empty`: the read now fails retryably after the first-cut deadline
    instead of pruning/pruning-adjacent work on an empty index.
  - Major 3: `catalogAcquisition()` joins the owner's cut, so a cold open,
    attention, automation and workspace read cannot miss a row the first
    reconcile has not published. `probe-early.mjs`: acquire right after
    `initialize()` is now ok.
  - Major 4: `SessionCatalog.remove()` drops the row synchronously (commit
    already removed the file; the removal record still fences in-flight passes),
    so the list-changed event cannot republish a deleted row. `probe-delete.mjs`:
    list right after delete no longer contains the deleted ID.
  - Major 5 (partial): the cut wait resolves in a `finally` and is bounded by
    `CATALOG_FIRST_CUT_DEADLINE_MS` with a retryable `busy`.
  - Blocker 2 (partial): `CatalogDiscovery.sessionInfos`,
    `buildCatalogSessionInfos` and the `maximumRetainedBytes` budget are deleted;
    `catalog-discovery.test.ts` and the index-vs-full-scan case read one file at
    a time instead; the walk-counter case now asserts zero request-path walks.
- Not done: the owning integration suite is still red (measured 191/257 pass,
  66 failed; was 186/257 pass, 71 failed — the full-scan fixture case below
  passes individually after its fix, so 192/65) — the ~20 cases spying on
  removed internals, the reader
  capacity/fallback families, and the cluster-5 index/delegated-topology
  mismatches listed above still need the rework; no O-5/O-6a evidence yet.
- Residual: with a header-less `.jsonl` in the folder the owner still never
  publishes a complete cut, so reads fail retryably rather than serving the
  readable rows. That rule is the scan's (G-1b owner) and needs an orchestrator
  decision: an unreadable file should not make the folder's cut incomplete.

### G-1c · Claimed · 2026-09-28 · orchestrator-dispatched deepseek-worker, review round 2 (branch `hardening/g-1c`)

- Result: all three review blockers are fixed at the source; the listed check
  `session-archive.integration.test.ts` is **41/41** (was 4/41). The owning
  suite is still red, so the row stays Claimed.
- Fixes (commit `5d38ee986`, plus the cut rule below):
  1. An empty or missing sessions root publishes an empty complete cut when this
     owner has published nothing yet (a fresh install), so startup recovery and
     the first read no longer wait for a cut that never comes; a root that goes
     away after rows were published stays an outage (rows kept, `incomplete`).
     A file whose header cannot be read is `unprovenPaths` in the cut: its prior
     row is kept, no row is added, every other file still publishes, and
     `catalog.reconciled` counts it (the cut's `complete` now means the traversal
     only).
  2. `hasReconciledCut()` is a second fact: only a reconcile completed in this
     process authorizes destructive work. Storage maintenance throws retryable
     busy, attention/archive prune and Knowledge recovery keep their records, and
     an incomplete or failed pass clears the flag. The durable document still
     serves reads (`hasCompleteCut`).
  3. A read with no published cut fails fast with its own retryable reason
     `catalog_not_ready` (row added to `observability.md`), no 20 s park, and
     startup recovery waits for the in-process pass (`whenReconciled()`) instead
     of failing startup on it.
- Test rework landed: `initializeRegistry` awaits the owner's first cut at all
  86 registry-init sites, 8 inline readers initialize, the archive fixture waits
  for the first cut and settles the owner after it writes canonical files itself
  (`coldSession`/`rawSession` are async; a `settle()` helper forces the owner's
  cut, which is the deterministic form of waiting the watcher out).
- Evidence: `npx tsc --noEmit -p .` clean; `npm run build` clean;
  `session-archive.integration.test.ts` **41/41**;
  `catalog-discovery.test.ts` + `session-catalog.test.ts` **31/31**;
  `runtime-registry.integration.test.ts` **197 passed / 60 failed / 257**
  (`/tmp/g1c-r6.json`).
- Remaining owning-suite work, by cluster:
  - 33 cases spy on removed internals (`sessionInfos`,
    `fallbackCatalogAcquisition`, `validatedStructuralIndex`,
    `sharedCatalogStructureEvidence`) or drive a race inside the deleted
    acquisition/publication machinery. Each needs a behaviour assertion or the
    race reformulated at the commit fence (index claimant + target-file stat and
    header). The symlink-swap, same-inode rewrite, identity/duplicate and delete
    gap cases are the ones the reviewer named.
  - 27 behaviour cases: capacity/fallback/instability families belong on the
    owner (`catalogReconciled` outcome, retryable `catalog_not_ready`) rather
    than a reader walk; the delegated-topology and duplicate-quarantine cases
    write canonical files after `initialize()` and need `settleCatalog`; the two
    Knowledge-recovery cases named "without a warmed catalog" now need the owner's
    cut by design (decision 2).
  - Cases writing canonical files after `initialize()` need `settleCatalog`
    (already the helper's shape: force `reconcile()` then `settled()`).
- Still owed: the O-5 zero-request-path-walk evidence and the O-6a smoke; the
  `session.list` p99 (orchestrator's quiet-host run); G-1d's doc wording.
- Deviations: the missing-root rule above is narrower than the reviewed decision
  (fresh install publishes empty; a root away after rows exist keeps them and
  reports `incomplete`) because an absent root proves no removal and the existing
  G-1a case pins that. `catalog_not_ready` is the new reason for a read before
  the first cut.

### G-1c · Claimed · 2026-09-28 · orchestrator-dispatched deepseek-worker, review round 3 (branch `hardening/g-1c`)

- Result: review-2's blockers stay fixed; the owning suite is 213/232 (review
  time: 192/257 with 65 failures; 21 obsolete cases deleted since).
  `session-archive.integration.test.ts` 41/41 and `catalog-discovery.test.ts` +
  `session-catalog.test.ts` 31/31. Row stays Claimed: 18 cases remain.
- Landed (`371306fb7`, `89c62abc2`, `1f5ce404d`): test seams `catalogWalks()`
  (the owner's one whole-folder walk) and `catalogHeaderReads()`; a read now
  asserts it adds no walk and reads only the file it admits. Rewritten to the new
  contract: list/cold-open/hot-re-acquire, restart index, unprovable artifact,
  unrelated malformed header, incomplete-pass contract, duplicate/removal
  membership, the Knowledge recovery matrix (`incomplete` mode becomes decision
  1's unprovable neighbour), parallel delegated appends, artifact ownership,
  user-vs-all scope, duplicate quarantine beside a contradictory child.
- Deleted 21 cases whose subject no longer exists (one line each, same commit):
  durable-index materialization and publication gaps (retires a durable load,
  cannot republish, rejects a mutation in the final publication gap, fails busy
  after a second unstable materialization, never stamps captured stale fields,
  keeps cold acquisition independent of mutable metadata, acquires from header
  evidence while materialization is suspended, serializes an all-scope
  materialization, lets user discovery finish while all-scope is blocked, retires
  viewer capacity during one shared wait); fallback SDK acquisition and its
  retries (coalesces concurrent fallback scans, revalidates oversized SDK
  identities, retries lightweight acquisition, fails busy after a second
  lightweight invalidation, coalesces acquisition successors); shared
  request-path walks and caches (shares one successor header walk, keeps a
  live-owned index cut during reconciliation, rejects an inode replacement that
  races durable-index reconciliation, keeps a warmed disk index, retains the
  stable user cut, isolates an unfinished child append).
- Remaining 18: reader-capacity family (`bounds recursive catalog directories`,
  `bounds discovered session count and bytes`, `caps canonical session path
  normalization concurrency`, `bounds validation reads and retained acquisition
  evidence`, `reserves a deterministic aggregate header-read budget`,
  `initializes storage without requiring catalog presentation metadata`) → assert
  the owner's `catalogReconciled` outcome plus a retryable `catalog_not_ready`
  read; commit-fence races (`rejects identity, cwd, or duplicate mutation` — its
  duplicate arm writes the claimant inside the race; `does not follow a session
  path replaced by a symlink during delete`; `revalidates parent creation,
  duplicate identity, and topology changes in the delete gap`; `fails closed when
  multiple canonical files claim one session ID`) → drive at the new fence;
  unstable-file rule (`rejects an unowned append that races durable-index
  reconciliation`, `fails closed with retryable busy when an unowned canonical
  file ends in a partial line`) → decision 1 answers with the last provable row,
  not `busy`; and the live-only/identity group (`projects empty live sessions
  until deletion, persistence, eviction, or restart`, `advances user catalog
  identity when canonical membership changes beside delegated rows`, `refreshes
  user metadata and duplicate quarantine after a scoped cut is warm`, `reclaims
  reloadable idle runtimes under pressure`, `bounds cold catalog previews`
  (fixture Buffer/string fault), `discovers oversized active lifecycle headers`).
- Evidence: `npx tsc --noEmit -p .` clean; `npm run build` clean; registry suite
  213/232 (`/tmp/g1c-r13.json`).
- Still owed: the O-5 zero-request-path-walk evidence, the O-6a smoke and the
  `session.list` p99 (orchestrator's quiet-host run); G-1d's doc wording.


### G-1c · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker, review round 4 (branch `hardening/g-1c`)

- Result: **green**. `runtime-registry.integration.test.ts` 232/232 (review
  time: 192/257 with 65 failures), `session-archive.integration.test.ts` 41/41,
  `session-catalog.test.ts` + `catalog-discovery.test.ts` +
  `catalog-metadata-index.test.ts` 91/91. Only the request path's real work
  remains: `session.list` p99 and the O-6a quiet-host run are the orchestrator's.
- Commits this round: `371306fb7` (removed-internals rework + 21 deletions),
  `89c62abc2`, `1f5ce404d`, `c8c97145f` (finish the rework: owner outcomes,
  commit-fence races, T-1 fix, row-facts projection digest), `d187aa3c8`
  (three fixtures wait for the owner's cut), plus round-3 source commits
  `5d38ee986`, `cdb2f2f77`.
- Zero-request-path-walk evidence (Done-when, O-5 counter): the case "counts no
  request-path walk while the reader joins the owner's cut" runs a
  `session.delete` inside a `RequestSpan` with `resources.recordCatalogWalk`
  recorded and asserts **no** request-path walk at all while the owner's own
  passes stay background (`/tmp/g1c-r17.json`). T-1's race case
  ("discovers oversized active lifecycle headers…") uses the documented fix
  (`discoverExtensionArtifactsUntil`).
- Guarantees kept by the 21 deletions (each deleted case → the case that now
  holds, or the reason the subject is gone):
  1. "keeps a live-owned index cut when the owner appends during reconciliation"
     → session-catalog.test.ts's append-to-row cases + "resolves a list, a cold
     open and a hot re-acquire…" (the reader no longer loads the durable index).
  2. "rejects an inode replacement that races durable-index reconciliation"
     → "reads only the admitted file's own header…" + the delete/attention fences.
  3. "retires a durable load invalidated before publication and falls back to a
     fresh canonical cut" → "keeps the published rows through an incomplete pass
     and authorizes nothing destructive" (the load/fallback path is deleted).
  4. "keeps a warmed disk index across live-only create and delete" → "projects
     empty live sessions until deletion, persistence, eviction, or restart" +
     "retains persisted, ambiguous, and live-only artifact owners…".
  5. "coalesces concurrent fallback acquisition scans for one catalog generation"
     and 6. "revalidates oversized SDK identities after fallback resolution"
     → "falls back to stable SDK discovery…" is gone; membership is the index
     ("keeps an unrelated malformed header out of the cut without a fallback
     scan").
  7. "retries lightweight acquisition without stamping invalidated evidence
     current" and 8. "fails busy after a second lightweight acquisition
     invalidation" → the lightweight/fallback loop is deleted; the generation
     fence remains and is covered by "rejects identity, cwd, or duplicate
     mutation before runtime creation".
  9. "cannot republish an acquisition invalidated during full materialization"
     and 10. "rejects a mutation in the final full-catalog publication gap"
     → no publication step remains; the slot-publication generation fence is the
     same case as 7.
  11. "fails busy without publishing after a second unstable full materialization"
     → "keeps the last provable row when an unowned canonical file ends in a
     partial line" (decision 1's rule replaces the busy).
  12. "retains the stable user cut during a real child-session write" → "advances
     user catalog identity when canonical membership changes beside delegated
     rows".
  13. "isolates an unfinished child append from unrelated catalog and cold-open
     reads" → "keeps an unrelated malformed header out of the cut…" and "keeps
     an unprovable artifact out of the index…".
  14. "shares one successor header walk across concurrent post-read validations"
     → "caps canonical session path normalization concurrency" (the owner's one
     pass) + "reads only the admitted file's own header…".
  15. "keeps cold acquisition independent of mutable catalog metadata"
     → "uses only bounded header evidence…" is deleted with
     `validatedStructuralIndex`; cold acquisition reads the owner's rows by
     design.
  16. "coalesces acquisition successors across invalidations until prior physical
     work settles" and 17. "lets user discovery finish while an all-scope scan
     remains blocked and fails" → acquisition has no physical work: "resolves a
     list, a cold open and a hot re-acquire…".
  18. "retires viewer capacity during one shared catalog wait without multiplying
     physical scans" and 19. "serializes an all-scope materialization behind an
     active user flight" → a read either serves the published cut or refuses
     retryably ("bounds recursive catalog directories…").
  20. "acquires from header evidence while a full catalog materialization is
     suspended" → "reads only the admitted file's own header when a cold open
     has no cached admission".
  21. "never stamps captured stale catalog fields with a newer summary revision"
     → the captured-materialization path is deleted; summary revisioning is
     covered by the attention/summary cases.
- Production fixes this round beyond the review blockers:
  - Page-source generations carry a digest of the index-owned row facts
    (`materializeCatalogSnapshot`), so a row field that changes without moving
    `listRevision` (an external rename) moves the projection token instead of
    serving a cached stale page — required by the `projectionToken` contract and
    covered by "refreshes user metadata and duplicate quarantine after a scoped
    cut is warm".
  - `catalog.changed`-driven row changes reach a read only through the owner;
    tests that write canonical files themselves now settle the owner.
- Merge gate (branch `hardening/g-1c`): `npx tsc --noEmit -p .` clean;
  `npm run build` clean; `npx vitest run src/sessions src/transport src/admin
  src/workspace` **1210 passed / 4 failed / 1214**; all four fail only under the
  whole-directory load (`recent-model-usage`, `session-catalog`'s ENOTEMPTY
  cleanup, `transport/logger` rotation, T-1's documented `request-span`
  `durationMs > 100`) and pass when run as their own file
  (`session-catalog` + `logger` + `recent-model-usage` 46/46;
  `request-span` 1/1). `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Not owed by this row: the O-6a qualification smoke, `session.list` p99 and the
  G-1d doc wording.


### G-1c · Done · 2026-09-28 · review round 5 (branch `hardening/g-1c`)

- B1 (unproven file with no kept row was pruned as deleted): a pass that
  cannot prove a file and has no row to keep is no longer a complete cut for
  destructive callers — `hasReconciledCut()` stays false and the pass reports
  `incomplete` with its unproven count — while the rows it *can* prove are still
  published (an unreadable neighbour must not blind the reader). The IDs it read
  are remembered (`unprovenSessionIds`), so `acquire`, `delete` and automation
  admission refuse retryably instead of answering `not_found`; the owner
  re-reads the folder once after `CATALOG_INCOMPLETE_RETRY_MS` (2 s, at most
  three times) so a torn append costs seconds of refusal; `rebuild`'s own
  unproven list is kept (it used to be dropped, hiding the signal).
  Regression: "keeps the records of an unprovable session that has no stored
  row" — archived session, durable document removed, transcript torn; the pass
  reports incomplete, startup recovery keeps the archive record, maintenance
  refuses retryably, `list` serves, `acquire`/`delete` refuse retryably, and
  rolling the append back restores the listed session with its archived state.
- B2 (startup automations failed on the unready catalog): `automations.initialize()`
  runs right after `initialize()` returns, so `requirePersistedUserSession` and
  `automationRecoveryEvidence` now wait for the owner's first pass
  (`whenPublished()` raced with `whenReconciled()`), the scheduler treats a
  `catalog_not_ready` recovery as a deferral (no `outcomeUnknown`, no marker
  clear, a diagnostic instead), and `gateway-main` logs
  `automation.recovery-deferred` and continues rather than aborting startup.
  Regression: "admits an existing-session automation while the first cut runs"
  (`it.each([false, true])`, 200 sessions) and a scheduler case that asserts a
  deferred recovery commits nothing.
- Minor 1 fixed (above). Minor 4 fixed earlier (the deleted `maximumRetainedBytes`
  argument is gone; the Knowledge case is renamed to "after the owner's cut").
  Minor 2 (closed-hook gap) is not fixed: the `closed` hook is synchronous, so
  awaiting the row refresh there needs a hook-contract change — noted for the
  next round rather than patched.
- Residual of the B1 fix, stated for review: a session whose row cannot be built
  from a torn transcript is absent from `list` until a pass proves it. Its
  records, artifact ownership and Knowledge coverage survive, and no caller is
  told it does not exist.
- Checks: `npx tsc --noEmit -p .` and `npm run build` clean; owning suite
  **235/235**; `npx vitest run src/sessions src/transport src/admin src/workspace`
  **1216 passed / 1 failed / 1217**, the failure being `session-catalog.test.ts`'s
  known `ENOTEMPTY` cleanup flake under directory load (29/29 alone).


### G-1c · Done · 2026-09-28 · merge-gate response (branch `hardening/g-1c`)

- The merge gate reproduced the deferred minor 2 as a real regression: "scopes
  extension shutdown to the owning runtime slot" failed intermittently because a
  slot's close queues its catalog row at the commit point, so a reopen could land
  in the window and answer `not_found`.
- Fix: membership for a *named* session now waits for the row work the Gateway
  itself has queued (`SessionCatalog.awaitQueuedChanges()`, the owner's lane) and
  re-resolves before it may report absence. Wired into every read that can name
  one session: `acquire`, `delete`, `setArchived`, attention resolution,
  automation admission and recovery, and `workspaceForSession`. A session cannot
  become unopenable because its runtime closed.
- Evidence: `scopes extension shutdown to the owning runtime slot` **10/10**
  alone; new deterministic case "reopens a session whose runtime closed before
  its index row landed" holds the row build open across the close and fails with
  `not_found` when the wait is removed (negative control run, then reverted).
  Owning suite **236/236**; `npx tsc --noEmit -p .` and `npm run build` clean;
  zone sweep `npx vitest run src/sessions src/transport src/admin src/workspace`
  **1216 passed / 2 failed / 1218**, both failures being the known load-only
  flakes (`session-catalog.test.ts` ENOTEMPTY cleanup and
  `recent-model-usage.integration.test.ts`), each green as its own file (32/32
  together).


### G-1c · Done · 2026-09-28 · merge of `hardening/integration` (branch `hardening/g-1c`)

- Merged `hardening/integration` (76 commits: G-9, G-8c, G-11, E-3a, C-7 and the
  rest). Two files conflicted: this plan (both handoff tails kept) and
  `session-catalog.ts` (five regions).
- Resolutions:
  - `verifiedCut` (G-8c) and `reconciledCut` are one flag: the owner keeps
    `reconciledCut`, set only by a pass this process verified over the whole
    folder and cleared by an incomplete or failed pass, and `searchIdentities()`
    now tests it. G-8c's stricter-than-durable requirement holds, and it is
    stricter still where a pass could not prove every file: a derived reader gets
    `undefined` rather than rows that are not complete membership.
  - `searchIdentities()` still reads the owner's index rows (`rowsByPath`), skips
    delegated and duplicated IDs, and `searchCatalogIdentities()` delegates to it;
    none of G-1c's deleted helpers are referenced.
  - G-9 keeps the periodic pass: `scheduleReconcileInterval()` registers
    `catalog.reconcile` with `backgroundWork`, `stopWatching()` unregisters it,
    and both the reconcile batches and `rebuild` hand the loop back with
    `yieldToLoop()`. G-1c's incomplete-pass re-read stays a bounded one-shot
    (`CATALOG_INCOMPLETE_RETRY_MS`, at most three), not a second periodic timer,
    and its work yields through the same scheduler.
  - G-1c's additions are intact through the merge: the unified cut flags,
    `whenPublished`/`whenReconciled`, `awaitQueuedChanges`, `unprovenSessionIds`,
    `hasUnknownMembership`, `catalog_not_ready`, the automation wait/deferral,
    `SessionCatalogScan.unproven` and `CatalogStructureEvidence.unprovenPaths`.
  - The merge-gate case "projects empty live sessions until deletion,
    persistence, eviction, or restart" polled for the persisted row and timed out
    under whole-directory load; it now applies the owner's commit point itself
    (`refresh(persistedSessionFile)`), which is deterministic. The hook that
    fires that change stays covered by "resolves a list, a cold open and a
    hot re-acquire from the owner's rows without a walk".
- Evidence: `npx tsc --noEmit -p .` and `npm run build` clean; merge gate
  **363/363** over `runtime-registry.integration`, `session-archive.integration`,
  `session-catalog`, `catalog-discovery`, `catalog-metadata-index`,
  `session-search-service`, `session-search-index`, `session-search-stall` and
  `background-work`; owning suite **237/237**; zone sweep
  `npx vitest run src/sessions src/transport src/admin src/workspace`
  **1250 passed / 2 failed / 1252**, both failures load-only
  (`transport/logger.test.ts` 40 MB rotation; `session-search-stall.test.ts`
  event-loop bounds, 2/2 alone three times).

### Orchestrator · 2026-09-28 · baseline timing

- Decision: the `main` baseline and the release-candidate numbers are measured
  back to back at R-1, alternating `main` and candidate runs on the same host
  in the same window, so both columns see the same conditions. The worktree
  for the `main` runs is `main` plus the O-6a/O-6b profiler scripts (protocol
  5 driver). The provisional column stays until then.

### T-4 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/t-4`)

- Result: the killer is the test runner itself, not another worktree's run.
  - No overlap: `20260928T203739Z-run.InevV5` (recorder + log export, crashed)
    and `20260928T203326Z-run.VIQPj2` (five suites, crashed) had no other run
    open on the simulator in either direction — checked against every
    `summary.json` start/finish in `~/Library/Developer/Tron/ios/test-runs`
    (2,380 runs). T-2's contention finding applies to
    `20260928T160853Z-run.0UFrCv`, not to this pair.
  - The simulator log for the crash window shows the host ending the test host
    0.02 s after xcodebuild began a new test session:
    `SpringBoard: Request received from CoreSimulatorBr.96766 to terminate
    application com.tron.mobile.testhost: "Termination requested by simulator
    host"` → `Executing termination request … Force Quit (0xFBFBFBFB)` → the app
    is SIGKILLed, and XCTestCore reports `Test crashed with signal kill.` plus
    `Restarting after unexpected exit, crash, or test timeout`.
  - XCTestCore owns that restart string and the per-test allowance that causes
    it (`Test Case '%@' exceeded execution time allowance of %@`,
    `XCTestConfiguration.activeTestConfiguration.testTimeoutsEnabled`,
    `com.apple.dt.xctest.timeoutQueue`). The kill lands ~30 s into whichever test
    is running; here that is always `byteEnvelopeReservesTheChatTrace`, the
    process's CPU-heaviest test, at 29.4/29.5/30.6 s of test time in the three
    runs measured against their xcresult durations.
  - That test spent 8.6-10.3 s in `GatewayLogExport.jsonLines`, and all of it in
    one pattern: `IOSClientDiagnosticBuffer.redactedMessage`'s
    `[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+` retries the greedy scheme run from
    every start position, so one unbroken run of scheme characters costs
    super-quadratic time before it can fail on a missing `://` — measured on the
    host 3.257 ms at 512 characters, 18.4 at 1,024, 63.4 at 2,048, 653.7 at
    4,096, once per field per row. Diagnostics carry exactly such runs (a base64
    token, a hash, a parameter value), so this is a production cost, not a test
    artifact: `AppModel.exportDiagnostics` redacts up to 1,000 rows on the main
    actor.
- Changes: `packages/ios-app/Core/Support/IOSClientDiagnostics.swift` only.
  `redactURLs` walks the scheme runs and offers the pattern only the windows a
  match can start in (first letter of a run followed by `://` and a non-empty
  body); the pattern still decides the match, so the three other patterns, the
  redaction semantics and the byte bounds are unchanged.
- Failure modes this isolated change covers (written before the code):
  1. cost grows with the square of a long unbroken token/hash/base64 message;
  2. a window anchored at the wrong start or end drops, shortens or duplicates a
     redaction;
  3. a whitespace or delimiter class divergence from the pattern changes what is
     redacted;
  4. a second URL later in one token is skipped by the match cursor.
- Evidence:
  - Equivalence: a standalone port of both forms over 20,247 inputs (44
    hand-written shapes plus 20,200 random strings from an alphabet of scheme
    characters, `://`, delimiters, quotes, angle brackets, `\v`, a combining
    mark and non-ASCII) → 0 differences. Cost, same host under load and quiet:
    1 KiB letter run 73.709 → 0.212 ms and 8.977 → 0.024 ms, 800-byte trace row
    1.390 → 0.220 ms and 0.164 → 0.030 ms, 4 KiB letter run 1183.902 → 0.665 ms
    and 130.893 → 0.088 ms.
  - iOS: `GatewayLogExportTests` + `GatewayConnectionEpisodeRecorderTests` +
    `GatewayDiagnosticsServiceTests` + `ChatInteractionTraceTests` 49/49 twice
    (`20260928T212300Z-run.CNDzIZ`, `20260928T212334Z-run.6281OA`), 11.074 s and
    10.997 s total, with `byteEnvelopeReservesTheChatTrace` at 0.072 s and
    0.073 s (it was 8.646-10.297 s in every retained bundle). The same four
    suites pass twice on the merged branch at this commit on lane CT22
    (`20260928T213843Z-run.aIjlev`, `20260928T213916Z-run.CdUiY8`: 49/49, 10.961 s
    and 11.102 s, byte-envelope 0.080 s and 0.074 s); the default lane was held
    by another worktree's run, so the paired-on-default-lane re-run is the only
    one not repeated after the merge.
  - Flake context: the same pair passed on the shared default lane before the
    fix (`20260928T211803Z-run.AA7EP2`, 21/21, byte-envelope 8.646 s), and on
    lane CT22 (21/21 and 83/83). All six c-1 "signal kill" failures fall between
    20:10 and 20:37 UTC, the hour when several worktrees were building and
    running at once: three were this pair alone and three a five-suite set that
    contains it. That is the contention that stretched a 9 s CPU-bound test past
    the allowance; the fix removes the CPU-bound half of the exposure (the
    remaining multi-second test is wall-clock `Thread.sleep`).
  - Gateway gate after merging `hardening/integration`: the six transport
    integration files 132/132, `runtime-registry.integration.test.ts` 258/258 on
    a re-run (the first attempt read 257/258 from one unrelated flake),
    `npx tsc --noEmit -p .` clean.
- What is left (the next agent, not this one):
  1. The recorder suite's `blockedMainActorIsMeasuredAndReported` is now the
     process's only multi-second test (10 s of `Thread.sleep` wall clock, T-2's
     `mainStallTestBlock` twice). Unlike the fixed export it does not grow with
     host load, so no allowance change is owed.
  2. Any other diagnostics-shaped surface that redacts long field values should
     use `redactURLs` rather than the bare pattern; `IOSClientDiagnosticBuffer`
     is the only caller today.

### C-2 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/c-2`)

- Result: a live socket is never labelled **Reconnecting** and a mounted
  restoration reports itself through the chat's own catch-up treatment instead.
- Changes: `packages/ios-app/Sources/State/GatewayLifecycleCoordinator.swift`
  (one assertion-bearing test only; C-1 had already removed the post-handshake
  `.reconnecting` assignments, and the C-2 label invariant is now protected by
  tests), `packages/ios-app/Sources/State/SessionPresentationStore.swift` (the
  restoring chat's identity, its grace and the catch-up treatment scoped to and
  retired against it),
  `packages/ios-app/Tests/Gateway/AppModelReconnectTests.swift`,
  `packages/ios-app/Tests/UI/MountedRestorationLabelHostedTests.swift` (new),
  `packages/ios-app/docs/architecture.md`.
- Result detail: `SessionPresentationStore` now owns restoration as its own
  loading state. `reconnectMountedPresentation()` captures the mounted chat it
  is restoring, and a restoration that outlasts
  `mountedRestorationTreatmentGrace` (2 s, the same
  shape as the outage copy's delay) shows the chat's existing catch-up notice
  (`sessionCatchUpNotice`, "Live session view is catching up; the run continues
  on your Mac.") **in that chat's own scope**, and only while that chat is still
  the mounted one with no open pending. A restoration that completes inside the
  grace shows nothing.
  Success and failure keep the outcomes the synchronization owner already
  publishes (success removes the notice, failure replaces it with "The
  conversation could not catch up…", and Manage Session keeps the Retry
  Conversation surface for a failed mounted sync while connected); a restoration
  that ends without such an outcome retires its own treatment, whether it was
  cancelled, superseded by another chat or connection generation, or interrupted
  by the transport's loss. A newer restoration supersedes an older one's cleanup by
  owner generation, so a late finish cannot clear the state the chat is showing.
- Failure modes written first (C-2's list, mapped): a slow `session.open` after
  a replacement handshake (the label and the treatment in
  `slowRestorationKeepsConnectedLabel` and the hosted test); the socket dying
  during a restoration (`slowRestorationDoesNotParkRecovery` now also asserts the
  live-socket `.connected` before the drop and `.reconnecting` at once after it);
  restoration failing while the socket lives (existing
  `mountedRestoreFailureKeepsTransport`, `AppModelEventTests.resyncFailureHasScopedRecovery`
  for the retry surface); leaving the chat and opening another chat while the
  notice timer is pending (`leavingChatInsideRestorationGraceDropsTheTreatment`,
  `openingAnotherChatInsideRestorationGraceDropsTheTreatment`, added in review
  round 1); profile switch and background during restoration
  (existing `AppModelLifecycleTests` / `enteredBackground` cancellation of the
  deferred projection).
- Evidence: `scripts/tron-ios-test build` succeeds;
  `scripts/tron-ios-test run --only-testing TronMobileTests/AppModelReconnectTests`
  passes 46/46 (the file's 45 plus the new case);
  `SessionPresentationStore.swift` and the tests are byte-for-byte the sources
  that produced both runs, with the negative-control edit reverted;
  `scripts/tron-ios-test run --only-testing TronMobileTests/MountedRestorationLabelHostedTests`
  passes 1/1 in 0.081 s with its `mounted-restoration-connected-label` capture in
  the run's `TestResults.xcresult`.
- Checks: the hosted case mounts the production `GatewayConnectionStatusBadge`
  over the production `AppModel` while the replacement's `session.open` is
  unanswered, asserts the socket is live (`client.activeConnectionID()`), and
  asserts the badge's own input (the production
  `dashboardServerState(for:)`) reads **Connected** at every step — before, during
  and after the restoration — plus the catch-up notice while it runs and its
  absence once the answered restoration completes. SwiftUI paints `Text` without
  `UILabel` in this version, so the rendered label is the capture, not an
  assertion; the assertion is on the exact state the badge draws.
- Deviations: `slowRestorationKeepsConnectedLabel` drives the real AppModel
  through `enteredBackground()` → `becameActive()` → replacement hello with the
  `session.open` held, and advances the injected `ManualClock` past the grace
  rather than waiting 2 s of wall clock. No new UI: the treatment is the chat's
  existing `sessionCatchUp` notice, and the state is published by its owning
  store. C-1's `GatewayLifecycleCoordinator` test needed one assertion added; no
  coordinator source change was left to make, because C-1's merge already ends
  the replacement attempt at event activation.
- Negative control (the catch-up treatment post removed, everything else
  unchanged): the hosted case fails 1/1 in 3.4 s and the AppModel case fails on
  the missing notice in 2.5 s while its label assertions still pass, which is
  what C-1 already fixed; the edit was then reverted, rebuilt and re-run green.
  Neighbour suites in one run (retained at
  `~/Library/Developer/Tron/ios/test-runs/20260928T210956Z-run.9NShry`):
  `SessionPresentationStoreTests`, `AppModelEventTests`, `AppModelCatalogSyncTests`,
  `AppModelLifecycleTests`, `AppModelReconnectTests`,
  `MountedRestorationLabelHostedTests` — 182 tests, 182 passed, 0 failed. One
  earlier attempt was refused because another worktree held the shared default
  lane (T-3); nothing was taken by force.
- For the next agent: C-3 follows in the same zone (backoff and the split
  transport-open deadline); do not merge `hardening/integration` into this
  branch without re-running the two suites above, since the plan file is the
  only expected conflict.

#### C-2 review round 1 (changes-required) — 2026-09-28

- Fixed: the grace timer posted the catch-up notice through `noticeScope`
  (`pendingTarget ?? target`), so leaving the chat posted it app-wide and
  opening another chat posted it into that chat, and nothing removed it when the
  restoration ended without a latched failure; the published
  `isRestoringMountedPresentation` had no reader. The timer now requires the
  restoring chat to still be mounted with no open pending, posts with
  `noticeScope(for: target)`, and `finishMountedRestoration(owner:restored:)`
  removes the treatment in that captured scope unless the store latched a
  failure for the same target. `isRestoringMountedPresentation` is deleted;
  `packages/ios-app/docs/architecture.md` no longer names it.
- Evidence: `scripts/tron-ios-test build --lane C2R` succeeds; one run of
  `AppModelReconnectTests`, `MountedRestorationLabelHostedTests`,
  `SessionPresentationStoreTests`, `AppModelEventTests`,
  `AppModelCatalogSyncTests` and `AppModelLifecycleTests` passes 183 Swift
  Testing tests in 5 suites plus the 1 XCTest, retained at
  `~/Library/Developer/Tron/ios/test-runs/20260928T215653Z-run.2qXI8r`.
  Negative control (the two guards reverted to the reviewed revision): both new
  cases fail on the leaked `.sessionCatchUp` notice; the edit was reverted,
  rebuilt and re-run green.
- Deviations: the plan's "profile switch during restoration" case is still
  covered only by the route-change cases above; no profile-switch test holds the
  notice timer pending.

### G-2 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-2`)

- Result: measured what fills a cold `session.open` from the O-3 spans and
  removed the one whole-branch cost the snapshot projection still carried. For
  a 200 MB session the open is the JSONL parse (45–56%,
  `session.open.manager`), the SDK runtime create (22–28%,
  `session.open.runtime`) and the bounded snapshot projection (19–24%,
  `snapshot.build`); the three candidates G-2 named — registry mutex, idle
  eviction, fork-boundary parent reads — are not the cost (`session.open.catalog`
  3–13 ms from the index, no lane wait, no parent read for a top-level session).
- Parse share (reported separately, as the task asks): the pinned SDK's
  `loadEntriesFromFile`/`parseSessionEntryLine` runs inside
  `session.open.manager` and is 45–56% of every slow open measured
  (3,936/8,034; 2,496/5,492; 3,985/8,034; 2,677/4,782 ms). It is not
  Gateway-owned and is not reducible without an SDK change; the target is met
  with it in place.
- Evidence for "Done when" (cold p99 ≤ 1.5 s for sessions up to 200 MB):
  - `scripts/tron-profile gateway --scenario multi-session --no-build
    --iterations 1 --cases none --catalog-files 100 --catalog-mib 2048
    --mixed-seconds 40` — this catalog's five large sessions are
    104,876,508 / 131,076,142 / 157,297,276 / 183,508,419 / 209,721,307 B
    (`catalog.json` `largeBytes`), so the largest is exactly 200 MiB.
    `latency.session_open_cold_large` (largest first, seconds×1000):
    **951 / 857 / 671 / 483 / 412 ms** at 1-minute load **56**
    (`20260928T215040Z-multi-session-1b30cf`), and **494 / 446 / 366 / 369 /
    266 ms** at load **10** (`20260928T221024Z-multi-session-957a94`). Both
    runs hold the target with margin; the between-run difference is the host
    load and is not claimed as this change. Warm opens ≤ 1,025 ms in the loaded
    run (35 ms in the quiet one), `session.list` ≤ 751 ms / ≤ 13 ms.
  - Copy of report, catalog, per-iteration samples, prime result and the
    extracted O-3 `session.open` spans for those runs:
    `~/.tron/workspace/files/hardening/g-2/`.
  - O-3 span source for the composition split: a third smoke at
    `--catalog-mib 3072` (150–300 MiB files) whose opens cross the 1,000 ms
    `rpc.completed` warning threshold, so the fixture log carries the stage
    breakdown (`20260928T220150Z-multi-session-e8c752`, run at load 22):
    `session.open.manager` 45–56%, `session.open.runtime` 22–28%,
    `snapshot.build` 19–24%, `session.open.catalog` 3–13 ms,
    `response.encode` ≤ 19 ms, `attention.reconcile` 2–58 ms.
  - The change itself, measured on the removed work: on a 100,000-entry branch
    with no delivery or invocation receipt — the shape of the qualification
    catalog, where a snapshot projection still built three whole-branch index
    maps per build — `contextDeliveryMetadataByEntry` falls **12.4 → 0.42 ms**
    and `invocationReceipts` **6.7 → 0.4 ms** (median of 5, one-off script
    `~/.tron/workspace/files/hardening/g-2/g2-alloc-measure.mjs`, Node 25.9.0; ≈19 ms of synchronous whole-branch
    work per snapshot gone, the removable part of G-11's 62 ms
    `projectTranscriptPage` stretch).
  - Merge gate after merging `hardening/integration` at `5ccc7a009`:
    `session-archive` + `server-capacity` + `sync-protocol` +
    `stall-diagnostics` + `server-heartbeat` + `server-http-lifecycle`
    integration/unit files **132/132**, `runtime-registry.integration.test.ts`
    **237/237**, `npx vitest run src/sessions/projection.test.ts
    src/sessions/invocation-receipts.test.ts` **85/85**,
    `npx tsc --noEmit -p .` clean, `npm run build` clean,
    `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass. Re-run after merging E-3b at
    `c70ccb4df` (final merge `ec1c3f8f5`): the same six files plus
    `lan-endpoint.integration.test.ts` **144/144**, and
    `runtime-registry` + `projection` + `invocation-receipts` **322/322**;
    `tsc --noEmit` clean. After the validation-once half landed, all ten files
    together are **466/466**. E-3b does not touch the measured cold-open path, so
    the smoke numbers above stay as measured.
  - Negative control for the new case: reverting the single-validation
    refactor in `projectableTranscriptEntries` (back to parsing the receipt once
    for the refusal and again for use) leaves it green, and deleting the refusal
    makes `refuses a malformed invocation receipt while projecting a branch`
    fail.
- Changes: commit on `hardening/g-2`: `projection.ts` (validate each invocation
  receipt once per entry instead of twice), `context-delivery-receipts.ts` and
  `invocation-receipts.ts` (skip building the whole-branch index maps when the
  branch holds no receipt of that type), `projection.test.ts` (the missing
  malformed-receipt refusal case), this plan.
- Tasks added: none. **Deviation the orchestrator should record under O-6a:**
  on `hardening/integration` the multi-session prime failed on the first
  attempt — a fresh fixture answers the prime's `session.list` with a retryable
  `busy` (`catalog_not_ready`) until the catalog owner publishes its first cut,
  and the driver did not retry it (24 such records, run
  `20260928T214631Z-multi-session-00d238` exited 1 at prime). `G-1c` made that
  refusal deliberate, so the prime now retries it like every other read the
  driver times (`scripts/tron-profile-gateway-driver.mjs`, the Profiler zone);
  without it no O-6a smoke can run on a generated catalog whose first cut takes
  longer than pairing.
- Kept on purpose: the parse (the SDK's, above); `session.open.runtime`'s agent
  runtime create (the SDK's `createAgentSessionRuntime`/extension binding, G-11
  measured its module compile as not Gateway-owned); `projectTranscriptPage`'s
  remaining O(branch) classification walk (it produces `total`, the page
  boundaries and each row's invocation/delivery semantics, so it is not
  removable by slicing); `attention.reconcile` on the open path (≤58 ms).
- Deviations: the smoke catalog is 100 files, not 3,000: the large-session sizes
  scale with `--catalog-mib`, so a 100–200 MiB large session is only reachable at
  the 2,048 MiB reference total. A cold open reads the index for membership and
  one header, so the file count does not enter its cost. The driver retry above
  is outside G-2's owning files and is here only because the evidence needs it.
- For the next agent: the O-6a quiet-host repeat should run
  `--catalog-files 100 --catalog-mib 2048 --iterations 3` and read
  `latency.session_open_cold_large.p99`; on a host above load 20 a 200 MiB open
  moves by seconds, so compare runs at similar load only.

### G-13 · Blocked · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-13`)

- Result: the Gateway names its startup budget and the restart case reads and
  judges it, with G-13's criterion reported beside the numbers.
  - **Budget.** `gateway.startup-budget` is recorded the moment the Gateway
    serves: process start to listening against `STARTUP_LISTEN_BUDGET_MS`
    (5 s; `packages/gateway/src/lifecycle/startup-budget.ts`), info inside the
    budget and warning past it, with the step that owns most of the time. The
    constant is set from the measured `gateway.startup-step` records (about 1 s
    quiet, 4.0–4.6 s on the qualification catalog under load), and the reason is
    the phone's own retry schedule: its clients retry about 2 s and again about
    5.4 s after their socket closes, so a slower start costs a whole backoff step.
  - **Case.** `FixtureGateway.restart` reads the new process's own
    `gateway.startup-step` records from the offset the restart began at and the
    profiler reports `impairment.restart.startup_ms`; the driver carries the
    budget into the leg. `restart_criterion_warnings` states a missed criterion
    with its numbers — slowest reconnect over 10 s, a served storm request over
    1 s, a start over budget, or no budget read at all — and deliberately does not
    reject the run: a busy host slows the start itself, and `validate_impairment`
    already owns what a case proved it measured.
- Evidence (short runs, 200-file/32 MiB catalog, `--cases restart --no-build`;
  this host at 1-minute load 26–50, so the host is the storm's dominant cost):
  - Before (integration + G-1c/G-1b/G-9), report
    `20260928T214555Z-multi-session-b3c70e`: downtime 7,168 ms, slowest reconnect
    **15,187 ms**, 1 storm request over 1 s, p99 1,160 ms. The new process's own
    records: `modules` 4,460 ms of a 4,605 ms start; the old process's shutdown
    2,165 ms of which `work-settle` was 1,999 ms (the 2 s cleanup grace expiring
    with 8 owned operations outstanding).
  - After, report `20260928T220215Z-multi-session-941b6c`: `startup_ms` 6,257
    (steps named: `modules` 5,529 ms), slowest reconnect 13,215 ms, **0 storm
    requests over 1 s** (p99 849 ms). Its warnings state exactly both misses. The
    reconnect misses on this host because the start is host-bound — 5.5 s of the
    6.3 s is the module graph under load, against 0.38 s on the user's quiet
    machine — so the clients' third attempt (about 5.7 s) meets a Gateway that is
    still importing and pays the 5.8 s backoff. The same run's own records show
    the contrast: its priming starts were 1,235 ms and 1,029 ms (info, budget
    met), the restart 6,258 ms (warning) during the host's load spike, and the
    production record is in that run's `fixture/gateway.jsonl`. Quiet-host
    confirmation is the orchestrator's, like the rest of the plan's measured rows.
  - Checks: `npx vitest run src/lifecycle/startup-budget.test.ts` 4/4;
    `python3 scripts/test-tron-profile.py ImpairmentCases MultiSessionSamples`
    12/12; `python3 scripts/test-tron-profile.py
    MultiDriverImpairment.test_the_restart_case_reports_the_new_startups_budget`
    1/1; build and `tsc --noEmit` clean.
- Changes: `packages/gateway/src/lifecycle/startup-budget.ts` (+ test),
  `packages/gateway/src/gateway-main.ts`,
  `packages/gateway/docs/observability.md`, `scripts/tron-profile-gateway`,
  `scripts/tron-profile-gateway-driver.mjs`, `scripts/test-tron-profile.py`.
- Deviations: the case reports the criterion rather than failing the run, so one
  host's slowness cannot reject the whole qualification (the run only rejects a
  case that measured nothing). The reconnect target is not demonstrated here.
- Proposed rows for the orchestrator (not touched by this task):
  1. A restart with running sessions pays the old process's whole 2 s
     `work-settle` cleanup grace before it exits, so the new process starts 2 s
     later (measured 1,999 ms of a 2,165 ms shutdown, 8 owned operations). A
     shorter restart-mode grace is a shutdown-semantics decision, not a startup
     budget one.
  2. Each storm reconnect spends 0.7–1.2 s in the upgrade's `auth` stage on this
     host (six upgrades serialized by `DeviceStore`'s credential mutex, one
     devices-file read each), which is what the driver's ready sequence waits on
     after `connectUntilReady` succeeds.
- Left: the quiet-host run of the full qualification, and R-1's exit-criterion
  row for the restart.

#### G-13 review response 1 (changes-required) — 2026-09-28

- Status corrected: the entry above claimed Done, but the task's "Done when"
  (every client reconnecting within 10 s, no request over 1 s) was not met by
  its own after run (slowest reconnects 13.2, 12.2, 12.0, 11.8 and 13.1 s), and
  the change measures and reports the restart rather than moving it. G-13 is
  **Blocked** until the two causes above have rows or a quiet-host R-1 run
  meets the criterion; nothing here claims the criterion.
- The startup budget no longer claims to bound the clients' wait. The
  Gateway's `gateway.startup-budget` record is this process's own start
  (unchanged constant, 5 s, corrected reason: the clients count from their own
  socket's close, before the predecessor is down). The profiler now judges the
  span they do wait: the predecessor's `gateway.stopped` start (timestamp less
  `durationMs`) to the new `gateway.listening`, budget
  `RESTART_CLOSE_TO_LISTENING_BUDGET_MS` (4 s; the third retry comes 5.4 s after
  the close, as early as 4.3 s with its ±20% jitter). The before run above shows
  why the old check could not see that: its 4,605 ms start (logged "budget met")
  came with a 15,187 ms slowest reconnect. The rewritten fixture case asserts the
  clients' span (7,120 ms of close → listening beside a 5,660 ms start).
- The profiler reads the Gateway's own `gateway.startup-budget` record instead
  of re-summing rounded step records, so the budget constant has one owner; the
  reader walks the log's segments newest-first, so a 5 MB rotation inside the
  restart neither loses the record nor splits it. `fixture.startup` is read
  directly (no test-only `getattr`).
- Docs: `gateway.startup-budget` in `packages/gateway/README.md` and the new
  `impairment.restart.close_to_listening_ms` in its impairment list, plus that
  the restart criterion is reported rather than enforced; the
  `packages/gateway/docs/observability.md` row's reason corrected.
- End-to-end (this host, 1-minute load 25.3, so still not the quiet run the
  row wants): `scripts/tron-profile gateway --scenario multi-session --cases
  restart --iterations 1 --catalog-files 200 --catalog-mib 32 --no-build`, run
  `.../profiles/gateway/20260928T223130Z-multi-session-f3a999`. The reader took
  the real record (`startup_ms` 4,598, the record's own `budgetMs` 5,000,
  `modules` 4,011 ms) and the report carries
  `impairment.restart.close_to_listening_ms` 6,987 against `reconnect_ms_max`
  12,911 and one request over 1 s. The Gateway logged that start as "budget
  met" — the reviewed warning would have stayed silent on exactly this storm;
  the case now says: "the new Gateway was listening 6987 ms after the clients'
  sockets closed, over its 4000 ms budget ... (its own process start was
  4598 ms of the 5000 ms it records; slowest step modules at 4011 ms)".
- Evidence: `python3 scripts/test-tron-profile.py ImpairmentCases
  MultiSessionSamples
  MultiDriverImpairment.test_the_restart_case_counts_the_storm_from_the_restore
  MultiDriverImpairment.test_the_restart_case_reports_the_new_startups_budget
  MultiDriverImpairment.test_a_capped_legs_close_keeps_every_other_leg_and_the_restart`
  15/15 (44 s); the two rewritten profiler cases fail against the reviewed
  revision (stash check) and pass after; the merge gate on this branch with
  `hardening/integration` merged (132 + 241 tests) and `tsc --noEmit` clean.
- Deviations: no code change aims at the two causes above, so the criterion is
  still not demonstrated; the quiet-host run remains the orchestrator's.

### E-3c · Blocked · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3c`)

- Result: the phone-side race, the pinned trust and the fallback are built and
  covered by focused tests; the task is **not Done**. `GatewayClient` now dials
  the profile's advertised LAN lane first (with its pin) and the saved Tailscale
  lane after `LAN_RACE_STAGGER` (250 ms, `GatewayClient.lanRaceStagger`) unless
  the LAN lane's hello already completed; the first authenticated hello wins,
  every losing lane is closed before it can carry work (including one that
  opened while the winner was taken), a reconnect races both lanes at once
  (liveness loss never waits the stagger), a lane that carried this network path
  skips the stagger next time, and a LAN dial the system reports as "not
  connected" while Tailscale reached the Mac marks the install's Local Network
  permission denied (`GatewayLanPermissionRecord`, `gateway.lan-permission-denied`)
  and stops dialing the lane. `GatewayLanPin.admitsServerTrust` is the pinned
  lane's whole TLS evaluation (the challenge is cancelled on a pin mismatch,
  during the handshake and before URLSession writes the credential-bearing
  request); an unpinned lane keeps the platform's own evaluation. Losing lanes
  are recorded, and the winning hello records `transport=lan|tailscale`
  (`GatewayHandshakeDiagnostic.transport`, `packages/ios-app/docs/events.md`).
- Evidence: `scripts/tron-ios-test build` clean; `scripts/tron-ios-test run
  --only-testing TronMobileTests/GatewayClientLanLaneTests --only-testing
  TronMobileTests/GatewayClientTransportTests --only-testing
  TronMobileTests/GatewayProtocolContractTests` 89/89 including the six new LAN-lane
  cases (the LAN lane wins before the staggered lane dials and only the LAN dial
  carries the pin; a LAN lane that never answers is retired and the saved endpoint
  wins after >= 250 ms; a reconnect dials both lanes in < 200 ms; a lane this
  network already carries skips the stagger; a pin-refused lane is named
  `lan_pin_mismatch`, its socket sent nothing, and the lane that carried the
  attempt is the one whose dial holds the credential; a recorded denial is not dialed
  again), and the shared-fixture case now also asserts
  `admitsServerTrust` admits the fixture certificate for its pin and refuses
  another. `scripts/tron-ios-test run --only-testing
  TronMobileTests/GatewayClientLanLaneTests ... AppModelReconnectTests
  GatewayDiagnosticsServiceTests` 155/155; `DashboardStateOwnerTests`,
  `AppModelLifecycleTests`, `GatewayLogExportTests`, `AppModelEventTests`,
  `AppModelPairingAttemptTests` 122/122.
- Deviations: (1) Do item 3 ("HTTP routes use the winning endpoint for that
  epoch") is **not implemented**: live-view, media/blob and upload routes still
  address `profile.httpURL`, so a LAN-won epoch reads HTTP over Tailscale. The
  `BoundedHTTPDataTransport`/upload/file transports have no pin plumbing yet, so
  routing them over the LAN lane would fail TLS closed; that work plus its pin
  plumbing is the remaining half of the item. (2) The two-leg E2E cases are
  **not written**: `scripts/ios-gateway-e2e-test` still runs its single loopback
  proxy leg, so the "Tailscale leg blackholed 90 s -> no visible disconnect" and
  "LAN leg blocked -> Tailscale wins within the stagger plus one handshake" cases
  have no harness yet. The lane's advertisement is the Gateway's own bind, so a
  controllable second leg needs either a TLS+WS fixture proxy that injects the
  advertisement (and computes a pin over its own certificate) or a Gateway
  fixture seam for the advertised address; both are harness work this budget did
  not reach. (3) `AppModelReconnectTests`' maintenance-restart-watchdog case
  advanced the manual clock on an ambiguous signal (two 90 s sleeps, the restart
  watchdog and no ordering guarantee that the reconnect loop had parked first);
  the faster lane-close path exposed it and it is now fenced on the loop's own
  `reconnect.delay` record before the advance. No production behavior changed for
  that test.
- For E-3d: **do not enable the LAN endpoint by default on this evidence.** The
  two E2E cases E-3d's own text requires have not run; the focused tests prove
  the race's decisions, not a live 90 s Tailscale blackhole or a blocked LAN leg.
- For the next agent: the seams are `GatewayClient.dialPlan(for:)` (lane
  eligibility: Wi-Fi, a pin, an endpoint, not denied), `raceLanes`/`attemptLeg`
  (per-lane dial and retirement) and
  `GatewaySocketFactory.makeConnection(_:pin:)`/`BoundedURLSessionDataLoader.load`
  for the HTTP pin. The winner's route is not kept client-side: the HTTP item
  adds its own winning-endpoint base.

### E-3c · Blocked · review fixes · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3c`)

- Result: the four major findings of the review and the cheap minors are fixed;
  the task stays Blocked (item 3 and both E2E cases still open).
  (1) The attempt reports a lane's *answer*, not the last lane to end: a Mac
  refusal (401/403/503), a pin refusal or a protocol/identity mismatch from any
  lane outranks a transport failure, so a revoked device the LAN lane refuses
  with 401 reaches `unauthorized` instead of retrying the saved lane's timeout;
  the LAN record maps an upgrade failure through the shared classifier instead
  of `lan_unreachable`.
  (2) The stagger is skipped only when the *saved* lane is the one this network
  carried; a remembered LAN win keeps the LAN first with a 250 ms head start
  (50 ms on a reconnect), an equal finish in a no-head-start race goes to the LAN
  lane, and a race that never learned why the LAN lane lost cannot overwrite a
  remembered LAN win.
  (3) The denied Local Network permission is detected from state production has:
  the app's path monitor writes `NWPath.unsatisfiedReason == .localNetworkDenied`
  into `GatewayLanPermissionRecord` (a later reading clears it), and the pinned
  lane dials with `waitsForConnectivity = false` so a blocked lane fails inside
  the connect budget; both paths record `lan_denied` once per launch.
  (4) The `gateway.connection` row names `transport-race`, `transport=lan|tailscale`
  and the three LAN reasons, and the path-snapshot comment no longer claims it
  never gates a connection.
  Minors: the reported failure's record is the newest one (so
  `latestHandshakeDiagnostic` and `gateway.attempt` read the reported lane), the
  staggered lane wakes as soon as the lane ahead fails, a single-route attempt
  records no `transport` and a `hello-receive` failure infers an opened socket,
  the unused `currentRoute`/HTTP-route-base scaffolding is deleted, and an attempt
  owns its lane sockets so `close()` and `retireForBackground()` end a handshake
  in flight. Rejected: none.
- Evidence: `scripts/tron-ios-test build` clean; `--only-testing
  TronMobileTests/GatewayClientLanLaneTests` (15 cases, including the LAN-401
  race, the remembered-LAN head start, the equal-finish tie, the monitor-reported
  denial and the close that ends an in-flight lane) with `GatewayClientTransportTests`,
  `GatewayProtocolContractTests`, `AppModelReconnectTests`,
  `GatewayDiagnosticsServiceTests`, `DashboardStateOwnerTests` and
  `GatewayPairingTransportTests` 236/236 (`20260929T082003Z-run.2DdkCd`). The pin test
  now fails the pinned dial the way production does (`URLError.cancelled`, the
  socket's own cancelled trust challenge) instead of an injected
  `.serverCertificateUntrusted`. `scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- What is left: item 3 (HTTP routes on the winning endpoint) and the two E2E
  cases, unchanged from the entry above. The denial is now reachable in
  production (the path monitor's `unsatisfiedReason` and a pinned dial that fails
  as not connected) but was not observed on a device in this session; the
  E2E/device run is still what proves it. `AppModelPerformanceSignpostTests`'
  "presentation open and authoritative resync close distinct intervals" is a
  pre-existing flake under load: it failed 1/3 in a six-suite run on this branch
  both with and without these fixes, and passes alone.

### E-3c2 · Blocked · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3c2`)

- Result: E-3c's two-lane E2E cases are built and pass against the fixture
  Gateway's own pinned LAN listener; item 3 (HTTP routes on the winning lane)
  is **not done**, so the row is Blocked, not Done.
  `scripts/ios-gateway-e2e-test run-lan` renews the fixture with the lane on
  (`TRON_GATEWAY_LAN_ENDPOINT=on`, also preserved across the proxy's
  `restart-gateway`) and runs one new case,
  `TronMobileTests/RealGatewayPiBoundaryTests.testRacesLanAndTailscaleLanes`,
  which pairs through the existing fault proxy and then dials production code
  end to end: the advertised endpoint and pin come from the pairing response
  (E-3b), the lane's own TLS certificate, WebSocket and hello carry the
  connection, and the pin is checked by the socket's trust evaluation.
  Its four legs: (1) a Wi-Fi phone's handshake transport is `lan` (the fixture
  advertised `192.168.4.24:53058`); (2) the saved lane blackholed at the fault
  proxy for 90 s left that connection up - the leg answers `system.info` every
  5 s through the blackhole (18 requests), keeps one successful handshake and
  records no `helloReceive` failure; (3) a blocked LAN lane
  (`127.0.0.1:<free loopback port>`) fell back to `tailscale` within the
  250 ms stagger plus one handshake (the leg asserts < 1.75 s) and the attempt
  recorded the LAN lane it lost; (4) a profile pinned to a value the served
  certificate does not match produced `lan_pin_mismatch` with
  `handshake.transportOpened == false` while the saved lane carried the
  connection, so no credential-bearing upgrade was written.
- Evidence: `scripts/ios-gateway-e2e-test build` clean;
  `scripts/ios-gateway-e2e-test run-lan` green in 106 s (status 0), case passed
  in 91.6 s. Retained artifact:
  `.../tron-ios-gateway-e2e-501/results/20260929T084513Z-run.yMXeBw/FocusedE2E.xcresult`
  (`summary.json`: passedTests 1, failedTests 0, skippedTests 0) plus the
  per-attempt `test.log` in the same directory. The unchanged boundary test
  also re-ran green on this branch with the lane off
  (`scripts/ios-gateway-e2e-test run`, `testStreamsReconnectsAndSettlesExtensionTools`
  passed in 164.8 s, status 0, artifact
  `.../results/20260929T085003Z-run.eBMbuH`), so the harness change leaves `run`
  as it was. No Gateway source changed, so
  the Gateway merge gate does not apply; `scripts/check-documentation-policy.py`
  and `scripts/personal-info-guard.sh` pass.
- Deviations: (a) the lane-on fixture is a new `run-lan` command instead of
  flipping `run`, so the boundary test keeps the fault proxy on every leg it
  drives - turning the lane on there would let a LAN win bypass the proxy's
  fault modes. (b) The lane is dialed only on Wi-Fi (E-3c's own gate) and the
  simulator reports this Mac's wired path, so the new case states the phone's
  own path through `GatewayClient`'s existing `networkPath` initializer seam;
  no production change. (c) The blocked lane is the fixture's own unreachable
  loopback endpoint: blocking this Mac's real LAN address is not a fixture's
  job. (d) "Sends no credential" is asserted from the phone's own refusal with
  the transport never opened (the trust challenge is cancelled before the
  upgrade request is written); the byte-level "the socket wrote nothing"
  assertion stays in the focused test.
- What is left: E-3c's Do item 3 - live view, media/blob and upload HTTP routes
  still address `profile.httpURL`, and
  `BoundedHTTPDataTransport`/`BoundedHTTPFileTransport` have no pin plumbing, so
  routing them over a LAN-won epoch needs the pin carried into those transports
  and the winning endpoint kept client-side. That is one focused change with
  `scripts/tron-ios-test run` cases; it is not started here (landed in the
  review-fix entry below).
- For E-3d: the two E2E cases E-3d's text requires now pass on this evidence
  (`run-lan`), so `lanEndpoint.enabled` default true is defensible for the
  release; the setting stays the kill switch for R-4. No host network or
  installed app was touched by these runs: `run-lan` starts its own fixture
  Gateway (loopback plus this Mac's own LAN address on an ephemeral port) and
  removes it when the command ends.

### E-3c2 · review fixes · Done · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3c2`)

- Result: the review's two majors and three minors are fixed, and E-3c's Do item
  3 lands, so E-3c2 is Done. An epoch keeps the route it won with; every
  authenticated HTTP route that connection owns (live view, blob/media reads,
  staged export files, upload staging and discard) composes its base from the
  winning lane's own endpoint and passes that lane's pin to the transport
  instead of addressing `profile.httpURL`, and a request with no epoch or a
  saved-endpoint epoch keeps the saved endpoint. The three bounded HTTP
  transports take an optional `pin` (a 2-argument closure still compiles for
  every fixture), both URLSession loaders answer the server-trust challenge
  through `GatewayLanPin.answerServerTrustChallenge`, a pinned request owns a
  fresh session so the pin decides TLS before any credential-bearing byte, and
  `LiveLease` carries the pin to its frame and close requests. The E2E's
  blocked-LAN leg is now a listening socket that never accepts — TCP connects
  and TLS hangs, what a client-isolated network does, not a refused port — and
  asserts the saved lane wins at or after the 250 ms stagger and within stagger
  plus one handshake, that the losing LAN socket was accepted and drained to EOF
  (retired, not left dialing), and that the retired lane records no failure. The
  90 s leg arms the fault proxy's new opt-in HTTP blackhole and uploads an
  attachment every 5 s through it: the proxied saved lane cannot answer that
  POST, so its 18 answers are the proof that HTTP followed the winning lane.
- Evidence: `scripts/tron-ios-test build` clean;
  `scripts/tron-ios-test run --only-testing
  TronMobileTests/GatewayClientLanLaneTests` 17/17 including two new cases (a LAN
  epoch routes media, the staged export file and an upload to
  `https://192.168.1.24:9847` with the profile's pin; a saved-endpoint epoch
  keeps `http://gateway.test:9847` with no pin) with `GatewayClientTransportTests`
  76/76 (`20260929T091728Z-run.3ZuwEN`). `scripts/ios-gateway-e2e-test build`
  clean; `scripts/ios-gateway-e2e-test run-lan` green in 112 s (status 0), case
  passed in 92.1 s, artifact
  `.../tron-ios-gateway-e2e-501/results/20260929T092123Z-run.w5HPgm/FocusedE2E.xcresult`;
  that run's fixture logged `lan.listener state=bound port=60445`, one LAN
  connection opening in 2 ms, and 18 staged uploads while the proxy blackholed
  the saved lane's HTTP. `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Deviations: the proxy's HTTP blackhole is opt-in (`{"mode":"blackhole",
  "http":true}`) so the other legs keep reading their fixture through the proxy
  while a socket is blackholed; `run-lan` is a hosted-CI step after the boundary
  case (it needs this host's private address, which the lane binds), and
  `packages/ios-app/docs/development.md`, `packages/ios-app/docs/architecture.md`
  and `packages/gateway/docs/connection-resilience.md` now describe `run-lan`
  and the HTTP half.
- For E-3d: every E-3c E2E leg passes on this evidence, HTTP routes included, so
  `lanEndpoint.enabled` default true is defensible for the release; the setting
  stays the kill switch for R-4. E-3c's own row is left for the orchestrator:
  its Do items 1, 2, 3, 4 and 5 now all land across E-3c/E-3c2.

### E-3b · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3b`)

- Result: a paired phone learns the LAN lane on the two channels it already
  owns. `lan-endpoint.ts` exposes `advertisement()` (the lane's current bind as
  `{host, port}`, or an empty list while it is off or unbound) and
  `lanPin(certificate)`; `server.ts` merges them into the pairing response and
  the hello frame as `lanEndpoints` / `lanPin` and into no other response —
  `/health` on both listeners, the lane's 404 pairing route and every other
  unauthenticated answer are unchanged. On the phone `GatewayProfile` carries
  `lanEndpoints`/`lanPin` (canonical host, port 1...65535, a pin that decodes to
  32 bytes), the pairing response fills them, and
  `GatewayProfileStore.adoptLanAdvertising` replaces both on a hello. The
  advertisement reaches the phone through `GatewayHello`/`GatewayInfo`, because
  `GatewayClient` already threads `decoded.info` into the connection identity
  and that file belongs to E-3c.
- The pin is standard base64 of SHA-256 over the certificate's public key as the
  raw uncompressed X9.63 point (`0x04 || X || Y`): the encoding each platform
  exports without synthesising a key structure
  (`SecKeyCopyExternalRepresentation` on iOS, the JWK coordinates in Node).
- Evidence: `npx vitest run src/transport/lan-endpoint.integration.test.ts` 12/12
  — the new case pairs against a real `DeviceStore` over the primary listener and
  reads the hello frame over both the `wss` lane and the plain listener:
  `lanEndpoints` is the lane's bound `::1` endpoint and `lanPin` is
  `lanPin(tls-certificate.pem)`, the main and lane `/health` documents name
  neither, and with the setting off the hello advertises `lanEndpoints: []` and
  no pin. Merge gate (integration at `249f242b2`, a no-op merge): `npx tsc
  --noEmit -p .` clean; `session-archive` + `server-capacity` + `sync-protocol` +
  `stall-diagnostics` + `server-heartbeat` + `server-http-lifecycle` 132/132;
  `src/sessions/runtime-registry.integration.test.ts` 258/258;
  `server-http-admission` + `server-startup` + `lan-endpoint` 18/18. Phone:
  `scripts/tron-ios-test run` on `TronMobileTests/GatewayClientTransportTests`,
  `GatewayPairingTransportTests`, `GatewayProfileStoreTests` and
  `GatewayProtocolContractTests` 100/100, including the five new cases: hello
  carries the advertisement into the connection identity and drops an entry the
  phone cannot dial, a pairing response gives the profile the endpoints and pin,
  an endpoint composes the `wss` socket and `https` base the race dials
  (including a bracketed IPv6 ULA), a hello replaces what the store held (an
  unchanged answer writes nothing, an empty list clears both), and the phone
  reproduces the shared fixture's pin. Retained run: the 100-test run
  `20260928T213833Z-run.x6hAyM` (`1e12290c8` with the URL-composition change
  uncommitted); the review-fixes entry below cites a run at this branch's final
  HEAD.
- Deviations: the advertisement rides on `GatewayInfo` (the hello projection)
  instead of a new field on `GatewayConnectionIdentity`, so no E-3c-owned client
  file changed in this task. `GatewayProfileStore.adoptLanAdvertising` is the
  seam the Phone lifecycle calls after a hello and is covered by tests here; the
  call site itself was added in the review round below. No new log record:
  the advertisement is state on an existing frame, not a juncture, and a
  per-hello record would be hot-path volume.
- For the next agent (E-3c): `profile.lanEndpoints`/`lanPin` are already
  validated and kept current (each hello of the focused connection replaces
  them), so race those endpoints and compare the served certificate with
  `GatewayLanPin.pin(forCertificateDER:)`; a hello with no `lanEndpoints`
  decodes as an empty list, which is the lane being off. Each endpoint composes
  its own dial URLs (`socketURL`, `httpURL(path:queryItems:)`, both TLS) because
  `URLComponents` refuses a bare IPv6 literal and a ULA-only Mac advertises one.
  The lane binds the main listener's port on the private address.

### E-3b · review fixes · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3b`)

- Result: an independent review's one major and two minors are fixed on the same
  branch (no merge). (1) The hello now stores what it advertises: `AppModel`'s
  `adoptConnectedGatewayLanAdvertising()` runs beside
  `adoptConnectedGatewayIdentity()` in `lifecycleRefreshAll`, which the
  lifecycle calls on every connect and reconnect, so the selected profile's
  `lanEndpoints`/`lanPin` are replaced by the hello's advertisement before the
  dashboard pool reconciles. No revision is bumped: nothing presents the
  advertisement yet and the dial endpoint did not change. A phone paired before
  this release now gets the lane on its next connection, and an address that
  moved or a lane that was switched off corrects the profile instead of leaving
  E-3c a stale endpoint. (2) `DashboardGatewayConnectionPool.reconcile` compares
  a `DashboardPoolProfileIdentity` (host, port, label, machine identity, enabled
  — plus the token it already compared) instead of whole-profile equality, so a
  refreshed advertisement no longer stops and restarts a working background
  connection; a changed dial identity still does. (3) The earlier entry's
  evidence path named a sibling worktree's run and is replaced with this
  worker's own; the run below is at this branch's final source.
- Evidence: `scripts/tron-ios-test build` + `run` on
  `TronMobileTests/GatewayClientTransportTests`, `GatewayPairingTransportTests`,
  `GatewayProfileStoreTests`, `GatewayProtocolContractTests`,
  `AppModelLifecycleTests` and `DashboardStateOwnerTests` 172/172, including the
  two new cases below. Retained run:
  `~/Library/Developer/Tron/ios/test-runs/20260928T220641Z-run.VlfXfG`. Each new
  case fails on the pre-fix code for its own reason: with the comparison
  reverted, the pooled entry dials a second socket and closes the first
  (`DashboardStateOwnerTests.swift:295`); with the adoption call removed, the
  stored profile keeps `[]`/`nil` (`AppModelLifecycleTests.swift:346`). No
  Gateway source changed in this round, so the merge gate was not re-run.
- Deviations: the adoption call lands in `AppModel.swift` (the zone table gives
  it to E-3c) and the pool comparison in `DashboardGatewayConnectionPool.swift`
  (C-5's file), because the plan's own E-3b "Do" and both docs already say the
  phone replaces the advertisement on every hello; deferring either to E-3c
  would have left the shipped branch contradicting both.

### G-12 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-12`)

- Result: overload is predictable. One table, `DISPOSABLE_READ_DEADLINES_MS`
  (`packages/gateway/src/transport/server.ts`), gives every disposable read a
  server-side deadline (10 s for `session.open`, whose cold load may parse a
  large transcript before its subscription commits; 5 s for the other eight);
  expiry marks the request shed, aborts it through C-6's abort plumbing and the
  ordinary failure path answers `busy` with `details.retryAfterMs`
  (`SHED_RETRY_AFTER_MS`, 1 s) — the one record for it is `gateway.shed` with
  `reason=deadline` instead of `rpc.completed`. A method with no entry (every
  mutation, every prompt, `session.sync`) has no timer and is never shed. Three
  concurrency caps queue rather than refuse: `MAXIMUM_CONCURRENT_COLD_LOADS` (2,
  `sessions/runtime-registry.ts`, via the new `util/queued-work-gate.ts`),
  `MAXIMUM_CONCURRENT_SESSION_EXPORTS` (1) and
  `MAXIMUM_CONCURRENT_WORKSPACE_INSPECTIONS` (2) in
  `transport/gateway-service.ts`; a queued waiter whose requester left is
  dropped, so the work it queued for is never started (the load already in
  flight still keeps running and is shared, C-6). Cold loads are additionally
  gated on real heap pressure read from `process.memoryUsage()` and
  `getHeapStatistics().heap_size_limit`: above `HEAP_EVICTION_SHARE` (0.70) idle
  runtimes are retired largest first through G-5's own `retireIdleRuntime` (new
  reason `heap`), and above `HEAP_REFUSAL_SHARE` (0.85) the load is refused with
  `busy`, `HEAP_REFUSAL_RETRY_AFTER_MS` (5 s) and one `gateway.shed` with
  `reason=heap` and the heap counts; a protected runtime is never retired to make
  room, so a heap made of protected runtimes refuses instead of pretending it
  made room. The phone (`GatewayDisposableReadPolicy` +
  `GatewayClient.requestOnce`) waits a shed disposable read's hint (bounded to
  10 s), retries it once under a fresh request identity, records
  `rpc.retry-after`, and never retries a mutation.
- Failure modes written first: (1) the deadline fires while an open's
  subscription is already committed, leaving an orphan barrier and no answer;
  (2) a cold load queued behind the cap still loads for a client that left, so a
  transcript nobody waits for is parsed into the live set; (3) heap pressure
  retires a runtime that has an audience, or the refusal that should replace it
  never happens and the load takes the process to the limit.
- Evidence:
  - `npx vitest run src/transport/server-capacity.integration.test.ts` 35/35
    (the new case drives a held `session.open` whose subscription commits before
    the response, a held `session.list`, and a held mutation: the two reads are
    answered `busy` with `retryAfterMs=1000` while the work is still held, the
    committed subscription is given back (`subscriptions.size === 0`), one
    `gateway.shed` carries `reason=deadline`, the mutation gets no shed record
    and its own `ok:true` answer after 300 ms past its (absent) deadline, and a
    retry of the same open is answered normally — no leaked barrier).
  - `npx vitest run src/sessions/runtime-registry.integration.test.ts` 239/239
    (the two new cases: three cold loads with the loader held prove exactly two
    loads start, the third waits, an aborted waiter rejects and never loads; and
    a heap sample driven over the shares proves the largest *idle* runtime is
    retired with `reason=heap` while the protected one survives, then that a
    second cold load is refused with `busy`/`retryAfterMs=5000` and one
    `capacityShedRecord` — the refusal happens because every remaining runtime is
    protected, not because the pass gave up early).
  - Merge gate on this branch merged with `hardening/integration`
    (`c70ccb4df`, "Already up to date"): the six-file transport set 133/133;
    `src/sessions/runtime-registry.integration.test.ts` 239/239; `npx tsc
    --noEmit -p .` clean. One earlier full-file registry run reported 1 failure
    and the immediate rerun 239/239, matching the host-load flake G-9 recorded.
  - `python3 scripts/check-documentation-policy.py` passes.
- Checks: the row's two named owners (`server-capacity.integration.test.ts`,
  `runtime-registry.integration.test.ts`) carry the deadline, cap and
  heap-pressure cases above.
- Docs: `packages/gateway/docs/connection-resilience.md` gains the G-12 limits
  table (every bound, its value, its owner and what it does);
  `packages/gateway/docs/observability.md` gains the `gateway.shed` row (both
  producers), the `heap` eviction reason on `runtime.evicted` and the phone's
  `rpc.retry-after` row; `packages/gateway/README.md` states the deadline table,
  the caps, the heap shares and the phone's retry in the protocol and session
  invariants sections.
- Volume: `gateway.shed` is one record per shed request or refused load (a rare
  event by construction: it needs a real deadline overrun or heap past 85%);
  `rpc.retry-after` is one memory-only phone record per honoured hint.
- Deviations: the deadlines are overridable through the server's existing
  named-bound option style (`disposableReadDeadlinesMs`, like
  `synchronizationTimeoutMs`) so a fixture can prove a deadline in milliseconds
  instead of waiting a production bound; the heap sample is injectable for the
  same reason, defaulting to the process's own numbers. The queue logic is one
  shared `util/queued-work-gate.ts` used by both the registry's cold-load cap and
  the service's two caps instead of two copies. `acquire` gained an optional
  `signal` used only for the cold-load queue wait (the shared start is
  deliberately not abandoned, C-6), so `session.open` passes `client.signal`.
  `RuntimeEvictionReason` gained `heap`, documented in the row above.
- Phone evidence: `scripts/tron-ios-test build` + `run --only-testing
  TronMobileTests/GatewayClientTransportTests` 57 passed / 0 failed, including
  the new case "a shed disposable read is retried after the Gateway's hint, a
  mutation is not" (asserts the retry frame's own identity, exactly one
  `rpc.retry-after` with `code=busy` and the hint's `durationMs`, and that a shed
  `session.prompt` is never retried). Retained run:
  `~/Library/Developer/Tron/ios/test-runs/20260928T225017Z-run.GXO9TZ`.
- Remaining: the plan's "Done when" — O-6a with the heap limit lowered, showing
  the Gateway sheds instead of exceeding the limit and no request exceeding its
  deadline — is the orchestrator's qualification run; this branch proves the
  mechanisms it depends on.

### G-12 · review round 1 addressed · 2026-09-28 · deepseek-worker (branch `hardening/g-12`)

- Result: the independent review's three majors and three minors are fixed on the
  same branch (no merge). (1) A shared cold start no longer carries one
  requester's signal: `pendingSlotStarts` now holds a `PendingColdLoad` (its
  operation, one `AbortController` for the queue wait, and its live waiters), each
  `acquire` joins it through `joinColdLoad`, and the queued load is dropped only
  when the *last* waiter leaves, so a phone reconnecting on a new socket keeps the
  load the retiring connection was waiting for (`C-6`). (2) The heap pass measures
  progress from the registry's own accounting: it returns the
  `estimatedHeapBytes` of each runtime it actually retired and both its stop
  condition and the refusal behind it read the sampled heap less that total
  (`projectedHeapShare`), so a sample that does not fall on eviction no longer
  retires the whole live set for one load. (3) The deadline table is limited to
  the reads the plan names (`session.open` 10 s; `session.list`, `session.transcript`,
  `session.history.list`, `session.history.entry` 5 s); `session.search` (Jev's
  own 20 s paid remote ranking), `provider.usage` (10 s per fetch, then a typed
  timed-out snapshot), `model.list` and `provider.list` have no deadline, so
  nothing can shed them and the phone's one retry can never buy a second paid
  search. (4) The deadline timer is cleared the moment a response is attempted
  (`clearDeadline`), so an answered request cannot be relabelled `gateway.shed` by
  a timer that fires during its own catch-up. (5) `CapacityShedRecord` carries
  `admission` (`open` / `import`) instead of claiming `session.open` for every
  refusal, and the docs say a JSONL import is the one mutation the heap bound can
  refuse — before it writes anything. (6) `QueuedWorkGate` hands a released place
  to the next waiter directly instead of lowering the count and re-checking.
- Evidence: `npx vitest run src/sessions/runtime-registry.integration.test.ts
  src/transport/server-capacity.integration.test.ts` 275/275. The two new cases
  fail on the pre-fix code for their own reason: with the pass ignoring its own
  accounting, the heap case retires the idle runtime it must leave alone
  (`AssertionError` on the eviction list); with the shared start carrying the
  first requester's signal, the two-waiter case never starts the queued load.
  The capacity case now derives its table from `DISPOSABLE_READ_DEADLINES_MS`'s
  own keys and asserts a held `session.search` is never shed.
- Deviations: (a) `session.search`/`provider.usage` keep no deadline rather than
  getting one above their owner's bound, which is the plan's "initial" list read
  literally; the phone needed no change because the Gateway never answers those
  reads with a retry hint. (b) Finding 4's window needs a request that owns a
  synchronization completion, and today only `session.sync` pushes one — a method
  with no deadline — so that fix is ordering hardening with no reachable
  reproduction, and no fixture pretends otherwise. (c) The gate's FIFO pass-over
  could not be reproduced: with a queued waiter the new case passes on the old
  gate too, so the change is kept as the simpler structural form of the same
  bound, not as a proven defect.
- Remaining: the plan's "Done when" (O-6a with the heap limit lowered) stays the
  orchestrator's qualification run.

### G-8a · G-8d · T-1 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-8a`)

- Result: the 750 ms ambient discovery pass reads a run's `status.json` only when
  the identity of that file changed, and offers a candidate to a slot only when
  that slot can attribute the run — a canonical JSONL fact, an ownership binding
  or a projected activity (`RuntimeSlot.extensionAmbientArtifactAttribution`) — so
  an unchanged artifact a slot already received costs one `stat` and no routed
  `open`/read/parse. A pass that still stops at a budget reports
  `extension.discovery-truncated` with its counts (`dropped` included) when the
  stop starts, when it begins dropping candidates the per-root budget cut, and
  otherwise at most hourly; the fact and routing caches age out after four unseen
  passes even when a pass stops early, so the 4,096-entry cap no longer fixes the
  same cached decisions forever. Both lanes that read an artifact still retry a
  read that lost an atomic replace before reporting it, and the registry test
  helper runs a pass it starts itself instead of awaiting a call that can be a
  silent no-op.
- Evidence:
  - G-8d change gate: `npx vitest run src/sessions/runtime-registry.integration.test.ts
    -t "does not reopen an unchanged ambient artifact"` — a production-shaped root
    (2,498 run directories, 556 finished `status.json`, one live slot) routes only
    the artifacts that slot can attribute, the next unchanged pass routes only the
    live exact binding, and a changed finished artifact is offered again. Reads per
    steady-state pass: **556 → 0** for artifacts no live slot can attribute (the
    review measured 556 on this branch and 233 on `hardening/integration`).
  - G-8d bound and report: `-t "examines every ambient artifact within a bounded
    number of passes"` — pass 1 `{entries 1_025, statusReads 1_024, work 0,
    dropped 0}`, pass 2 `{entries 1_100, statusReads 76, work 0, dropped 76}`: the
    walk reaches the whole root, reads only the entries it had not, and counts the
    candidates its routing budget cut; a third unchanged pass records nothing
    further, and no artifact is routed.
  - G-8a check (the row's negative control): `-t "retries a status.json read that
    raced an atomic replacement"` atomically replaces `status.json` across real
    discovery passes bounded by wall clock. On the pre-fix source it fails **4/4**
    runs with the `artifact-replacement-in-progress` warning; after the fix it
    passes with the running projection intact.
  - Owning suite `npx vitest run src/sessions/runtime-registry.integration.test.ts`,
    merge gate `npx vitest run src/transport/session-archive.integration.test.ts
    src/transport/server-capacity.integration.test.ts
    src/transport/sync-protocol.integration.test.ts
    src/transport/stall-diagnostics.test.ts
    src/transport/server-heartbeat.integration.test.ts
    src/transport/server-http-lifecycle.integration.test.ts`, `npx tsc --noEmit -p .`,
    `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` — see the commit for the recorded results.
- Changes: `packages/gateway/src/sessions/runtime-registry.ts` (identity-gated
  ambient read, per-slot artifact-identity routing gate, `dropped` count, aged
  fact/route caches, start-and-hourly truncation report), `runtime-slot.ts`
  (`extensionAmbientArtifactAttribution`, bounded discovery-lane retry, watcher-lane
  retry when a debounce already owns the read), `gateway-main.ts` (the record),
  `packages/gateway/docs/observability.md`, and the registry integration tests.
- Deviations: the row named only the discovery lane; the required atomic-replace
  check shows the watcher lane was the source of the warnings under a replace
  storm, because a pending `fs.watch` debounce made its retry unreachable. The
  ambient lane now needs the slot to attribute the run, and the
  `reconciles an exact-owned active artifact` fixture appended its canonical tool
  result to the fixture manager, which the live slot never reads; the fixture now
  appends to the slot's own session manager, as every other canonical-fact fixture
  here does.
- Residual: a candidate a slot can attribute but cannot yet project is offered
  every pass until its artifact changes (bounded by that session's own runs); a
  terminal artifact's sidecar refresh rests on the exact-binding lane, as the
  review specified. The `artifact-replacement-in-progress` reason still covers an
  unclassified read error and a `status.json` that has not been written yet.
- Round 2 (review response): a route is recorded only after the slot decided the
  artifact. `RuntimeSlot.discoverExtensionArtifact` now reports `accepted`,
  `rejected` or `transient`, and the pass records only the first two, so an offer
  a busy work registry, a losing read or any other temporary failure refused is
  offered again on the next pass instead of being treated as delivered (the run
  that `claimExtensionReceiptOwnership` refuses once reaches `completed` on the
  second pass; it never appears on `bc8d23dc0`). Attributed candidates are now
  filtered before the per-root budget slice, so unattributable directories can no
  longer consume that budget or be reported as deferred work (`dropped` in
  `extension.discovery-truncated` now counts only candidates a live slot still
  had to be offered).

### G-1d · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/g-1d`)

- Result: the docs describe the catalog that exists. `connection-resilience.md`
  replaces the "speculative caches" sentence (keeping "no transcript mirrors" and
  "no higher queue limits") with the index contract: one owner
  (`session-catalog.ts`), three feeds (Gateway commit points, the recursive
  folder watcher, the 30-minute whole-folder reconcile), the durable
  `catalog-metadata-v2.json` as the owner's own acceleration, JSONL authority and
  rebuild from canonical files on loss, `catalog_not_ready` for an unprovable
  row, and target-file-only commit fences. The README's catalog paragraphs
  (acquisition, `RuntimeRegistry` membership, the cold-open/fence paragraph, the
  attention paragraph, the session-invariant paragraph and the summary-row
  paragraph) now say the same thing and no longer describe the deleted
  request-path walks, `validatedStructuralIndex`/`sharedCatalogStructureEvidence`,
  `fallbackCatalogAcquisition`, the lightweight fallback, the successor
  header-walk cut, the user/all acquisition cuts and sidecar, "ten-way metadata
  reads", or a startup structural evidence cut.
- Evidence: every stale mechanism name is gone from the two docs —
  `grep -rn "validatedStructuralIndex\|sharedCatalogStructureEvidence\|fallbackCatalogAcquisition\|lightweight acquisition\|successor cut\|whole-tree header\|whole-catalog header\|acquisition generations\|sidecar generation" packages/gateway/README.md packages/gateway/docs/` returns no match, and every remaining "walk" mention describes the owner's own scan, the profiler's counter, or an explicit "no request walks" statement. `python3 scripts/check-documentation-policy.py` passed (46 authored files); `scripts/personal-info-guard.sh` OK.
- Changes: `packages/gateway/docs/connection-resilience.md`,
  `packages/gateway/README.md`, this plan.
- Kept on purpose: the discovery bounds (50,001 entries, 25,001 directories/8 MiB,
  25,000 records/8 MiB, 1,024-byte previews, 512-byte header reads, 16-file
  batches, 64 KiB/candidate, 64 MiB aggregate, 4 MiB acquisition) and the
  classification/topology rules, because they are the owner's scan, not the
  request path. `packages/gateway/docs/observability.md` needed no change: its
  `catalog.reconciled` row already says the reconcile is "the only whole-folder
  walk left on this side".
- Deviations: the plan's G-1b wording said reconcile batches are "at most 50
  files"; the shipped owner batches at `RECONCILE_CONCURRENCY` (16), so the docs
  state 16.
- For the next agent: none. Nothing in this row is owed.

### C-3 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/c-3`)

- Failure modes written before the change (plan, C-3; each isolated test below
  targets one of them):
  1. a working path opening in 4–6 s: the transport-open bound must give up at
     5 s without spending the hello budget, and a hello that answers after the
     socket opened must still get its own 15 s;
  2. a path flapping every second: each return cancels the pending wait and
     attempts at once, and never puts two sockets on the wire;
  3. an attempt in flight when the path changes: the change starts no second
     attempt, and the in-flight attempt keeps its own deadline;
  4. a path change after a long run of failures: the curve restarts at the base
     interval, while repeated failures on an unchanged path keep the cap and
     jitter.
- Result: the transport open and the hello after it have separate bounds, and a
  path return cancels a pending backoff wait and restarts the curve.
  `clientTransportOpenDeadline` (5 s) replaces the first half of the shared
  15-second `clientHandshakeDeadline`, which is now `clientHelloDeadline` and
  bounds only the hello exchange on a socket that opened. The phone's retry
  owner cancels a pending wait on a satisfied path notice and restarts the
  backoff curve from its base interval, so the route that just returned is
  attempted at once instead of after the wait the route that went away had
  grown; repeated failures that see no path notice keep the capped, jittered
  curve. The O-6b driver reads both bounds from the contract for its phone model
  and cancels the modelled wait at the blackhole's path return.
- Evidence: `scripts/tron-ios-test build --lane C3` succeeds;
  `scripts/tron-ios-test run --lane C3` for `AppModelReconnectTests` (50/50,
  including `pathReturnCancelsPendingBackoff` and
  `pathChangeDuringReconnectAttemptStartsNoSecondSocket`), `GatewayClientTransportTests`
  (57/57, including the transport-open/hello boundary pair),
  `GatewayProtocolContractTests` + `GatewayReconnectScheduleTests`, the four
  neighbouring suites and E-3b's tests after merging `hardening/integration` —
  232 tests in 8 suites, 0 failures, retained at
  `~/Library/Developer/Tron/ios/test-runs/20260928T223640Z-run.9udavo`;
  `npx vitest run src/transport/connection-policy.test.ts` 1/1 (the fixture's
  server-side parity); `python3 scripts/test-tron-profile.py` 45/45 against the
  driver's updated phone model (the blackhole case now recovers 3.5 s after the
  path's return — the rest of the transport-open attempt that was in flight —
  and asserts it stays inside one transport-open deadline).
- Deviations: `handshakeDeadline`/`clientHandshakeDeadline` are renamed to the
  hello bound because the split leaves them owning only the hello, and the name
  is what the contract's reason text now says. `GatewayConnectionPolicy`,
  `GatewayClient`, `GatewayLifecycleCoordinator`, `ReconnectDelayPolicy`
  (`GatewayReconnectSchedule.restartForPathChange`), the fixture, the O-6b
  driver, `scripts/tron-profile-gateway`, `scripts/test-tron-profile.py` and the
  three docs change with it.
- For the next agent: O-6b's blackhole p95 (target ≤ 5 s from the path's
  return) and the 90 s iOS E2E case's recovery measurement are the
  orchestrator's quiet-host run; the driver's model bounds the p95 at one
  transport-open deadline plus one connect once the path returns, and the relay
  still refuses to forward the attempt that was in flight.

#### C-3 review round · 2026-09-28 · same branch, same worker

An independent reviewer found the modelled phone's wait broken and two real
recovery gaps; all three were fixed on the same branch.

1. The driver handed `phoneBackoffWait` a *function* as its race value, so
   `Promise.race` settled it immediately and every modelled wait was zero — the
   recovery figure was a floor the phone never had. `connectUntilReady` now
   takes the leg's path-change object (`returnedAt`/`signal`), `phoneBackoffWait`
   returns whether the return cancelled it, an attempt record carries the
   `waitMs` that preceded it, and a change that arrived while an attempt was on
   the wire is consumed when it fails. The `ws` library's `handshakeTimeout` is
   now a backstop 1 s past the phone's bound: the library destroying the socket
   first reported the model's own timeout as an unexpected close.
2. `GatewayLifecycleCoordinator.notePathHint` recorded nothing when a satisfied
   notice arrived during an in-flight attempt, so the loop then waited the grown
   curve (up to 15 s) after it. It now records the change, and the loop consumes
   it after that attempt fails and retries at once from the restarted curve
   (`reconnect.delay cause=pathChanged`; the next attempt's `actualDelayMs`≈0).
3. Every satisfied notice — a scene activation, an interface-flag or VPN
   update, and the monitor's own repeats — restarted the curve, which weakens
   Do 3. The observer now forwards the monitored route's interface signature
   (`TronMobileApp.routeSignature`, status-independent), and only a change of
   that signature (or an unsatisfied→satisfied transition) restarts the curve;
   a notice on the same route still cancels a pending wait. The dashboard pool
   keeps its own transition gate.
- Evidence (review round): `scripts/test-tron-profile.py -k test_the_blackhole`
  2/2 (~30 s) — the 5 s/8 s leg recovers 3.5 s after the return with the
  consumed change's attempt at `waitMs: 0`, and the new 6 s/2 s leg pays a
  ~2.1 s base-interval wait before its second attempt and recovers 0.61 s after
  the return; a zero-gap retry model fails the new leg's backoff assertion.
  `scripts/tron-ios-test run --lane C3` for `AppModelReconnectTests`,
  `GatewayReconnectScheduleTests`, `GatewayClientTransportTests` and
  `GatewayProtocolContractTests`: 131 tests in 4 suites, 0 failures, retained at
  `~/Library/Developer/Tron/ios/test-runs/20260928T230918Z-run.T7wXvI`.
- Deviation: the modelled cancel assumes the phone sees a path change at the
  relay's return. A relay blackhole raises no path callback — `NWPathMonitor`
  still reports a satisfied path — so on a device the O-6b leg's recovery is the
  wait it was in plus the attempt that follows, and the modelled p95 ≤ 5 s is
  the path-change case C-3 targets. The gateway README now says so; the quiet
  host run still owns the real numbers.

### F-1 · Done · 2026-09-28 · orchestrator-dispatched deepseek-worker (branch `hardening/f-1`)

- Result: the two deterministic iOS regressions on the integration branch are
  gone; both were tests pinning the pre-`C-6` write log, so no product change was
  needed and neither suite's guarantee was weakened.
- Root causes: (1) `ProviderAuthCoordinatorTests.completionDispatchIsOwned`
  indexed the write log by absolute frame, but the profile clear abandons the
  retired `provider.list`/`model.list` pair and `C-6` now appends one `cancel`
  control frame per abandoned read, so frames 3–4 were the cancels rather than
  the fresh pair (decoding a cancel frame has no `method`).
  (2) `SessionSheetPresentationTests.testSessionHistoryPagingStartsNewNativeBatchAtTopAndRetainsFailures`
  pinned the reactivation read to frame 8 and the total to 10; the read the covered
  surface abandons is likewise cancelled, so the reactivation read is frame 9 and
  the total is 11. Its `InvalidTransition { phase: idle targetPhase:
  failed(deinit) }` was the sheet's SwiftUI gesture teardown of that failed
  fixture response, not the cause: the fixture's own `Expected
  session.history.list` error preceded it.
- Changes: `packages/ios-app/Tests/Gateway/ProviderAuthCoordinatorTests.swift`
  (wait for the retired pair's two cancel frames before the fresh pair, then the
  pair at 5–6, the Recent-rail warm at 7 and a bound of 8 frames),
  `packages/ios-app/Tests/UI/SessionSheetPresentationTests.swift` (a
  `waitForCancellation(ofRequestAt:socket:)` helper that waits for the exact
  cancel frame naming the abandoned read, then frame indices 9 and 10 with a
  bound of 11 frames).
- Evidence: `scripts/tron-ios-test build` and
  `scripts/tron-ios-test run --only-testing TronMobileTests/ProviderAuthCoordinatorTests
  --only-testing TronMobileTests/SessionSheetPresentationTests
  --only-testing TronMobileTests/AppModelReconnectTests
  --only-testing TronMobileTests/GatewayClientTransportTests
  --only-testing TronMobileTests/SessionPresentationStoreTests` on lane F1 pass
  213/213 with 0 failures (retained at
  `~/Library/Developer/Tron/ios/test-runs/20260929T000253Z-run.4nTQ3g`). Before
  the fix the same command failed both cases on revision `93cc80968`; the
  instrumented write logs that named the condition are not part of the change.
- For the next agent: no other case in those suites indexes the write log past a
  cancel frame; a new surface-abandonment case does, so a frame index is only
  trustworthy after the control frame it waits for exists.

### Interim release · 2026-09-28 · orchestrator

- Result: at the user's request, an interim install of the merged Phase 1
  work before the plan's single release. Candidate `hardening/integration`
  `419a67a53` (protocol 6): O-1..O-5, O-7, C-1..C-7, G-1a..G-1d, G-2..G-5,
  G-7..G-13 (G-13 measurement only), E-2*, E-3a/E-3b (LAN listener off by
  default; phone half E-3c not built), T-1..T-4, F-1. Not included: E-3c,
  E-3d, G-3a.
- Evidence: Gateway full vitest 2,172/2,173 with `--maxWorkers=4` (the one
  failure is "keeps a large streamed write visible…", which also fails
  intermittently on `main`); iOS full unit run 1,913/1,914 (T-5 flake, passes
  alone 3/3); iOS↔Gateway E2E including C-1's 90 s blackhole passed
  (`tron-ios-gateway-e2e-501/results/20260928T235314Z-run.bZKigP`); short
  multi-session smoke (300 files, 60 s, `--cases none`,
  `20260929T000118Z-multi-session-26dbfd`): `session.list` p50 24 ms / max
  1.5 s (provisional `main` p99 46.5 s), cold open max 1.6 s (large 0.5 s),
  catalog walks 0, no-subscriber CPU 9.7% of a core (provisional `main` 57%),
  heap peak 12.8% of the limit; event-loop max ~1 s remains (G-3a).
- Builds: Mac Release `~/Workspace/tron-interim-build/Tron.app` (bundled
  Gateway manifest `sourceRevision 419a67a53`, protocol 6); iOS `Tron Device` +
  `LocalDevice` prebuilt in `packages/ios-app/build/DerivedData` of the
  integration worktree, installed with `scripts/tron-ios-device install`
  after `scripts/tron mac verify`.
- Rollback: Mac app 0.1.0 (7), Gateway payload
  `0.1.0-beta.7-source-1790559163986`, source `d47425afc`; reinstall the
  previous Mac and iOS builds together (protocol 5).
- Deviation: the interim install comes from `hardening/integration`, not
  `main`; R-1 still merges once to `main` for the final release.
- Tasks added: T-5, F-2.

### Main merge (iOS module split MS-3b) · 2026-09-28 · integration worker

- Result: `hardening/integration` merges `main` `c892ce017` before the release.
  Thirteen conflicted files resolved: the iOS files keep every hardening
  behaviour (protocol 6 / minimum 6, `transportOpenDeadline` 5 s plus
  `helloDeadline` 15 s with `handshakeDeadline` gone, the cancel frame and the
  disposable-read shed policy, `GatewayLanPin` and the LAN advertisement,
  `restartForPathChange`/`adopt`, the AppLog `operation.*`/`rpc.*` records, the
  `IOSClientDiagnostics` excused-liveness and client-work records,
  `gatewayConnectionId`) under main's `Core/` paths, `package` access and
  Foundation-only rule. `GatewayLanPin.swift` lives at
  `Core/Gateway/GatewayLanPin.swift`: Core may import CryptoKit and Security,
  and only the app test host reads it beyond Core.
- `runtime-registry.ts` keeps the pass/counts discovery refactor and gains
  main's paused-subagent settlement: `readAmbientExtensionArtifact` now derives
  `settledPaused` from `observedPausedProcessTerminalAt`, so a settled paused
  artifact no longer outranks live ones for the bounded discovery budget.
  `packages/gateway/docs/observability.md` keeps the hardening rows with
  main's paths.
- Access widened only where the compiler required it, following MS-3b's rule:
  `ReconnectDelayPolicy.init`/`multiplier`/`maximumSeconds` (the dashboard pool
  builds its own curves), `PerformanceSignposting.endOpenIntervalsAtBackground`
  (its requirement takes the protocol's `package` level, so the default
  implementation and `AppLogSignposts`'s witness do too),
  `GatewayDiagnosticFailure.answerCode`, `IOSClientDiagnosticBuffer.redactedMessage`,
  `GatewayLanEndpoint`, `GatewayProfile.lanEndpoints`/`lanPin`/`adoptLanAdvertising`,
  `GatewayProfileStore.adoptLanAdvertising`, `GatewayInfo.lanEndpoints`/`lanPin`/
  `pushRegistrationRevision`, `GPS`-free `GatewayProfile` members, the
  `GatewayFailure` init and `answeredByGateway`, and
  `GatewayConnectionIdentity.gatewayConnectionID`. Files the app or tests reach
  across the new module boundary that were added after MS-3b (the episode
  recorder, its tests, the mounted-restoration hosted test) import
  `TronMobileCore`; `Sources/{Gateway,Models,Support}` leave no file, duplicate
  or stale path literal behind, including in `connection-resilience.md`.
- Evidence: Gateway `tsc --noEmit` clean; `runtime-registry.integration`,
  `session-archive.integration`, `sync-protocol.integration` 290/290;
  `paused-subagent.integration`, `process-activity`, `process-activity-recency`,
  `extension-run-projection`, `extension-lifecycle-coordinator`, `restart-drain`,
  `administrative-drain-snapshot`, `extension-activity-recency` 69/69; iOS full
  unit plan 1,835 tests / 148 suites pass, no T-5 occurrence
  (`~/Library/Developer/Tron/ios/test-runs/20260929T021733Z-run.ZwLHv2`).
  `check-documentation-policy.py`, `test-gateway-protocol-contract.py`,
  `packages/ios-app/scripts/test-source-policy.sh` (Foundation-only Core) and
  `personal-info-guard.sh` pass.
- Deviation: the plan's file paths for moved iOS files were updated to `Core/`
  so the plan matches the tree, as MS-3b did on `main`.

### Early merge to main · 2026-09-28 · orchestrator

- Result: at the user's request, `hardening/integration` (Phase 1 so far,
  protocol 6) was merged into `main` once, ahead of R-1, after merging the
  latest `main` (iOS module split MS-3b, paused-subagent settlement) into it
  and re-running the gates: Gateway `tsc` clean, registry + session-archive +
  sync-protocol 290/290, paused-subagent/process-activity suites 69/69, iOS
  full unit plan 1,835/1,835 (`20260929T021733Z-run.ZwLHv2`), protocol
  contract, source policy, profiler and triage tests pass.
- Deviation from the branch model: `main` now carries protocol 6 and every
  Done Phase 1 row. The Mac app and iOS app built from `main` must be installed
  together. Remaining rows (E-3c, E-3d, G-3a, T-5, F-2, O-6a/O-6b baselines)
  continue on `hardening/integration`, branched from this `main`, and R-1
  merges them once more.
- For the next agent: the plan copy on `main` and on `hardening/integration`
  are identical at this point; keep updating the integration copy until R-1.

### G-5a · 2026-09-29 · direct session on `main`

- Incident: the user installed the Release app built from `efc88f1b5` after
  the early merge. The menu showed Update required (with two "Repair Tron" rows
  and no Pause), and the phone did not connect. `scripts/tron mac verify`
  passed every check.
- Cause 1 (Mac): G-5 made the launcher exec
  `node --max-old-space-size=4096 index.js --host … --port …`, but
  `StableGatewayProvenance.processCommand` and
  `LiveLaunchAgentManager.processCommandOwnsProfile` each held their own copy
  of the old six-field argv. Stable admission refused the running Gateway
  (Update required, pairing and native capture refused), registration repair
  treated it as stale (Repair relaunched into the same state), and Debug
  admission would refuse a Debug Gateway the same way. `mac verify` matched the
  command with a glob. The launcher's shell test and the Swift tests each
  asserted their own copy of the argv; nothing ran the launcher's real output
  through the Swift checks.
- Cause 2 (phone): the phone ran a build installed 2026-09-28 01:02 PDT,
  before the protocol-6 bump (`c16e4b279`, 07:22 PDT). The Gateway logged 29
  `http.upgrade` `protocol_mismatch` refusals after the restart, none naming the
  phone's version. The fix is installing the iOS app from `main`; no code change.
- Failure modes written before the code: (1) Stable admission refuses the argv
  the real launcher execs from the LaunchAgent plist; (2) registration repair
  treats that runtime as stale; (3) Debug admission refuses the argv the same
  launcher execs for `scripts/tron dev`; (4) the fix loosens the contract
  (missing heap flag, another heap value, flag after the entrypoint, an extra
  flag are admitted); (5) a refusal does not say which check refused; (6) the
  refused menu offers no Pause, so the reinstall runbook cannot be followed;
  (7) `mac verify` passes a command the app refuses; (8) `protocol_mismatch`
  omits the peer's version.
- Result: `StableGatewayProvenance.launchArguments` is the one Swift argv
  contract; Stable/Debug admission and registration repair use it, and
  `verify-mac-install.sh` compares the exact same string (plist arguments for
  Stable, the lifecycle host for Debug). `StableGatewayObserver.observe`
  returns a `Refusal` naming the refusing check, which becomes the Update
  required reason and the `observer.state-changed` `why`. The menu offers Pause
  in Update required with a single Repair. The Gateway's `protocol_mismatch`
  record carries `peerProtocolVersion` and the accepted range. The payload
  fixture builder moved from `GatewayPayloadStoreTests` to
  `Tests/Support/GatewayPayloadFixture.swift` so the launcher test can use it.
  Version bumped to `0.1.0-beta.8` / build 8 (`scripts/tron-version bump beta`).
- Tests: `GatewayLauncherArgvTests` copies the test host's signed
  `Tron Agent.app`, stubs Node with an argv recorder in a fixture payload, runs
  the real launcher with the plist's arguments and environment (and the
  `scripts/tron dev` invocation), and checks the recorded argv against Stable
  admission, registration repair and Debug admission (modes 1-3). It failed on
  the unfixed source with the real argv, and again with `launchArguments`
  mutated back to the six-field list (3 issues); it passes on the fix.
  `StableGatewayObserverTests.refusesOtherLaunchArguments` (4, 5),
  `ServerStatusPollerTests.refusalNamesItsCheck` (5),
  `MenuBarItemBuilderTests.needsRepairOffersPause` (6; failed first with
  `[resumeServer, restartServer]` and no Pause), and the extended
  `server-http-lifecycle` protocol-mismatch case (8; failed first without
  `peerProtocolVersion`). Mode 7 is the live `mac verify` run below.
- Evidence: the ten touched Mac suites pass 79/79
  (`GatewayLauncherArgvTests`, `MenuBarItemBuilderTests`,
  `StableGatewayObserverTests`, `ServerStatusPollerTests`,
  `ServerStatusPollerBoundedAdmissionTests`, `LiveLaunchAgentManagerTests`,
  `MacAppStartupMaintenanceTests`, `DebugGatewayObserverTests`,
  `GatewayPayloadStoreTests`, `PresentationRequestFenceTests`); the full Mac
  unit run passes 310 tests in 50 suites;
  `server-http-lifecycle.integration.test.ts` 20/20; Gateway `tsc` clean;
  `scripts/test-mac-reinstall.py` 69/69; `scripts/tron-version check` in sync;
  documentation, agent, protocol-contract and personal-info checks pass; the
  exact `mac verify` command check passes against the installed `efc88f1b5`
  Gateway.
- Signals: `observer.state-changed` `why` names the refusing admission check,
  and `http.upgrade` `peerProtocolVersion` names the stale side; either would
  have diagnosed its half of this incident in one step. Rows updated in
  `packages/gateway/docs/observability.md`.
- Deviation: done on `main` at the user's request so the installed app could be
  fixed before R-1, not on `hardening/integration`; integration picks it up
  when it next merges `main`. The build bump is deliberate: the build-7 wrapper
  in Update required cannot Pause, and a new build number makes the new
  wrapper's startup re-register (boot out and restart) the Gateway the old one
  started.
- For the next agent: the user installs the build-8 Release app (quit the old
  wrapper after Disable Helper for Update, replace, launch), then runs
  `scripts/tron mac verify`, then installs the iOS app from `main`. Building
  the Mac app from a shell whose PATH puts GNU `find`/`stat` first fails in
  `bundle-gateway.sh`; put `/usr/bin` first.
- Follow-up after the install (2026-09-29): the build-8 app's startup
  re-registered the Gateway (`launch-agent.unregister`, `register`, then
  Running on `0.1.0-beta.8`), `scripts/tron mac verify` passed, and the phone,
  reinstalled from `main`, opened a paired mobile connection. The live log
  showed the writer's fixed field list dropped `peerProtocolVersion` (the
  message kept "peer 5, Gateway accepts 6-6"): the lifecycle test asserted the
  mocked logger's input, not the persisted record. `GatewayLogger` now
  persists it, covered by `logger.test.ts` ("persists the protocol version a
  refused hello asked for", red first with `expected undefined to be 5`); the
  field reaches the installed app with the next Mac build.

### G-3a · Done · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/g-3a`)

- Result: streaming progress now follows the rule `publishSnapshot` already
  follows. `flushPendingProgress` returns before `projectMessage` /
  `boundStreamingProgressItem` / `safeJson` when `sessionAudience(id)` is 0, and
  `message_end`'s finalized declaration is serialized only with an audience. The
  two things beside those frames are slot state and stay on every path: the
  stream identity capture (`captureStreamIdentity`) and the tool-invocation
  group latch (`toolInvocationGroups`, which the projection in
  `finalizeToolInvocationGroups` still computes).
- Evidence:
  - Focused case `projects no streaming progress for a session with no
    subscriber and resumes it on subscribe` in
    `runtime-registry.integration.test.ts`: an unsubscribed stream settles with
    zero `session.progress` frames, then a subscribed stream produces frames
    (last one carries the watched text). Passes in 1.9 s; on the reverted half
    (source stashed, test kept) it fails at the zero-frame assertion
    (`1 failed | 244 skipped`).
  - Owning file: 244 passed | 1 failed. The failure is "keeps a large streamed
    write visible through snapshot recovery and canonical handoff" (its 5 s
    `!slot.isBusy` wait), and the unmodified file fails the same case the same
    way in a full-file run (243 passed | 1 failed); R-1's handoff already
    records it failing on `main`, so it is a pre-existing full-file flake, not a
    G-3a regression. That case reads `session.progress` frames, so it now
    subscribes an audience (G-3 deviation 4).
  - O-6a smokes, G-11's parameters (`--scenario multi-session --no-build
    --iterations 1 --cases none --catalog-files 100 --catalog-mib 512
    --mixed-seconds 30 --cpu-profile`): before
    `~/Library/Developer/Tron/profiles/gateway/20260929T061112Z-multi-session-4b25f5`,
    after `…/20260929T061654Z-multi-session-a18c7f`; both reports and both
    iteration CPU profiles are retained at
    `~/.tron/workspace/files/hardening/g-3a/` with the arithmetic in its
    `attribution.txt`, so the numbers outlive the profile sweep.
    - CPU profile, the same call path (the throttled timer's
      `flushPendingProgress`): exclusive subtree **551.7 → 193.5 ms** of 14.0 →
      13.8 s non-idle CPU (3.9% → 1.4%). The children the guard removes are
      `toolLabels` 129.7 → 7.5 ms, `projectMessage` 115.4 → 3.0 ms, `safeJson`
      75.0 → 0 ms, `boundStreamingProgressItem` 39.6 → 0 ms; what remains is the
      one subscribed session plus the guard itself (`sessionAudience` 22.9 ms +
      the `id` getter 26.4 ms over the run's ~3,200 no-audience windows).
    - Wire parity for the subscriber: mobile `session.progress` 177 → 178
      frames, 229,687 → 229,792 bytes. The projected frames a subscriber
      receives did not change.
    - Event loop: overall max 87.1 → 62.6 ms, p99 16.8 → 8.5 ms; no-subscriber
      window max 13.0 → 10.5 ms. Both runs were on a load ~10 host and the
      82 ms single run G-11 measured did not reproduce here (this branch's
      largest single flush run is ~9 ms before the fix), so the max delta stays
      inside host noise: the load-robust evidence is the profile attribution
      above plus the focused case. The exit numbers (max ≤ 250 ms, p99 ≤ 20 ms)
      remain O-6a's to measure.
  - Merge gate: this branch's base is `hardening/integration`'s head
    (`5eb6fa505`, 0 commits behind, nothing to merge); 133/133 across
    `session-archive`, `server-capacity`, `sync-protocol`, `stall-diagnostics`,
    `server-heartbeat` and `server-http-lifecycle` integration/unit files;
    `npx tsc --noEmit -p .` clean. No message shape changed, so protocol stays 6.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: one commit on `hardening/g-3a` (`packages/gateway/src/sessions/runtime-slot.ts`,
  its integration test, `packages/gateway/README.md`, this plan).
- Tasks added: none.
- Kept on purpose: `captureStreamIdentity` on the flush path — the streaming
  identity is slot state a later snapshot projects, and `message_update` captures
  it outside the flush too, so keeping the call preserves the subscribed path
  byte for byte; the pending message is still dropped per window (there is
  nothing to carry without an audience); the leading-edge/trailing-timer shape of
  `emitProgress` is unchanged, so a subscribed stream keeps its cadence.
- Deviations: (1) The plan has no `### G-3a` task-details section; the row,
  G-3's handoff ("G-3a owns the same rule for streaming progress frames") and
  the review nit are the whole contract, so the rule implemented is the row's
  no-audience one — not chunking or incrementally projecting the subscribed
  path, which no measurement here shows over 50 ms. (2) `finalizeToolInvocationGroups`
  keeps its projection and guards only the frame, because the group latch needs
  the projection. (3) One fixture gained an audience (the large-streamed-write
  case, above). (4) The before/after numbers are reported as profile
  attribution and wire parity rather than as an event-loop max delta, because
  the max is host noise on this host (see Evidence).
- For the next agent: a subscribed session still re-projects the whole
  cumulative streaming message once per 150 ms window (`projectMessage` +
  `boundStreamingProgressItem` + `safeJson` + `toolLabels`); if R-1's event-loop
  max is still driven by a subscribed stream, the next owner is an incremental
  streaming projection at the same site, and the guard above is what makes that
  work only about the one session a client is watching. A nonzero
  `unaudiencedSnapshotBuilds` warning still means an audience check was lost. The
  `session.progress` rule now matches `session.snapshot`: no subscriber, no
  frame.

### T-5 · Blocked · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/t-5`)

- Result: `AppModelInvalidationTests/providerCatalogResponsesRemainKeyed` no
  longer addresses the write log by position. The pair of reads each catalog
  load sends is found by method and scope and reserved, so an extra frame (a
  `cancel` control frame or a read the model appends for a reason the scenario
  did not pin) can no longer shift a tracked read: before, a shifted index
  answered the wrong request, the load the scenario meant to answer was never
  answered, and the scenario's `await load.value` ignored the watchdog's
  cancellation - the reported "blocked on a wait that ignores cancellation",
  since awaiting a child `Task`'s value does not observe the waiter's
  cancellation. A read that never reaches the socket now fails with a named
  `ScriptedReadMissing` instead of expiring the watchdog. The two `.global`
  pairs the scenario answers out of order stay distinguishable because each
  discovered read is reserved; which of `provider.list`/`model.list` is written
  first is not fixed (they are spawned concurrently), and neither was the old
  test's assumption - it filtered by method.
- What the check found: this scenario cannot be shown to receive a C-6 `cancel`
  frame - every load's Task is awaited, the scripted socket answers every
  request, `model.recent` and `auth.*` are never cancelled - so the shift class
  here is any read the model appends, not a cancel frame specifically. The fix
  covers both, and the addressing no longer depends on which class it was.
- Blocked on: validation. Every attempt at `scripts/tron-ios-test build` and
  `run` returned `error: iOS test simulator is already leased` for this
  worktree's whole session (first a stale-content holder, then the E-3c worker
  on the default lane, `pid 22138`), so the edited file was never compiled and
  the suite was never run. The change must be built and run
  (`scripts/tron-ios-test build` then `scripts/tron-ios-test run
  --only-testing TronMobileTests/AppModelInvalidationTests`) before it is merged.
- For the next agent: with the writes found by identity, the remaining
  positional assumption in the same file is `settingsResponsesRemainKeyed`,
  which still indexes frames 1-4 and 3-5 absolutely and has the same shape.

### F-2 · Done · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/f-2`, second pass)

- Root cause (driver, not Gateway): the O-6b page leg mounts `bandwidthInFlight`
  (default 6) pages **concurrently on the one mobile connection**, and a mobile
  connection holds exactly one presentation. `server.ts`'s `beginSynchronization`
  calls `revokePresentationOwners` for a `presentationOnly` (clientRole `mobile`)
  connection, which retires every other session's synchronization and
  subscription — synchronized or not. When the pages arrive faster than the cap
  delivers them, each page's `session.sync` reaches the Gateway after the next
  lane's open already retired its barrier, so `completeSynchronization` refuses it
  with "Session synchronization is no longer owned by this token". Every lane then
  retries, stays in lockstep, and a lane exhausts `retry("mount")`'s 40 attempts,
  which fails the driver (exit 1).
- The earlier "Gateway regression" reading was a mis-read of the artifact: in
  `20260929T072833Z-multi-session-357ca1` the first `session.open` on the fresh
  connection is answered with a 603,526-byte page, its `session.sync` answer is
  **104 bytes** (a success - `{synchronized:true}` is 104, the refusal is 188),
  and the `session.presentation.set` right after it succeeds, which is only
  possible once that barrier committed. The 271 refusals are the six page lanes.
  The reconnect is not the trigger: the run cited as passing
  (`20260929T061808Z-multi-session-9ebc17`, `--cases bandwidth`) carries **264
  identical `session.sync` conflicts** and only survived because its lanes drifted
  out of lockstep inside the retry budget.
- Fix (driver): `RecordingClient.openPresentation` numbers each `session.open`
  sent on a socket and reports whether a newer attempt superseded it;
  `MountedChat.open` then abandons a superseded page with the `{type:"cancel"}`
  frame the phone sends for a read it stopped waiting for (`C-6`,
  `GatewayDisposableReadPolicy` admits `session.open`) instead of synchronizing
  it. The page's bytes are still the load the connection carried, so the leg's
  measurements are unchanged in kind and its lane no longer fails on a mount the
  connection retired by design. `scripts/tron-profile-gateway-driver.mjs`.
- Contract pinned: `sync-protocol.integration.test.ts` gains "mobile presentation
  slot" — an answered mobile page whose successor retires it, the refusal of its
  `syncToken`, the phone's `cancel`, the newer page's commit, and the re-opened
  page synchronizing normally. The rule is now stated in `packages/gateway/README.md`
  (transport invariant 4) and the bandwidth leg's paragraph describes the new shape.
- Evidence (this branch): repro `scripts/tron-profile gateway --scenario
  multi-session --no-build --iterations 1 --catalog-files 300 --catalog-mib 256
  --mixed-seconds 60 --cases blackhole,bandwidth` is **green** in 5.0 min —
  `20260929T073639Z-multi-session-e06f2e`: `impairment.bandwidth.link_use` 0.993,
  `delivered_bytes_per_second` 248,270 B/s, `max_in_flight` 6, 327 operations,
  `max_ping_to_pong_ms` 1,840, 0 pong misses, 0 unexpected closes, and **zero
  `session.sync` refusals** in the fixture Gateway log (the failure run carried
  271). Before the fix the same command failed 1/1 on this branch
  (`20260929T072833Z-multi-session-357ca1`, 271 conflicts, driver exit 1).
  `npx vitest run src/transport/sync-protocol.integration.test.ts` 6/6, and the
  driver's own stub suites (`MultiDriverImpairment`, `MultiDriverWindows`,
  `ImpairmentCases`, `RelayBackpressure`) 25/25.
- Left for other rows (not F-2): the `bandwidth-stream` leg has the same
  one-presentation premise — it mounts up to `bandwidthStreamSessions` (7) chats
  sequentially on the one mobile connection, so each mount retires the previous
  subscription and its reported `streams` count is opens issued, not live
  subscriptions (one running session's ~300 kB/s of decoded state is what the leg
  actually measured). It passes today because sequential mounts synchronize before
  the next open, and because one stream alone out-produces the 0.08 Mbit/s cap.
  Proposed follow-up row: measure that leg as one live stream (or hold its streams
  on a technical connection), with its README paragraph and validator floor.

#### F-2 first pass (branch `hardening/t-5`) — superseded by the entry above

- Decided (then): **Gateway regression**, not a driver artifact. Concurrent page mounts
  on one connection are not the trigger: `scripts/tron-profile gateway
  --scenario multi-session --no-build --iterations 1 --catalog-files 300
  --catalog-mib 256 --mixed-seconds 60 --cases bandwidth` passes
  (`20260929T061808Z-multi-session-9ebc17`), while the same command with
  `--cases blackhole,bandwidth` fails 2/2 (`20260929T062215Z-multi-session-cbeb96`,
  and the row's original `20260928T235606Z-multi-session-471100`). The trigger is
  the mobile's fresh connection after the Gateway closes its blackholed socket by
  heartbeat timeout (`connection.heartbeat-timeout`), not the page leg itself.
- Evidence (all three runs agree): the mobile reconnects, `connection.opened`
  records a new connection id, and the **first** `session.open` on it is answered
  (604179 bytes in `cbeb96`), the `session.sync` that immediately follows with
  that response's `syncToken` is refused with `conflict` "Session synchronization
  is no longer owned by this token" 0.7 ms later, and 243 more `session.sync`
  refusals follow on that one connection until the run ends. The open response
  and the refused sync are on the same socket (the driver's timeline shows no
  reconnect between them), so `server.ts`'s `completeSynchronization` refuses a
  token its own `beginSynchronization` had just installed for that connection.
  `session.progress` frames arrive unquarantined right after the refusal, so the
  session's `SessionSyncBarrier` was already gone - the synchronization was
  revoked, not merely mismatched. No `gateway.shed`, `transport.resyncRequired` or
  other warning record precedes it.
- Repro artifact: `~/Library/Developer/Tron/profiles/gateway/20260929T062215Z-multi-session-cbeb96`
  (`driver-iteration-1.log` names the failure; `fixture/gateway.jsonl` carries the
  243 `rpc.error session.sync` records on `640e5b53`).
- Left: the root cause. Candidates narrowed by the evidence, in the transport
  barrier paths (`src/transport/server.ts`): the open handler's
  `releaseOwnSynchronizations` (`finally`, when `rpcOutcome` is not success),
  `revokeAbandonedOpen`, and `beginSynchronization`'s deterministic replacement
  of an installed token. The failing open is the first mount on a connection that
  replaces one the Gateway closed itself, which points at a revoke that outlives
  the connection that owned the open, or at a delivered open response whose
  barrier is released before its `session.sync` can commit. Start from a focused
  `sync-protocol.integration.test.ts` case that reproduces "open answered, then
  the sync of that same token refused" before touching the code.
- Deviation: F-2 was dispatched to this lane with T-5; the two are unrelated and
  the T-5 change (iOS test) does not touch the Gateway, so nothing here depends on
  an unvalidated edit.

### T-6 · Done · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/t-6`)

- Result: both cases are deterministic, and neither flake was a product race.
  (1) "keeps a large streamed write visible through snapshot recovery and
  canonical handoff" spent 4.3–5.4 s of its 5 s `waitUntil(() => !slot.isBusy)`
  guard streaming the same 51 KB write: the faux provider's default 12–20
  character chunks make 3,188 chunks, each paying a real ~1.7 ms `setTimeout`
  floor, so the case sat ~0.7 s from its own guard and any host load tipped it
  over. The write's size and every assertion stay; only the provider's chunk size
  changed (`tokenSize: { min: 32, max: 32 }`, 400 chunks).
  (2) "does not reopen an unchanged ambient artifact for a live slot" failed as
  `extension artifact discovery stayed in flight`: `discoverExtensionArtifactsUntil`
  capped its wait for an *interval* pass at 5 s, and one pass over this case's
  production-shaped root (2,498 entries, 558 `status.json`) is 90–216 ms idle but
  far longer on a loaded host. The helper now waits for the running pass to end
  and keeps its 5 s `deadline` for the retries it starts itself, so
  "did not settle" stays bounded and the test's own timeout reports a pass that
  never ends.
- Evidence: reproduction on the pre-change file — whole file twice in parallel:
  run B failed test 1 at `waitUntil` (line 6692); 12 targeted runs of test 2 under
  two parallel whole-file runs: run 11 failed `stayed in flight` (line 5738). The
  same case measured by the helper's own probe: an interval pass takes 141–334 ms
  to wait out and a pass 90–216 ms idle (test 2 alone 2.4 s). The single frame
  test 1 asserts on is unchanged by the pacing: the finalized declaration with a
  4,238-byte argument preview, `streaming` equal to the published frame
  (`declarations` was already length 1 before the change, at every chunk size
  from 4 to the default). After the change: `npx vitest run
  src/sessions/runtime-registry.integration.test.ts` **245/245, three runs in
  parallel, 127.9–129.5 s of tests**; 8/8 targeted runs of each case under three
  parallel whole-file runs; test 1 alone 647–756 ms of test time (4.34–5.4 s
  before). Merge gate on this branch (already up to date with
  `hardening/integration` `18185b61f`): six-file transport set **134/134**,
  `npx tsc --noEmit -p .` clean, `python3 scripts/check-documentation-policy.py`
  and `scripts/personal-info-guard.sh` pass.
- Changes: `packages/gateway/src/sessions/runtime-registry.integration.test.ts`
  only (the discovery helper's barrier and the write case's provider pacing). No
  product code and no owning doc change: no behavior changed.
- Keeping on purpose: the 51 KB write, the 2,498-directory fixture, and every
  assertion of both cases.
- For the next agent: the discovery helper's remaining 5 s is a *retry* budget
  for predicates, not a pass budget. The ambient pass itself is bounded per pass
  by entries (4,096) and reads (1,024), not by time, and one pass over a
  production-shaped root costs one `stat` per entry every 750 ms — measured here
  at 90–216 ms idle. A future row that wants pass *latency* bounded, rather than
  pass *work*, starts there; the two cases are deterministic without it.


### E-3d · Done · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/e-3d`)

- Result: `lanEndpoint.enabled` defaults to true for a Gateway that is not bound
  to loopback, so the release and the evaluation day serve the pinned LAN lane;
  a loopback bind (`127.0.0.0/8`, `::1`, `localhost`) keeps one loopback
  listener exactly as before E-3a, and `--lan-endpoint on` forces the lane on
  there. `--lan-endpoint off` and `TRON_GATEWAY_LAN_ENDPOINT=off` take it down
  and stay the kill switch for R-4. The parser, the CLI/env precedence and the
  invalid-value refusal are unchanged.
- Review fixes (both majors): (1) the kill switch is now documented on the route
  the Mac-supervised release can actually take. The wrapper's LaunchAgent
  program arguments and environment are the ownership contract
  (`ExistingInstallDetector`, `LiveLaunchAgentManager`, `StableGatewayProvenance`
  all reject any extra flag or variable), so neither spelling can ride in the
  plist; `launchctl setenv TRON_GATEWAY_LAN_ENDPOINT off` reaches the Gateway
  because `tron-gateway-launcher.c` only `setenv`s a fixed list and then
  `execv`s. The README and connection-resilience doc name that route, its
  `launchctl unsetenv` reversal, the next-start scope, and the
  `reason=setting_off` record; both state that the end-to-end proof on an
  installed release is still owed (R-2/R-4, see the row notes). Nothing was set
  on this host. (2) The default now reads the resolved bind host, so profiling
  and qualification fixtures that bind loopback (`scripts/tron-profile-gateway`,
  O-6a/O-6b, G-13) create no certificate, open no second listener and poll
  nothing, and the `AGENTS.md` "developer default is loopback" invariant is true
  again.
- Evidence: `scripts/ios-gateway-e2e-test run-lan` green 108 s (status 0, case
  passed 93.1 s, 1/1 with 0 failures), artifact
  `${TMPDIR}/tron-ios-gateway-e2e-501/results/20260929T102055Z-run.ZnxmTI/FocusedE2E.xcresult`.
  Focused Gateway suites: `npx vitest run src/config.test.ts
  src/transport/lan-endpoint.integration.test.ts` **40/40** in 19.4 s; the config
  case now asserts loopback default off, non-loopback default on (flag and env),
  `--lan-endpoint on` with loopback, and the invalid-value refusal. Default proof
  at the process level, three private fixtures from this worktree's
  `dist/index.js` (own `HOME`/`TRON_DATA_DIR`/`PI_CODING_AGENT_DIR`, free port,
  started and killed by this worker): loopback with **no** LAN setting logged
  `LAN endpoint disabled (state=disabled reason=setting_off)` and wrote no
  certificate directory; loopback with `on` logged `state=bound`; `tailscale`
  with **no** LAN setting logged `state=bound`. Merge gate with
  `hardening/integration` at `adb0887b6` (already the branch's base, nothing to
  merge): transport six-file set **134/134**, runtime-registry **245/245**,
  `npx tsc --noEmit -p .` clean. `python3 scripts/check-documentation-policy.py`
  and `scripts/personal-info-guard.sh` pass.
- Changes: `packages/gateway/src/config.ts` (host-scoped default),
  `packages/gateway/src/config.test.ts`, `packages/gateway/README.md` transport
  section, `packages/gateway/docs/connection-resilience.md` (Tailscale flaps),
  `AGENTS.md` exposure invariant. No transport, iOS or E2E-harness change: the
  harness's explicit `off` for the boundary case and `on` for `run-lan` still
  win over either default.
- Keeping on purpose: the harness's explicit `e2e_lan_endpoint` values. They are
  not redundant with the default: `run` needs the lane off so the fault proxy
  owns every leg of the boundary case, and the explicit values keep both E2E legs
  reproducible whatever the default is.
- Deviations: the release default is host-scoped (the review's option 2a), not a
  bare `true`; a loopback-bound Gateway therefore needs `--lan-endpoint on` for
  the lane.
- For the next agent (R-2): the LAN kill switch's end-to-end proof on an
  installed release is owed — `launchctl setenv TRON_GATEWAY_LAN_ENDPOINT off`,
  the user restarts the Gateway, and `lan.listener state=disabled
  reason=setting_off` appears. For R-4: the evaluation day's LAN review reads
  `lan.listener` transitions plus `transport=lan` on `http.upgrade`, so a user
  who turned the lane off is distinguishable from a Mac that never had a private
  address (`reason=no_private_address`), and a loopback-bound Gateway is
  distinguishable too (`reason=setting_off` with no user switch).

### F-3 · Done · 2026-09-29 · orchestrator-dispatched deepseek-worker (branch `hardening/f-3`)

- Result: a hello whose protocol the Mac cannot speak is now a typed close
  (`PROTOCOL_MISMATCH_CLOSE_CODE` 4006 + JSON close reason
  `{code:"protocol_mismatch",gatewayProtocol,minProtocol}`), and the phone
  classifies that close as the non-retryable `protocol_mismatch` it already
  stops recovery on, with a message that names the build to update ("Update Tron
  on the Mac" / "Update Tron on this iPhone"). Both the selected lifecycle and a
  dashboard pool entry stop retrying; the device-detail Status group shows the
  reason durably, and the transient notice keeps the existing surface.
- Changes: `packages/gateway/src/transport/server.ts` (close code, reason
  builder, `closeFailedConnection` gains the optional wire reason),
  `packages/ios-app/Core/Gateway/GatewaySocketTransport.swift` (peer close
  reason on `GatewaySocketMetadata`), `GatewayProtocolContract.swift`
  (`GatewayProtocolMismatchClose`: close code, reason decode, message),
  `GatewayClient.swift` (classify the hello close; the post-hello range check
  now uses the same message), `packages/ios-app/Sources/UI/Settings/ConnectionSettingsView.swift`
  (Status group shows the selected profile's stop reason), owning tests, and the
  gateway connection-resilience + iOS development docs.
- Evidence: `npx vitest run src/transport/server-http-lifecycle.integration.test.ts`
  **21/21** (the refusal case is now `it.each([5, 99])`: asserts close 4006, the
  JSON range, and the ≤123-byte control-frame bound); merge gate on this branch
  (up to date with `hardening/integration` `adb0887b6`): six-file transport set
  **135/135** in 37.7 s, `npx vitest run src/sessions/runtime-registry.integration.test.ts`
  **245/245** in 139.1 s, `npx tsc --noEmit -p .` clean.
  iOS (lane `F3`, `scripts/tron-ios-test build` + `run`): 3 suites
  **175/175** in 10.3 s (`20260929T095829Z-run.IIpJMs`), including
  `GatewayClientTransportTests/a typed protocol-mismatch close names the build
  that must update` (older Mac and older app), `AppModelReconnectTests/a
  protocol-mismatch close stops recovery and names the stale build` (state
  `.offline("…Update Tron on the Mac")`, one socket attempt, `reconnect.stopped
  … code=protocol_mismatch nonRetryable=true`), and `DashboardStateOwnerTests/
  dashboard protocol mismatch stops retrying the background profile`
  (`.offline`, `factory.requests.count == 1`).
  `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- Kept on purpose: 1008-class refusals for `hello_required`/`invalid_frame`/
  revocation; the `http.upgrade` record (unchanged, already
  `reason=protocol_mismatch` + `peerProtocolVersion`); the existing
  `GatewayRecoveryFailurePolicy`/pool non-retryable plumbing and the post-hello
  range check; a protocol-5 *phone* still cannot decode the new close, which no
  phone-side change can fix.
- Deviation: none beyond the durable Status-group row (the notice alone is
  transient); the close reason is not added to the iOS `gateway.connection`
  record — the existing `closeCode=4006` + `reason=protocol_mismatch` pair
  already names it in one step.
- For the next agent: the 4006 code and reason shape are the contract
  (`packages/gateway/docs/connection-resilience.md`, "Failure boundaries"); a
  future protocol bump keeps `PROTOCOL_VERSION`/`MIN_PROTOCOL_VERSION` in
  `config/GatewayProtocol.json` as the single authority. A real-device check of
  the old-Mac scenario is R-2's install, not this row.

#### F-4 · Blocked · 2026-09-30 · orchestrator-dispatched deepseek-worker (branch `hardening/f-4`)

- Result: removed the ineffective `ws.bufferedAmount` gate and its private
  `_socket`/`drain` hook, and deleted the test that modeled an unreachable
  production state. One-frame-at-a-time `ws` sends do not bound bytes accepted
  into kernel/path buffers; F-4 remains blocked pending a mechanism that does.
- Evidence: reviewer's real-`ws` probe observed 1,114,112 bytes written with a
  paused reader, zero gate closures and zero `drain` events; this disproves the
  gate rather than qualifying F-4. After removal, focused merge-gate checks
  passed (6 files/135 tests; registry 245 tests) and `tsc --noEmit` passed.
- Qualification blocked: both before-change profile attempts using
  `scripts/tron-profile gateway --scenario multi-session --no-build --iterations
  1 --cases bandwidth-stream,bandwidth` stopped in `prime` because
  `session.list` returned `busy: The session catalog has not been read yet`;
  the fixture's `gateway.startup-step attention-recovery` took 11.5 s, beyond
  the driver's retry window. Host load was 61–87 with parallel iOS builds, so no
  after-change numbers or claim against the pong deadline/link-use targets are
  available. The stored R-1 baseline remains `bandwidth-stream` 24,430–24,577 ms,
  2 deadline misses; `bandwidth` max ping 1,558–1,622 ms, 0 misses and link use
  0.979–0.993.
- For the next agent: re-run the prescribed before/after qualification on a
  quiet host. Do not mark Done unless `bandwidth-stream` has zero deadline
  misses and ping-to-pong well under 8 s without regressing the `bandwidth` leg.

#### F-3 review round 1 · 2026-09-29

- Result: (1) **no compatibility bridge** for a Gateway built before this close
  (Option B, orchestrator decision): `1008 "protocol version mismatch"` stays a
  retryable transport failure, every fixture now models the close a shipped
  Gateway actually sends (4006 carrying the Gateway's own protocol range), and
  the Gateway README, `connection-resilience.md` and the iOS contract state that
  a Mac must run an F-3 Gateway before the typed close protects it. (2) A
  background profile's non-retryable stop keeps its message on the pool entry
  (`stopReason(for:)`), publishes it with the state, and the device detail reads
  it for any profile via `AppModel.dashboardConnectionStopReason(for:)`. (3) A
  protocol/identity mismatch on the LAN lane is reported as its own reason
  instead of `lan_unreachable`. (4) The terminal client maps close 4006 to a
  non-retryable `protocol_mismatch` naming the stale side instead of showing the
  raw JSON reason.
- Changes: `packages/gateway/src/version.ts` now owns
  `PROTOCOL_MISMATCH_CLOSE_CODE` (the transport and the terminal client both read
  it; `server.ts` cannot be imported from a client process),
  `src/client/gateway-client.ts`, `DashboardGatewayConnectionPool.swift`,
  `AppModel.swift`, `ConnectionSettingsView.swift`, `GatewayClient.swift`,
  `GatewayProtocolContract.swift`, the owning tests, the three docs.
- Evidence: `npx vitest run src/transport/server-http-lifecycle.integration.test.ts`
  **21/21**, `npx vitest run src/client/gateway-client.test.ts` **5/5**; merge
  gate on this branch (up to date with `hardening/integration` `adb0887b6`):
  six-file transport set **135/135** in 15.7 s, `runtime-registry.integration.test.ts`
  **245/245** in 72.4 s, `npx tsc --noEmit -p .` clean. iOS (lane `F3`): three
  suites **177/177** (`20260929T102047Z-run.Yl0vZd`) plus `GatewayClientLanLaneTests`
  **18/18** (`20260929T102149Z-run.HEP2Er`); reverting only the LAN change makes
  the new LAN test fail (`.lanUnreachable` vs `.protocolMismatch`), so it is not
  vacuous, and the narrowed range-message assertion re-ran
  `GatewayClientTransportTests` **61/61**. `python3 scripts/check-documentation-policy.py` and
  `scripts/personal-info-guard.sh` pass.
- For the next agent: the Option B residual is real — a phone whose Mac still
  runs a pre-F-3 Gateway keeps retrying the mismatch until that Mac is updated,
  and R-2 installs both sides; the close code now lives in
  `packages/gateway/src/version.ts`.
