//! Orchestrator modules — session management and multi-session coordination.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `orchestrator` | Multi-session coordinator, broadcast channel, capacity limits, sequence counters |
//! | `session_manager` | Session CRUD, active session cache, fork |
//! | `session_reconstructor` | Rebuild session state from persisted events |
//! | `session_context` | Per-session context and workspace path |
//! | `agent_runner` | High-level primitive run and event ordering |
//! | `agent_factory` | Creates `TronAgent` instances with provider and `execute` capability |
//! | `event_persister` | Persists agent events to the event store (supports pre-assigned sequences) |
//! | `turn_accumulator` | In-memory per-session scratchpad of in-flight turn content for `session.reconstruct` |
//! | `streaming_journal` | Per-turn append-only WAL for crash recovery of partial LLM output |
//! | `recovery` | Startup crash recovery — persists orphaned journal content |
//! | `capability_invocation_tracker` | Tracks in-flight capability invocations for cancellation |
//! | `invocation_abort_registry` | Per-invocation `CancellationToken` registry for `agent.abortCapabilityInvocation` |
//!
//! ## Event Sequencing
//!
//! Per-session monotonic sequence numbers are assigned at event emission time via
//! `Orchestrator::sequence_counters` (`DashMap<String, Arc<AtomicI64>>`). The counter
//! is initialized on session create (start=0) or resume (start=MAX from DB), and
//! threaded through: `Orchestrator → AgentRunner → TronAgent → TurnRunner →
//! StreamProcessor / CapabilityInvocationExecutor`. All emitted events carry `sequence` in both
//! the `TronEvent` (via `BaseEvent.sequence`) and server stream event sequence fields.
//! Runtime-persisted events that pre-assign from the counter must go through
//! `EventPersister::append_with_runtime_sequence`: it advances the counter from
//! DB truth and retries sequence collisions caused by any direct event-store
//! writer racing with the active turn.
//!
//! ## Streaming Journal (Crash Recovery)
//!
//! Each active LLM turn writes streaming deltas to a journal file at
//! `~/.tron/internal/database/journals/{session_id}/turn_{n}.wal`. On normal
//! completion the journal is deleted. If the server crashes mid-turn, orphaned
//! journals are recovered on next startup by `recovery::recover_incomplete_turns`,
//! which persists partial content as assistant messages before accepting connections.
//!
pub(crate) mod agent_factory;
pub(crate) mod agent_runner;
pub(crate) mod capability_invocation_tracker;
pub(crate) mod event_persister;
pub(crate) mod invocation_abort_registry;
#[allow(clippy::module_inception)]
pub(crate) mod orchestrator;
pub(crate) mod recovery;
pub(crate) mod session_context;
pub(crate) mod session_manager;
pub(crate) mod session_reconstructor;
pub(crate) mod streaming_journal;
pub(crate) mod turn_accumulator;
