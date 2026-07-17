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
//! Shared event DTOs, stream DTOs, event factories, capability summaries, and
//! the generated `TronEvent` catalog live here. The exhaustive `TronEvent`
//! variant catalog stays together in `events/tron/catalog.rs` for serde tagging
//! and match exhaustiveness. Shared DTOs stay domain-neutral so persistence
//! projections can construct them without reversing dependency direction.

use serde::{Deserialize, Serialize};
use serde_json::Value;

mod capability;
mod factory;
mod stream;
mod tron;

#[cfg(test)]
mod tests;

pub use capability::{CapabilityEventIdentity, CapabilityInvocationSummary};
pub use factory::{
    agent_end_event, agent_ready_event, agent_start_event, error_event,
    session_processing_changed_event, turn_failed_event,
};
pub use stream::{AssistantMessage, RetryErrorInfo, StreamEvent, is_stream_event_type};
#[cfg(test)]
pub(crate) use tron::VARIANT_COUNT;
pub use tron::{BaseEvent, CompactionReason, TronEvent};

/// Activity summary line carried by session-list update events.
///
/// Persistence projections construct this wire DTO, while clients enrich
/// primitive operation lines with generic presentation helpers.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySummaryLine {
    /// Discriminator for the line type (for example `"userPrompt"`, `"text"`, `"capability"`).
    pub kind: String,
    /// Plain-text excerpt, present for prompt and assistant-text lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Provider-visible primitive name for capability lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_primitive_name: Option<String>,
    /// Primitive operation requested inside `execute`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_name: Option<String>,
    /// Trace id for Inspect/debug surfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Root invocation id for Inspect/debug surfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_invocation_id: Option<String>,
    /// Runtime-owned theme color.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub theme_color: Option<String>,
    /// Runtime-owned presentation hints.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presentation_hints: Option<Value>,
    /// Plain activity summary.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// Capability invocation arguments, present for capability lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_args: Option<Value>,
    /// Capability invocation time in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    /// Whether the capability invocation produced an error.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    /// Number of agent turns for nested activity summaries.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turns: Option<i64>,
}
