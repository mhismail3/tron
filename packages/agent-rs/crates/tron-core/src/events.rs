//! Event types for agent operation.
//!
//! Two event families:
//!
//! - **[`StreamEvent`]**: Low-level LLM streaming events from a provider
//!   (text deltas, thinking deltas, tool call construction, done/error).
//! - **[`TronEvent`]**: High-level agent lifecycle events with session context
//!   (agent start/end, turn boundaries, tool execution, hooks, compaction).
//!
//! `StreamEvent` is purely in-memory (never persisted). `TronEvent` is
//! broadcast over WebSocket and may be recorded as session events.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::messages::{ToolCall, TokenUsage};
use crate::tools::TronToolResult;

// ─────────────────────────────────────────────────────────────────────────────
// StreamEvent — LLM provider streaming events
// ─────────────────────────────────────────────────────────────────────────────

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
    },

    /// Thinking block completed.
    #[serde(rename = "thinking_end")]
    ThinkingEnd {
        /// Full thinking text.
        thinking: String,
        /// Verification signature.
        #[serde(skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
    },

    /// Tool call started.
    #[serde(rename = "toolcall_start")]
    ToolCallStart {
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Tool name.
        name: String,
    },

    /// Incremental tool call argument JSON.
    #[serde(rename = "toolcall_delta")]
    ToolCallDelta {
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Partial JSON arguments.
        #[serde(rename = "argumentsDelta")]
        arguments_delta: String,
    },

    /// Tool call fully constructed.
    #[serde(rename = "toolcall_end")]
    ToolCallEnd {
        /// Complete tool call.
        #[serde(rename = "toolCall")]
        tool_call: ToolCall,
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
// TronEvent — agent lifecycle events
// ─────────────────────────────────────────────────────────────────────────────

/// Common fields for all agent events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BaseEvent {
    /// Session this event belongs to.
    pub session_id: String,
    /// ISO 8601 timestamp.
    pub timestamp: String,
}

impl BaseEvent {
    /// Create a new base event with the current UTC timestamp.
    #[must_use]
    pub fn now(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            timestamp: chrono::Utc::now().to_rfc3339(),
        }
    }
}

/// Token usage reported in turn-end events.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnTokenUsage {
    /// Input tokens.
    pub input_tokens: u64,
    /// Output tokens.
    pub output_tokens: u64,
    /// Tokens read from prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<u64>,
    /// Tokens written to prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_tokens: Option<u64>,
}

/// Extended token usage for response-complete events.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResponseTokenUsage {
    /// Input tokens.
    pub input_tokens: u64,
    /// Output tokens.
    pub output_tokens: u64,
    /// Tokens read from prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<u64>,
    /// Tokens written to prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_tokens: Option<u64>,
    /// 5-minute cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_5m_tokens: Option<u64>,
    /// 1-hour cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_1h_tokens: Option<u64>,
}

/// Tool call summary in a batch event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolCallSummary {
    /// Tool call ID.
    pub id: String,
    /// Tool name.
    pub name: String,
    /// Tool arguments.
    pub arguments: serde_json::Map<String, Value>,
}

/// Hook completion result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookResult {
    /// Hook allowed the operation to continue.
    Continue,
    /// Hook blocked the operation.
    Block,
    /// Hook modified the operation.
    Modify,
}

/// Background hook completion result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BackgroundHookResult {
    /// All hooks succeeded.
    Continue,
    /// At least one hook failed.
    Error,
}

/// Compaction trigger reason.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompactionReason {
    /// Pre-turn guardrail triggered compaction.
    PreTurnGuardrail,
    /// Token threshold exceeded.
    ThresholdExceeded,
    /// User requested compaction.
    Manual,
}

