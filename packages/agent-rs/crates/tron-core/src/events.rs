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

/// Info about a dynamically activated scoped rule.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivatedRuleInfo {
    /// Path relative to project root (e.g., `src/context/.claude/CLAUDE.md`).
    pub relative_path: String,
    /// Directory this rule applies to (e.g., `src/context`).
    pub scope_dir: String,
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
        /// LLM stop reason (e.g., `end_turn`, `tool_use`).
        #[serde(rename = "stopReason", skip_serializing_if = "Option::is_none")]
        stop_reason: Option<String>,
        /// Context window limit (for iOS sync after model switch).
        #[serde(rename = "contextLimit", skip_serializing_if = "Option::is_none")]
        context_limit: Option<u64>,
        /// Model used for this turn.
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
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
        /// Canonical token record (iOS attaches stats from this).
        #[serde(rename = "tokenRecord", skip_serializing_if = "Option::is_none")]
        token_record: Option<Value>,
        /// Model used for this response.
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
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
        /// Error code (e.g. `overloaded_error`).
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        /// Provider that produced the error.
        #[serde(skip_serializing_if = "Option::is_none")]
        provider: Option<String>,
        /// Error category (e.g. `rate_limit`, `auth`, `network`).
        #[serde(skip_serializing_if = "Option::is_none")]
        category: Option<String>,
        /// Suggested user action.
        #[serde(skip_serializing_if = "Option::is_none")]
        suggestion: Option<String>,
        /// Whether the error is retryable.
        #[serde(skip_serializing_if = "Option::is_none")]
        retryable: Option<bool>,
        /// HTTP status code.
        #[serde(skip_serializing_if = "Option::is_none")]
        status_code: Option<u16>,
        /// Error type classification.
        #[serde(skip_serializing_if = "Option::is_none")]
        error_type: Option<String>,
        /// Model in use when error occurred.
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
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

    // -- Session lifecycle --

    /// Session created.
    #[serde(rename = "session_created")]
    SessionCreated {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Model used for the session.
        model: String,
        /// Working directory for the session.
        #[serde(rename = "workingDirectory")]
        working_directory: String,
    },

    /// Session archived.
    #[serde(rename = "session_archived")]
    SessionArchived {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
    },

    /// Session unarchived.
    #[serde(rename = "session_unarchived")]
    SessionUnarchived {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
    },

    /// Session forked.
    #[serde(rename = "session_forked")]
    SessionForked {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// The new session ID.
        #[serde(rename = "newSessionId")]
        new_session_id: String,
    },

    /// Session deleted.
    #[serde(rename = "session_deleted")]
    SessionDeleted {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
    },

    /// Session metadata updated (live sync to iOS).
    #[serde(rename = "session_updated")]
    SessionUpdated {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Session title.
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        /// Current model.
        model: String,
        /// Message count.
        #[serde(rename = "messageCount")]
        message_count: i64,
        /// Total input tokens.
        #[serde(rename = "inputTokens")]
        input_tokens: i64,
        /// Total output tokens.
        #[serde(rename = "outputTokens")]
        output_tokens: i64,
        /// Input tokens for last turn.
        #[serde(rename = "lastTurnInputTokens")]
        last_turn_input_tokens: i64,
        /// Cache read tokens.
        #[serde(rename = "cacheReadTokens")]
        cache_read_tokens: i64,
        /// Cache creation tokens.
        #[serde(rename = "cacheCreationTokens")]
        cache_creation_tokens: i64,
        /// Cost in USD.
        cost: f64,
        /// Last activity timestamp.
        #[serde(rename = "lastActivity")]
        last_activity: String,
        /// Whether the session is active.
        #[serde(rename = "isActive")]
        is_active: bool,
        /// Last user prompt preview.
        #[serde(rename = "lastUserPrompt", skip_serializing_if = "Option::is_none")]
        last_user_prompt: Option<String>,
        /// Last assistant response preview.
        #[serde(rename = "lastAssistantResponse", skip_serializing_if = "Option::is_none")]
        last_assistant_response: Option<String>,
        /// Parent session ID (for forked sessions).
        #[serde(rename = "parentSessionId", skip_serializing_if = "Option::is_none")]
        parent_session_id: Option<String>,
    },

    /// Memory updating (shows spinner in iOS).
    #[serde(rename = "memory_updating")]
    MemoryUpdating {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
    },

    /// Memory updated.
    #[serde(rename = "memory_updated")]
    MemoryUpdated {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Memory entry title.
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        /// Memory entry type.
        #[serde(rename = "entryType", skip_serializing_if = "Option::is_none")]
        entry_type: Option<String>,
        /// Event ID of the persisted memory.ledger event (for iOS detail sheet lookup).
        #[serde(rename = "eventId", skip_serializing_if = "Option::is_none")]
        event_id: Option<String>,
    },

    /// Context cleared.
    #[serde(rename = "context_cleared")]
    ContextCleared {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Token count before clearing.
        #[serde(rename = "tokensBefore")]
        tokens_before: i64,
        /// Token count after clearing.
        #[serde(rename = "tokensAfter")]
        tokens_after: i64,
    },

    /// Message deleted.
    #[serde(rename = "message_deleted")]
    MessageDeleted {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// The event ID that was deleted.
        #[serde(rename = "targetEventId")]
        target_event_id: String,
        /// The type of the deleted event.
        #[serde(rename = "targetType")]
        target_type: String,
        /// Turn number of the deleted message.
        #[serde(rename = "targetTurn", skip_serializing_if = "Option::is_none")]
        target_turn: Option<i64>,
        /// Reason for deletion.
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },

    /// Rules loaded (workspace rules loaded into context).
    #[serde(rename = "rules_loaded")]
    RulesLoaded {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Number of rule files loaded.
        #[serde(rename = "totalFiles")]
        total_files: u32,
        /// Number of dynamic rules loaded.
        #[serde(rename = "dynamicRulesCount")]
        dynamic_rules_count: u32,
    },

    /// Scoped rules activated by file path touches.
    #[serde(rename = "rules_activated")]
    RulesActivated {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Newly activated rules.
        rules: Vec<ActivatedRuleInfo>,
        /// Total number of activated scoped rules (cumulative).
        #[serde(rename = "totalActivated")]
        total_activated: u32,
    },

    /// Memory loaded (memory context loaded).
    #[serde(rename = "memory_loaded")]
    MemoryLoaded {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Number of memory entries loaded.
        count: u32,
    },

    /// Skill removed.
    #[serde(rename = "skill_removed")]
    SkillRemoved {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Name of the removed skill.
        #[serde(rename = "skillName")]
        skill_name: String,
    },

    // -- Subagents --

    /// Subagent spawned.
    #[serde(rename = "subagent_spawned")]
    SubagentSpawned {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Child session ID.
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        /// Task description.
        task: String,
        /// Model used.
        model: String,
        /// Maximum turns.
        #[serde(rename = "maxTurns")]
        max_turns: u32,
        /// Nesting depth.
        #[serde(rename = "spawnDepth")]
        spawn_depth: u32,
        /// Tool call ID that triggered the spawn.
        #[serde(rename = "toolCallId", skip_serializing_if = "Option::is_none")]
        tool_call_id: Option<String>,
        /// Whether the subagent blocks the parent.
        blocking: bool,
        /// Working directory for the subagent.
        #[serde(rename = "workingDirectory", skip_serializing_if = "Option::is_none")]
        working_directory: Option<String>,
    },

    /// Subagent status update (forwarded child events).
    #[serde(rename = "subagent_status_update")]
    SubagentStatusUpdate {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Child session ID.
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        /// Current status.
        status: String,
        /// Current turn.
        #[serde(rename = "currentTurn")]
        current_turn: u32,
        /// Activity description.
        #[serde(skip_serializing_if = "Option::is_none")]
        activity: Option<String>,
    },

    /// Subagent completed.
    #[serde(rename = "subagent_completed")]
    SubagentCompleted {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Child session ID.
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        /// Total turns executed.
        #[serde(rename = "totalTurns")]
        total_turns: u32,
        /// Duration in milliseconds.
        duration: u64,
        /// Full output text.
        #[serde(rename = "fullOutput", skip_serializing_if = "Option::is_none")]
        full_output: Option<String>,
        /// Truncated result summary.
        #[serde(rename = "resultSummary", skip_serializing_if = "Option::is_none")]
        result_summary: Option<String>,
        /// Token usage.
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<Value>,
        /// Model used.
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },

    /// Subagent failed.
    #[serde(rename = "subagent_failed")]
    SubagentFailed {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Child session ID.
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        /// Error message.
        error: String,
        /// Duration in milliseconds.
        duration: u64,
    },

    /// Forwarded child event (streaming content for iOS detail sheet).
    #[serde(rename = "subagent_event")]
    SubagentEvent {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Child session ID.
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        /// Mapped child event payload.
        event: Value,
    },

    /// Non-blocking subagent result available (WebSocket notification).
    #[serde(rename = "subagent_result_available")]
    SubagentResultAvailable {
        /// Base fields.
        #[serde(flatten)]
        base: BaseEvent,
        /// Parent session ID.
        #[serde(rename = "parentSessionId")]
        parent_session_id: String,
        /// Child session ID.
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        /// Task description.
        task: String,
        /// Truncated result summary.
        #[serde(rename = "resultSummary")]
        result_summary: String,
        /// Whether the subagent succeeded.
        success: bool,
        /// Total turns executed.
        #[serde(rename = "totalTurns")]
        total_turns: u32,
        /// Duration in milliseconds.
        duration: u64,
        /// Token usage.
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<Value>,
        /// Error message (if failed).
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        /// ISO 8601 completion timestamp.
        #[serde(rename = "completedAt")]
        completed_at: String,
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
            | Self::ThinkingEnd { base, .. }
            | Self::SessionCreated { base, .. }
            | Self::SessionArchived { base, .. }
            | Self::SessionUnarchived { base, .. }
            | Self::SessionForked { base, .. }
            | Self::SessionDeleted { base, .. }
            | Self::SessionUpdated { base, .. }
            | Self::MemoryUpdating { base, .. }
            | Self::MemoryUpdated { base, .. }
            | Self::ContextCleared { base, .. }
            | Self::MessageDeleted { base, .. }
            | Self::RulesLoaded { base, .. }
            | Self::RulesActivated { base, .. }
            | Self::MemoryLoaded { base, .. }
            | Self::SkillRemoved { base, .. }
            | Self::SubagentSpawned { base, .. }
            | Self::SubagentStatusUpdate { base, .. }
            | Self::SubagentCompleted { base, .. }
            | Self::SubagentFailed { base, .. }
            | Self::SubagentEvent { base, .. }
            | Self::SubagentResultAvailable { base, .. } => base,
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
            Self::SessionCreated { .. } => "session_created",
            Self::SessionArchived { .. } => "session_archived",
            Self::SessionUnarchived { .. } => "session_unarchived",
            Self::SessionForked { .. } => "session_forked",
            Self::SessionDeleted { .. } => "session_deleted",
            Self::SessionUpdated { .. } => "session_updated",
            Self::MemoryUpdating { .. } => "memory_updating",
            Self::MemoryUpdated { .. } => "memory_updated",
            Self::ContextCleared { .. } => "context_cleared",
            Self::MessageDeleted { .. } => "message_deleted",
            Self::RulesLoaded { .. } => "rules_loaded",
            Self::RulesActivated { .. } => "rules_activated",
            Self::MemoryLoaded { .. } => "memory_loaded",
            Self::SkillRemoved { .. } => "skill_removed",
            Self::SubagentSpawned { .. } => "subagent_spawned",
            Self::SubagentStatusUpdate { .. } => "subagent_status_update",
            Self::SubagentCompleted { .. } => "subagent_completed",
            Self::SubagentFailed { .. } => "subagent_failed",
            Self::SubagentEvent { .. } => "subagent_event",
            Self::SubagentResultAvailable { .. } => "subagent_result_available",
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
            stop_reason: Some("end_turn".into()),
            context_limit: Some(200_000),
            model: None,
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
                stop_reason: None,
                context_limit: None,
                model: None,
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
                token_record: None,
                model: None,
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
                code: None,
                provider: None,
                category: None,
                suggestion: None,
                retryable: None,
                status_code: None,
                error_type: None,
                model: None,
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
                base: base.clone(),
                thinking: "t".into(),
            },
            TronEvent::SessionUpdated {
                base: base.clone(),
                title: None,
                model: "m".into(),
                message_count: 0,
                input_tokens: 0,
                output_tokens: 0,
                last_turn_input_tokens: 0,
                cache_read_tokens: 0,
                cache_creation_tokens: 0,
                cost: 0.0,
                last_activity: "t".into(),
                is_active: true,
                last_user_prompt: None,
                last_assistant_response: None,
                parent_session_id: None,
            },
            TronEvent::MemoryUpdating {
                base: base.clone(),
            },
            TronEvent::MemoryUpdated {
                base: base.clone(),
                title: None,
                entry_type: None,
                event_id: None,
            },
            TronEvent::ContextCleared {
                base: base.clone(),
                tokens_before: 0,
                tokens_after: 0,
            },
            TronEvent::MessageDeleted {
                base: base.clone(),
                target_event_id: "id".into(),
                target_type: "t".into(),
                target_turn: None,
                reason: None,
            },
            TronEvent::RulesLoaded {
                base: base.clone(),
                total_files: 3,
                dynamic_rules_count: 1,
            },
            TronEvent::RulesActivated {
                base: base.clone(),
                rules: vec![ActivatedRuleInfo {
                    relative_path: "src/.claude/CLAUDE.md".into(),
                    scope_dir: "src".into(),
                }],
                total_activated: 1,
            },
            TronEvent::MemoryLoaded {
                base: base.clone(),
                count: 2,
            },
            TronEvent::SkillRemoved {
                base: base.clone(),
                skill_name: "n".into(),
            },
            TronEvent::SubagentSpawned {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                task: "t".into(),
                model: "m".into(),
                max_turns: 50,
                spawn_depth: 0,
                tool_call_id: None,
                blocking: true,
                working_directory: None,
            },
            TronEvent::SubagentStatusUpdate {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                status: "running".into(),
                current_turn: 1,
                activity: None,
            },
            TronEvent::SubagentCompleted {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                total_turns: 3,
                duration: 5000,
                full_output: None,
                result_summary: None,
                token_usage: None,
                model: None,
            },
            TronEvent::SubagentFailed {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                error: "e".into(),
                duration: 1000,
            },
            TronEvent::SubagentEvent {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                event: json!({"type": "text_delta", "data": {"delta": "hi"}}),
            },
            TronEvent::SubagentResultAvailable {
                base,
                parent_session_id: "p1".into(),
                subagent_session_id: "sub-1".into(),
                task: "t".into(),
                result_summary: "done".into(),
                success: true,
                total_turns: 2,
                duration: 3000,
                token_usage: None,
                error: None,
                completed_at: "2024-01-01T00:00:00Z".into(),
            },
        ];

        // All 44 variants
        assert_eq!(events.len(), 44);

        let mut types: Vec<&str> = events.iter().map(TronEvent::event_type).collect();
        types.sort();
        types.dedup();
        assert_eq!(types.len(), 44);
    }

    #[test]
    fn session_updated_event_type() {
        let e = TronEvent::SessionUpdated {
            base: BaseEvent::now("s1"),
            title: Some("title".into()),
            model: "claude-opus-4-6".into(),
            message_count: 5,
            input_tokens: 100,
            output_tokens: 50,
            last_turn_input_tokens: 20,
            cache_read_tokens: 10,
            cache_creation_tokens: 5,
            cost: 0.01,
            last_activity: "2024-01-01T00:00:00Z".into(),
            is_active: true,
            last_user_prompt: Some("hello".into()),
            last_assistant_response: Some("world".into()),
            parent_session_id: None,
        };
        assert_eq!(e.event_type(), "session_updated");
        assert_eq!(e.session_id(), "s1");
    }

    #[test]
    fn memory_updating_event_type() {
        let e = TronEvent::MemoryUpdating { base: BaseEvent::now("s1") };
        assert_eq!(e.event_type(), "memory_updating");
    }

    #[test]
    fn memory_updated_event_type() {
        let e = TronEvent::MemoryUpdated {
            base: BaseEvent::now("s1"),
            title: Some("entry".into()),
            entry_type: Some("feature".into()),
            event_id: Some("evt_123".into()),
        };
        assert_eq!(e.event_type(), "memory_updated");
    }

    #[test]
    fn context_cleared_event_type() {
        let e = TronEvent::ContextCleared {
            base: BaseEvent::now("s1"),
            tokens_before: 5000,
            tokens_after: 0,
        };
        assert_eq!(e.event_type(), "context_cleared");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["tokensBefore"], 5000);
        assert_eq!(json["tokensAfter"], 0);
    }

    #[test]
    fn message_deleted_event_type() {
        let e = TronEvent::MessageDeleted {
            base: BaseEvent::now("s1"),
            target_event_id: "evt-123".into(),
            target_type: "message.user".into(),
            target_turn: Some(3),
            reason: Some("user request".into()),
        };
        assert_eq!(e.event_type(), "message_deleted");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["targetEventId"], "evt-123");
        assert_eq!(json["targetType"], "message.user");
        assert_eq!(json["targetTurn"], 3);
    }

    #[test]
    fn rules_loaded_event_type() {
        let e = TronEvent::RulesLoaded {
            base: BaseEvent::now("s1"),
            total_files: 3,
            dynamic_rules_count: 1,
        };
        assert_eq!(e.event_type(), "rules_loaded");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["totalFiles"], 3);
        assert_eq!(json["dynamicRulesCount"], 1);
    }

    #[test]
    fn memory_loaded_event_type() {
        let e = TronEvent::MemoryLoaded {
            base: BaseEvent::now("s1"),
            count: 2,
        };
        assert_eq!(e.event_type(), "memory_loaded");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["count"], 2);
    }

    #[test]
    fn skill_removed_event_type() {
        let e = TronEvent::SkillRemoved {
            base: BaseEvent::now("s1"),
            skill_name: "web-search".into(),
        };
        assert_eq!(e.event_type(), "skill_removed");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["skillName"], "web-search");
    }
}
