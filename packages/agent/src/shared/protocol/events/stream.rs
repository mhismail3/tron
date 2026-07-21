//! Provider stream event DTOs and type guards.

use serde::{Deserialize, Serialize};

use crate::shared::protocol::content::ThinkingContentKind;
use crate::shared::protocol::messages::{TokenUsage, ToolInvocationDraft};

/// Events emitted during LLM response streaming.
///
/// These are transient (never persisted) and drive real-time UI updates
/// as the model generates content.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum StreamEvent {
    /// Stream started.
    #[serde(rename = "start")]
    Start,

    /// Text block started.
    #[serde(rename = "text_start")]
    TextStart,

    /// Incremental text content.
    #[serde(rename = "text_delta")]
    TextDelta {
        /// Text fragment.
        delta: String,
    },

    /// Text block completed.
    #[serde(rename = "text_end")]
    TextEnd {
        /// Full accumulated text.
        text: String,
        /// Verification signature.
        #[serde(skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
    },

    /// Thinking block started (extended thinking).
    #[serde(rename = "thinking_start")]
    ThinkingStart,

    /// Incremental thinking content.
    #[serde(rename = "thinking_delta")]
    ThinkingDelta {
        /// Thinking text fragment.
        delta: String,
        /// Source contract for this thinking-like stream.
        #[serde(default, skip_serializing_if = "ThinkingContentKind::is_thinking")]
        kind: ThinkingContentKind,
    },

    /// Thinking block completed.
    #[serde(rename = "thinking_end")]
    ThinkingEnd {
        /// Full thinking text.
        thinking: String,
        /// Source contract for this thinking-like stream.
        #[serde(default, skip_serializing_if = "ThinkingContentKind::is_thinking")]
        kind: ThinkingContentKind,
        /// Verification signature.
        #[serde(skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
    },

    /// Tool invocation started.
    #[serde(rename = "tool_invocation_start")]
    ToolInvocationDraftStart {
        /// Tool invocation ID.
        #[serde(rename = "invocationId")]
        invocation_id: String,
        /// Tool name.
        name: String,
    },

    /// Incremental tool invocation argument JSON.
    #[serde(rename = "tool_invocation_delta")]
    ToolInvocationDraftDelta {
        /// Tool invocation ID.
        #[serde(rename = "invocationId")]
        invocation_id: String,
        /// Partial JSON arguments.
        #[serde(rename = "argumentsDelta")]
        arguments_delta: String,
    },

    /// Tool invocation fully constructed.
    #[serde(rename = "tool_invocation_end")]
    ToolInvocationDraftEnd {
        /// Complete tool invocation.
        #[serde(rename = "toolInvocation")]
        tool_invocation: ToolInvocationDraft,
    },

    /// Stream completed successfully.
    #[serde(rename = "done")]
    Done {
        /// Full assistant message.
        message: AssistantMessage,
        /// Stop reason from LLM.
        #[serde(rename = "stopReason")]
        stop_reason: String,
    },

    /// Stream error.
    #[serde(rename = "error")]
    Error {
        /// Error message.
        error: String,
    },

    /// Retryable error — a retry is about to happen.
    #[serde(rename = "retry")]
    Retry {
        /// Current attempt (1-based).
        attempt: u32,
        /// Maximum retries configured.
        #[serde(rename = "maxRetries")]
        max_retries: u32,
        /// Delay before next retry in ms.
        #[serde(rename = "delayMs")]
        delay_ms: u64,
        /// Error info.
        error: RetryErrorInfo,
    },

    /// Safety block (Gemini provider).
    #[serde(rename = "safety_block")]
    SafetyBlock {
        /// Categories that triggered the block.
        #[serde(rename = "blockedCategories")]
        blocked_categories: Vec<String>,
        /// Error message.
        error: String,
    },
}

/// Error info attached to a [`StreamEvent::Retry`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RetryErrorInfo {
    /// Error category string.
    pub category: String,
    /// Human-readable message.
    pub message: String,
    /// Whether retryable.
    #[serde(rename = "isRetryable")]
    pub is_retryable: bool,
}

// ─────────────────────────────────────────────────────────────────────────────

// Type guards
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────

/// An assistant message (used in [`StreamEvent::Done`]).
///
/// This is a type alias for the message type — the full `Message::Assistant`
/// variant carries all the fields, but for streaming we only need
/// the content + metadata.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantMessage {
    /// Assistant content blocks.
    pub content: Vec<crate::shared::protocol::content::AssistantContent>,
    /// Token usage.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<TokenUsage>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
