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

use crate::messages::{TokenUsage, ToolCall};
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

// `TurnTokenUsage` and `ResponseTokenUsage` were consolidated into
// `crate::messages::TokenUsage` — all extra fields are `Option` with
// `skip_serializing_if`, so the wire format is identical when unset.

/// Backward-compatible alias for turn-end events.
pub type TurnTokenUsage = crate::messages::TokenUsage;
/// Backward-compatible alias for response-complete events.
pub type ResponseTokenUsage = crate::messages::TokenUsage;

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

// ─────────────────────────────────────────────────────────────────────────────
// tron_events! macro — generates TronEvent enum, base(), event_type()
// ─────────────────────────────────────────────────────────────────────────────

/// Declarative macro that generates [`TronEvent`], its `base()` and
/// `event_type()` accessors, and a compile-time `VARIANT_COUNT`.
///
/// Adding a new variant requires ONE edit (inside this invocation).
/// The compiler enforces exhaustive matching everywhere else.
macro_rules! tron_events {
    ($(
        $(#[doc = $doc:literal])*
        $variant:ident {
            $(
                $(#[$fmeta:meta])*
                $field:ident : $ty:ty
            ),*
            $(,)?
        } => $rename:literal
    ),* $(,)?) => {
        /// High-level agent event with session context.
        ///
        /// These events are broadcast over WebSocket and may be persisted as
        /// session events. iOS relies on exact type strings and field names.
        #[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
        #[serde(tag = "type")]
        #[allow(missing_docs)]
        pub enum TronEvent {
            $(
                $(#[doc = $doc])*
                #[serde(rename = $rename)]
                $variant {
                    #[serde(flatten)]
                    base: BaseEvent,
                    $(
                        $(#[$fmeta])*
                        $field: $ty,
                    )*
                },
            )*
        }

        impl TronEvent {
            /// Get the base event fields.
            #[must_use]
            pub fn base(&self) -> &BaseEvent {
                match self {
                    $(Self::$variant { base, .. } => base,)*
                }
            }

            /// Get the event type string (for type discrimination).
            #[must_use]
            pub fn event_type(&self) -> &str {
                match self {
                    $(Self::$variant { .. } => $rename,)*
                }
            }
        }

        /// Number of `TronEvent` variants (compile-time constant for tests).
        #[cfg(test)]
        pub(crate) const VARIANT_COUNT: usize = [$($rename),*].len();
    };
}

tron_events! {
    // -- Agent lifecycle --

    /// Agent started processing.
    AgentStart {} => "agent_start",

    /// Agent finished processing.
    AgentEnd {
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    } => "agent_end",

    /// Agent ready (post-processing complete, safe to send next message).
    AgentReady {} => "agent_ready",

    /// Agent interrupted by user.
    AgentInterrupted {
        turn: u32,
        #[serde(rename = "partialContent", skip_serializing_if = "Option::is_none")]
        partial_content: Option<String>,
        #[serde(rename = "activeTool", skip_serializing_if = "Option::is_none")]
        active_tool: Option<String>,
    } => "agent_interrupted",

    // -- Turn lifecycle --

    /// Turn started.
    TurnStart {
        turn: u32,
    } => "turn_start",

    /// Turn completed.
    TurnEnd {
        turn: u32,
        duration: u64,
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<TurnTokenUsage>,
        #[serde(rename = "tokenRecord", skip_serializing_if = "Option::is_none")]
        token_record: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cost: Option<f64>,
        #[serde(rename = "stopReason", skip_serializing_if = "Option::is_none")]
        stop_reason: Option<String>,
        #[serde(rename = "contextLimit", skip_serializing_if = "Option::is_none")]
        context_limit: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    } => "turn_end",

    /// Turn failed.
    TurnFailed {
        turn: u32,
        error: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        category: Option<String>,
        recoverable: bool,
        #[serde(rename = "partialContent", skip_serializing_if = "Option::is_none")]
        partial_content: Option<String>,
    } => "agent.turn_failed",

    /// LLM response finished streaming (before tool execution).
    ResponseComplete {
        turn: u32,
        #[serde(rename = "stopReason")]
        stop_reason: String,
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<ResponseTokenUsage>,
        #[serde(rename = "hasToolCalls")]
        has_tool_calls: bool,
        #[serde(rename = "toolCallCount")]
        tool_call_count: u32,
        #[serde(rename = "tokenRecord", skip_serializing_if = "Option::is_none")]
        token_record: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    } => "response_complete",

    // -- Message --

    /// Message content update.
    MessageUpdate {
        content: String,
    } => "message_update",

    // -- Tool execution --

    /// All tool calls from the model's response (before execution).
    ToolUseBatch {
        #[serde(rename = "toolCalls")]
        tool_calls: Vec<ToolCallSummary>,
    } => "tool_use_batch",

    /// Tool execution started.
    ToolExecutionStart {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName")]
        tool_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        arguments: Option<serde_json::Map<String, Value>>,
    } => "tool_execution_start",

    /// Tool execution progress update.
    ToolExecutionUpdate {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        update: String,
    } => "tool_execution_update",

    /// Tool execution completed.
    ToolExecutionEnd {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName")]
        tool_name: String,
        duration: u64,
        #[serde(rename = "isError", skip_serializing_if = "Option::is_none")]
        is_error: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<TronToolResult>,
    } => "tool_execution_end",

    /// Tool call argument delta (during streaming).
    ToolCallArgumentDelta {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        #[serde(rename = "argumentsDelta")]
        arguments_delta: String,
    } => "toolcall_delta",

    /// Tool call generating (before arguments streamed).
    ToolCallGenerating {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName")]
        tool_name: String,
    } => "toolcall_generating",

    // -- Hooks --

    /// Hook execution triggered.
    HookTriggered {
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        #[serde(rename = "hookEvent")]
        hook_event: String,
        #[serde(rename = "toolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        #[serde(rename = "toolCallId", skip_serializing_if = "Option::is_none")]
        tool_call_id: Option<String>,
    } => "hook_triggered",

    /// Hook execution completed.
    HookCompleted {
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        #[serde(rename = "hookEvent")]
        hook_event: String,
        result: HookResult,
        #[serde(skip_serializing_if = "Option::is_none")]
        duration: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(rename = "toolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        #[serde(rename = "toolCallId", skip_serializing_if = "Option::is_none")]
        tool_call_id: Option<String>,
    } => "hook_completed",

    /// Background hook execution started.
    HookBackgroundStarted {
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        #[serde(rename = "hookEvent")]
        hook_event: String,
        #[serde(rename = "executionId")]
        execution_id: String,
    } => "hook.background_started",

    /// Background hook execution completed.
    HookBackgroundCompleted {
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        #[serde(rename = "hookEvent")]
        hook_event: String,
        #[serde(rename = "executionId")]
        execution_id: String,
        result: BackgroundHookResult,
        duration: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    } => "hook.background_completed",

    // -- Session --

    /// Session saved.
    SessionSaved {
        #[serde(rename = "filePath")]
        file_path: String,
    } => "session_saved",

    /// Session loaded.
    SessionLoaded {
        #[serde(rename = "filePath")]
        file_path: String,
        #[serde(rename = "messageCount")]
        message_count: u32,
    } => "session_loaded",

    // -- Context --

    /// Context window warning.
    ContextWarning {
        #[serde(rename = "usagePercent")]
        usage_percent: f64,
        message: String,
    } => "context_warning",

    // -- Compaction --

    /// Compaction started.
    CompactionStart {
        reason: CompactionReason,
        #[serde(rename = "tokensBefore")]
        tokens_before: u64,
    } => "compaction_start",

    /// Compaction completed.
    CompactionComplete {
        success: bool,
        #[serde(rename = "tokensBefore")]
        tokens_before: u64,
        #[serde(rename = "tokensAfter")]
        tokens_after: u64,
        #[serde(rename = "compressionRatio")]
        compression_ratio: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<CompactionReason>,
        #[serde(skip_serializing_if = "Option::is_none")]
        summary: Option<String>,
        #[serde(rename = "estimatedContextTokens", skip_serializing_if = "Option::is_none")]
        estimated_context_tokens: Option<u64>,
    } => "compaction_complete",

    // -- Error / Retry --

    /// Error event.
    Error {
        error: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        context: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        provider: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        category: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        suggestion: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        retryable: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        status_code: Option<u16>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error_type: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    } => "error",

    /// API retry event.
    ApiRetry {
        attempt: u32,
        #[serde(rename = "maxRetries")]
        max_retries: u32,
        #[serde(rename = "delayMs")]
        delay_ms: u64,
        #[serde(rename = "errorCategory")]
        error_category: String,
        #[serde(rename = "errorMessage")]
        error_message: String,
    } => "api_retry",

    // -- Thinking (agent-level with session context) --

    /// Thinking started.
    ThinkingStart {} => "thinking_start",

    /// Thinking delta.
    ThinkingDelta {
        delta: String,
    } => "thinking_delta",

    /// Thinking ended.
    ThinkingEnd {
        thinking: String,
    } => "thinking_end",

    // -- Session lifecycle --

    /// Session created.
    SessionCreated {
        model: String,
        #[serde(rename = "workingDirectory")]
        working_directory: String,
    } => "session_created",

    /// Session archived.
    SessionArchived {} => "session_archived",

    /// Session unarchived.
    SessionUnarchived {} => "session_unarchived",

    /// Session forked.
    SessionForked {
        #[serde(rename = "newSessionId")]
        new_session_id: String,
    } => "session_forked",

    /// Session deleted.
    SessionDeleted {} => "session_deleted",

    /// Session metadata updated (live sync to iOS).
    SessionUpdated {
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        model: String,
        #[serde(rename = "messageCount")]
        message_count: i64,
        #[serde(rename = "inputTokens")]
        input_tokens: i64,
        #[serde(rename = "outputTokens")]
        output_tokens: i64,
        #[serde(rename = "lastTurnInputTokens")]
        last_turn_input_tokens: i64,
        #[serde(rename = "cacheReadTokens")]
        cache_read_tokens: i64,
        #[serde(rename = "cacheCreationTokens")]
        cache_creation_tokens: i64,
        cost: f64,
        #[serde(rename = "lastActivity")]
        last_activity: String,
        #[serde(rename = "isActive")]
        is_active: bool,
        #[serde(rename = "lastUserPrompt", skip_serializing_if = "Option::is_none")]
        last_user_prompt: Option<String>,
        #[serde(rename = "lastAssistantResponse", skip_serializing_if = "Option::is_none")]
        last_assistant_response: Option<String>,
        #[serde(rename = "parentSessionId", skip_serializing_if = "Option::is_none")]
        parent_session_id: Option<String>,
    } => "session_updated",

    /// Memory updating (shows spinner in iOS).
    MemoryUpdating {} => "memory_updating",

    /// Memory updated.
    MemoryUpdated {
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(rename = "entryType", skip_serializing_if = "Option::is_none")]
        entry_type: Option<String>,
        #[serde(rename = "eventId", skip_serializing_if = "Option::is_none")]
        event_id: Option<String>,
    } => "memory_updated",

    /// Context cleared.
    ContextCleared {
        #[serde(rename = "tokensBefore")]
        tokens_before: i64,
        #[serde(rename = "tokensAfter")]
        tokens_after: i64,
    } => "context_cleared",

    /// Message deleted.
    MessageDeleted {
        #[serde(rename = "targetEventId")]
        target_event_id: String,
        #[serde(rename = "targetType")]
        target_type: String,
        #[serde(rename = "targetTurn", skip_serializing_if = "Option::is_none")]
        target_turn: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    } => "message_deleted",

    /// Rules loaded (workspace rules loaded into context).
    RulesLoaded {
        #[serde(rename = "totalFiles")]
        total_files: u32,
        #[serde(rename = "dynamicRulesCount")]
        dynamic_rules_count: u32,
    } => "rules_loaded",

    /// Scoped rules activated by file path touches.
    RulesActivated {
        rules: Vec<ActivatedRuleInfo>,
        #[serde(rename = "totalActivated")]
        total_activated: u32,
    } => "rules_activated",

    /// Memory loaded (memory context loaded).
    MemoryLoaded {
        count: u32,
    } => "memory_loaded",

    /// Skill removed.
    SkillRemoved {
        #[serde(rename = "skillName")]
        skill_name: String,
    } => "skill_removed",

    // -- Subagents --

    /// Subagent spawned.
    SubagentSpawned {
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        task: String,
        model: String,
        #[serde(rename = "maxTurns")]
        max_turns: u32,
        #[serde(rename = "spawnDepth")]
        spawn_depth: u32,
        #[serde(rename = "toolCallId", skip_serializing_if = "Option::is_none")]
        tool_call_id: Option<String>,
        blocking: bool,
        #[serde(rename = "workingDirectory", skip_serializing_if = "Option::is_none")]
        working_directory: Option<String>,
    } => "subagent_spawned",

    /// Subagent status update (forwarded child events).
    SubagentStatusUpdate {
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        status: String,
        #[serde(rename = "currentTurn")]
        current_turn: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        activity: Option<String>,
    } => "subagent_status_update",

    /// Subagent completed.
    SubagentCompleted {
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        #[serde(rename = "totalTurns")]
        total_turns: u32,
        duration: u64,
        #[serde(rename = "fullOutput", skip_serializing_if = "Option::is_none")]
        full_output: Option<String>,
        #[serde(rename = "resultSummary", skip_serializing_if = "Option::is_none")]
        result_summary: Option<String>,
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    } => "subagent_completed",

    /// Subagent failed.
    SubagentFailed {
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        error: String,
        duration: u64,
    } => "subagent_failed",

    /// Forwarded child event (streaming content for iOS detail sheet).
    SubagentEvent {
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        event: Value,
    } => "subagent_event",

    /// Non-blocking subagent result available (WebSocket notification).
    SubagentResultAvailable {
        #[serde(rename = "parentSessionId")]
        parent_session_id: String,
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        task: String,
        #[serde(rename = "resultSummary")]
        result_summary: String,
        success: bool,
        #[serde(rename = "totalTurns")]
        total_turns: u32,
        duration: u64,
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(rename = "completedAt")]
        completed_at: String,
    } => "subagent_result_available",
}

impl TronEvent {
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
            StreamEvent::Error { error: "e".into() },
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
                ..TurnTokenUsage::default()
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
            TronEvent::AgentStart { base: base.clone() },
            TronEvent::AgentEnd {
                base: base.clone(),
                error: None,
            },
            TronEvent::AgentReady { base: base.clone() },
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
            TronEvent::ThinkingStart { base: base.clone() },
            TronEvent::ThinkingDelta {
                base: base.clone(),
                delta: "d".into(),
            },
            TronEvent::ThinkingEnd {
                base: base.clone(),
                thinking: "t".into(),
            },
            TronEvent::SessionCreated {
                base: base.clone(),
                model: "m".into(),
                working_directory: "/tmp".into(),
            },
            TronEvent::SessionArchived { base: base.clone() },
            TronEvent::SessionUnarchived { base: base.clone() },
            TronEvent::SessionForked {
                base: base.clone(),
                new_session_id: "new-s1".into(),
            },
            TronEvent::SessionDeleted { base: base.clone() },
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
            TronEvent::MemoryUpdating { base: base.clone() },
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

        assert_eq!(events.len(), VARIANT_COUNT);

        let mut types: Vec<&str> = events.iter().map(TronEvent::event_type).collect();
        types.sort();
        types.dedup();
        assert_eq!(types.len(), VARIANT_COUNT);
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
        let e = TronEvent::MemoryUpdating {
            base: BaseEvent::now("s1"),
        };
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
