//! Event types for agent operation.
//!
//! Two event families:
//!
//! - **[`StreamEvent`]**: Low-level LLM streaming events from a provider
//!   (text deltas, thinking deltas, capability invocation construction, done/error).
//! - **[`TronEvent`]**: High-level agent lifecycle events with session context
//!   (agent start/end, turn boundaries, capability invocation, hooks, compaction).
//!
//! `StreamEvent` is purely in-memory (never persisted). `TronEvent` is
//! published through engine streams and may be recorded as session events.
//!
//! ## Size note
//!
//! Two large enums (`StreamEvent` ~30 variants, `TronEvent` ~60 variants)
//! plus their `Display` impls. These are exhaustive event catalogs that
//! benefit from being in one place for grep-ability and match exhaustiveness.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::shared::messages::{TokenUsage, ToolCall};
use crate::shared::tools::CapabilityResult;

/// Capability identity attached to provider protocol tool events.
///
/// `capability.invocation.started` / `capability.invocation.completed` are current capability event labels,
/// but active UI identity must come from these fields. The model-facing name is
/// intentionally separate from the resolved contract/implementation so an
/// `execute` call can render the concrete capability after binding resolution.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityEventIdentity {
    /// Provider-visible primitive name (`search`, `inspect`, or `execute`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_tool_name: Option<String>,
    /// Stable abstract capability contract id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contract_id: Option<String>,
    /// Concrete implementation selected for execution.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub implementation_id: Option<String>,
    /// Engine function id backing the selected implementation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub function_id: Option<String>,
    /// Plugin or domain manifest that owns the implementation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<String>,
    /// Worker that registered the selected function.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    /// Digest of the selected function schema.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema_digest: Option<String>,
    /// Engine catalog revision used for resolution.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog_revision: Option<u64>,
    /// Trust tier assigned by registry/plugin policy.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trust_tier: Option<String>,
    /// Capability risk level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub risk_level: Option<String>,
    /// Capability effect class.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effect_class: Option<String>,
    /// Trace id correlating stream, ledger, and audit records.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Root invocation id for the capability execution tree.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_invocation_id: Option<String>,
    /// Durable binding decision id selected by the registry resolver.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binding_decision_id: Option<String>,
}

impl CapabilityEventIdentity {
    /// Build identity for a model-facing primitive before binding resolution.
    #[must_use]
    pub fn with_model_tool(name: impl Into<String>) -> Self {
        Self {
            model_tool_name: Some(name.into()),
            ..Self::default()
        }
    }

    /// Whether this identity carries no capability metadata.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

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

    /// Capability invocation started.
    #[serde(rename = "toolcall_start")]
    ToolCallStart {
        /// Capability invocation ID.
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        /// Tool name.
        name: String,
    },

    /// Incremental capability invocation argument JSON.
    #[serde(rename = "toolcall_delta")]
    ToolCallDelta {
        /// Capability invocation ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Partial JSON arguments.
        #[serde(rename = "argumentsDelta")]
        arguments_delta: String,
    },

    /// Capability invocation fully constructed.
    #[serde(rename = "toolcall_end")]
    ToolCallEnd {
        /// Complete capability invocation.
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
    /// Monotonic per-session sequence number, assigned at emission time.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sequence: Option<i64>,
    /// Engine trace id for events emitted inside an engine invocation chain.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Parent engine invocation id for events emitted by a child invocation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_invocation_id: Option<String>,
}

impl BaseEvent {
    /// Create a new base event with the current UTC timestamp.
    #[must_use]
    pub fn now(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            sequence: None,
            trace_id: None,
            parent_invocation_id: None,
        }
    }

    /// Attach a sequence number.
    #[must_use]
    pub fn with_sequence(mut self, seq: i64) -> Self {
        self.sequence = Some(seq);
        self
    }

    /// Attach engine trace context.
    #[must_use]
    pub fn with_trace_context(
        mut self,
        trace_id: Option<String>,
        parent_invocation_id: Option<String>,
    ) -> Self {
        self.trace_id = trace_id;
        self.parent_invocation_id = parent_invocation_id;
        self
    }
}

