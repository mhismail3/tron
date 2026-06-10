# Concurrency Scheduling Discipline Scorecard

Created: 2026-06-10

Initial score: **0/100**

Current score: **100/100**

Status: **complete**

Branch: `codex/primitive-engine-teardown`

Evidence manifest:
[`concurrency-scheduling-discipline-evidence-manifest.md`](concurrency-scheduling-discipline-evidence-manifest.md)

Inventory:
[`concurrency-scheduling-discipline-inventory.md`](concurrency-scheduling-discipline-inventory.md)
and
[`concurrency-scheduling-discipline-inventory.tsv`](concurrency-scheduling-discipline-inventory.tsv)

Invariant target:
[`../tests/concurrency_scheduling_discipline_invariants.rs`](../tests/concurrency_scheduling_discipline_invariants.rs)
with focused modules under
[`../tests/concurrency_scheduling_discipline/`](../tests/concurrency_scheduling_discipline/)

## Scope

This campaign proves that production Rust and Swift scheduling surfaces have
owners, bounded capacity or a documented non-queue policy, cancellation or view
lifecycle ownership, explicit timer cadence, blocking isolation, and focused
test evidence.

The campaign preserves public APIs, protocol DTOs, database schema, CLI
commands, generated project contents, and iOS UX while removing scheduling
patterns that made ownership harder to prove.

## Non-Negotiable Direction

- Delete or replace unsafe scheduling surfaces instead of carrying broad
  exceptions.
- Production `tokio::spawn`, Swift `Task`, channel, stream, timer, sleep,
  dispatch, and callback bridges need an inventory row.
- Bounded queues, coalescers, scoped tasks, cancellation tokens, view-scoped
  tasks, owner serial queues, and blocking supervisors are the accepted
  production patterns.
- Production Rust `mpsc::unbounded_channel`, Swift `Task.detached`,
  `DispatchQueue.global`, and `DispatchQueue.main.asyncAfter` are banned.
- Test-critical waits use existing focused tests, Tokio time controls, explicit
  notifications, injected clocks, or bounded assertions. New production sleeps
  must be runtime loops, UI animation/layout delays, or inventory-backed
  deadlines.

## Scenario Ledger

| Row | Requirement | Points | Status | Owner | Evidence | Closure | Checkpoint |
|---|---|---:|---|---|---|---|---|
| CSD-0 | Campaign harness, red gates, README links, scorecard/evidence/inventory scaffolding | 5 | passed_after_fix | docs/static gates | Added CSD scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, and initial findings for unbounded worker outbound scheduling plus iOS global dispatch/main asyncAfter/detached work. | Closed. | CSD-0 campaign harness checkpoint |
| CSD-1 | Whole-repo scheduling inventory | 10 | passed_after_fix | docs/static gates | Added a 112-row TSV covering every tracked production Rust/Swift file with CSD markers. Allowed classes cover tracked tasks, request tasks, bounded queues, timer loops, coalescers, blocking supervision, actor serialization, callback bridges, main-actor UI, and view-scoped tasks. | Closed. | CSD-1 scheduling inventory checkpoint |
| CSD-2 | Spawn/task ownership | 12 | passed_after_fix | runtime/iOS owners | Static gates require Rust spawn rows to name shutdown, cancellation, join, scoped, or await ownership and require Swift stored task fields to expose deinit, stop, reset, disconnect, cleanup, cancel, or view-disappear cancellation. `KeyboardObserver` gained an explicit stop/cancel path. | Closed. | CSD-2 task ownership checkpoint |
| CSD-3 | Channels, streams, and backpressure | 12 | passed_after_fix | runtime/event streams | Replaced external-worker unbounded MPSC with a bounded 128-slot queue and send timeout. `AsyncEventStream` now defaults to bounded newest-value buffering and has focused overload coverage. Static gates ban unbounded production MPSC. | Closed. | CSD-3 backpressure checkpoint |
| CSD-4 | Timer loops and scheduling fairness | 10 | passed_after_fix | runtime/iOS loop owners | Inventory rows document queue drainer, heartbeat, stream push, profile watcher, reconnect, debounce, ACK, layout, animation, and upload cadence. Static gates require timer/sleep files to carry deadline or cadence policy. | Closed. | CSD-4 timer fairness checkpoint |
| CSD-5 | Blocking and CPU/IO isolation | 8 | passed_after_fix | shared server/iOS capture | Rust blocking work remains behind `BlockingTaskSupervisor` or async I/O. iOS camera and QR capture start/stop now use owner serial queues, and decoded images use a serial worker instead of detached work. | Closed. | CSD-5 blocking isolation checkpoint |
| CSD-6 | Agent/session turn concurrency | 10 | passed_after_fix | agent orchestrator/session store | Inventory and existing focused tests cover run semaphore ownership, active-run state, event persister bounded order, forwarder drain, abort tokens, pending invocation trackers, and sequence counters. Static gates require those rows to stay classified. | Closed. | CSD-6 agent/session concurrency checkpoint |
| CSD-7 | Engine queue and external worker scheduling | 10 | passed_after_fix | engine runtime/transport | Queue drainer rows record per-queue lease cadence and retry/dead-letter evidence. External worker outbound scheduling is bounded, pending invocations complete on disconnect, and bounded send backpressure is tested with paused Tokio time. | Closed. | CSD-7 engine worker scheduling checkpoint |
| CSD-8 | iOS transport/event/update scheduling | 12 | passed_after_fix | iOS transport/persistence/session UI | Inventory and focused tests cover `EngineConnection`, `EngineClient`, `EventStoreManager`, `SessionRefreshService`, `ConnectionManager`, `AsyncEventStream`, `UIUpdateQueue`, diagnostics ingestion, and capture-session owner queues. | Closed. | CSD-8 iOS scheduling checkpoint |
| CSD-9 | Deterministic scheduling tests | 6 | passed_after_fix | tests/static gates | Added static checks for direct sleep policy, used Tokio paused time for the new worker backpressure test, retained injected-clock retry tests, and avoided new sleep-based static tests. | Closed. | CSD-9 deterministic tests checkpoint |
| CSD-10 | Final closeout | 5 | passed_after_fix | static gates/verification | CSD scorecard, evidence, inventory, README links, production scheduling bans, CI closeout target wiring, focused Rust/iOS checks, full Rust CI, personal-info guard, XcodeGen drift check, whitespace check, ignored-artifact audit, and clean status were run for closeout. | Closed. | CSD-10 final closeout checkpoint |

