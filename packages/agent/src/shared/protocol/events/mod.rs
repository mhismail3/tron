//! Event types for agent operation.
//!
//! Two event families:
//!
//! - **[`StreamEvent`]**: Low-level LLM streaming events from a provider
//!   (text deltas, thinking deltas, capability invocation construction, done/error).
//! - **[`TronEvent`]**: High-level agent lifecycle events with session context
//!   (agent start/end, turn boundaries, capability invocation, compaction).
//!
//! `StreamEvent` is purely in-memory (never persisted). `TronEvent` is
//! published through engine streams and may be recorded as session events.
//!
//! Stream DTOs, event factories, capability summaries, and the generated
//! `TronEvent` catalog live in focused child modules. The exhaustive
//! `TronEvent` variant catalog stays together in `events/tron/catalog.rs` for
//! serde tagging and match exhaustiveness.

mod capability;
mod factory;
mod stream;
mod tron;

#[cfg(test)]
mod tests;

pub use capability::{CapabilityEventIdentity, CapabilityInvocationSummary};
pub use factory::{
    agent_end_event, agent_ready_event, agent_start_event, session_processing_changed_event,
};
pub use stream::{AssistantMessage, RetryErrorInfo, StreamEvent, is_stream_event_type};
#[cfg(test)]
pub(crate) use tron::VARIANT_COUNT;
pub use tron::{BaseEvent, CompactionReason, TronEvent};
