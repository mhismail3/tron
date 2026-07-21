//! Primitive agent loop.
//!
//! The loop owns provider execution after startup has accepted a prompt:
//! reconstruct session state, compose product intent and durable history, call the
//! provider with the resolved direct typed surface, persist resulting events,
//! and repeat until the assistant reaches a terminal response.
//!
//! Runtime observability is intentionally first-class here. The loop emits
//! structured `agent_event` logs for run/turn boundaries, provider requests,
//! stream lifecycle, and model-requested tool execution. INFO logs mark
//! durable lifecycle transitions and IDs; TRACE logs add high-volume stream
//! sizes and sequencing metadata without recording prompt text, generated text,
//! or tool arguments. Provider-facing tool results stay terse for users
//! while selected read/list/record operations append bounded model-context
//! evidence containing safe ids, lifecycle/status, refs, and truncation
//! metadata; raw logs, commands, code, file contents, local paths, secrets,
//! grant ids, authority ids, and hidden reasoning are not projected. Failures
//! rejected before durable trace insertion still rely on direct bounded failure
//! result evidence.
//!
//! Every `TronAgent` owns a required engine host for its full lifetime. Each
//! turn borrows that host to adapt the worker-kernel-owned live tool surface
//! into provider schemas and to execute provider-requested tool invocations
//! through the same engine. The kernel resolver records the exact catalog
//! revision and surface hash; the prompt receives a compact revision/count
//! primer rather than another catalog-inspection workflow.
//! Turn starts, ends, and failures are persisted before their matching live
//! broadcast, and each surface shares the durable row sequence. User
//! cancellation is terminalized by the active turn runner, which owns the
//! session-global turn ordinal and any partial content; prompt completion never
//! manufactures turn lifecycle rows. The streaming journal remains until
//! tool completions and the turn terminal have committed; journal-write
//! failure stops the stream before broadcasting content that cannot be
//! recovered. Provider failures atomically retain any already visible partial
//! assistant content with `turn.failed`. Durable turn entry precedes cancellable
//! pre-turn compaction. The compaction handler owns cancellation rollback and a
//! matching failed completion event before Stop closes the active ordinal.
//! Direct-tool results always return to provider context; no tool metadata or
//! result flag can terminate the agent loop. Only provider completion, limits,
//! cancellation, and runtime failure own terminal control flow.

#![deny(unsafe_code)]

pub mod compaction_handler;
pub mod errors;
pub mod event_emitter;
pub mod orchestrator;
pub(crate) mod pipeline;
pub mod primitive_surface;
mod stream_message;
pub mod stream_processor;
mod stream_state;
pub mod tool_executor;
pub mod tron_agent;
pub mod turn_runner;
pub(crate) mod types;

pub(crate) use event_emitter::EventEmitter;
pub use orchestrator::core::Orchestrator;
pub use orchestrator::recovery::recover_incomplete_turns;
pub use orchestrator::session_manager::SessionManager;
