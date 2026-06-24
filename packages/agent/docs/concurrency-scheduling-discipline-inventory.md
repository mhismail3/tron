# Concurrency Scheduling Discipline Inventory

Status: CSD-10 `passed_after_fix`; 123 scheduling-surface rows and 24 static-gate/predecessor rows inventoried and classified.

This inventory classifies production scheduling surfaces by owner, scheduler
class, start site, cancellation or stop path, backpressure or capacity policy,
ordering or fairness policy, timeout or deadline, blocking policy, and focused
test evidence.

Machine-readable rows live in
[`concurrency-scheduling-discipline-inventory.tsv`](concurrency-scheduling-discipline-inventory.tsv).

## Allowed Scheduler Classes

| Class | Meaning |
|---|---|
| `tracked_background_task` | Long-lived task registered, stored, cancelled, joined, or drained by an owner. |
| `scoped_request_task` | Task or cancellation token scoped to one request, turn, invocation, or method future. |
| `bounded_queue` | Channel/queue with explicit capacity, close, lag, or backpressure semantics. |
| `unbounded_queue_exception` | Narrow exception requiring an explicit row and evidence. No production rows use this class. |
| `timer_loop` | Loop, retry, heartbeat, timeout, debounce, animation, or layout cadence with a cancellation/deadline policy. |
| `debounce_or_coalescer` | Scheduler that folds repeated updates into one pending task or batch. |
| `ack_coalescer` | Stream acknowledgment scheduler that keeps only the latest cursor/state before sending. |
| `blocking_supervisor` | Blocking or CPU-heavy work isolated behind the server supervisor, a process boundary, an actor worker, or an owner serial queue. |
| `actor_serialization` | Actor, semaphore, lock, or serial executor that orders concurrent access. |
| `main_actor_ui` | UI mutation task scoped to a user action or MainActor state change. |
| `external_callback_bridge` | Async stream, notification, WebSocket, AVCapture, or other callback bridge with bounded owner policy. |
| `view_scoped_task` | SwiftUI `.task` tied to view identity and automatically cancelled by SwiftUI. |
| `test_fixture` | Test-only scheduling surface excluded from production claims. |

## Inventory Summary

The TSV covers every tracked production Rust/Swift file containing CSD marker
patterns, plus static-gate/predecessor rows that keep follow-on scorecard
artifacts visible to the CSD harness:

- Rust markers: `tokio::spawn`, Tokio channel constructors, `CancellationToken`,
  Tokio sleep/timeout, and blocking sleeps.
- Swift markers: Swift `Task` creation/storage/sleep/yield, SwiftUI `.task`,
  `DispatchQueue`, `AsyncStream`, timers, debounce/coalescing markers, and
  `AsyncSemaphore`.

Scheduler class distribution for the 123 production scheduling-surface rows:

| Scheduler class | Rows |
|---|---:|
| `timer_loop` | 40 |
| `scoped_request_task` | 17 |
| `debounce_or_coalescer` | 12 |
| `tracked_background_task` | 13 |
| `main_actor_ui` | 13 |
| `actor_serialization` | 8 |
| `external_callback_bridge` | 8 |
| `view_scoped_task` | 6 |
| `bounded_queue` | 4 |
| `blocking_supervisor` | 1 |
| `ack_coalescer` | 1 |

Static-gate/predecessor rows: 23 `test_fixture` rows.

## Rust Scheduling Proof

| Surface | Owner | Scheduling proof |
|---|---|---|
| Shutdown coordinator | `app_lifecycle` | Registered tasks self-prune, reject late registration after close, run phase callbacks with timeout/panic isolation, drain with bounded timeout, and abort slow tasks. |
| Blocking task supervisor | `shared_server` | Blocking work is bounded by semaphore permits, tracked by active guards, registered with shutdown, and drained by the coordinator. |
| Event persister | `agent_orchestrator` | Bounded MPSC preserves send order into one worker; worker death and flush/shutdown paths are tested. |
| Agent runner forwarder | `agent_orchestrator` | Forwarder task owns a cancellation token and drains buffered events before `agent.ready`. |
| Provider retry | `model_domain` | Backoff observes cancellation and has focused retry/cancel tests. |
| Queue drainer | `engine_runtime_transport` | One drainer per queue owns lease-owner identity, cadence, retry, and dead-letter timing. |
| Stream event pump | `engine_runtime_transport` | Broadcast lag is observed through metrics, cancellation exits the loop, and stream publication stays behind engine stream ownership. |
| External workers | `engine_runtime_transport` | Outbound messages use bounded MPSC capacity, pending invocations finish on disconnect, and send backpressure fails with waiter cleanup. |

## iOS Scheduling Proof

| Surface | Owner | Scheduling proof |
|---|---|---|
| `EngineConnection` | `ios_websocket_transport` | Receive, ping, reconnect, open-timeout, and request-timeout tasks are stored and cancelled on disconnect, backgrounding, cleanup, and deinit. |
| `EngineClient` | `ios_websocket_transport` | Stream subscriptions are deduplicated, ACK work coalesces to the latest cursor, and disconnect cancels ACK/observation tasks. |
| `AsyncEventStream` | `ios_event_stream` | Continuations are removed on termination; default buffering is bounded with newest-value overload semantics. |
| `EventStoreManager` | `ios_event_persistence` | Engine-client replacement cancels the previous global event task and prevents duplicate handling. |
| `SessionRefreshService` | `ios_event_persistence` | Connected refresh and reconnect hooks are coalesced and cancellable. |
| `UIUpdateQueue` | `ios_chat_coordinators` | Equal-priority ordering is stable, text deltas coalesce, and reset cancels pending batch work. |
| `ClientLogIngestionService` | `ios_diagnostics` | Uploads serialize, endpoint generation is respected, retry delay is cancellable, and stop cancels the loop. |
| Camera and QR capture | `ios_chat_composer` / `ios_onboarding` | AVCapture start/stop runs on owner serial queues instead of global dispatch. |

## Closeout Policy

The CSD static gates intentionally reject these production patterns:

- `mpsc::unbounded_channel`, `UnboundedSender`, or `UnboundedReceiver`.
- `Task.detached`.
- `DispatchQueue.global`.
- `DispatchQueue.main.asyncAfter`.
- `AsyncStream` without bounded buffering or a protocol-level cursor polling
  row.
- Stored Swift task fields without a visible cancellation path.
- New production sleep/timer files without inventory-backed deadline, cadence,
  animation, layout, debounce, retry, or runtime-loop policy.
