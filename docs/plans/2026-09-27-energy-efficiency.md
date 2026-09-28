# Energy efficiency

- **Started:** 2026-09-27
- **Status:** Active (approved in chat by the user on 2026-09-27)
- **Last updated:** 2026-09-27, P-6 and R-FOLLOW added
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

Baselines recorded 2026-09-27 (P-4; medians of five iterations on the owned
simulator, optimized `DevicePerformance`, source = P-1 profiler over `main` at
`8e1a58ccb`; Gateway medians of three iterations at `060697d21`, before
T3-DEFLATE):

| iOS scenario (window) | Instructions | Main-thread CPU | Interrupt wakeups | Logical writes |
| --- | ---: | ---: | ---: | ---: |
| idle-dashboard (30 s) | 8.24 G | 2.36 s | 3,834 | 420 KiB |
| idle-chat (30 s) | 0.01 G | 0.00 s | 39 | 0 |
| streaming-reply (12 s) | 31.5 G | 3.05 s | 1,119 | 16 KiB |
| tool-loop (15 s) | 136.3 G | 8.95 s | 1,482 | 764 KiB |
| composer-typing (10 s) | 8.32 G | 1.21 s | 675 | 236 KiB |
| summary-storm (15 s) | 28.7 G | 3.04 s | 1,614 | 3,624 KiB |

| Gateway scenario | Phone socket bytes | Phone frames |
| --- | ---: | ---: |
| stream-reply | 705 KiB | 165 |
| tool-loop | 15.5 MiB | 219 |
| idle (60 s) | 468 B | 1 |