/// High-level agent event with session context.
///
/// These events are broadcast over WebSocket and may be persisted as
/// session events. iOS relies on exact type strings and field names.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum TronEvent {
    // -- Agent lifecycle --

    /// Agent started processing.
    #[serde(rename = "agent_start")]
    AgentStart {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
    },

    /// Agent finished processing.
    #[serde(rename = "agent_end")]
    AgentEnd {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Error message if ended due to error.
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    /// Agent ready (post-processing complete, safe to send next message).
    #[serde(rename = "agent_ready")]
    AgentReady {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
    },

    /// Agent interrupted by user.
    #[serde(rename = "agent_interrupted")]
    AgentInterrupted {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Turn number when interrupted.
        turn: u32,
        /// Partial content captured before interruption.
        #[serde(rename = "partialContent", skip_serializing_if = "Option::is_none")]
        partial_content: Option<String>,
        /// Tool that was running when interrupted.
        #[serde(rename = "activeTool", skip_serializing_if = "Option::is_none")]
        active_tool: Option<String>,
    },

    // -- Turn lifecycle --

    /// Turn started.
    #[serde(rename = "turn_start")]
    TurnStart {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Turn number.
        turn: u32,
    },

    /// Turn completed.
    #[serde(rename = "turn_end")]
    TurnEnd {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Turn number.
        turn: u32,
        /// Duration in milliseconds.
        duration: u64,
        /// Token usage for this turn.
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<TurnTokenUsage>,
        /// Canonical token record.
        #[serde(rename = "tokenRecord", skip_serializing_if = "Option::is_none")]
        token_record: Option<Value>,
        /// Cost for this turn in USD.
        #[serde(skip_serializing_if = "Option::is_none")]
        cost: Option<f64>,
        /// Context window limit (for iOS sync after model switch).
        #[serde(rename = "contextLimit", skip_serializing_if = "Option::is_none")]
        context_limit: Option<u64>,
    },

    /// Turn failed.
    #[serde(rename = "agent.turn_failed")]
    TurnFailed {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Turn number.
        turn: u32,
        /// Human-readable error message.
        error: String,
        /// Error category code.
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        /// Human-readable error category.
        #[serde(skip_serializing_if = "Option::is_none")]
        category: Option<String>,
        /// Whether the user can retry.
        recoverable: bool,
        /// Content generated before failure.
        #[serde(rename = "partialContent", skip_serializing_if = "Option::is_none")]
        partial_content: Option<String>,
    },

    /// LLM response finished streaming (before tool execution).
    #[serde(rename = "response_complete")]
    ResponseComplete {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Turn number.
        turn: u32,
        /// Stop reason from LLM.
        #[serde(rename = "stopReason")]
        stop_reason: String,
        /// Raw token usage.
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<ResponseTokenUsage>,
        /// Whether the response contains tool calls.
        #[serde(rename = "hasToolCalls")]
        has_tool_calls: bool,
        /// Number of tool calls.
        #[serde(rename = "toolCallCount")]
        tool_call_count: u32,
    },

    // -- Message --

    /// Message content update.
    #[serde(rename = "message_update")]
    MessageUpdate {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Content delta.
        content: String,
    },

    // -- Tool execution --

    /// All tool calls from the model's response (before execution).
    #[serde(rename = "tool_use_batch")]
    ToolUseBatch {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Tool calls.
        #[serde(rename = "toolCalls")]
        tool_calls: Vec<ToolCallSummary>,
    },

    /// Tool execution started.
    #[serde(rename = "tool_execution_start")]
    ToolExecutionStart {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Tool name.
        #[serde(rename = "toolName")]
        tool_name: String,
        /// Tool arguments.
        #[serde(skip_serializing_if = "Option::is_none")]
        arguments: Option<serde_json::Map<String, Value>>,
    },

    /// Tool execution progress update.
    #[serde(rename = "tool_execution_update")]
    ToolExecutionUpdate {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Progress update text.
        update: String,
    },

    /// Tool execution completed.
    #[serde(rename = "tool_execution_end")]
    ToolExecutionEnd {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Tool name.
        #[serde(rename = "toolName")]
        tool_name: String,
        /// Duration in milliseconds.
        duration: u64,
        /// Whether execution resulted in error.
        #[serde(rename = "isError", skip_serializing_if = "Option::is_none")]
        is_error: Option<bool>,
        /// Detailed result.
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<TronToolResult>,
    },

    /// Tool call argument delta (during streaming).
    #[serde(rename = "toolcall_delta")]
    ToolCallArgumentDelta {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Tool name.
        #[serde(rename = "toolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        /// Partial JSON arguments delta.
        #[serde(rename = "argumentsDelta")]
        arguments_delta: String,
    },

    /// Tool call generating (`toolcall_start`, before arguments streamed).
    #[serde(rename = "toolcall_generating")]
    ToolCallGenerating {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Tool name.
        #[serde(rename = "toolName")]
        tool_name: String,
    },

    // -- Hooks --

    /// Hook execution triggered.
    #[serde(rename = "hook_triggered")]
    HookTriggered {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Hook names being executed.
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        /// Hook event type.
        #[serde(rename = "hookEvent")]
        hook_event: String,
        /// Tool name for tool-related hooks.
        #[serde(rename = "toolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        /// Tool call ID for tool-related hooks.
        #[serde(rename = "toolCallId", skip_serializing_if = "Option::is_none")]
        tool_call_id: Option<String>,
    },

    /// Hook execution completed.
    #[serde(rename = "hook_completed")]
    HookCompleted {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Hook names that were executed.
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        /// Hook event type.
        #[serde(rename = "hookEvent")]
        hook_event: String,
        /// Result action.
        result: HookResult,
        /// Duration in milliseconds.
        #[serde(skip_serializing_if = "Option::is_none")]
        duration: Option<u64>,
        /// Reason for block/modify.
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        /// Tool name.
        #[serde(rename = "toolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        /// Tool call ID.
        #[serde(rename = "toolCallId", skip_serializing_if = "Option::is_none")]
        tool_call_id: Option<String>,
    },

    /// Background hook execution started.
    #[serde(rename = "hook.background_started")]
    HookBackgroundStarted {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Hook names.
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        /// Hook event type.
        #[serde(rename = "hookEvent")]
        hook_event: String,
        /// Correlation ID.
        #[serde(rename = "executionId")]
        execution_id: String,
    },

    /// Background hook execution completed.
    #[serde(rename = "hook.background_completed")]
    HookBackgroundCompleted {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Hook names.
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        /// Hook event type.
        #[serde(rename = "hookEvent")]
        hook_event: String,
        /// Correlation ID.
        #[serde(rename = "executionId")]
        execution_id: String,
        /// Result.
        result: BackgroundHookResult,
        /// Duration in milliseconds.
        duration: u64,
        /// Error message if result is error.
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    // -- Session --

    /// Session saved.
    #[serde(rename = "session_saved")]
    SessionSaved {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// File path.
        #[serde(rename = "filePath")]
        file_path: String,
    },

    /// Session loaded.
    #[serde(rename = "session_loaded")]
    SessionLoaded {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// File path.
        #[serde(rename = "filePath")]
        file_path: String,
        /// Number of messages loaded.
        #[serde(rename = "messageCount")]
        message_count: u32,
    },

    // -- Context --

    /// Context window warning.
    #[serde(rename = "context_warning")]
    ContextWarning {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Usage percentage.
        #[serde(rename = "usagePercent")]
        usage_percent: f64,
        /// Warning message.
        message: String,
    },

    // -- Compaction --

    /// Compaction started.
    #[serde(rename = "compaction_start")]
    CompactionStart {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Trigger reason.
        reason: CompactionReason,
        /// Token count before compaction.
        #[serde(rename = "tokensBefore")]
        tokens_before: u64,
    },

    /// Compaction completed.
    #[serde(rename = "compaction_complete")]
    CompactionComplete {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Whether compaction succeeded.
        success: bool,
        /// Token count before compaction.
        #[serde(rename = "tokensBefore")]
        tokens_before: u64,
        /// Token count after compaction.
        #[serde(rename = "tokensAfter")]
        tokens_after: u64,
        /// Compression ratio (0-1, lower is better).
        #[serde(rename = "compressionRatio")]
        compression_ratio: f64,
        /// Trigger reason.
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<CompactionReason>,
        /// Summary of compacted context.
        #[serde(skip_serializing_if = "Option::is_none")]
        summary: Option<String>,
        /// Estimated total context tokens after compaction.
        #[serde(rename = "estimatedContextTokens", skip_serializing_if = "Option::is_none")]
        estimated_context_tokens: Option<u64>,
    },

    // -- Error / Retry --

    /// Error event.
    #[serde(rename = "error")]
    Error {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Error message.
        error: String,
        /// Error context.
        #[serde(skip_serializing_if = "Option::is_none")]
        context: Option<String>,
    },

    /// API retry event.
    #[serde(rename = "api_retry")]
    ApiRetry {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Current attempt (1-based).
        attempt: u32,
        /// Maximum retries configured.
        #[serde(rename = "maxRetries")]
        max_retries: u32,
        /// Delay before next retry in ms.
        #[serde(rename = "delayMs")]
        delay_ms: u64,
        /// Error category.
        #[serde(rename = "errorCategory")]
        error_category: String,
        /// Error message.
        #[serde(rename = "errorMessage")]
        error_message: String,
    },

    // -- Thinking (agent-level with session context) --

    /// Thinking started.
    #[serde(rename = "thinking_start")]
    ThinkingStart {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
    },

    /// Thinking delta.
    #[serde(rename = "thinking_delta")]
    ThinkingDelta {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Thinking text fragment.
        delta: String,
    },

    /// Thinking ended.
    #[serde(rename = "thinking_end")]
    ThinkingEnd {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Full thinking text.
        thinking: String,
    },
}

impl TronEvent {
    /// Get the base event fields.
    #[must_use]
    pub fn base(&self) -> &BaseEvent {
        match self {
            Self::AgentStart { base, .. }
            | Self::AgentEnd { base, .. }
            | Self::AgentReady { base, .. }
            | Self::AgentInterrupted { base, .. }
            | Self::TurnStart { base, .. }
            | Self::TurnEnd { base, .. }
            | Self::TurnFailed { base, .. }
            | Self::ResponseComplete { base, .. }
            | Self::MessageUpdate { base, .. }
            | Self::ToolUseBatch { base, .. }
            | Self::ToolExecutionStart { base, .. }
            | Self::ToolExecutionUpdate { base, .. }
            | Self::ToolExecutionEnd { base, .. }
            | Self::ToolCallArgumentDelta { base, .. }
            | Self::ToolCallGenerating { base, .. }
            | Self::HookTriggered { base, .. }
            | Self::HookCompleted { base, .. }
            | Self::HookBackgroundStarted { base, .. }
            | Self::HookBackgroundCompleted { base, .. }
            | Self::SessionSaved { base, .. }
            | Self::SessionLoaded { base, .. }
            | Self::ContextWarning { base, .. }
            | Self::CompactionStart { base, .. }
            | Self::CompactionComplete { base, .. }
            | Self::Error { base, .. }
            | Self::ApiRetry { base, .. }
            | Self::ThinkingStart { base, .. }
            | Self::ThinkingDelta { base, .. }
            | Self::ThinkingEnd { base, .. } => base,
        }
    }

    /// Get the session ID.
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.base().session_id
    }

    /// Get the timestamp.
    #[must_use]
    pub fn timestamp(&self) -> &str {
        &self.base().timestamp
    }

    /// Get the event type string (for type discrimination).
    #[must_use]
    pub fn event_type(&self) -> &str {
        match self {
            Self::AgentStart { .. } => "agent_start",
            Self::AgentEnd { .. } => "agent_end",
            Self::AgentReady { .. } => "agent_ready",
            Self::AgentInterrupted { .. } => "agent_interrupted",
            Self::TurnStart { .. } => "turn_start",
            Self::TurnEnd { .. } => "turn_end",
            Self::TurnFailed { .. } => "agent.turn_failed",
            Self::ResponseComplete { .. } => "response_complete",
            Self::MessageUpdate { .. } => "message_update",
            Self::ToolUseBatch { .. } => "tool_use_batch",
            Self::ToolExecutionStart { .. } => "tool_execution_start",
            Self::ToolExecutionUpdate { .. } => "tool_execution_update",
            Self::ToolExecutionEnd { .. } => "tool_execution_end",
            Self::ToolCallArgumentDelta { .. } => "toolcall_delta",
            Self::ToolCallGenerating { .. } => "toolcall_generating",
            Self::HookTriggered { .. } => "hook_triggered",
            Self::HookCompleted { .. } => "hook_completed",
            Self::HookBackgroundStarted { .. } => "hook.background_started",
            Self::HookBackgroundCompleted { .. } => "hook.background_completed",
            Self::SessionSaved { .. } => "session_saved",
            Self::SessionLoaded { .. } => "session_loaded",
            Self::ContextWarning { .. } => "context_warning",
            Self::CompactionStart { .. } => "compaction_start",
            Self::CompactionComplete { .. } => "compaction_complete",
            Self::Error { .. } => "error",
            Self::ApiRetry { .. } => "api_retry",
            Self::ThinkingStart { .. } => "thinking_start",
            Self::ThinkingDelta { .. } => "thinking_delta",
            Self::ThinkingEnd { .. } => "thinking_end",
        }
    }

    /// Whether this is a tool execution event.
    #[must_use]
    pub fn is_tool_execution(&self) -> bool {
        matches!(
            self,
            Self::ToolExecutionStart { .. }
                | Self::ToolExecutionUpdate { .. }
                | Self::ToolExecutionEnd { .. }
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Factory helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Create an agent-start event.
#[must_use]
pub fn agent_start_event(session_id: impl Into<String>) -> TronEvent {
    TronEvent::AgentStart {
        base: BaseEvent::now(session_id),
    }
}

/// Create an agent-end event.
#[must_use]
pub fn agent_end_event(session_id: impl Into<String>) -> TronEvent {
    TronEvent::AgentEnd {
        base: BaseEvent::now(session_id),
        error: None,
    }
}

/// Create an agent-ready event.
#[must_use]
pub fn agent_ready_event(session_id: impl Into<String>) -> TronEvent {
    TronEvent::AgentReady {
        base: BaseEvent::now(session_id),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Type guards
// ─────────────────────────────────────────────────────────────────────────────

/// Stream event type strings.
const STREAM_EVENT_TYPES: &[&str] = &[
    "start",
    "text_start",
    "text_delta",
    "text_end",
    "thinking_start",
    "thinking_delta",
    "thinking_end",
    "toolcall_start",
    "toolcall_delta",
    "toolcall_end",
    "done",
    "error",
    "retry",
    "safety_block",
];

/// Check if a type string is a stream event type.
#[must_use]
pub fn is_stream_event_type(type_str: &str) -> bool {
    STREAM_EVENT_TYPES.contains(&type_str)
}

// ─────────────────────────────────────────────────────────────────────────────
// AssistantMessage type alias
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
    pub content: Vec<crate::content::AssistantContent>,
    /// Token usage.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<TokenUsage>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // -- StreamEvent --

    #[test]
    fn stream_event_start_serde() {
        let e = StreamEvent::Start;
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json, json!({"type": "start"}));
        let back: StreamEvent = serde_json::from_value(json).unwrap();
        assert_eq!(e, back);
    }

    #[test]
    fn stream_event_text_delta_serde() {
        let e = StreamEvent::TextDelta {
            delta: "hello".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "text_delta");
        assert_eq!(json["delta"], "hello");
    }

    #[test]
    fn stream_event_text_end_serde() {
        let e = StreamEvent::TextEnd {
            text: "full text".into(),
            signature: Some("sig123".into()),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "text_end");
        assert_eq!(json["text"], "full text");
        assert_eq!(json["signature"], "sig123");
    }

    #[test]
    fn stream_event_text_end_no_signature() {
        let e = StreamEvent::TextEnd {
            text: "text".into(),
            signature: None,
        };
        let json = serde_json::to_value(&e).unwrap();
        assert!(json.get("signature").is_none());
    }

    #[test]
    fn stream_event_thinking_delta() {
        let e = StreamEvent::ThinkingDelta {
            delta: "hmm".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "thinking_delta");
    }

    #[test]
    fn stream_event_toolcall_start() {
        let e = StreamEvent::ToolCallStart {
            tool_call_id: "tc-1".into(),
            name: "bash".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "toolcall_start");
        assert_eq!(json["toolCallId"], "tc-1");
        assert_eq!(json["name"], "bash");
    }

    #[test]
    fn stream_event_toolcall_delta() {
        let e = StreamEvent::ToolCallDelta {
            tool_call_id: "tc-1".into(),
            arguments_delta: r#"{"comm"#.into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["argumentsDelta"], r#"{"comm"#);
    }

    #[test]
    fn stream_event_done() {
        let msg = AssistantMessage {
            content: vec![crate::content::AssistantContent::text("response")],
            token_usage: None,
        };
        let e = StreamEvent::Done {
            message: msg,
            stop_reason: "end_turn".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "done");
        assert_eq!(json["stopReason"], "end_turn");
    }

    #[test]
    fn stream_event_error() {
        let e = StreamEvent::Error {
            error: "connection reset".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "error");
    }

    #[test]
    fn stream_event_retry() {
        let e = StreamEvent::Retry {
            attempt: 2,
            max_retries: 5,
            delay_ms: 2000,
            error: RetryErrorInfo {
                category: "rate_limit".into(),
                message: "too many requests".into(),
                is_retryable: true,
            },
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "retry");
        assert_eq!(json["attempt"], 2);
        assert_eq!(json["maxRetries"], 5);
    }

    #[test]
    fn stream_event_safety_block() {
        let e = StreamEvent::SafetyBlock {
            blocked_categories: vec!["HARM_CATEGORY_DANGEROUS".into()],
            error: "blocked by safety filter".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "safety_block");
    }

    #[test]
    fn stream_event_all_variants_serialize() {
        let events: Vec<StreamEvent> = vec![
            StreamEvent::Start,
            StreamEvent::TextStart,
            StreamEvent::TextDelta { delta: "d".into() },
            StreamEvent::TextEnd {
                text: "t".into(),
                signature: None,
            },
            StreamEvent::ThinkingStart,
            StreamEvent::ThinkingDelta { delta: "d".into() },
            StreamEvent::ThinkingEnd {
                thinking: "t".into(),
                signature: None,
            },
            StreamEvent::ToolCallStart {
                tool_call_id: "id".into(),
                name: "n".into(),
            },
            StreamEvent::ToolCallDelta {
                tool_call_id: "id".into(),
                arguments_delta: "d".into(),
            },
            StreamEvent::ToolCallEnd {
                tool_call: ToolCall::default(),
            },
            StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![],
                    token_usage: None,
                },
                stop_reason: "end_turn".into(),
            },
            StreamEvent::Error {
                error: "e".into(),
            },
            StreamEvent::Retry {
                attempt: 1,
                max_retries: 3,
                delay_ms: 1000,
                error: RetryErrorInfo {
                    category: "c".into(),
                    message: "m".into(),
                    is_retryable: true,
                },
            },
            StreamEvent::SafetyBlock {
                blocked_categories: vec![],
                error: "e".into(),
            },
        ];
        for event in &events {
            let json = serde_json::to_value(event).unwrap();
            assert!(json.get("type").is_some());
        }
        assert_eq!(events.len(), 14);
    }

    // -- TronEvent --

    #[test]
    fn tron_event_agent_start() {
        let e = agent_start_event("sess-1");
        assert_eq!(e.session_id(), "sess-1");
        assert_eq!(e.event_type(), "agent_start");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "agent_start");
        assert_eq!(json["sessionId"], "sess-1");
    }

    #[test]
    fn tron_event_agent_end() {
        let e = agent_end_event("sess-1");
        assert_eq!(e.event_type(), "agent_end");
    }

    #[test]
    fn tron_event_agent_ready() {
        let e = agent_ready_event("sess-1");
        assert_eq!(e.event_type(), "agent_ready");
    }

    #[test]
    fn tron_event_turn_start() {
        let e = TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 3,
        };
        assert_eq!(e.event_type(), "turn_start");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["turn"], 3);
    }

    #[test]
    fn tron_event_turn_end_with_token_usage() {
        let e = TronEvent::TurnEnd {
            base: BaseEvent::now("s1"),
            turn: 1,
            duration: 5000,
            token_usage: Some(TurnTokenUsage {
                input_tokens: 100,
                output_tokens: 50,
                cache_read_tokens: Some(20),
                cache_creation_tokens: None,
            }),
            token_record: None,
            cost: Some(0.005),
            context_limit: Some(200_000),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["tokenUsage"]["inputTokens"], 100);
        assert_eq!(json["tokenUsage"]["cacheReadTokens"], 20);
        assert!(json["tokenUsage"].get("cacheCreationTokens").is_none());
        assert_eq!(json["cost"], 0.005);
        assert_eq!(json["contextLimit"], 200_000);
    }

    #[test]
    fn tron_event_turn_failed() {
        let e = TronEvent::TurnFailed {
            base: BaseEvent::now("s1"),
            turn: 2,
            error: "rate limit".into(),
            code: Some("PRATE".into()),
            category: Some("rate_limit".into()),
            recoverable: true,
            partial_content: None,
        };
        assert_eq!(e.event_type(), "agent.turn_failed");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "agent.turn_failed");
        assert!(json["recoverable"].as_bool().unwrap());
    }

    #[test]
    fn tron_event_tool_execution_start() {
        let e = TronEvent::ToolExecutionStart {
            base: BaseEvent::now("s1"),
            tool_call_id: "tc-1".into(),
            tool_name: "bash".into(),
            arguments: None,
        };
        assert!(e.is_tool_execution());
    }

    #[test]
    fn tron_event_compaction_complete() {
        let e = TronEvent::CompactionComplete {
            base: BaseEvent::now("s1"),
            success: true,
            tokens_before: 100_000,
            tokens_after: 30_000,
            compression_ratio: 0.3,
            reason: Some(CompactionReason::ThresholdExceeded),
            summary: Some("Summarized 50 messages".into()),
            estimated_context_tokens: Some(45_000),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["tokensBefore"], 100_000);
        assert_eq!(json["tokensAfter"], 30_000);
        assert_eq!(json["compressionRatio"], 0.3);
        assert_eq!(json["reason"], "threshold_exceeded");
    }

    #[test]
    fn tron_event_hook_completed() {
        let e = TronEvent::HookCompleted {
            base: BaseEvent::now("s1"),
            hook_names: vec!["pre-tool-use".into()],
            hook_event: "PreToolUse".into(),
            result: HookResult::Block,
            duration: Some(150),
            reason: Some("Dangerous command detected".into()),
            tool_name: Some("bash".into()),
            tool_call_id: Some("tc-1".into()),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["result"], "block");
        assert_eq!(json["reason"], "Dangerous command detected");
    }

    #[test]
    fn tron_event_api_retry() {
        let e = TronEvent::ApiRetry {
            base: BaseEvent::now("s1"),
            attempt: 2,
            max_retries: 5,
            delay_ms: 4000,
            error_category: "rate_limit".into(),
            error_message: "429 Too Many Requests".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "api_retry");
        assert_eq!(json["attempt"], 2);
    }

    #[test]
    fn is_stream_event_type_positive() {
        assert!(is_stream_event_type("start"));
        assert!(is_stream_event_type("text_delta"));
        assert!(is_stream_event_type("done"));
        assert!(is_stream_event_type("safety_block"));
    }

    #[test]
    fn is_stream_event_type_negative() {
        assert!(!is_stream_event_type("agent_start"));
        assert!(!is_stream_event_type("turn_end"));
        assert!(!is_stream_event_type("unknown"));
    }

    #[test]
    fn base_event_now_has_timestamp() {
        let base = BaseEvent::now("s1");
        assert_eq!(base.session_id, "s1");
        assert!(!base.timestamp.is_empty());
    }

    #[test]
    fn tron_event_all_event_types() {
        // Verify every variant has a distinct event_type
        let base = BaseEvent::now("s1");
        let events: Vec<TronEvent> = vec![
            TronEvent::AgentStart {
                base: base.clone(),
            },
            TronEvent::AgentEnd {
                base: base.clone(),
                error: None,
            },
            TronEvent::AgentReady {
                base: base.clone(),
            },
            TronEvent::AgentInterrupted {
                base: base.clone(),
                turn: 1,
                partial_content: None,
                active_tool: None,
            },
            TronEvent::TurnStart {
                base: base.clone(),
                turn: 1,
            },
            TronEvent::TurnEnd {
                base: base.clone(),
                turn: 1,
                duration: 0,
                token_usage: None,
                token_record: None,
                cost: None,
                context_limit: None,
            },
            TronEvent::TurnFailed {
                base: base.clone(),
                turn: 1,
                error: "e".into(),
                code: None,
                category: None,
                recoverable: false,
                partial_content: None,
            },
            TronEvent::ResponseComplete {
                base: base.clone(),
                turn: 1,
                stop_reason: "end_turn".into(),
                token_usage: None,
                has_tool_calls: false,
                tool_call_count: 0,
            },
            TronEvent::MessageUpdate {
                base: base.clone(),
                content: "c".into(),
            },
            TronEvent::ToolUseBatch {
                base: base.clone(),
                tool_calls: vec![],
            },
            TronEvent::ToolExecutionStart {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: "n".into(),
                arguments: None,
            },
            TronEvent::ToolExecutionUpdate {
                base: base.clone(),
                tool_call_id: "id".into(),
                update: "u".into(),
            },
            TronEvent::ToolExecutionEnd {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: "n".into(),
                duration: 0,
                is_error: None,
                result: None,
            },
            TronEvent::ToolCallArgumentDelta {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: None,
                arguments_delta: "d".into(),
            },
            TronEvent::ToolCallGenerating {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: "n".into(),
            },
            TronEvent::HookTriggered {
                base: base.clone(),
                hook_names: vec![],
                hook_event: "e".into(),
                tool_name: None,
                tool_call_id: None,
            },
            TronEvent::HookCompleted {
                base: base.clone(),
                hook_names: vec![],
                hook_event: "e".into(),
                result: HookResult::Continue,
                duration: None,
                reason: None,
                tool_name: None,
                tool_call_id: None,
            },
            TronEvent::HookBackgroundStarted {
                base: base.clone(),
                hook_names: vec![],
                hook_event: "e".into(),
                execution_id: "id".into(),
            },
            TronEvent::HookBackgroundCompleted {
                base: base.clone(),
                hook_names: vec![],
                hook_event: "e".into(),
                execution_id: "id".into(),
                result: BackgroundHookResult::Continue,
                duration: 0,
                error: None,
            },
            TronEvent::SessionSaved {
                base: base.clone(),
                file_path: "p".into(),
            },
            TronEvent::SessionLoaded {
                base: base.clone(),
                file_path: "p".into(),
                message_count: 0,
            },
            TronEvent::ContextWarning {
                base: base.clone(),
                usage_percent: 80.0,
                message: "m".into(),
            },
            TronEvent::CompactionStart {
                base: base.clone(),
                reason: CompactionReason::Manual,
                tokens_before: 0,
            },
            TronEvent::CompactionComplete {
                base: base.clone(),
                success: true,
                tokens_before: 100,
                tokens_after: 50,
                compression_ratio: 0.5,
                reason: None,
                summary: None,
                estimated_context_tokens: None,
            },
            TronEvent::Error {
                base: base.clone(),
                error: "e".into(),
                context: None,
            },
            TronEvent::ApiRetry {
                base: base.clone(),
                attempt: 1,
                max_retries: 3,
                delay_ms: 1000,
                error_category: "c".into(),
                error_message: "m".into(),
            },
            TronEvent::ThinkingStart {
                base: base.clone(),
            },
            TronEvent::ThinkingDelta {
                base: base.clone(),
                delta: "d".into(),
            },
            TronEvent::ThinkingEnd {
                base,
                thinking: "t".into(),
            },
        ];

        // All 29 variants
        assert_eq!(events.len(), 29);

        // All have unique event types (except thinking_start/delta/end which
        // share names with stream events, but that's by design)
        let mut types: Vec<&str> = events.iter().map(TronEvent::event_type).collect();
        types.sort();
        types.dedup();
        assert_eq!(types.len(), 29);
    }
}
