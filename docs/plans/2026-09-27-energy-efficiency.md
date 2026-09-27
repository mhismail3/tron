# Energy efficiency

- **Started:** 2026-09-27
- **Status:** Active (approved in chat by the user on 2026-09-27)
- **Last updated:** 2026-09-27, T1-CACHE, T1-DRAFTS and T3-DEFLATE claimed
- **Goal:** Tron for iPhone does measurably less CPU, disk, timer and radio work per minute of real use, proven by a reliable profiler that every agent can run, with no change to what the user sees or does.

## Goal and constraints

The user asked for every performance and battery improvement from the
2026-09-27 audit (tiers 1–3) that leaves the UI and UX untouched, and for a
robust, agent-callable profiler first, so every change and every future
bottleneck is judged by data.

What must not change, overriding any agent's judgment:

- **UI and UX.** Screens, copy, layout, animation curves and timing, scroll
  position and continuity, chat identity, composer and keyboard behavior,
  accessibility labels and VoiceOver output, and any timing a user can feel
  (launch, open, send, streaming cadence, reconnect, dead-socket detection).
  A change that alters a pixel, a frame sequence or a label value at the same
  instant is out of scope. When in doubt, the change does not ship and the doubt
  goes in a handoff entry for the user.
- **Correctness and resilience.** Canonical truth, ordering, idempotency,
  bounds, cancellation, recovery and every `AGENTS.md` architecture invariant.
  Performance work may only make these stronger.
- **Wire contracts.** Old iPhone builds and old Gateways keep working unchanged.
  Protocol savings are additive and negotiated per connection; a Gateway sends
  today's payload to any client that did not ask for the new form, and falls
  back to today's full payload whenever it cannot prove the compact form is
  exact. The phone fails closed to its existing authoritative resynchronization.
  Mac-first rollout still holds.
- **Coordination.** Do not change the client ping interval, pong deadline,
  reconnect or retry policy; the
  [phone reconnect tuning plan](2026-09-24-phone-reconnect-tuning.md) owns those.
  Transcript container work belongs to the
  [chat transcript stability plan](2026-09-26-chat-transcript-stability.md);
  this plan only reduces work inside today's container and must pass its CT-12
  visual and CT-14 motion parity gates. Rebase over the
  [iOS module split](2026-09-23-ios-module-split.md) if MS-3 starts.
- **Operational safety.** Never rebuild, restart or update the running Gateway;
  Gateway changes take effect only when the user does. Profiling runs an
  isolated fixture Gateway, never the user's. Agents never install on a
  physical device and never erase app or Keychain data.

## Context

