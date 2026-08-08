//! Event types for agent operation.
//!
//! Two event families:
//!
//! - **[`StreamEvent`]**: Low-level LLM streaming events from a provider
//!   (text deltas, thinking deltas, tool invocation construction, done/error).
//! - **[`TronEvent`]**: High-level agent lifecycle events with session context
//!   (agent start/end, turn boundaries, tool invocation, compaction).
//!
//! `StreamEvent` is purely in-memory (never persisted). `TronEvent` is
//! published through engine streams and may be recorded as session events.
//! Failed `AgentEnd` events retain the terminal failure's recoverability so
//! downstream runtimes do not have to infer policy from display text.
//!
//! Shared event DTOs, stream DTOs, event factories, tool summaries, and
//! the generated `TronEvent` catalog live here. The exhaustive `TronEvent`
//! variant catalog stays together in `events/tron/catalog.rs` for serde tagging
//! and match exhaustiveness. Shared DTOs stay domain-neutral so persistence
//! projections can construct them without reversing dependency direction.

use serde::{Deserialize, Serialize};
use serde_json::Value;

mod factory;
mod stream;
mod tool;
mod tron;

#[cfg(test)]
mod tests;

#[cfg(test)]
pub use factory::{agent_end_event, agent_ready_event, agent_start_event};
pub use factory::{error_event, turn_failed_event};
pub use stream::{AssistantMessage, RetryErrorInfo, StreamEvent};
pub use tool::{ToolEventIdentity, ToolInvocationSummary};
#[cfg(test)]
pub(crate) use tron::VARIANT_COUNT;
pub use tron::{BaseEvent, CompactionReason, TronEvent};

/// Activity summary line carried by session-list update events.
///
/// Persistence projections construct this wire DTO, while clients enrich tool
/// lines with generic presentation helpers.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivitySummaryLine {
    /// Discriminator for the line type (for example `"userPrompt"`, `"text"`, `"tool"`).
    pub kind: String,
    /// Plain-text excerpt, present for prompt and assistant-text lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Provider-visible tool name for tool lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
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
    /// Tool invocation arguments, present for tool lines.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_args: Option<Value>,
    /// Tool invocation time in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    /// Whether the tool invocation produced an error.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    /// Number of agent turns for nested activity summaries.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turns: Option<i64>,
}
