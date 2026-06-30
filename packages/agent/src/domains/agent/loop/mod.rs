//! Primitive agent loop.
//!
//! The loop owns provider execution after startup has accepted a prompt:
//! reconstruct session state, compose soul/state/history context, call the
//! provider with one `execute` capability, persist resulting events, and repeat
//! until the assistant reaches a terminal response.
//!
//! Runtime observability is intentionally first-class here. The loop emits
//! structured `agent_event` logs for run/turn boundaries, provider requests,
//! stream lifecycle, and model-requested capability execution. INFO logs mark
//! durable lifecycle transitions and IDs; TRACE logs add high-volume stream
//! sizes and sequencing metadata without recording prompt text, generated text,
//! or tool arguments. Provider-facing capability results stay terse for users
//! while selected read/list/record operations append bounded model-context
//! evidence containing safe ids, lifecycle/status, refs, and truncation
//! metadata; raw logs, commands, code, file contents, local paths, secrets,
//! grant ids, authority ids, and hidden reasoning are not projected. Failures
//! rejected before durable trace insertion still rely on direct bounded failure
//! result evidence; adding a pre-trace failure record is a separate tracing
//! slice.

#![deny(unsafe_code)]

pub mod capability_invocation_executor;
pub mod compaction_handler;
pub mod errors;
pub mod event_emitter;
pub mod orchestrator;
pub(crate) mod pipeline;
pub mod primitive_surface;
pub mod profile_runtime;
mod stream_message;
pub mod stream_processor;
mod stream_state;
pub mod tron_agent;
pub mod turn_runner;
pub(crate) mod types;

pub(crate) use event_emitter::EventEmitter;
pub use orchestrator::core::Orchestrator;
pub use orchestrator::recovery::recover_incomplete_turns;
pub use orchestrator::session_manager::{SessionFilter, SessionManager};
pub use profile_runtime::ProfileRuntime;