/// Capability invocation summary in a batch event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolCallSummary {
    /// Capability invocation ID.
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
    /// Token threshold exceeded.
    ThresholdExceeded,
    /// Progress signal detected (commit, push, PR, tag).
    ProgressSignal,
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

    /// Agent ready (post-processing complete, safe to send next message).
    AgentReady {} => "agent_ready",

    /// Session processing state changed (global broadcast for dashboard).
    SessionProcessingChanged {
        #[serde(rename = "isProcessing")]
        is_processing: bool,
    } => "session_processing_changed",

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
        recoverable: bool,
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

    // -- Capability invocation --

    /// All capability invocations from the model's response (before execution).
    CapabilityInvocationBatch {
        #[serde(rename = "toolCalls")]
        tool_calls: Vec<ToolCallSummary>,
    } => "capability.invocation.batch",

    /// Capability invocation started.
    CapabilityInvocationStarted {
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        #[serde(rename = "modelToolName")]
        tool_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        arguments: Option<serde_json::Map<String, Value>>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.invocation.started",

    /// Capability invocation progress update.
    CapabilityInvocationOutput {
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        update: String,
    } => "capability.invocation.output",

    /// Long-running capability progress heartbeat.
    ///
    /// Carries an optional human-readable status message (shown as chip
    /// subtitle) and an optional 0.0–1.0 completion fraction.
    CapabilityInvocationProgress {
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        percent: Option<f64>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.invocation.progress",

    /// Capability binding resolution update for an `execute` primitive call.
    CapabilityResolution {
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        #[serde(rename = "modelToolName")]
        model_tool_name: String,
        #[serde(rename = "requestedContractId", skip_serializing_if = "Option::is_none")]
        requested_contract_id: Option<String>,
        #[serde(rename = "requestedImplementationId", skip_serializing_if = "Option::is_none")]
        requested_implementation_id: Option<String>,
        #[serde(rename = "requestedFunctionId", skip_serializing_if = "Option::is_none")]
        requested_function_id: Option<String>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.resolution",

    /// Capability invocation completed.
    CapabilityInvocationCompleted {
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        #[serde(rename = "modelToolName")]
        tool_name: String,
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
        tool_call_id: String,
        #[serde(rename = "modelToolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        #[serde(rename = "argumentsDelta")]
        arguments_delta: String,
    } => "capability.invocation.arguments_delta",

    /// Capability invocation generating (before arguments streamed).
    CapabilityInvocationGenerating {
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        #[serde(rename = "modelToolName")]
        tool_name: String,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.invocation.generating",

    // -- Hooks --

    /// Hook execution triggered.
    HookTriggered {
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        #[serde(rename = "hookEvent")]
        hook_event: String,
        #[serde(rename = "modelToolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        #[serde(rename = "invocationId", skip_serializing_if = "Option::is_none")]
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
        #[serde(rename = "modelToolName", skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        #[serde(rename = "invocationId", skip_serializing_if = "Option::is_none")]
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

    /// LLM-based hook result (prompt hook completed asynchronously).
    LlmHookResult {
        #[serde(rename = "hookName")]
        hook_name: String,
        #[serde(rename = "hookId")]
        hook_id: String,
        #[serde(rename = "hookEvent")]
        hook_event: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        output: Option<String>,
        #[serde(rename = "durationMs")]
        duration_ms: u64,
        model: String,
        #[serde(rename = "inputTokens")]
        input_tokens: u64,
        #[serde(rename = "outputTokens")]
        output_tokens: u64,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        /// Structured suggestions parsed from suggest-prompts hook output.
        #[serde(skip_serializing_if = "Option::is_none")]
        suggestions: Option<Vec<String>>,
    } => "hook.llm_result",

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
        /// Session source (e.g. "chat" for persistent chat sessions).
        #[serde(skip_serializing_if = "Option::is_none")]
        source: Option<String>,
        /// Execution profile selected for the session.
        #[serde(skip_serializing_if = "Option::is_none")]
        profile: Option<String>,
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
    /// All stats/model fields are Optional so partial updates (e.g., title-only
    /// from the title-gen hook) don't zero out real session data on the client.
    SessionUpdated {
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
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
        activity_lines: Option<Vec<crate::domains::session::event_store::sqlite::repositories::session::ActivitySummaryLine>>,
    } => "session_updated",

    /// Memory updating (shows spinner in iOS).
    MemoryUpdating {} => "memory_updating",

    /// Memory updated.
    MemoryUpdated {
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        summary: Option<String>,
        #[serde(rename = "entryType", skip_serializing_if = "Option::is_none")]
        entry_type: Option<String>,
        #[serde(rename = "eventId", skip_serializing_if = "Option::is_none")]
        event_id: Option<String>,
    } => "memory_updated",

    /// Auto-retain threshold crossed; retain pipeline is about to start.
    /// Emitted once, immediately before `MemoryUpdating`, so iOS can render
    /// a distinct indicator for automatic retentions.
    MemoryAutoRetainTriggered {
        #[serde(rename = "intervalFired")]
        interval_fired: u32,
    } => "memory_auto_retain_triggered",

    /// Auto-retain pipeline failed (or was orphaned by a server restart).
    /// Paired with a prior `MemoryAutoRetainTriggered` for the same session.
    /// iOS uses this to exit the retain pill's spinner state with an error
    /// label instead of a perpetual "retaining…".
    MemoryAutoRetainFailed {
        #[serde(rename = "intervalFired")]
        interval_fired: u32,
        /// Operator-readable reason (one line). Rendered verbatim.
        reason: String,
    } => "memory_auto_retain_failed",

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

    /// Message queued for later delivery (user sent while agent busy).
    MessageQueued {
        #[serde(rename = "queueId")]
        queue_id: String,
        text: String,
        position: u32,
    } => "message_queued",

    /// Queued message consumed or cancelled.
    MessageDequeued {
        #[serde(rename = "queueId")]
        queue_id: String,
        reason: String,
    } => "message_dequeued",

    /// Queued message sent as a user prompt (auto-drain).
    /// Broadcast so iOS can render the user message bubble in real-time.
    QueuedMessageSent {
        text: String,
        #[serde(rename = "queueId")]
        queue_id: String,
    } => "queued_message_sent",

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

    /// Skill activated in session.
    SkillActivated {
        #[serde(rename = "skillName")]
        skill_name: String,
        source: String,
    } => "skill_activated",

    /// Skill deactivated from session.
    SkillDeactivated {
        #[serde(rename = "skillName")]
        skill_name: String,
    } => "skill_deactivated",

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
        #[serde(rename = "invocationId", skip_serializing_if = "Option::is_none")]
        tool_call_id: Option<String>,
        #[serde(rename = "blockingTimeoutMs", skip_serializing_if = "Option::is_none")]
        blocking_timeout_ms: Option<u64>,
        #[serde(rename = "workingDirectory", skip_serializing_if = "Option::is_none")]
        working_directory: Option<String>,
        #[serde(rename = "spawnType", skip_serializing_if = "Option::is_none")]
        spawn_type: Option<String>,
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
        #[serde(rename = "spawnType", skip_serializing_if = "Option::is_none")]
        spawn_type: Option<String>,
    } => "subagent_completed",

    /// Subagent failed.
    SubagentFailed {
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        error: String,
        duration: u64,
        #[serde(rename = "spawnType", skip_serializing_if = "Option::is_none")]
        spawn_type: Option<String>,
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
        /// Whether iOS should surface a user-facing notification for this
        /// completion. `false` when the parent session is actively running
        /// (backend delivers results via system-prompt injection instead).
        notify: bool,
    } => "subagent_result_available",

    // -- Worktree isolation --

    /// Worktree acquired for a session.
    WorktreeAcquired {
        path: String,
        branch: String,
        #[serde(rename = "baseCommit")]
        base_commit: String,
        #[serde(rename = "baseBranch", skip_serializing_if = "Option::is_none")]
        base_branch: Option<String>,
    } => "worktree.acquired",

    /// Commit made in a session's worktree.
    WorktreeCommit {
        #[serde(rename = "commitHash")]
        commit_hash: String,
        message: String,
        #[serde(rename = "filesChanged")]
        files_changed: Vec<String>,
        insertions: usize,
        deletions: usize,
        /// Total commits since worktree base commit (server-authoritative).
        #[serde(rename = "totalCommitCount")]
        total_commit_count: u64,
        /// Whether uncommitted changes remain after this commit.
        #[serde(rename = "hasUncommittedChanges")]
        has_uncommitted_changes: bool,
    } => "worktree.commit",

    /// Session branch merged into target.
    WorktreeMerged {
        #[serde(rename = "sourceBranch")]
        source_branch: String,
        #[serde(rename = "targetBranch")]
        target_branch: String,
        #[serde(rename = "mergeCommit", skip_serializing_if = "Option::is_none")]
        merge_commit: Option<String>,
        strategy: String,
    } => "worktree.merged",

    /// Worktree released (session ended or explicit release).
    WorktreeReleased {
        #[serde(rename = "finalCommit", skip_serializing_if = "Option::is_none")]
        final_commit: Option<String>,
        #[serde(rename = "branchPreserved")]
        branch_preserved: bool,
        deleted: bool,
    } => "worktree.released",

    /// Worktree branch renamed by LLM hook.
    WorktreeRenamed {
        #[serde(rename = "oldBranch")]
        old_branch: String,
        #[serde(rename = "newBranch")]
        new_branch: String,
    } => "worktree.renamed",

    // -- Git workflow suite (Phase 4) --

    /// Local main fast-forwarded from remote.
    WorktreeMainSynced {
        #[serde(rename = "mainBranch")]
        main_branch: String,
        #[serde(rename = "oldHead")]
        old_head: String,
        #[serde(rename = "newHead")]
        new_head: String,
        #[serde(rename = "advancedBy")]
        advanced_by: u64,
    } => "worktree.main_synced",

    /// Session finalized (merge + rebranch).
    WorktreeSessionFinalized {
        #[serde(rename = "sourceBranch")]
        source_branch: String,
        #[serde(rename = "targetBranch")]
        target_branch: String,
        #[serde(rename = "mergeCommit", skip_serializing_if = "Option::is_none")]
        merge_commit: Option<String>,
        strategy: String,
        #[serde(rename = "newBranch")]
        new_branch: String,
        #[serde(rename = "newBaseCommit")]
        new_base_commit: String,
        #[serde(rename = "oldBranchDeleted")]
        old_branch_deleted: bool,
        #[serde(rename = "oldBranchDeleteError", skip_serializing_if = "Option::is_none")]
        old_branch_delete_error: Option<String>,
    } => "worktree.session_finalized",

    /// Merge started with conflicts kept on disk.
    WorktreeMergeStarted {
        #[serde(rename = "sourceBranch")]
        source_branch: String,
        #[serde(rename = "targetBranch")]
        target_branch: String,
        strategy: String,
        #[serde(rename = "conflictCount")]
        conflict_count: u32,
    } => "worktree.merge_started",

    /// Conflict(s) detected in an in-flight merge / rebase / stash-pop.
    WorktreeConflictDetected {
        #[serde(rename = "sourceBranch")]
        source_branch: String,
        #[serde(rename = "targetBranch")]
        target_branch: String,
        /// Origin discriminator (`"finalize" | "rebase_on_main" | "stash_pop"`)
        /// — iOS renders contextual copy without re-deriving from branch names.
        origin: String,
        paths: Vec<String>,
    } => "worktree.conflict_detected",

    /// Single conflict resolved.
    WorktreeConflictResolved {
        path: String,
        resolution: String,
        remaining: u32,
    } => "worktree.conflict_resolved",

    /// In-flight merge / rebase / stash-pop continued after conflicts cleared.
    WorktreeMergeContinued {
        #[serde(rename = "mergeCommit")]
        merge_commit: String,
        strategy: String,
        /// Origin of the underlying pending merge
        /// (`"finalize" | "rebase_on_main" | "stash_pop"`). Drives iOS
        /// banner clear semantics.
        origin: String,
    } => "worktree.merge_continued",

    /// In-flight merge / rebase / stash-pop aborted.
    WorktreeMergeAborted {
        strategy: String,
        reason: String,
        /// Origin of the aborted pending merge. See `WorktreeMergeContinued`.
        origin: String,
    } => "worktree.merge_aborted",

    /// Branch pushed to remote.
    WorktreePushed {
        branch: String,
        remote: String,
        #[serde(rename = "setUpstream")]
        set_upstream: bool,
        #[serde(rename = "dryRun")]
        dry_run: bool,
        #[serde(rename = "forceWithLease")]
        force_with_lease: bool,
    } => "worktree.pushed",

    /// Pending merge detected during crash recovery.
    WorktreePendingMergeDetected {
        #[serde(rename = "sourceBranch")]
        source_branch: String,
        #[serde(rename = "targetBranch")]
        target_branch: String,
        strategy: String,
        #[serde(rename = "startedAtMs")]
        started_at_ms: u64,
        #[serde(rename = "autoAbortAtMs")]
        auto_abort_at_ms: u64,
    } => "worktree.pending_merge_detected",

    /// Session branch rebased onto main (clean or post-conflict resolution).
    WorktreeRebasedOnMain {
        #[serde(rename = "mainBranch")]
        main_branch: String,
        strategy: String,
        #[serde(rename = "oldBaseCommit")]
        old_base_commit: String,
        #[serde(rename = "newBaseCommit")]
        new_base_commit: String,
        #[serde(rename = "mainCommitsIncorporated")]
        main_commits_incorporated: u64,
        #[serde(rename = "hadAutoStash")]
        had_auto_stash: bool,
    } => "worktree.rebased_on_main",

    /// `git stash pop` after a successful rebase produced unmerged paths.
    /// Stash stays on the stash stack for manual recovery.
    WorktreePostRebaseStashConflict {
        #[serde(rename = "stashRef")]
        stash_ref: String,
        paths: Vec<String>,
    } => "worktree.post_rebase_stash_conflict",

    /// Auto-committed orphan changes in a session worktree during
    /// recovery or branch deletion. The SHA is preserved so the user
    /// can recover the work (via `git cherry-pick <sha>` or by checking
    /// out the branch if `branch_removed` is `false`).
    WorktreeAutoRecoveredCommits {
        branch: String,
        #[serde(rename = "commitHash")]
        commit_hash: String,
        path: String,
        #[serde(rename = "branchRemoved")]
        branch_removed: bool,
    } => "worktree.auto_recovered_commits",

    /// Per-repo lock acquired by a session.
    RepoLockAcquired {
        #[serde(rename = "repoRoot")]
        repo_root: String,
        #[serde(rename = "sessionId")]
        session_id: String,
        op: String,
    } => "repo.lock_acquired",

    /// Per-repo lock released.
    RepoLockReleased {
        #[serde(rename = "repoRoot")]
        repo_root: String,
        #[serde(rename = "sessionId")]
        session_id: String,
        op: String,
    } => "repo.lock_released",

    /// Main branch advanced in a repo (cross-session broadcast).
    RepoMainAdvanced {
        #[serde(rename = "repoRoot")]
        repo_root: String,
        #[serde(rename = "oldHead")]
        old_head: String,
        #[serde(rename = "newHead")]
        new_head: String,
        #[serde(rename = "sourceSessionId")]
        source_session_id: String,
        cause: String,
    } => "repo.main_advanced",

    // -- Display streaming --

    /// A single frame in a display stream (transient, not persisted).
    DisplayFrame {
        /// Stream identifier.
        #[serde(rename = "streamId")]
        stream_id: String,
        /// Capability invocation that initiated the stream.
        #[serde(rename = "invocationId")]
        tool_call_id: String,
        /// Base64-encoded JPEG frame data.
        data: String,
        /// Monotonically increasing frame counter.
        #[serde(rename = "frameId")]
        frame_id: u64,
        /// Frame width in pixels.
        width: u32,
        /// Frame height in pixels.
        height: u32,
    } => "display_frame",

    // -- Process management --

    /// A managed process was spawned (foreground or background).
    ProcessSpawned {
        /// Process identifier.
        #[serde(rename = "processId")]
        process_id: String,
        /// Human-readable label.
        label: String,
        /// Process kind ("shell", "display_stream", "tool_operation").
        kind: String,
        /// Whether the process was started in the background.
        background: bool,
        /// Capability invocation that spawned this process.
        #[serde(rename = "invocationId")]
        tool_call_id: String,
    } => "process_spawned",

    /// A managed process changed status (promoted, cancelled).
    ProcessStatusUpdate {
        /// Process identifier.
        #[serde(rename = "processId")]
        process_id: String,
        /// New status ("background", "cancelled").
        status: String,
    } => "process_status_update",

    /// A background process completed — result available for agent context.
    ProcessCompleted {
        /// Session that owns the process.
        #[serde(rename = "parentSessionId")]
        parent_session_id: String,
        /// Process identifier.
        #[serde(rename = "processId")]
        process_id: String,
        /// Human-readable label.
        label: String,
        /// Whether the process completed successfully.
        success: bool,
        /// Exit code (None for non-shell processes).
        #[serde(rename = "exitCode")]
        #[serde(skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        /// Duration in milliseconds.
        duration: u64,
        /// Truncated output summary.
        #[serde(rename = "resultSummary")]
        result_summary: String,
        /// Blob ID for full output (if large).
        #[serde(rename = "blobId")]
        #[serde(skip_serializing_if = "Option::is_none")]
        blob_id: Option<String>,
        /// ISO 8601 completion timestamp.
        #[serde(rename = "completedAt")]
        completed_at: String,
    } => "process_completed",

    /// A blocking job was moved to the background (auto-timeout or user action).
    JobBackgrounded {
        /// Job identifier (process ID or subagent session ID).
        #[serde(rename = "jobId")]
        job_id: String,
        /// Why it was backgrounded: `"auto_timeout"` or `"user_action"`.
        reason: String,
        /// Human-readable label.
        label: String,
        /// Capability invocation that spawned this job.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
    } => "job_backgrounded",
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
                | Self::CapabilityResolution { .. }
                | Self::CapabilityInvocationCompleted { .. }
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

/// Create a session-processing-changed event.
#[must_use]
pub fn session_processing_changed_event(
    session_id: impl Into<String>,
    is_processing: bool,
) -> TronEvent {
    TronEvent::SessionProcessingChanged {
        base: BaseEvent::now(session_id),
        is_processing,
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
    pub content: Vec<crate::shared::content::AssistantContent>,
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
            name: "execute".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "toolcall_start");
        assert_eq!(json["invocationId"], "tc-1");
        assert_eq!(json["name"], "execute");
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
            content: vec![crate::shared::content::AssistantContent::text("response")],
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
            token_usage: Some(TokenUsage {
                input_tokens: 100,
                output_tokens: 50,
                cache_read_tokens: Some(20),
                cache_creation_tokens: None,
                ..TokenUsage::default()
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
    fn tron_event_capability_invocation_started() {
        let e = TronEvent::CapabilityInvocationStarted {
            base: BaseEvent::now("s1"),
            tool_call_id: "tc-1".into(),
            tool_name: "execute".into(),
            arguments: None,
            capability_identity: CapabilityEventIdentity {
                model_tool_name: Some("execute".into()),
                contract_id: Some("filesystem::read_file".into()),
                implementation_id: Some("first_party.filesystem.v1.read_file".into()),
                function_id: Some("filesystem::read_file".into()),
                plugin_id: Some("first_party.filesystem".into()),
                worker_id: Some("filesystem-worker".into()),
                schema_digest: Some("sha256:test".into()),
                catalog_revision: Some(7),
                trust_tier: Some("first_party_signed".into()),
                risk_level: Some("low".into()),
                effect_class: Some("read".into()),
                trace_id: Some("trace-test".into()),
                root_invocation_id: Some("root-test".into()),
                binding_decision_id: Some("binding-test".into()),
            },
        };
        assert!(e.is_capability_invocation());
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["modelToolName"], "execute");
        assert_eq!(json["contractId"], "filesystem::read_file");
        assert_eq!(
            json["implementationId"],
            "first_party.filesystem.v1.read_file"
        );
        assert_eq!(json["schemaDigest"], "sha256:test");
        assert_eq!(json["catalogRevision"], 7);
        assert_eq!(json["bindingDecisionId"], "binding-test");
    }

    #[test]
    fn tron_event_binding_resolution_is_capability_invocation_event() {
        let e = TronEvent::CapabilityResolution {
            base: BaseEvent::now("s1"),
            tool_call_id: "tc-1".into(),
            model_tool_name: "execute".into(),
            requested_contract_id: Some("filesystem::read_file".into()),
            requested_implementation_id: None,
            requested_function_id: None,
            capability_identity: CapabilityEventIdentity::with_model_tool("execute"),
        };
        assert!(e.is_capability_invocation());
        assert_eq!(e.event_type(), "capability.resolution");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["type"], "capability.resolution");
        assert_eq!(json["invocationId"], "tc-1");
        assert_eq!(json["requestedContractId"], "filesystem::read_file");
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
            preserved_turns: Some(3),
            summarized_turns: Some(5),
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
            tool_name: Some("execute".into()),
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
            TronEvent::SessionProcessingChanged {
                base: base.clone(),
                is_processing: true,
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
            TronEvent::CapabilityInvocationBatch {
                base: base.clone(),
                tool_calls: vec![],
            },
            TronEvent::CapabilityInvocationStarted {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: "n".into(),
                arguments: None,
                capability_identity: CapabilityEventIdentity::default(),
            },
            TronEvent::CapabilityInvocationOutput {
                base: base.clone(),
                tool_call_id: "id".into(),
                update: "u".into(),
            },
            TronEvent::CapabilityInvocationProgress {
                base: base.clone(),
                tool_call_id: "id".into(),
                message: Some("msg".into()),
                percent: Some(0.5),
                capability_identity: CapabilityEventIdentity::default(),
            },
            TronEvent::CapabilityResolution {
                base: base.clone(),
                tool_call_id: "id".into(),
                model_tool_name: "execute".into(),
                requested_contract_id: Some("filesystem::read_file".into()),
                requested_implementation_id: None,
                requested_function_id: None,
                capability_identity: CapabilityEventIdentity::with_model_tool("execute"),
            },
            TronEvent::CapabilityInvocationCompleted {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: "n".into(),
                duration: 0,
                is_error: None,
                result: None,
                capability_identity: CapabilityEventIdentity::default(),
            },
            TronEvent::CapabilityInvocationArgumentDelta {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: None,
                arguments_delta: "d".into(),
            },
            TronEvent::CapabilityInvocationGenerating {
                base: base.clone(),
                tool_call_id: "id".into(),
                tool_name: "n".into(),
                capability_identity: CapabilityEventIdentity::default(),
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
            TronEvent::LlmHookResult {
                base: base.clone(),
                hook_name: "test".into(),
                hook_id: "test-id".into(),
                hook_event: "sessionStart".into(),
                output: Some("title".into()),
                duration_ms: 100,
                model: "m".into(),
                input_tokens: 10,
                output_tokens: 5,
                success: true,
                error: None,
                suggestions: None,
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
                preserved_turns: None,
                summarized_turns: None,
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
                source: None,
                profile: None,
                title: None,
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
                model: Some("m".into()),
                message_count: Some(0),
                input_tokens: Some(0),
                output_tokens: Some(0),
                last_turn_input_tokens: Some(0),
                cache_read_tokens: Some(0),
                cache_creation_tokens: Some(0),
                cost: Some(0.0),
                last_activity: "t".into(),
                is_active: true,
                last_user_prompt: None,
                last_assistant_response: None,
                parent_session_id: None,
                activity_lines: None,
            },
            TronEvent::MemoryUpdating { base: base.clone() },
            TronEvent::MemoryUpdated {
                base: base.clone(),
                title: None,
                summary: None,
                entry_type: None,
                event_id: None,
            },
            TronEvent::MemoryAutoRetainTriggered {
                base: base.clone(),
                interval_fired: 5,
            },
            TronEvent::MemoryAutoRetainFailed {
                base: base.clone(),
                interval_fired: 5,
                reason: "subagent error".into(),
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
            TronEvent::MessageQueued {
                base: base.clone(),
                queue_id: "q1".into(),
                text: "hello".into(),
                position: 0,
            },
            TronEvent::MessageDequeued {
                base: base.clone(),
                queue_id: "q1".into(),
                reason: "processed".into(),
            },
            TronEvent::QueuedMessageSent {
                base: base.clone(),
                text: "hello".into(),
                queue_id: "q1".into(),
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
            TronEvent::SkillActivated {
                base: base.clone(),
                skill_name: "browser".into(),
                source: "global".into(),
            },
            TronEvent::SkillDeactivated {
                base: base.clone(),
                skill_name: "browser".into(),
            },
            TronEvent::SubagentSpawned {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                task: "t".into(),
                model: "m".into(),
                max_turns: 50,
                spawn_depth: 0,
                tool_call_id: None,
                blocking_timeout_ms: Some(300_000),
                working_directory: None,
                spawn_type: None,
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
                spawn_type: None,
            },
            TronEvent::SubagentFailed {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                error: "e".into(),
                duration: 1000,
                spawn_type: None,
            },
            TronEvent::SubagentEvent {
                base: base.clone(),
                subagent_session_id: "sub-1".into(),
                event: json!({"type": "text_delta", "data": {"delta": "hi"}}),
            },
            TronEvent::SubagentResultAvailable {
                base: base.clone(),
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
                notify: true,
            },
            TronEvent::WorktreeAcquired {
                base: base.clone(),
                path: "/repo/.worktrees/session/abc".into(),
                branch: "session/abc".into(),
                base_commit: "deadbeef".into(),
                base_branch: Some("main".into()),
            },
            TronEvent::WorktreeCommit {
                base: base.clone(),
                commit_hash: "cafebabe".into(),
                message: "wip".into(),
                files_changed: vec!["file.txt".into()],
                insertions: 10,
                deletions: 2,
                total_commit_count: 3,
                has_uncommitted_changes: false,
            },
            TronEvent::WorktreeMerged {
                base: base.clone(),
                source_branch: "session/abc".into(),
                target_branch: "main".into(),
                merge_commit: Some("12345678".into()),
                strategy: "merge".into(),
            },
            TronEvent::WorktreeReleased {
                base: base.clone(),
                final_commit: Some("cafebabe".into()),
                branch_preserved: true,
                deleted: true,
            },
            TronEvent::WorktreeRenamed {
                base: base.clone(),
                old_branch: "session/abc123".into(),
                new_branch: "session/fuzzy-purple-elephant".into(),
            },
            TronEvent::DisplayFrame {
                base: base.clone(),
                stream_id: "stream-1".into(),
                tool_call_id: "call-1".into(),
                data: "base64data".into(),
                frame_id: 1,
                width: 1280,
                height: 720,
            },
            TronEvent::ProcessSpawned {
                base: base.clone(),
                process_id: "proc-1".into(),
                label: "test".into(),
                kind: "shell".into(),
                background: false,
                tool_call_id: "tc-1".into(),
            },
            TronEvent::ProcessStatusUpdate {
                base: base.clone(),
                process_id: "proc-1".into(),
                status: "background".into(),
            },
            TronEvent::ProcessCompleted {
                base: base.clone(),
                parent_session_id: "s1".into(),
                process_id: "proc-1".into(),
                label: "test".into(),
                success: true,
                exit_code: Some(0),
                duration: 100,
                result_summary: "ok".into(),
                blob_id: None,
                completed_at: "2026-01-01T00:00:00Z".into(),
            },
            TronEvent::JobBackgrounded {
                base: base.clone(),
                job_id: "proc-1".into(),
                reason: "auto_timeout".into(),
                label: "test".into(),
                tool_call_id: "tc-1".into(),
            },
            TronEvent::WorktreeMainSynced {
                base: base.clone(),
                main_branch: "main".into(),
                old_head: "abc".into(),
                new_head: "def".into(),
                advanced_by: 3,
            },
            TronEvent::WorktreeSessionFinalized {
                base: base.clone(),
                source_branch: "session/1".into(),
                target_branch: "main".into(),
                merge_commit: Some("def".into()),
                strategy: "merge".into(),
                new_branch: "session/1/next".into(),
                new_base_commit: "def".into(),
                old_branch_deleted: false,
                old_branch_delete_error: None,
            },
            TronEvent::WorktreeMergeStarted {
                base: base.clone(),
                source_branch: "session/1".into(),
                target_branch: "main".into(),
                strategy: "merge".into(),
                conflict_count: 2,
            },
            TronEvent::WorktreeConflictDetected {
                base: base.clone(),
                source_branch: "session/1".into(),
                target_branch: "main".into(),
                origin: "finalize".into(),
                paths: vec!["f.txt".into()],
            },
            TronEvent::WorktreeConflictResolved {
                base: base.clone(),
                path: "f.txt".into(),
                resolution: "ours".into(),
                remaining: 0,
            },
            TronEvent::WorktreeMergeContinued {
                base: base.clone(),
                merge_commit: "def".into(),
                strategy: "merge".into(),
                origin: "finalize".into(),
            },
            TronEvent::WorktreeMergeAborted {
                base: base.clone(),
                strategy: "merge".into(),
                reason: "user".into(),
                origin: "finalize".into(),
            },
            TronEvent::WorktreePushed {
                base: base.clone(),
                branch: "session/1".into(),
                remote: "origin".into(),
                set_upstream: true,
                dry_run: false,
                force_with_lease: false,
            },
            TronEvent::WorktreePendingMergeDetected {
                base: base.clone(),
                source_branch: "session/1".into(),
                target_branch: "main".into(),
                strategy: "merge".into(),
                started_at_ms: 0,
                auto_abort_at_ms: 0,
            },
            TronEvent::WorktreeRebasedOnMain {
                base: base.clone(),
                main_branch: "main".into(),
                strategy: "rebase".into(),
                old_base_commit: "abc".into(),
                new_base_commit: "def".into(),
                main_commits_incorporated: 1,
                had_auto_stash: false,
            },
            TronEvent::WorktreePostRebaseStashConflict {
                base: base.clone(),
                stash_ref: "stash@{0}".into(),
                paths: vec!["f.txt".into()],
            },
            TronEvent::WorktreeAutoRecoveredCommits {
                base: base.clone(),
                branch: "session/abc".into(),
                commit_hash: "cafebabe".into(),
                path: "/repo/.worktrees/session/abc".into(),
                branch_removed: true,
            },
            TronEvent::RepoLockAcquired {
                base: base.clone(),
                repo_root: "/repo".into(),
                session_id: "s1".into(),
                op: "syncMain".into(),
            },
            TronEvent::RepoLockReleased {
                base: base.clone(),
                repo_root: "/repo".into(),
                session_id: "s1".into(),
                op: "syncMain".into(),
            },
            TronEvent::RepoMainAdvanced {
                base,
                repo_root: "/repo".into(),
                old_head: "abc".into(),
                new_head: "def".into(),
                source_session_id: "s1".into(),
                cause: "sync".into(),
            },
        ];

        assert_eq!(events.len(), VARIANT_COUNT);

        let mut types: Vec<&str> = events.iter().map(TronEvent::event_type).collect();
        types.sort_unstable();
        types.dedup();
        assert_eq!(types.len(), VARIANT_COUNT);
    }

    #[test]
    fn session_updated_event_type() {
        let e = TronEvent::SessionUpdated {
            base: BaseEvent::now("s1"),
            title: Some("title".into()),
            model: Some("claude-opus-4-6".into()),
            message_count: Some(5),
            input_tokens: Some(100),
            output_tokens: Some(50),
            last_turn_input_tokens: Some(20),
            cache_read_tokens: Some(10),
            cache_creation_tokens: Some(5),
            cost: Some(0.01),
            last_activity: "2024-01-01T00:00:00Z".into(),
            is_active: true,
            last_user_prompt: Some("hello".into()),
            last_assistant_response: Some("world".into()),
            parent_session_id: None,
            activity_lines: None,
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
            summary: Some("summary text".into()),
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
    fn display_frame_event_type_and_fields() {
        let e = TronEvent::DisplayFrame {
            base: BaseEvent::now("sess-1"),
            stream_id: "stream-1".into(),
            tool_call_id: "call-1".into(),
            data: "base64jpeg".into(),
            frame_id: 42,
            width: 1280,
            height: 720,
        };
        assert_eq!(e.event_type(), "display_frame");
        assert_eq!(e.session_id(), "sess-1");

        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["streamId"], "stream-1");
        assert_eq!(json["invocationId"], "call-1");
        assert_eq!(json["data"], "base64jpeg");
        assert_eq!(json["frameId"], 42);
        assert_eq!(json["width"], 1280);
        assert_eq!(json["height"], 720);
    }

    #[test]
    fn display_frame_serde_roundtrip() {
        let original = TronEvent::DisplayFrame {
            base: BaseEvent::now("s1"),
            stream_id: "s".into(),
            tool_call_id: "t".into(),
            data: "d".into(),
            frame_id: 1,
            width: 640,
            height: 480,
        };
        let json = serde_json::to_string(&original).unwrap();
        let deserialized: TronEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(original, deserialized);
    }

    // ── Process management events ──

    #[test]
    fn process_spawned_event_type_and_fields() {
        let e = TronEvent::ProcessSpawned {
            base: BaseEvent::now("sess-1"),
            process_id: "proc-abc".into(),
            label: "cargo build".into(),
            kind: "shell".into(),
            background: true,
            tool_call_id: "tc-1".into(),
        };
        assert_eq!(e.event_type(), "process_spawned");
        assert_eq!(e.session_id(), "sess-1");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["processId"], "proc-abc");
        assert_eq!(json["label"], "cargo build");
        assert_eq!(json["kind"], "shell");
        assert_eq!(json["background"], true);
        assert_eq!(json["invocationId"], "tc-1");
    }

    #[test]
    fn process_spawned_serde_roundtrip() {
        let original = TronEvent::ProcessSpawned {
            base: BaseEvent::now("s1"),
            process_id: "proc-1".into(),
            label: "test".into(),
            kind: "shell".into(),
            background: false,
            tool_call_id: "tc-1".into(),
        };
        let json = serde_json::to_string(&original).unwrap();
        let back: TronEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(original, back);
    }

    #[test]
    fn process_status_update_event_type() {
        let e = TronEvent::ProcessStatusUpdate {
            base: BaseEvent::now("s1"),
            process_id: "proc-1".into(),
            status: "background".into(),
        };
        assert_eq!(e.event_type(), "process_status_update");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["processId"], "proc-1");
        assert_eq!(json["status"], "background");
    }

    #[test]
    fn process_completed_event_type_and_fields() {
        let e = TronEvent::ProcessCompleted {
            base: BaseEvent::now("sess-1"),
            parent_session_id: "sess-1".into(),
            process_id: "proc-abc".into(),
            label: "npm test".into(),
            success: false,
            exit_code: Some(1),
            duration: 12300,
            result_summary: "3 tests failed".into(),
            blob_id: Some("blob-xyz".into()),
            completed_at: "2026-03-29T12:00:00Z".into(),
        };
        assert_eq!(e.event_type(), "process_completed");
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["parentSessionId"], "sess-1");
        assert_eq!(json["processId"], "proc-abc");
        assert_eq!(json["label"], "npm test");
        assert_eq!(json["success"], false);
        assert_eq!(json["exitCode"], 1);
        assert_eq!(json["duration"], 12300);
        assert_eq!(json["resultSummary"], "3 tests failed");
        assert_eq!(json["blobId"], "blob-xyz");
        assert_eq!(json["completedAt"], "2026-03-29T12:00:00Z");
    }

    #[test]
    fn process_completed_nullable_fields() {
        let e = TronEvent::ProcessCompleted {
            base: BaseEvent::now("s1"),
            parent_session_id: "s1".into(),
            process_id: "proc-1".into(),
            label: "stream".into(),
            success: true,
            exit_code: None,
            duration: 5000,
            result_summary: "stream ended".into(),
            blob_id: None,
            completed_at: "2026-03-29T12:00:00Z".into(),
        };
        let json = serde_json::to_value(&e).unwrap();
        // skip_serializing_if = None means these fields should be absent.
        assert!(json.get("exitCode").is_none());
        assert!(json.get("blobId").is_none());
    }

    #[test]
    fn process_completed_serde_roundtrip() {
        let original = TronEvent::ProcessCompleted {
            base: BaseEvent::now("s1"),
            parent_session_id: "s1".into(),
            process_id: "proc-1".into(),
            label: "test".into(),
            success: true,
            exit_code: Some(0),
            duration: 100,
            result_summary: "ok".into(),
            blob_id: None,
            completed_at: "2026-03-29T12:00:00Z".into(),
        };
        let json = serde_json::to_string(&original).unwrap();
        let back: TronEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(original, back);
    }

    // ── BaseEvent sequence tests ──

    #[test]
    fn base_event_sequence_serialized() {
        let base = BaseEvent::now("s1").with_sequence(5);
        let json = serde_json::to_value(&base).unwrap();
        assert_eq!(json["sequence"], 5);
    }

    #[test]
    fn base_event_no_sequence_omitted() {
        let base = BaseEvent::now("s1");
        assert!(base.sequence.is_none());
        let json = serde_json::to_value(&base).unwrap();
        assert!(json.get("sequence").is_none());
    }

    #[test]
    fn base_event_with_sequence_builder() {
        let base = BaseEvent::now("s1").with_sequence(42);
        assert_eq!(base.sequence, Some(42));
        assert_eq!(base.session_id, "s1");
    }

    #[test]
    fn tron_event_set_sequence() {
        let mut e = agent_start_event("s1");
        assert!(e.sequence().is_none());
        e.set_sequence(7);
        assert_eq!(e.sequence(), Some(7));
    }

    #[test]
    fn tron_event_sequence_serialized_in_json() {
        let mut e = TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        };
        e.set_sequence(10);
        let json = serde_json::to_value(&e).unwrap();
        assert_eq!(json["sequence"], 10);
    }

    #[test]
    fn tron_event_no_sequence_omitted_from_json() {
        let e = TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        };
        let json = serde_json::to_value(&e).unwrap();
        assert!(json.get("sequence").is_none());
    }
}
