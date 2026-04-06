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
//! | `agent_factory` | Creates `TronAgent` instances with provider/tools/hooks |
//! | `event_persister` | Persists agent events to the event store (supports pre-assigned sequences) |
//! | `subagent_manager` | Spawns/manages child agents for parallel tool execution |
//! | `process_manager` | Centralized lifecycle management for deterministic processes |
//! | `tool_call_tracker` | Tracks in-flight tool calls for cancellation |
//!
//! ## Event Sequencing
//!
//! Per-session monotonic sequence numbers are assigned at event emission time via
//! `Orchestrator::sequence_counters` (`DashMap<String, Arc<AtomicI64>>`). The counter
//! is initialized on session create (start=0) or resume (start=MAX from DB), and
//! threaded through: `Orchestrator → AgentRunner → TronAgent → TurnRunner →
//! StreamProcessor / ToolExecutor`. All emitted events carry `sequence` in both
//! the `TronEvent` (via `BaseEvent.sequence`) and `RpcEvent.sequence` fields.
//!
//! ## Critical Event Ordering
//!
//! `agent_runner` controls the post-run sequence: `agent.complete` (from `TronAgent`)
//! → drain background hooks → `agent.ready` (from `AgentRunner`). iOS depends on
//! `agent.ready` arriving AFTER `agent.complete` to clear the send button.

pub mod agent_factory;
pub mod agent_runner;
pub mod event_persister;
pub mod job_manager;
#[allow(clippy::module_inception)]
pub mod orchestrator;
pub mod output_buffer;
pub mod process_manager;
pub mod session_context;
pub mod session_manager;
pub mod session_reconstructor;
pub mod subagent_manager;
pub mod tool_call_tracker;
pub mod turn_accumulator;