Findings of the 2026-09-27 read-only audit (six review lanes plus the
integrator's own verification). Line numbers are from that date.

Already good, keep: no background execution or silent pushes; continuous
animations are gated by surface, scene, viewport and Reduce Motion and capped
at 30 fps; no `CADisableMinimumFrameDurationOnPhone`; transcript projection is
off the main thread; hosted fixtures compile out of shipping builds.

Measured nothing yet. The existing opt-in baseline in
`packages/ios-app/Tests/UI/ChatPerformanceBaselineTests.swift` runs only under
the `DevicePerformance` scheme, whose build is unoptimized, and its documented
simulator command in `packages/ios-app/docs/performance-baseline.md` cannot
enable it (the `Tron Development` test action does not map
`TRON_PERFORMANCE_BASELINE`), so there is no trustworthy agent-runnable
measurement today.

Highest-cost mechanisms found:

- Gateway `emitProgress` in `packages/gateway/src/sessions/runtime-slot.ts`
  sends two frames per 150 ms window (leading edge fires again right after each
  trailing flush), each carrying the whole reply so far (≤ 24 KB).
- Every canonical append republishes a full `session.snapshot` (transcript page
  up to 600 KB inside ≤ 800 KB), about twice per tool call.
- `SnapshotCache` is rewritten after every `session.summary` and after mounted
  snapshot events that cannot change it (five checkpoint calls in
  `packages/ios-app/Sources/State/SessionPresentationStore.swift`).
- `ComposerDraftStore.save` re-reads and SHA-256s every stored draft attachment
  twice per 200 ms typing pause.
- `discreteInsertedIDs` in
  `packages/ios-app/Sources/UI/Chat/ChatTranscriptPresentationStore.swift` is
  O(n²) on the main thread; `ChatStreamingInlineText` in
  `packages/ios-app/Sources/UI/Chat/StreamingTextReveal.swift` splits settled
  paragraphs into words and rebuilds whole blocks 18–30 times a second while
  revealing.
- Idle timers: one unaligned 1 Hz clock per dashboard row, 10 Hz tool timers
  after the label drops to whole seconds, unaligned 10 s pings per socket, a
  15 s lease RPC and the Gateway's 25 s ping; every HTTP request builds its own
  `URLSession`, so live view opens a new TCP connection 4–5 times a second.
- `session.bashProgress` (per stdout chunk, unthrottled) and `session.heartbeat`
  have no consumer anywhere.

Measured 2026-09-27 with a throwaway local probe: Apple's
`URLSessionWebSocketTask` (macOS 26 CFNetwork, the stack iOS shares) offers
`Sec-WebSocket-Extensions: permessage-deflate` with no parameters and decodes
compressed context-takeover messages correctly. The Gateway's WebSocket server
sets `perMessageDeflate: false` in `packages/gateway/src/transport/server.ts`,
so nothing is negotiated today. Enabling it would compress every frame to the
phone with no protocol or iOS change; with context takeover, a cumulative
streaming frame compresses to roughly its new text. The iOS simulator runtime
still has to confirm the same offer (T3-DEFLATE).

## Plan rules

- **Measure, then keep.** Every T task records the relevant profiler scenario
  before and after on the same host state with the profiler's `compare`, plus
  its focused tests. Keep a change only if correctness passes and it improves
  its primary metric beyond the report's noise bound, or it is a pure
  simplification with no regression; record the numbers in the handoff.
- **Prove no UI change.** Any task that touches views, text, timelines or
  transcript projection runs the CT-12 visual parity and CT-14 motion parity
  hosted gates and the owning focused suites. Pure-function replacements get an
  equivalence check against the old implementation over generated inputs.
- **Worktrees and simulators.** Each task runs in its own worktree under
  `~/Workspace/tron-perf-<id>` on branch `perf/<id>`, with its own test
  simulator (`TRON_IOS_TEST_DEVICE_NAME="Tron iOS Tests Perf <ID>"` and a
  matching `TRON_IOS_TEST_STATE_DIR`). Profiling comparisons that decide a keep
  are run by the integrator on a quiet host, serialized through the profiler's
  lease.
- **Excluded as product decisions** (need the user's explicit choice, not part
  of this plan): stopping the composer orb in its recently-finished state, Low
  Power Mode motion reduction, slower offline-Mac retries, a longer ping
  interval, closing other Macs' sockets inside a chat, batching timestamp-only
  summaries (visible label lag), and receipt-poll backoff (confirmation timing).

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| P-1 | Claimed | iOS scenario profiler (new `tron-profile` in `scripts/`, `ios` subcommand), optimized profiling build, in-process energy metrics, deterministic scenarios, control self-test, JSON reports (details below) | none | energy-efficiency supervisor, worker lane p1, 2026-09-27 |
| P-2 | Claimed | Gateway wire-traffic profiler (`gateway` subcommand), isolated fixture Gateway with a faux model, recording client, per-topic frame and byte report (details below) | none | energy-efficiency supervisor, worker lane p2, 2026-09-27 |
| P-3 | Needs scoping | Attribution: `--trace` for iOS scenarios (xctrace Time Profiler, SwiftUI, Points of Interest; exported top-symbol summary) and an attach-only `device` mode for a user-launched LocalDevice app | P-1 | |
| P-4 | Needs scoping | Baseline: run every P-1 and P-2 scenario on `main`, record the numbers and host state in this plan's Context | P-1, P-2 | |
| T1-GW | Claimed | Gateway: re-arm the streaming throttle; delete `session.bashProgress` and `session.heartbeat`; skip the heartbeat ping while a client proved liveness within the interval, keeping today's detection bound | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-gw, 2026-09-27 |
| T1-CACHE | Claimed | `SnapshotCache`: drop checkpoints that cannot change it, coalesce summary checkpoints and checkpoint on background, drop the save-path double admission pass | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-persist, 2026-09-27 |
| T1-DRAFTS | Claimed | `ComposerDraftStore`: in-memory logical clock, size accounting without re-hashing, manifest-only writes when attachments are unchanged; no observable mutation for unchanged text | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-persist, 2026-09-27 |
| T1-TEXT | Claimed | `discreteInsertedIDs` to O(n) with an equivalence check; `ChatStreamingInlineText` keeps settled text whole (preserving the streaming-flip reveal state) and caches the revealed prefix | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-text, 2026-09-27 |
| T1-CLOCKS | Ready | Timeline schedules that fire when a label can change: dashboard rows, tool elapsed timers (sub-minute cadence preserved), static inbox formatter | none (keep decision: P-1, P-2) | |
| T1-NET | Ready | One shared ping grid for every socket (no interval ever longer than today), lease renewal on that grid at no longer than today's interval, one shared `URLSession` for idempotent GETs with per-task delegates | none (keep decision: P-1, P-2) | |
| T3-DEFLATE | Claimed | Negotiate `permessage-deflate` for paired (non-loopback) clients that offer it; confirm the offer from the iOS simulator app, keep inbound size bounds on decompressed bytes, and keep outbound queue accounting and backpressure exact | none (keep decision: P-2) | energy-efficiency supervisor, worker lane t3-deflate, 2026-09-27 |
| T2-CHATVIEW | Needs scoping | ChatView observes the snapshot and the installed transcript in separate child scopes; response state computed with the installed transcript | T1-TEXT | |
| T2-DASH | Needs scoping | Dashboard root stops re-evaluating on every summary; parsed ordering instants; cheaper per-row path helpers; filter preferences saved only on change | T1-CLOCKS | |
| T2-THINK | Needs scoping | Thinking trace measures its visible text instead of a hidden full copy | T1-TEXT | |
| T2-TEXTPREP | Needs scoping | Text preparation reuses history rows on the isolated streaming path and memoizes closed Markdown blocks | T1-TEXT | |
| T2-SMALL | Needs scoping | AppLog debug encode and restore ordering, diagnostics sanitized once, debounced extension drafts flushed on close and background, direct thumbnail images, push token writes only on change | P-4 | |
| T3-TRANSCRIPT | Needs scoping | Transcript append deltas for `session.snapshot` (deflate cuts its radio bytes but not the phone's decode of up to 800 KB per snapshot), negotiated per connection, exact-or-full on the Gateway, digest-verified with fail-closed resync on the phone | T3-DEFLATE | |
| T3-STREAM | Needs scoping | Streaming text append deltas for `session.progress`, same rules; only if P-2 shows progress bytes or decode cost still material after T3-DEFLATE | T3-DEFLATE | |
| T3-TOOLPROG | Needs scoping | Tool progress omits a `partialResult` the phone can reconstruct exactly, same rules; only if still material after T3-DEFLATE | T3-DEFLATE | |
| T3-CATALOG | Needs scoping | Conditional `session.list` on foreground: an unchanged catalog generation keeps the retained rows | P-4 | |
| V-1 | Needs scoping | Close-out: full Gateway and iOS suites, parity gates, profiler comparison against P-4, owning docs, user device check | all | |

## Task details

### P-1 — iOS scenario profiler

The profiler is the evidence source for this plan and for future bottlenecks,
so it must be boring to run and hard to misread.

- **Front door:** new `tron-profile` in `scripts/`, with `ios`, `compare` and
  `status` subcommands (P-2 adds `gateway`), `--help`, stable exit codes, and
  bounded processes through `scripts/ios-test-process.py`. It reuses the owned
  simulator, lease lock and build-identity stamping of `scripts/tron-ios-test`
  (same environment overrides), so it never collides with test runs.
- **Build:** measurements come from an optimized build. Make the existing
  `DevicePerformance` configuration optimized (Swift `-O`, testability kept for
  hosted tests, `HOSTED_TEST` kept) rather than adding a configuration or
  scheme, and make the `Tron Device Performance` test action runnable on the
  owned simulator. Fix the baseline enablement so the documented command works.
  Update `packages/ios-app/docs/performance-baseline.md`,
  `packages/ios-app/docs/development.md` and the tron-ios skill routing table.
- **Metrics (in-process `XCTMetric`s, reported to the xcresult):** instructions
  and cycles retired, process CPU time, main-thread CPU time, CPU energy,
  interrupt and platform-idle wakeups, disk bytes written and read, logical
  writes, peak memory footprint, plus scenario counters (frames and bytes the
  scripted transport delivered). Instructions are the primary CPU metric
  because they are the least sensitive to host contention.
- **Scenarios** use production owners (`AppModel`, stores, mounted SwiftUI
  views) with scripted Gateway transports at realistic cadence, deterministic
  seeds and a fixed window: idle dashboard, idle chat, streaming reply (with
  thinking), tool loop with snapshots, composer typing with draft attachments,
  and a multi-session summary storm. Reuse `SessionScenarioBuilder` and the
  real burst fixture where they fit.
- **Report:** one JSON report per run (schema-versioned; git revision, dirty
  state, worktree, Xcode, runtime, host load, booted simulator count, power
  source and thermal state) plus a short Markdown summary, under a stable
  directory outside the repository with a `latest` link. Each metric carries
  unit, direction, samples, median and spread. `compare` reports per-metric
  deltas against the noise bound and exits nonzero on a regression beyond it.
- **Self-test:** a control scenario and its known-bad variant (a fixed extra
  workload that exists only in hosted builds) must show the expected delta, so
  a broken measurement path fails loudly instead of reporting zeros.
- **Docs:** usage in `packages/ios-app/docs/development.md` and the
  [tron-performance skill](../../.agents/skills/tron-performance/SKILL.md) as
  the default way for agents to measure; observability rows if new signals are
  added.

### P-2 — Gateway wire-traffic profiler

- The profiler's `gateway --scenario <name>` subcommand builds the Gateway, starts
  an isolated fixture Gateway in a temporary home (the pattern in
  `scripts/ios-gateway-e2e-test`: faux provider, fixed tokens per second, no
  user state), connects recording WebSocket clients (one subscribed mobile
  client, one dashboard-only client) and runs a scripted session.
- Scenarios: streaming reply with thinking, tool loop with a large prior
  transcript, idle connection for a fixed window, dashboard observer while
  another session runs.
- Report (same schema and `compare` as P-1): frames and bytes per topic per
  client, per-second rates, largest frame, pings and pongs each way, and
  optional Node CPU profile. Always stops and removes the fixture Gateway,
  including on failure and timeout.

### T1 tasks — shared rules

Implementation may start before P-4; the keep decision needs the profilers
(P-1 for iOS, P-2 for the Gateway) and a baseline measured on the same host
state. Each T1 task names its primary scenario; the supervisor runs the
comparison before merging.

### T1-GW — Gateway send discipline

Primary scenario: Gateway `stream-reply`, `tool-loop`, `idle`.

- `emitProgress`: keep the immediate first frame after a quiet window, then at
  most one frame per `STREAMING_PROGRESS_FLUSH_MS`: when the timer fires with a
  pending message, flush it and re-arm; clear the timer only when nothing was
  pending. Existing flush points (`publishSnapshot`, message end, dispose) keep
  their ordering guarantee. Tighten the integration bound that today admits up
  to 40 frames so the doubled cadence fails it.
- Delete the `session.bashProgress` and `session.heartbeat` emissions after
  proving no consumer in Gateway, iOS, Mac, scripts or fixtures; the
  heartbeat's `publishSummary()` stays.
- Heartbeat: every tick still counts toward `unansweredHeartbeats` (so a dead
  client is retired at exactly today's tick), but the ping is sent only when
  the connection has been silent for at least one heartbeat interval. A client
  that pings every 10 s is never pinged; a silent or pong-only client still is.
  Update `packages/gateway/docs/connection-resilience.md` and the heartbeat
  tests, including a dead-client termination-time test.

### T1-CACHE — Session list cache writes

Primary scenario: iOS `tool-loop`, `summary-storm` (disk bytes written,
logical writes).

- Prove what `SnapshotCache` stores, then delete checkpoint requests that
  cannot change it (the `sessionPresentationStoreCheckpointCache` path) with
  their delegate method.
- Summary updates schedule a trailing, coalesced checkpoint instead of an
  immediate one; authoritative page publication, archive and delete keep their
  immediate checkpoint; entering the background flushes a pending checkpoint
  inside the existing background task assertion
  (`packages/ios-app/Sources/App/AppBackgroundCheckpointCoordinator.swift`).
  A cold start after a normal background exit must show exactly today's rows.
- Remove duplicate admission work on the save path only if the load path
  keeps every bound.

### T1-DRAFTS — Composer draft persistence

Primary scenario: iOS `composer-typing` (disk bytes read and written,
instructions).

- The store actor owns its root, so recover the logical clock once per process
  and keep it in memory; global bounds use manifest sizes and file sizes, not
  payload reads and hashes; a save whose attachments are unchanged rewrites
  only the manifest, atomically. `load()` keeps full verification, so corrupt
  drafts are still discarded before restore.
- `setText` with unchanged text must not mutate observed state.
- Crash-consistency contract unchanged: a crash at any point leaves either the
  previous or the new complete draft.

### T1-TEXT — Transcript text work

Primary scenarios: iOS `streaming-reply`, `tool-loop` (main-thread CPU,
instructions); gates: CT-12/CT-14 parity, focused transcript suites.

- `ChatTranscriptTransitionPolicy.discreteInsertedIDs`: build the previous
  semantic-ID set once and hoist the next semantic lookup, so the pass is
  linear; identical output for every input (verify against the old
  implementation over generated transitions before deleting it).
- `ChatStreamingInlineText`: when not streaming, keep the text as one
  authoritative token (no word split) while preserving exactly what a later
  switch to streaming would reveal or fade; while revealing, build the fully
  revealed prefix once per token revision and append only the pending tail,
  so a tick costs the ≤ 18 pending words instead of the whole block.
  Rendered attributed text must be identical frame for frame.

### T1-CLOCKS — Presentation clocks

Primary scenarios: iOS `idle-dashboard`, `tool-loop` (wakeups,
instructions).

- Dashboard rows: a `TimelineSchedule` that yields the next instant at which
  the row's relative label (and its accessibility text) can change, so a row
  re-renders when its text changes and not otherwise. The label shown at any
  instant must equal today's label at that instant or be fresher by less than
  today's one-second lag.
- Tool elapsed timers: keep each view's current sub-minute cadence (0.1 s,
  0.5 s, 1 s) and phase; after a minute tick on whole-second boundaries of the
  elapsed value, after an hour on whole minutes.
- Notification inbox: one formatter with identical output instead of one per
  row per second.

### T1-NET — Wakeup alignment and connection reuse

Primary scenarios: iOS `idle-chat`, `idle-dashboard` (wakeups); live view by
manual comparison.

- Every socket's liveness ping fires on one shared 10 s grid derived from the
  injected `MonotonicClock`, so N sockets wake together. The first ping after
  connect comes at the next grid tick (never later than today's 10 s), later
  pings exactly every 10 s; pong deadline and teardown unchanged.
- Presentation-lease renewal runs on the same grid ticks, never longer apart
  than today's 15 s.
- One shared `URLSession` per HTTP transport for idempotent GET requests, with
  per-task delegates carrying today's bounds, redirect and cancellation
  behavior; uploads and other non-idempotent requests keep a fresh session.

### T3-DEFLATE — WebSocket compression

Primary scenarios: Gateway `stream-reply`, `tool-loop`, `idle` (socket bytes
read per client), iOS `streaming-reply` and `tool-loop` (instructions, energy)
to confirm inflate cost on the phone stays below the saved decode-free radio
time.

- Loopback clients (the Mac app, CLI) keep uncompressed frames; paired clients
  that offer the extension get it. The ws server negotiates per server
  instance, so choose deliberately (for example two server instances selected
  in the upgrade handler) rather than compressing loopback traffic.
- Pick level, memory level, threshold and context takeover from P-2
  measurements (Mac CPU per client versus bytes saved); cap concurrent zlib
  work.
- Inbound `maxPayload` and the phone's 1 MiB frame ceiling must bound
  decompressed size (no decompression bomb); the outbound queue's frame and
  byte accounting, write-progress and heartbeat diagnostics must stay exact
  with asynchronous compression (extend the server capacity tests).
- Prove the iOS app negotiates and decodes it: a hosted or E2E run of the real
  `GatewaySocketTransport` against a compressing server, including a frame
  just under the 1 MiB ceiling and one over it.

## Handoff log