Total weight: **100**

## Findings Closed

- `packages/agent/src/transport/runtime/external_workers.rs` used
  `mpsc::unbounded_channel` for worker outbound messages. CSD-3 replaced it
  with bounded MPSC capacity and a send timeout, plus focused disconnect and
  backpressure tests.
- `packages/ios-app/Sources/Engine/Events/Live/AsyncEventStream.swift` used
  default unbounded `AsyncStream` buffering. CSD-3 made the buffer policy
  explicit and bounded by default.
- Camera and QR capture models used `DispatchQueue.global` for AVCapture
  start/stop. CSD-5 replaced those with owner serial queues.
- UI delayed-scroll and copy-feedback code used `DispatchQueue.main.asyncAfter`.
  CSD-4/CSD-8 replaced those with cancellation-aware Swift concurrency tasks.
- `DecodedImageView` used `Task.detached` for image decode. CSD-5 replaced it
  with a serial worker.
- `KeyboardObserver` stored notification tasks without a visible cancellation
  path. CSD-2 added explicit `stopObserving` cancellation.

## Static Gates

`packages/agent/tests/concurrency_scheduling_discipline_invariants.rs` and its
focused modules enforce:

- Scorecard weights sum to 100 and every row is `passed_after_fix`.
- README links all CSD artifacts.
- Inventory rows are structured, paths exist, scheduler classes are allowed,
  and every tracked production Rust/Swift scheduling-marker file has a row.
- Production Rust `tokio::spawn` files have explicit ownership policy.
- Production Rust unbounded MPSC APIs are absent unless a narrow
  `unbounded_queue_exception` row is added.
- Production Swift `Task.detached`, `DispatchQueue.global`, and
  `DispatchQueue.main.asyncAfter` are absent.
- Production Swift `AsyncStream` files have bounded buffering policy.
- Swift owner classes with stored task fields expose a visible cancellation
  path.
- Direct production sleeps have deadline, cadence, animation, layout, retry, or
  runtime-loop policy in the inventory.
- `tron ci test`, GitHub static gates, and README CI documentation list the CSD
  invariant target.
- CSD closeout artifacts reject stale active-state wording.

## Verification Commands

Focused CSD target:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture
```

Focused Rust targets:

```bash
cargo test --manifest-path packages/agent/Cargo.toml app::lifecycle::shutdown --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml shared::server::context --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml transport::engine::socket --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml transport::runtime --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml engine::tests::runtime --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::agent::loop::orchestrator --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::shared::retry --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml platform::device_broker --lib -- --nocapture
```

Focused iOS targets:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SourceGuardTests \
  -only-testing:TronMobileTests/EngineConnectionReconnectTests \
  -only-testing:TronMobileTests/EngineClientTests \
  -only-testing:TronMobileTests/AsyncEventStreamTests \
  -only-testing:TronMobileTests/EventStoreManagerTests \
  -only-testing:TronMobileTests/SessionRefreshServiceTests \
  -only-testing:TronMobileTests/ConnectionManagerTests \
  -only-testing:TronMobileTests/UIUpdateQueueTests \
  -only-testing:TronMobileTests/AsyncSemaphoreTests \
  -only-testing:TronMobileTests/ClientLogIngestionServiceTests
```

Final closeout:

```bash
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate && cd ../..
git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```
