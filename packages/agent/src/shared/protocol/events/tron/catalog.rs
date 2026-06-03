//! Generated `TronEvent` catalog and accessors.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::super::{CapabilityEventIdentity, CapabilityInvocationSummary};
use super::{ActivatedRuleInfo, BackgroundHookResult, BaseEvent, CompactionReason, HookResult};
use crate::shared::messages::TokenUsage;
use crate::shared::model_capabilities::CapabilityResult;

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

    /// Capability binding resolution update for an `execute` primitive call.
    CapabilityResolution {
        #[serde(rename = "invocationId")]
        invocation_id: String,
        #[serde(rename = "modelPrimitiveName")]
        model_primitive_name: String,
        #[serde(rename = "requestedContractId", skip_serializing_if = "Option::is_none")]
        requested_contract_id: Option<String>,
        #[serde(rename = "requestedImplementationId", skip_serializing_if = "Option::is_none")]
        requested_implementation_id: Option<String>,
        #[serde(rename = "requestedFunctionId", skip_serializing_if = "Option::is_none")]
        requested_function_id: Option<String>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.resolution",

    /// Capability execution paused for user/client/system input.
    CapabilityPauseRequested {
        #[serde(rename = "pauseId")]
        pause_id: String,
        #[serde(rename = "invocationId")]
        invocation_id: String,
        kind: String,
        status: String,
        #[serde(rename = "promptPayload")]
        prompt_payload: Value,
        #[serde(rename = "resumeSchema", skip_serializing_if = "Option::is_none")]
        resume_schema: Option<Value>,
        #[serde(rename = "answerAuthority")]
        answer_authority: String,
        #[serde(rename = "expiresAt", skip_serializing_if = "Option::is_none")]
        expires_at: Option<String>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.pause.requested",

    /// Capability pause resolved, denied, cancelled, or expired.
    CapabilityPauseResolved {
        #[serde(rename = "pauseId")]
        pause_id: String,
        #[serde(rename = "invocationId")]
        invocation_id: String,
        status: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        resolution: Option<Value>,
        #[serde(flatten)]
        capability_identity: CapabilityEventIdentity,
    } => "capability.pause.resolved",

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

    // -- Hooks --

    /// Hook execution triggered.
    HookTriggered {
        #[serde(rename = "hookNames")]
        hook_names: Vec<String>,
        #[serde(rename = "hookEvent")]
        hook_event: String,
        #[serde(rename = "modelPrimitiveName", skip_serializing_if = "Option::is_none")]
        model_primitive_name: Option<String>,
        #[serde(rename = "invocationId", skip_serializing_if = "Option::is_none")]
        invocation_id: Option<String>,
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
        #[serde(rename = "modelPrimitiveName", skip_serializing_if = "Option::is_none")]
        model_primitive_name: Option<String>,
        #[serde(rename = "invocationId", skip_serializing_if = "Option::is_none")]
        invocation_id: Option<String>,
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
        #[serde(rename = "resourceRefs", skip_serializing_if = "Option::is_none")]
        resource_refs: Option<Vec<serde_json::Value>>,
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
        invocation_id: Option<String>,
        #[serde(rename = "blockingTimeoutMs", skip_serializing_if = "Option::is_none")]
        blocking_timeout_ms: Option<u64>,
        #[serde(rename = "workingDirectory", skip_serializing_if = "Option::is_none")]
        working_directory: Option<String>,
        #[serde(rename = "spawnType", skip_serializing_if = "Option::is_none")]
        spawn_type: Option<String>,
        #[serde(rename = "taskProfile", skip_serializing_if = "Option::is_none")]
        task_profile: Option<Value>,
        #[serde(rename = "modelRouting", skip_serializing_if = "Option::is_none")]
        model_routing: Option<Value>,
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
        #[serde(rename = "taskProfile", skip_serializing_if = "Option::is_none")]
        task_profile: Option<Value>,
        #[serde(rename = "modelRouting", skip_serializing_if = "Option::is_none")]
        model_routing: Option<Value>,
    } => "subagent_completed",

    /// Subagent failed.
    SubagentFailed {
        #[serde(rename = "subagentSessionId")]
        subagent_session_id: String,
        error: String,
        duration: u64,
        #[serde(rename = "spawnType", skip_serializing_if = "Option::is_none")]
        spawn_type: Option<String>,
        #[serde(rename = "taskProfile", skip_serializing_if = "Option::is_none")]
        task_profile: Option<Value>,
        #[serde(rename = "modelRouting", skip_serializing_if = "Option::is_none")]
        model_routing: Option<Value>,
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
        #[serde(rename = "taskProfile", skip_serializing_if = "Option::is_none")]
        task_profile: Option<Value>,
        #[serde(rename = "modelRouting", skip_serializing_if = "Option::is_none")]
        model_routing: Option<Value>,
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
        /// Origin of the reconstructed pending merge
        /// (`"finalize" | "rebase_on_main" | "stash_pop"`).
        origin: String,
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
        invocation_id: String,
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
        /// Process kind ("shell", "display_stream", "capability_operation").
        kind: String,
        /// Whether the process was started in the background.
        background: bool,
        /// Capability invocation that spawned this process.
        #[serde(rename = "invocationId")]
        invocation_id: String,
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
        #[serde(rename = "invocationId")]
        invocation_id: String,
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
                | Self::CapabilityPauseRequested { .. }
                | Self::CapabilityPauseResolved { .. }
                | Self::CapabilityRunStatus { .. }
                | Self::CapabilityInvocationCompleted { .. }
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
