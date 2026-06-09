//! Generated `TronEvent` catalog and accessors.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::super::{CapabilityEventIdentity, CapabilityInvocationSummary};
use super::{BaseEvent, CompactionReason};
use crate::shared::protocol::messages::TokenUsage;
use crate::shared::protocol::model_capabilities::CapabilityResult;

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
        /// These events are published through engine streams and may be persisted as
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

            /// Get a mutable reference to the base event fields.
            pub fn base_mut(&mut self) -> &mut BaseEvent {
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

            /// Assign a sequence number to this event.
            pub fn set_sequence(&mut self, seq: i64) {
                self.base_mut().sequence = Some(seq);
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

    /// Agent ready after the terminal event has been published.
    AgentReady {} => "agent_ready",

    /// Session processing state changed (global broadcast for session activity).
    SessionProcessingChanged {
        #[serde(rename = "isProcessing")]
        is_processing: bool,
    } => "session_processing_changed",

    /// Agent interrupted by user.
    AgentInterrupted {
        turn: u32,
        #[serde(rename = "partialContent", skip_serializing_if = "Option::is_none")]
        partial_content: Option<String>,
        #[serde(rename = "activeCapability", skip_serializing_if = "Option::is_none")]
        active_capability: Option<String>,
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
        token_usage: Option<TokenUsage>,
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
        #[serde(skip_serializing_if = "Option::is_none")]
        retryable: Option<bool>,
        recoverable: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        origin: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        details: Option<Value>,
        #[serde(rename = "partialContent", skip_serializing_if = "Option::is_none")]
        partial_content: Option<String>,
    } => "agent.turn_failed",

    /// LLM response finished streaming (before capability invocation).
    ResponseComplete {
        turn: u32,
        #[serde(rename = "stopReason")]
        stop_reason: String,
        #[serde(rename = "tokenUsage", skip_serializing_if = "Option::is_none")]
        token_usage: Option<TokenUsage>,
        #[serde(rename = "hasCapabilityInvocations")]
        has_capability_invocations: bool,
        #[serde(rename = "capabilityInvocationCount")]
        capability_invocation_count: u32,
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

    // -- Capability invocation --

    /// All capability invocations from the model's response (before execution).
    CapabilityInvocationBatch {
        #[serde(rename = "capabilityInvocations")]
        capability_invocations: Vec<CapabilityInvocationSummary>,
    } => "capability.invocation.batch",

    /// Capability invocation started.
    CapabilityInvocationStarted {
        #[serde(rename = "invocationId")]
        invocation_id: String,
        #[serde(rename = "modelPrimitiveName")]
        model_primitive_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        arguments: Option<serde_json::Map<String, Value>>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.invocation.started",

    /// Capability invocation progress update.
    CapabilityInvocationOutput {
        #[serde(rename = "invocationId")]
        invocation_id: String,
        update: String,
    } => "capability.invocation.output",

    /// Long-running capability progress heartbeat.
    ///
    /// Carries an optional human-readable status message (shown as chip
    /// subtitle) and an optional 0.0–1.0 completion fraction.
    CapabilityInvocationProgress {
        #[serde(rename = "invocationId")]
        invocation_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        percent: Option<f64>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.invocation.progress",

    /// Capability async run status update.
    CapabilityRunStatus {
        #[serde(rename = "runId")]
        run_id: String,
        #[serde(rename = "invocationId")]
        invocation_id: String,
        status: String,
        #[serde(rename = "streamTopic", skip_serializing_if = "Option::is_none")]
        stream_topic: Option<String>,
        #[serde(rename = "childInvocations")]
        child_invocations: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        details: Option<Value>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.run.status",

    /// Capability invocation completed.
    CapabilityInvocationCompleted {
        #[serde(rename = "invocationId")]
        invocation_id: String,
        #[serde(rename = "modelPrimitiveName")]
        model_primitive_name: String,
        duration: u64,
        #[serde(rename = "isError", skip_serializing_if = "Option::is_none")]
        is_error: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<CapabilityResult>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.invocation.completed",

    /// Capability invocation argument delta (during streaming).
    CapabilityInvocationArgumentDelta {
        #[serde(rename = "invocationId")]
        invocation_id: String,
        #[serde(rename = "modelPrimitiveName", skip_serializing_if = "Option::is_none")]
        model_primitive_name: Option<String>,
        #[serde(rename = "argumentsDelta")]
        arguments_delta: String,
    } => "capability.invocation.arguments_delta",

    /// Capability invocation generating (before arguments streamed).
    CapabilityInvocationGenerating {
        #[serde(rename = "invocationId")]
        invocation_id: String,
        #[serde(rename = "modelPrimitiveName")]
        model_primitive_name: String,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.invocation.generating",

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
        #[serde(rename = "preservedTurns", skip_serializing_if = "Option::is_none")]
        preserved_turns: Option<usize>,
        #[serde(rename = "summarizedTurns", skip_serializing_if = "Option::is_none")]
        summarized_turns: Option<usize>,
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
        recoverable: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        origin: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        details: Option<Value>,
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
        /// Session title (e.g. "Chat" for persistent chat sessions).
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
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
    ///
    /// All stats/model fields are optional so partial updates do not zero out
    /// real session data on the client.
    SessionUpdated {
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(rename = "eventCount", skip_serializing_if = "Option::is_none")]
        event_count: Option<i64>,
        #[serde(rename = "turnCount", skip_serializing_if = "Option::is_none")]
        turn_count: Option<i64>,
        #[serde(rename = "messageCount", skip_serializing_if = "Option::is_none")]
        message_count: Option<i64>,
        #[serde(rename = "inputTokens", skip_serializing_if = "Option::is_none")]
        input_tokens: Option<i64>,
        #[serde(rename = "outputTokens", skip_serializing_if = "Option::is_none")]
        output_tokens: Option<i64>,
        #[serde(rename = "lastTurnInputTokens", skip_serializing_if = "Option::is_none")]
        last_turn_input_tokens: Option<i64>,
        #[serde(rename = "cacheReadTokens", skip_serializing_if = "Option::is_none")]
        cache_read_tokens: Option<i64>,
        #[serde(rename = "cacheCreationTokens", skip_serializing_if = "Option::is_none")]
        cache_creation_tokens: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cost: Option<f64>,
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
        #[serde(rename = "activityLines", skip_serializing_if = "Option::is_none")]
        activity_lines: Option<Vec<crate::domains::session::event_store::ActivitySummaryLine>>,
    } => "session_updated",

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

    /// Get the sequence number, if assigned.
    #[must_use]
    pub fn sequence(&self) -> Option<i64> {
        self.base().sequence
    }

    /// Get the engine trace id, if this event was emitted under one.
    #[must_use]
    pub fn trace_id(&self) -> Option<&str> {
        self.base().trace_id.as_deref()
    }

    /// Get the parent engine invocation id, if this event was emitted under one.
    #[must_use]
    pub fn parent_invocation_id(&self) -> Option<&str> {
        self.base().parent_invocation_id.as_deref()
    }

    /// Whether this is a capability invocation event.
    #[must_use]
    pub fn is_capability_invocation(&self) -> bool {
        matches!(
            self,
            Self::CapabilityInvocationStarted { .. }
                | Self::CapabilityInvocationOutput { .. }
                | Self::CapabilityInvocationProgress { .. }
                | Self::CapabilityRunStatus { .. }
                | Self::CapabilityInvocationCompleted { .. }
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
