//! Orchestrator modules — session management and multi-session coordination.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `orchestrator` | Multi-session coordinator, broadcast channel, capacity limits, sequence counters |
//! | `session_manager` | Session CRUD, active session cache, fork |
//! | `session_reconstructor` | Rebuild session state from persisted events |
//! | `session_context` | Per-session context (workspace path, rules, skills) |
//! | `agent_runner` | High-level agent run: skill injection → run → event ordering |
//! | `agent_factory` | Creates `TronAgent` instances with provider/capabilities/hooks |
//! | `event_persister` | Persists agent events to the event store (supports pre-assigned sequences) |
//! | `subagent_manager` | Spawns/manages child agents for parallel capability invocation |
//! | `process_manager` | Centralized lifecycle management for deterministic processes |
//! | `job_manager` | Unified `JobManagerOps` facade routing by id prefix: `proc-*` → processes, else → subagents |
//! | `output_buffer` | Always-on capped ring buffer for streaming process stdout/stderr with on-demand replay |
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
//!
//! ## Streaming Journal (Crash Recovery)
//!
//! Each active LLM turn writes streaming deltas to a journal file at
//! `~/.tron/internal/database/journals/{session_id}/turn_{n}.wal`. On normal
//! completion the journal is deleted. If the server crashes mid-turn, orphaned
//! journals are recovered on next startup by `recovery::recover_incomplete_turns`,
//! which persists partial content as assistant messages before accepting connections.
//!
//! ## Critical Event Ordering
//!
//! `agent_runner` controls the post-run sequence: `agent.complete` (from `TronAgent`)
//! → drain background hooks → `agent.ready` (from `AgentRunner`). iOS depends on
//! `agent.ready` arriving AFTER `agent.complete` to clear the send button.

pub mod agent_factory;
pub mod agent_runner;
pub mod capability_invocation_tracker;
pub mod event_persister;
pub mod invocation_abort_registry;
pub mod job_manager;
#[allow(clippy::module_inception)]
pub mod orchestrator;
pub mod output_buffer;
pub mod process_manager;
pub mod recovery;
pub mod session_context;
pub mod session_manager;
pub mod session_reconstructor;
pub mod streaming_journal;
pub mod subagent_manager;
pub mod turn_accumulator;
