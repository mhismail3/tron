# Concurrency Scheduling Discipline Evidence Manifest

Status: **complete**

Current score: **100/100**

Scorecard:
[`concurrency-scheduling-discipline-scorecard.md`](concurrency-scheduling-discipline-scorecard.md)

Inventory:
[`concurrency-scheduling-discipline-inventory.md`](concurrency-scheduling-discipline-inventory.md)
and
[`concurrency-scheduling-discipline-inventory.tsv`](concurrency-scheduling-discipline-inventory.tsv)

## Row Ledger

| Row | Status | Evidence | Verification | Closure | Checkpoint |
|---|---|---|---|---|---|
| CSD-0 | passed_after_fix | Added the scorecard, evidence manifest, inventory summary, machine-readable TSV, invariant target, and README links. Initial findings were recorded for unbounded external-worker outbound messages, unbounded async streams, global capture queues, main asyncAfter delays, detached image decode, and missing `KeyboardObserver` cancellation. | CSD target added and run after implementation. | Closed. | CSD-0 campaign harness checkpoint |
| CSD-1 | passed_after_fix | Added a 114-row scheduling inventory covering every tracked production Rust/Swift scheduling-marker file. Rows classify owner, scheduler class, start/stop policy, capacity/backpressure, fairness, deadline, blocking policy, test evidence, and CSD row coverage. | `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants csd_inventory_rows_are_structured_and_cover_marker_files -- --nocapture` | Closed. | CSD-1 scheduling inventory checkpoint |
| CSD-2 | passed_after_fix | Added static gates for Rust spawn ownership and Swift stored-task cancellation paths. `KeyboardObserver` now exposes `stopObserving` to cancel notification tasks. Swift view/action tasks are inventoried as view-scoped or main-actor UI. | CSD spawn/task ownership gates plus focused iOS SourceGuard and transport/session tests. | Closed. | CSD-2 task ownership checkpoint |
| CSD-3 | passed_after_fix | Replaced `mpsc::unbounded_channel` in external worker sockets with bounded MPSC capacity and send timeout. `AsyncEventStream` now uses bounded newest buffering by default. | External worker disconnect/backpressure tests, `AsyncEventStreamTests`, and CSD unbounded-channel/stream guards. | Closed. | CSD-3 backpressure checkpoint |
| CSD-4 | passed_after_fix | Timer-loop rows cover queue drainer, heartbeat, stream push, profile watcher, provider retry, reconnect, debounce, batch, layout, animation, and diagnostics upload cadence. Main asyncAfter sites were removed. | CSD timer/sleep policy guard plus focused runtime, retry, and iOS tests. | Closed. | CSD-4 timer fairness checkpoint |
| CSD-5 | passed_after_fix | Camera and QR capture use owner serial queues instead of global dispatch. Image decode uses a serial worker instead of detached work. Rust blocking policy remains behind `BlockingTaskSupervisor` and process/async boundaries. | CSD banned-marker guard, SourceGuardTests, `shared::server::context`, and focused UI compile/tests. | Closed. | CSD-5 blocking isolation checkpoint |
| CSD-6 | passed_after_fix | Agent/session rows and existing tests cover run semaphore ownership, active-run guards, event persister bounded ordering, forwarder drain, abort tokens, invocation trackers, and sequence counters. | CSD inventory guard plus focused agent/orchestrator/event persister tests. | Closed. | CSD-6 agent/session concurrency checkpoint |
| CSD-7 | passed_after_fix | Engine queue drainer rows document lease cadence and retry/dead-letter timing. External worker pending invocations complete on disconnect and outbound scheduling is bounded. | `transport::runtime` and engine durability/runtime tests plus new paused-time external-worker backpressure test. | Closed. | CSD-7 engine worker scheduling checkpoint |
| CSD-8 | passed_after_fix | iOS transport/event/update rows cover `EngineConnection`, `EngineClient`, `EventStoreManager`, `SessionRefreshService`, `ConnectionManager`, `AsyncEventStream`, `UIUpdateQueue`, diagnostics ingestion, and capture session owner queues. | Focused iOS tests listed in the scorecard and CSD static guards. | Closed. | CSD-8 iOS scheduling checkpoint |
| CSD-9 | passed_after_fix | New CSD checks are static or use Tokio paused time. Existing retry code uses injected `AsyncClock`; runtime sleeps are inventoried as loop cadence, deadlines, UI animation/layout, debounce, or reconnect policy. | CSD deterministic policy guard plus focused retry/transport tests. | Closed. | CSD-9 deterministic tests checkpoint |
| CSD-10 | passed_after_fix | Final closeout ran the focused CSD target, verified CSD is wired into local and GitHub closeout target lists, focused Rust/iOS tests, full Rust CI, personal-info guard, XcodeGen drift check, whitespace check, ignored-artifact audit, and clean status check. | Final verification log below. | Closed. | CSD-10 final closeout checkpoint |