The streaming-reply workload replays the corrected T1-GW cadence; with the old
two-frames-per-window cadence the same scenario measured 60.9 G instructions and
5.44 s of main-thread CPU, so T1-GW roughly halved phone-side streaming work.

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
| P-1 | Done | iOS scenario profiler (new `tron-profile` in `scripts/`, `ios` subcommand), optimized profiling build, in-process energy metrics, deterministic scenarios, control self-test, JSON reports (details below) | none | energy-efficiency supervisor, worker lane p1, 2026-09-27 |
| P-2 | Done | Gateway wire-traffic profiler (`gateway` subcommand), isolated fixture Gateway with a faux model, recording client, per-topic frame and byte report (details below) | none | energy-efficiency supervisor, worker lane p2, 2026-09-27 |
| P-3 | Done | Attribution: `--trace` for iOS scenarios (xctrace Time Profiler, SwiftUI, Points of Interest; exported top-symbol summary) and an attach-only `device` mode for a user-launched LocalDevice app | P-1 | energy-efficiency supervisor, worker lane p3, 2026-09-27 |
| P-4 | Done | Baseline: run every P-1 and P-2 scenario on `main`, record the numbers and host state in this plan's Context | P-1, P-2 | energy-efficiency supervisor, 2026-09-27 |
| P-5 | Blocked | Simulator-device Instruments (SwiftUI view-body counts, app signposts) never starts from agent sessions on this Mac ("Device disconnected while trying to set tap configuration", also on a fresh iOS 27 simulator); the user checks from their own Terminal, and `device --attach` capture is verified on a user-launched app | P-3 | |
| P-6 | Ready | Make every iOS scenario's workload deterministic: an iteration whose workload did not actually render (for example streaming-reply's pinned tail not followed, `chat.lease.repair-exhausted`) is detected, retried within a bound and otherwise fails the run; the mode is exposed as a scenario counter so `compare` never mixes modes | P-1 | |
| R-FOLLOW | Needs scoping | In about half of streaming-reply iterations on `main` the pinned chat does not follow the live stream (lease repair exhausted, reply off screen); determine whether this is a hosted-window artifact or a real following bug, and route a real bug to the chat transcript stability plan | none | |
| T1-GW | Done | Gateway: re-arm the streaming throttle; delete `session.bashProgress` and `session.heartbeat`; skip the heartbeat ping while a client proved liveness within the interval, keeping today's detection bound | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-gw, 2026-09-27 |
| T1-CACHE | Done | `SnapshotCache`: drop checkpoints that cannot change it, coalesce summary checkpoints and checkpoint on background, drop the save-path double admission pass | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-persist, 2026-09-27 |
| T1-DRAFTS | Done | `ComposerDraftStore`: in-memory logical clock, size accounting without re-hashing, manifest-only writes when attachments are unchanged; no observable mutation for unchanged text | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-persist, 2026-09-27 |
| T1-TEXT | Claimed | `discreteInsertedIDs` to O(n) with an equivalence check; `ChatStreamingInlineText` keeps settled text whole (preserving the streaming-flip reveal state) and caches the revealed prefix | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-text, 2026-09-27 |
| T1-CLOCKS | Claimed | Timeline schedules that fire when a label can change: dashboard rows, tool elapsed timers (sub-minute cadence preserved), static inbox formatter | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-clocks, 2026-09-27 |
| T1-NET | Claimed | One shared ping grid for every socket (no interval ever longer than today), lease renewal on that grid at no longer than today's interval, one shared `URLSession` for idempotent GETs with per-task delegates | none (keep decision: P-1, P-2) | energy-efficiency supervisor, worker lane t1-net, 2026-09-27 |
| T3-DEFLATE | Done | Negotiate `permessage-deflate` for paired (non-loopback) clients that offer it; confirm the offer from the iOS simulator app, keep inbound size bounds on decompressed bytes, and keep outbound queue accounting and backpressure exact | none (keep decision: P-2) | energy-efficiency supervisor, worker lane t3-deflate, 2026-09-27 |
| T2-FONTS | Claimed | Stop rebuilding fonts on view updates: `TronFontLoader.createUIFont` and `UIFont(descriptor:size:)` take 5–8% of main-thread time in every traced scenario; cache the created fonts by exact descriptor and size with identical output (Dynamic Type and settings changes still invalidate) | none (keep decision: P-1) | energy-efficiency supervisor, worker lane t2-theme, 2026-09-27 |
| T2-COLORS | Claimed | Stop re-parsing theme colors per body (`Color(lightHex:darkHex:)`, `UIColor(hex:)` in the idle-dashboard trace): resolve each theme color once with identical light/dark and settings behavior | none (keep decision: P-1) | energy-efficiency supervisor, worker lane t2-theme, 2026-09-27 |
| T2-PULSE | Claimed | Cut the per-frame main-thread cost of `TronPulseLoadingIndicator` (11% of idle-dashboard main-thread time) without changing a rendered frame, cadence or gating | none (keep decision: P-1) | energy-efficiency supervisor, worker lane t2-pulse, 2026-09-27 |
| T2-CHATVIEW | Needs scoping | Transcript install cost from the traces: `ChatPhysicalTranscriptReplacementHost.body` with `renderedContent`/`replacementContent` (21% of tool-loop main-thread time), whole-transcript equality (`InstalledChatTranscript ==`, `ChatTranscriptItems ==`, 7.5% of streaming) and render-item copies (memmove 8–10%); ChatView observes the snapshot and the installed transcript in separate scopes | T1-TEXT | |
| T2-DASH | Needs scoping | Dashboard root stops re-evaluating on every summary; parsed ordering instants; cheaper per-row path helpers; filter preferences saved only on change | T1-CLOCKS | |
| T2-THINK | Needs scoping | Thinking trace measures its visible text instead of a hidden full copy | T1-TEXT | |
| T2-TEXTPREP | Needs scoping | Text preparation reuses history rows on the isolated streaming path and memoizes closed Markdown blocks | T1-TEXT | |
| T2-SMALL | Needs scoping | AppLog debug encode and restore ordering, diagnostics sanitized once, debounced extension drafts flushed on close and background, direct thumbnail images, push token writes only on change | P-4 | |
| T3-TRANSCRIPT | Needs scoping | Transcript append deltas for `session.snapshot` (deflate cuts its radio bytes but not the phone's decode of up to 800 KB per snapshot), negotiated per connection, exact-or-full on the Gateway, digest-verified with fail-closed resync on the phone | T3-DEFLATE | |
| T3-STREAM | Needs scoping | Streaming text append deltas for `session.progress`, same rules; only if P-2 shows progress bytes or decode cost still material after T3-DEFLATE | T3-DEFLATE | |
| T3-TOOLPROG | Needs scoping | Tool progress omits a `partialResult` the phone can reconstruct exactly, same rules; only if still material after T3-DEFLATE | T3-DEFLATE | |
| T3-CATALOG | Needs scoping | Conditional `session.list` on foreground: an unchanged catalog generation keeps the retained rows | P-4 | |
| R-OPEN | Needs scoping | Investigate whether an unanswered optional older-history page during chat opening fails the opening ("layout did not settle") instead of falling back to the usable tail as `architecture.md` promises; fix the owner if so | none | |
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

### P-3 — Attribution

- `--trace TEMPLATE` on `ios` scenarios records an xctrace capture of the
  hosted test process covering exactly the measured windows (the scenario waits,
  bounded, for the profiler to confirm recording before its first measured
  iteration), keeps the `.trace`, and writes an attribution summary beside the
  report: top symbols by self and total time for all threads and for the main
  thread, per-thread CPU, and, for the SwiftUI template, view-body update counts
  by view type; Points of Interest summarizes the app's signpost intervals.
- Symbols must resolve for the app and test binaries (keep the matching debug
  symbols); the summary names unresolved frames rather than dropping them.
- Self-test: tracing the CPU control variant must attribute its known workload
  function among the top self-time symbols.
- `device --attach` records Time Profiler or Power Profiler for a fixed window
  on an explicitly named physical device against an already running app,
  never installing, launching or signing anything; it refuses without an
  explicit device identifier and documents that the user owns device runs.

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

### T3-TRANSCRIPT — Transcript append snapshots (design, reviewed before code)

Why after T3-DEFLATE: compression already cut snapshot radio bytes by about
80%, but the phone still decodes, admits and re-projects a full transcript page
(up to 512 items, 600 KB inside an 800 KB snapshot) about twice per tool call
(`tool-loop`: 19 snapshots, 10.7 MiB decoded in 15 s, main thread 60% busy).
Implement only if P-3 attribution shows snapshot decode, admission or
re-projection is a material share of that time.

- **Negotiation.** The phone's `hello` adds an additive capability list with
  `session-snapshot-append.v1`; the Gateway records it per connection. Old
  phones, the Mac app and the CLI never declare it and receive today's frames
  byte for byte.
- **Item revisions.** Every projected transcript item gains an additive `rev`:
  a short digest of that item's serialized projection. Decoders ignore unknown
  keys today (verify for every item decoder), so old clients are unaffected.
- **Gateway.** `publishSnapshot` still builds today's full snapshot. When the
  previous published page has the same runtime generation and the new page is
  exactly that page with `k` leading items dropped and `m` items appended —
  every retained item's `rev` equal, `start` and `total` consistent — it also
  builds an append variant: every non-transcript field, plus `baseStart`,
  `baseTotal`, `baseTailId`, a digest over the base page's item revisions,
  `drop: k` and the `m` new items. Anything else, including any in-place
  projection change, publishes only the full form.
- **Per-connection choice.** The transport sends the append variant only to
  connections that declared the capability, and never as the first snapshot
  after that connection's `session.open` or `session.sync` for the session
  (a per-connection flag cleared by the next full snapshot), so a client whose
  base came from an authoritative read cannot enter a mismatch loop.
  Synchronization barriers retain the variant chosen for that connection.
- **Phone.** `SessionPresentationStore` applies an append only if its
  authoritative tail matches `baseStart`, `baseTotal`, `baseTailId` and the
  revision digest it computes from the revisions it holds; it then builds the
  complete snapshot and admits it through today's full-snapshot path unchanged.
  Any mismatch requests today's authoritative resynchronization and never
  guesses. Nothing else in the reducer changes.
- **Proof.** Gateway tests for every exact-or-full decision (append, slide,
  branch switch, compaction, in-place projection change, runtime restart,
  capability absent, first snapshot after open/sync, barrier replay). A phone
  test for every accept/reject path. A differential run replaying the P-2
  `tool-loop` timeline shows the phone's installed transcripts identical with
  and without appends. The real-Gateway E2E, the parity gate, and `tool-loop`
  on both profilers show the saved decode and bytes.

## Handoff log

### P-2 · Done · 2026-09-27 · energy-efficiency supervisor (worker lane p2)

- Result: `scripts/tron-profile gateway` runs `stream-reply`, `tool-loop`,
  `idle` and `dashboard-observer` against an isolated fixture Gateway (faux
  model, private temporary home, free loopback port) with recording clients that
  pair and behave like the phone, including its exact `permessage-deflate`
  offer, 10 s pings, `session.open`/`sync` and 15 s presentation renewals. Each
  report carries per-client frames and bytes per topic, TCP socket bytes, pings
  and pongs, largest frame and fixture CPU, plus `timeline.jsonl`.
- Evidence: all four scenarios twice, three iterations each (idle wire metrics
  identical across six iterations; stream-reply total bytes within 1%;
  tool-loop within 3.5%, from a real extra snapshot the Gateway sometimes sends
  at prompt admission). `--self-test` passed twice: halving the faux reply
  moved progress frames 0.567× (expected 0.559) beyond the noise bound. Ctrl-C,
  wrong Node, busy lock and bad usage exit with their documented codes and leave
  no fixture behind. First measurement: ten tool calls on a 512-item session
  send the phone about 16 MB of `session.snapshot`, and a 6,000-character reply
  sends 1.2 MiB of cumulative `session.progress`.
- Changes: `scripts/tron-profile-gateway` with its driver and faux-model
  extension; `packages/gateway/README.md` (Wire-traffic profile); the
  tron-performance skill; CI syntax checks. The supervisor added automatic
  selection of a pinned Node that can load `node-pty` (Tron agent sessions put
  the Gateway payload's signed runtime first on `PATH`) and made `compare` treat
  a one-unit count change as noise.
- Kept on purpose: the fixture selects the profile model with `session.setModel`
  outside the measured window, because Pi 0.87.1 can cold-open a session whose
  extension-registered provider has no model yet; the report warns when that
  repair was needed.
- For the next agent: record P-4 on a quiet host (loads above 100 were seen
  during this work); the duplicate prompt-admission snapshot is a candidate for
  a later Gateway task; report the Pi model-restore race upstream.

### T1-GW · Done · 2026-09-27 · energy-efficiency supervisor (worker lane t1-gw)

- Result: the streaming throttle re-arms after a sending window, so continuous
  streaming sends one `session.progress` per 150 ms instead of two;
  `session.bashProgress` and `session.heartbeat` are no longer emitted; the
  server heartbeat still counts every tick but pings only a client that sent
  no message or ping of its own in the last interval.
- Evidence: `scripts/tron-profile gateway` on `main` (`982956b39`) versus this
  branch, three iterations each: stream-reply progress frames 284 → 148 and
  mobile bytes 1.29 MiB → 716 KiB (−46%); tool-loop total frames 330 → 219;
  idle server pings to each phone 3 → 0 per minute. Gateway CPU time and
  cycles moved within host contention (baseline load 115, instructions
  unchanged); these are Mac-side. New `server-heartbeat.integration.test.ts`
  proves dead-client termination on today's exact tick and pings for pong-only
  and silent clients; negative controls failed as expected (old throttle,
  pong-suppressed pings, counting only pinged ticks). Full Gateway suite
  1984/1985 (the logger rotation timeout passes alone).
- Changes: `runtime-slot.ts`, `server.ts`, the heartbeat and coalescing tests,
  `packages/gateway/README.md`, `packages/gateway/docs/connection-resilience.md`,
  `packages/gateway/docs/observability.md`, `packages/ios-app/docs/events.md`,
  `packages/ios-app/docs/architecture.md`.
- Deviations: the user's supervisor chose the client-initiated rule for the
  heartbeat (pongs never suppress a ping); its only residual is documented in
  `connection-resilience.md`: a client that goes quiet after sending may get its
  first server ping one tick later, so its pong must return within about 50 s
  instead of 75 s.
- For the next agent: the Gateway sometimes sends an extra `session.snapshot`
  at prompt admission (P-2 timeline); a candidate for a later task.

### T3-DEFLATE · Done · 2026-09-27 · energy-efficiency supervisor (worker lane t3-deflate)

- Result: paired clients that offer `permessage-deflate` get compressed frames
  with context takeover (zlib level 6, memLevel 8, 15 window bits, two
  concurrent zlib jobs); local-credential clients stay uncompressed through a
  second WebSocket server chosen in the upgrade handler by the existing
  credential check. `connection.opened` records the negotiated compression.
- Evidence: `scripts/tron-profile gateway` against `main` at `060697d21`,
  three iterations each: phone socket bytes for stream-reply 705 KiB → 13.6 KiB
  (−98%), tool-loop 15.5 MiB → 1.6 MiB (−89.5%), idle 468 B → 198 B. Mac-side
  cost: tool-loop Gateway instructions +47% (about 14 ms of zlib per 600 KB
  snapshot, 0.1 ms per streaming frame); the +3.6% message-byte move is the
  Gateway's timing-dependent extra admission snapshot noted under P-2, not
  compression. The real iOS simulator app negotiated compression on all ten
  connections of `scripts/ios-gateway-e2e-test run` (fixture proxy log and
  Gateway `connection.opened` records), with every existing fault case passing;
  a compressed frame of exactly 1 MiB decodes and one byte more retires the
  epoch with `frame_too_large`. New `server-compression.integration.test.ts`
  proves over-limit payloads are refused before compression on all five send
  paths and that `maxPayload` bounds inflated inbound size; negative controls
  (compressing local clients, numeric window options, raised `maxPayload`,
  letting fallback frames through, an uncompressed proxy) all failed as
  expected. Transport suite 295/295 after rebasing over T1-GW.
- Changes: `server.ts`, the compression and capacity tests,
  `scripts/ios-gateway-fault-proxy.mjs` (mirrors the app's offer; exact-size
  `inject-frame`), `RealGatewayPiBoundaryTests` (test code only),
  `packages/gateway/docs/connection-resilience.md` (Frame compression),
  `packages/gateway/docs/observability.md`, `packages/gateway/README.md`,
  `packages/ios-app/docs/architecture.md`.
- Deviations: CFNetwork's `maximumMessageSize` bounds compressed wire bytes, so
  the phone now rejects an over-ceiling frame after inflation
  (`frame_too_large`) instead of in URLSession; correct traffic is unchanged
  because the Gateway refuses decoded frames over 1 MiB before enqueue. The
  residual (memory before rejection against a broken or malicious paired
  Gateway) is documented and was accepted by the supervisor.
- For the next agent: T3-STREAM and T3-TOOLPROG are now judged against
  compressed bytes: cumulative streaming frames already compress to about 1.3%,
  so their remaining value is phone decode CPU, not radio. T3-TRANSCRIPT still
  removes the phone's decode of up to 800 KB per snapshot.

### P-1 · Done · 2026-09-27 · energy-efficiency supervisor (worker lane p1)

- Result: `scripts/tron-profile ios` builds the optimized `DevicePerformance`
  hosted tests (Swift `-O` whole-module, testability and `HOSTED_TEST` kept)
  and runs six deterministic scenarios on the owned simulator under the
  `scripts/tron-ios-test` lease, using production `AppModel`, `GatewayClient`
  over a scripted socket, `SessionShellView`, `ChatView` and the real draft
  store. In-process metrics (instructions, cycles, CPU energy, disk and logical
  writes, peak footprint, wakeups, main-thread and process CPU, wall time) and
  workload counters land in the xcresult and become one report per scenario.
- Evidence: `--self-test` passed three times (CPU, disk and wakeup controls
  each detected beyond the noise bound); two full runs moved median
  instructions by 0.3–2.6%; an identical control at load 100 versus 9 moved
  instructions 0.4% while cycles and CPU time moved 10–30%, so only
  instructions decide keeps. Full unit tier 1,796 passed with the profiling
  tests skipped.
- Changes: `scripts/tron-profile-ios`, `scripts/test-tron-profile-ios.py`,
  `packages/ios-app/Tests/Profiling/`, the optimized
  `packages/ios-app/Configuration/DevicePerformance.xcconfig`,
  `packages/ios-app/project.yml` (the baseline test now reads
  `TEST_RUNNER_TRON_PERFORMANCE_BASELINE`, the only form that reaches a hosted
  test), docs, both skills, CI. The supervisor updated the streaming script to
  replay the corrected T1-GW throttle.
- Kept on purpose: idle wakeups read 0 on the simulator and physical disk bytes
  follow the host cache; interrupt wakeups and logical writes are the stable
  counters.
- For the next agent: `packages/ios-app/scripts/test-build-matrix-policy.sh`
  already failed on `main` before this work (UI Validation configuration
  expectation). Opening a page-bound chat surfaced "Conversation unavailable —
  the conversation layout did not settle" when the optional older-history page
  read went unanswered, which may be a real resilience gap (see R-OPEN).

### P-4 · Done · 2026-09-27 · energy-efficiency supervisor

- Result: baselines in Context. Evidence: the iOS and Gateway reports under
  `~/Library/Developer/Tron/profiles/`. Host load varied 5–100; decisions use
  instructions, byte and frame counts.

### T1-CACHE and T1-DRAFTS · Done · 2026-09-27 · energy-efficiency supervisor (worker lane t1-persist)

- Result: `SnapshotCache` is written only when the catalog it stores changes:
  the five `SessionPresentationStore` checkpoint requests (left over from when
  the cache held chat snapshots) are gone; summaries start one fixed 2 s
  coalescing window; authoritative pages, archive, unread and delete still
  write immediately; background, inactive and profile retirement flush a
  pending write. The save path reuses admission's per-row bytes instead of
  encoding every row twice. `ComposerDraftStore` fully verifies once per
  process, keeps its logical clock in memory, bounds from manifests plus file
  sizes, and rewrites only the manifest (one atomic rename) when a draft's
  attachments are the exact files it last wrote; `load()` still verifies what
  it restores. Unchanged composer text no longer mutates observed state.
- Evidence: `scripts/tron-profile ios` against the P-4 baseline, five
  iterations each: tool-loop logical writes 764 → 104 KiB (−86%),
  summary-storm 3.54 MiB → 436 KiB (−88%) and instructions −8%,
  composer-typing instructions −18.5%; no scenario regressed. Ten new
  behavioral tests (coalesced burst, background and inactive flush, removal
  during a pending window, document equivalence over 60 generated catalogs,
  manifest-only save, replaced-payload detection, crash consistency, LRU and
  count bounds, unchanged-text observation), each with a negative control that
  failed as expected. Full unit tier 1,729 passed; focused suites passed again
  after rebasing onto the profilers.
- Deviations: after an abrupt process death within 2 s of a summary burst the
  cached rows can be up to 2 s old until the first authoritative list replaces
  them; a payload tampered in place with its size and nanosecond timestamps
  restored is no longer rewritten by typing saves and is instead discarded at
  the next load (corrupt bytes are still never restored).

### P-3 · Done · 2026-09-27 · energy-efficiency supervisor (worker lane p3)

- Result: `scripts/tron-profile ios --scenario X --trace time-profiler` records
  a host-wide Time Profiler capture filtered to the simulator test host, maps
  the scenario's measured windows onto it through a bounded file handshake,
  and writes `attribution.json`/`.md` (top self and total symbols for all
  threads and the main thread, an app-code ranking, per-thread CPU, resolved
  and unresolved time per binary). Traced reports are marked and refused by
  `compare`. Traced runs take a host-wide lock and wait, bounded, for another
  session's Instruments; a held kperf lock fails with a precise message.
  `scripts/tron-profile device --attach` captures an already running app on an
  explicitly named physical device and refuses simulators, this Mac, and
  missing or offline devices.
- Evidence: the traced self-test attributes the CPU control's own function
  within the windows with no samples outside them; test-binary frames resolved
  completely; attribution of streaming-reply, tool-loop and idle-dashboard
  produced the T2-FONTS, T2-COLORS, T2-PULSE and T2-CHATVIEW rows.
- Deviations: `swiftui` and `points-of-interest` need simulator-device
  recording, which never starts from agent sessions on this Mac (P-5); device
  capture is unverified. The worker wrote the attribution parser tests after
  the code (only the traced-compare refusal has a negative control) and once
  ran a pattern-based `pkill` on DTServiceHub processes early on; it believes it
  matched only its own. Later kills were by confirmed pid.

