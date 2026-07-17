//! Orchestrator modules — session management and multi-session coordination.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `core` | Multi-session coordinator, broadcast channel, capacity limits, sequence counters |
//! | `session_manager` | Cache-coordinated session lifecycle, reconstructed-state cache, prompt eviction guard |
//! | `session_reconstructor` | Rebuild the runtime execution projection from persisted events |
//! | `agent_runner` | High-level primitive run and event ordering |
//! | `agent_factory` | Creates `TronAgent` instances with their required provider and engine host owners |
//! | `event_persister` | Reconciles live sequence counters before direct transactional event-store writes |
//! | `turn_accumulator` | In-memory per-session scratchpad of in-flight turn content for `session.reconstruct` |
//! | `streaming_journal` | Per-turn append-only WAL for crash recovery of ordered partial LLM output |
//! | `recovery` | Startup crash recovery — persists orphaned journal content |
//! | `capability_invocation_tracker` | Tracks in-flight capability invocations for cancellation |
//! | `invocation_abort_registry` | Authoritative per-invocation `CancellationToken` registry for `agent.abortCapabilityInvocation` |
//!
//! ## Entry Points
//!
//! - [`core::Orchestrator`] coordinates sessions, runs, and stream broadcast.
//! - [`session_manager::SessionManager`] owns the reconstructed-state cache and
//!   delegates durable session lifecycle mutation to the event store;
//!   query owners read rows from the event store directly, while shutdown uses
//!   one cache-aware bulk-end operation.
//! - The runtime reconstruction projection contains only execution inputs used
//!   on resume; prompt-request and agent-construction owners retain configuration
//!   policy.
//! - [`recovery::recover_incomplete_turns`] replays orphaned streaming journals
//!   and closes durable starts that lack a later terminal row
//!   during startup.
//!
//! ## Dependency Direction
//!
//! Depends on agent loop primitives, session event-store contracts, and shared
//! protocol events. Depended on by bootstrap, prompt runtime services, and
//! session reconstruction. The core coordinator depends on sibling helpers, and
//! sibling helpers import the concrete owner directly.
//!
//! ## Event Sequencing
//!
//! Per-session monotonic sequence numbers are assigned at event emission time via
//! `Orchestrator::sequence_counters` (`DashMap<String, Arc<AtomicI64>>`). The counter
//! is initialized on session create (start=0) or resume (start=MAX from DB), and
//! threaded through: `Orchestrator → AgentRunner → TronAgent → TurnRunner →
//! StreamProcessor / CapabilityInvocationExecutor`. Agent-loop lifecycle and
//! content events emitted while that counter is attached carry `sequence` in
//! both the `TronEvent` (via `BaseEvent.sequence`) and server stream event
//! sequence fields. Pre-run failures that occur before a counter can be safely
//! attached remain explicitly outside this ordered run stream.
//! Runtime-persisted events that pre-assign from the counter must go through
//! `EventPersister::append_with_runtime_sequence`: it advances the counter from
//! DB truth and retries sequence collisions caused by any direct event-store
//! writer racing with the active turn.
//!
//! ## Streaming Journal (Crash Recovery)
//!
//! Each active LLM turn writes streaming deltas to a journal file at
//! `~/.tron/internal/database/journals/{session_id}/turn_{n}.wal`. On normal
//! completion or durable turn failure the journal is deleted. It remains open
//! through capability execution and turn-end persistence, not merely assistant
//! persistence. Startup recovery scopes rows to the latest start for an ordinal,
//! recognizes legacy terminal rows without starts, closes incomplete capability
//! invocations, and atomically appends any missing assistant/turn-end lifecycle
//! before accepting connections. A database sweep also closes durable starts
//! that have no terminal even when a crash or failed write happened before a
//! journal existed.
//! The journal records block-final snapshots and capability draft start/end
//! markers so recovered `message.assistant.content` uses the same ordered,
//! canonical content shape as normal turn completion.
//!
//! ## Invariants
//!
//! - Per-session sequence counters are monotonic, exhaustion is fail-closed,
//!   and counters are reconciled against durable event-store truth before
//!   runtime persistence; row-backed turn starts, ends, and failures allocate
//!   after any earlier transient runtime event.
//! - Requested capability starts commit as one batch before execution. A
//!   phase's executed and skipped completions likewise commit as one ordered
//!   batch before broadcast. A lifecycle persistence failure stops the turn
//!   rather than continuing with provider context that cannot be reconstructed.
//! - Journal appends fail closed. Provider-stream errors atomically persist any
//!   accumulated assistant content with `turn.failed` before journal cleanup.
//! - The event store, not an agent-owned queue, serializes per-session writes
//!   and owns parent/head threading; persistence calls return after commit.
//! - Active runs must hold a registry permit and remove their active session
//!   entry on drop.
//! - Streaming journal recovery runs before accepting new connections.
//!
//! ## Test Ownership
//!
//! Coordinator tests live in [`core`]. Helper behavior tests live beside each
//! helper module, and prompt/session integration tests exercise the public
//! [`core::Orchestrator`] boundary.
//!
pub(crate) mod agent_factory;
pub(crate) mod agent_runner;
pub(crate) mod capability_invocation_tracker;
pub(crate) mod core;
pub(crate) mod event_persister;
pub(crate) mod invocation_abort_registry;
pub(crate) mod recovery;
pub(crate) mod session_manager;
pub(crate) mod session_reconstructor;
pub(crate) mod streaming_journal;
pub(crate) mod turn_accumulator;