## Verification Log

| Command | Result | Evidence |
|---|---|---|
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 0 | CSD invariant target passed with 12 tests after CI-list wiring was added. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::runtime::external_workers --lib -- --nocapture` | exit 0 | External worker disconnect and bounded-outbound backpressure tests passed: 2 passed. |
| Focused Rust filter loop for shutdown, server context, engine socket/runtime, engine durability/runtime, agent orchestrator, provider retry, and device broker | exit 0 | All requested focused Rust filters passed. Intentional panic-isolation tests printed panic messages but completed successfully. |
| `cd packages/ios-app && xcodegen generate && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' ...` | exit 0 | Focused iOS command passed. XCTest selected tests passed with 12 tests; Swift Testing reported 88 tests across 6 suites. |
| First `scripts/tron ci fmt check clippy test` closeout attempt | exit 1 | CI caught missing DRC-9 replay parity wording in iOS architecture docs after the CSD doc update. The DRC wording was restored in the same checkpoint. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | exit 0 | DRC replay manifest/event parity target passed after the architecture doc fix: 17 passed. |
| Final `scripts/tron ci fmt check clippy test` | exit 0 | Formatting, check, clippy, workspace tests, named closeout targets including CSD, primitive trace, and serial integration all passed. |
| CSD closeout remediation `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | exit 0 | PCC tracked-file inventory coverage passed after adding retain rows for all CSD artifacts. |
| CSD closeout remediation `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 101 | The CSD guard still expected the old README abbreviation list; the guard was updated to assert the concrete closeout target names. |
| CSD closeout remediation `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 0 | CSD invariant target passed with the README precision fix and updated static assertion. |
| CSD closeout remediation `scripts/tron ci fmt check clippy test` rerun | exit 1 | CI then caught missing HRA file-inventory and ownership-map rows for the new CSD artifacts; matching CSD-10 rows were added to both HRA TSVs. |
| CSD closeout remediation `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | exit 0 | HRA tracked-file ownership coverage passed after adding CSD rows to both HRA inventories. |
| CSD closeout remediation `scripts/tron ci fmt check clippy test` rerun | exit 0 | Reran after adding CSD artifacts to PCC and HRA inventories, tightening README closeout-target wording, and updating the CSD static guard. |
| `scripts/personal-info-guard.sh` | exit 0 | Full personal-info scan reported no source leaks. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | exit 0 | XcodeGen produced no tracked project drift. |
| `git diff --check` | exit 0 | Whitespace check passed. |
| `git ls-files -ci --exclude-standard` | exit 0 | No ignored tracked artifacts were reported. |
| Slice 12 scheduler coverage `cargo test --manifest-path packages/agent/Cargo.toml scheduler::tests -- --nocapture` | exit 0 | Scheduler due evaluation is explicit request-scoped work with an injected clock in tests; no production timer loop or hidden background worker was added. |

## Closed Findings

| Surface | Finding | Resolution | Evidence |
|---|---|---|---|
| `packages/agent/src/transport/runtime/external_workers.rs` | Worker outbound messages used unbounded MPSC. | Replaced with bounded MPSC capacity and send timeout; pending waiter cleanup remains on disconnect, cancellation, timeout, and backpressure failure. | External worker tests and CSD static guard. |
| `packages/ios-app/Sources/Engine/Events/Live/AsyncEventStream.swift` | Default `AsyncStream` buffering was unbounded. | Defaulted to `.bufferingNewest(256)` and kept constructor policy injection for tighter tests. | `AsyncEventStreamTests.test_boundedBuffering_keepsNewestEvents`. |
| Camera and QR capture models | AVCapture start/stop used the global dispatch queue. | Added owner serial queues per capture model. | CSD `DispatchQueue.global` ban and iOS SourceGuard run. |
| Main-queue UI delays | Delayed scroll/copy feedback used `DispatchQueue.main.asyncAfter`. | Replaced with cancellation-aware Swift concurrency tasks and view/action scope. | CSD asyncAfter ban and focused UI compile/tests. |
| `DecodedImageView` | Image decode used `Task.detached`. | Replaced detached work with a serial image decode worker. | CSD `Task.detached` ban and focused UI compile/tests. |
| `KeyboardObserver` | Stored notification tasks had no visible cancellation path. | Added explicit `stopObserving` cancellation. | CSD stored-task cancellation guard. |
