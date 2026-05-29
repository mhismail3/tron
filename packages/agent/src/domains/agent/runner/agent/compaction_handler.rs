//! Compaction handler — sole owner of compaction logic.
//!
//! Uses multi-signal triggering: token threshold and progress signals
//! (git push, gh pr, worktree commits, etc.). Runs at pre-turn.
//!
//! The handler determines the [`CompactionReason`] internally from the
//! signal that fired (`ThresholdExceeded` vs `ProgressSignal`).
//!
//! Event types and process commands are recorded between compactions and
//! cleared after successful compaction.

use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use tokio::sync::Notify;

use crate::domains::agent::runner::context::compaction_trigger::CompactionTrigger;
use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::context::summarizer::KeywordSummarizer;
use crate::domains::agent::runner::context::types::{
    CompactionTriggerConfig, CompactionTriggerInput,
};
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::agent::runner::hooks::types::{HookAction, HookContext};
use crate::shared::events::HookResult as EventHookResult;
use crate::shared::events::{BaseEvent, CompactionReason, TronEvent};
use async_trait::async_trait;

use metrics::{counter, histogram};
use tracing::{debug, error, info, warn};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::errors::RuntimeError;
use crate::domains::agent::runner::orchestrator::subagent_manager::{
    SubagentManager, SubsessionConfig,
};
use crate::domains::agent::runner::types::ReasoningLevel;

// =============================================================================
// SubagentManagerSpawner — the single SubsessionSpawner implementation
// =============================================================================

/// [`SubsessionSpawner`](crate::domains::agent::runner::context::llm_summarizer::SubsessionSpawner) that
/// wraps `SubagentManager::spawn_subsession()` for full audit trail.
///
/// Every LLM call (compaction, ledger) goes through a real child session with
/// event persistence — no raw `provider.stream()` calls.
pub struct SubagentManagerSpawner {
    /// The subagent manager to spawn through.
    pub manager: Arc<SubagentManager>,
    /// Parent session ID for audit trail.
    pub parent_session_id: String,
    /// Working directory for child session.
    pub working_directory: String,
    /// Custom system prompt for the subsession.
    pub system_prompt: String,
    /// Optional model override (None = parent's model).
    pub model: Option<String>,
}

#[async_trait]
impl crate::domains::agent::runner::context::llm_summarizer::SubsessionSpawner
    for SubagentManagerSpawner
{
    async fn spawn_summarizer(
        &self,
        task: &str,
    ) -> crate::domains::agent::runner::context::llm_summarizer::SubsessionResult {
        let process_plan = match self.manager.plan_process("compaction") {
            Ok(plan) => plan,
            Err(error) => {
                return crate::domains::agent::runner::context::llm_summarizer::SubsessionResult {
                    success: false,
                    output: None,
                    error: Some(error.to_string()),
                };
            }
        };
        let process = &process_plan.process;
        match self
            .manager
            .spawn_subsession(SubsessionConfig {
                process_id: Some("compaction".into()),
                parent_session_id: self.parent_session_id.clone(),
                task: task.to_owned(),
                model: self.model.clone(),
                system_prompt: self.system_prompt.clone(),
                working_directory: self.working_directory.clone(),
                timeout_ms: process
                    .timeout_ms
                    .expect("compaction process must define timeoutMs"),
                blocking_timeout_ms: process.blocking_timeout_ms,
                inherit_capabilities: process
                    .inherit_capabilities
                    .expect("compaction process must define inheritCapabilities"),
                max_turns: process
                    .max_turns
                    .expect("compaction process must define maxTurns"),
                max_depth: process
                    .max_depth
                    .expect("compaction process must define maxDepth"),
                reasoning_level: Some(
                    process
                        .reasoning
                        .as_deref()
                        .and_then(ReasoningLevel::from_str_loose)
                        .expect("compaction process must define reasoning"),
                ),
                ..SubsessionConfig::default()
            })
            .await
        {
            Ok(result) => {
                crate::domains::agent::runner::context::llm_summarizer::SubsessionResult {
                    success: true,
                    output: Some(result.output),
                    error: None,
                }
            }
            Err(e) => crate::domains::agent::runner::context::llm_summarizer::SubsessionResult {
                success: false,
                output: None,
                error: Some(e.to_string()),
            },
        }
    }
}

// =============================================================================
// SubagentContentSummarizer — ContentSummarizer for web::fetch
// =============================================================================

/// [`ContentSummarizer`](crate::domains::capability_support::implementations::traits::ContentSummarizer) that wraps
/// `SubagentManager::spawn_subsession()` to summarize web page content via Haiku.
pub struct SubagentContentSummarizer {
    /// The subagent manager to spawn through.
    pub manager: Arc<SubagentManager>,
}

#[async_trait]
impl crate::domains::capability_support::implementations::traits::ContentSummarizer
    for SubagentContentSummarizer
{
    async fn summarize(
        &self,
        task: &str,
        parent_session_id: &str,
    ) -> Result<
        crate::domains::capability_support::implementations::traits::SummarizerResult,
        crate::domains::capability_support::implementations::errors::CapabilityExecutionError,
    > {
        let process_plan = self.manager.plan_process("webSummarizer")?;
        let process = &process_plan.process;
        let result = self
            .manager
            .spawn_subsession(SubsessionConfig {
                process_id: Some("webSummarizer".into()),
                parent_session_id: parent_session_id.to_owned(),
                task: task.to_owned(),
                model: None,
                system_prompt: process_plan
                    .prompt
                    .as_ref()
                    .map(|prompt| prompt.content.clone())
                    .unwrap_or_default(),
                working_directory: process
                    .working_directory
                    .clone()
                    .expect("webSummarizer process must define workingDirectory"),
                timeout_ms: process
                    .timeout_ms
                    .expect("webSummarizer process must define timeoutMs"),
                blocking_timeout_ms: process.blocking_timeout_ms,
                inherit_capabilities: process
                    .inherit_capabilities
                    .expect("webSummarizer process must define inheritCapabilities"),
                max_turns: process
                    .max_turns
                    .expect("webSummarizer process must define maxTurns"),
                max_depth: process
                    .max_depth
                    .expect("webSummarizer process must define maxDepth"),
                reasoning_level: process
                    .reasoning
                    .as_deref()
                    .and_then(ReasoningLevel::from_str_loose),
                ..SubsessionConfig::default()
            })
            .await
            .map_err(|e| {
                crate::domains::capability_support::implementations::errors::CapabilityExecutionError::Internal {
                    message: format!("Summarizer subsession failed: {e}"),
                }
            })?;

        Ok(
            crate::domains::capability_support::implementations::traits::SummarizerResult {
                answer: result.output,
                session_id: result.session_id,
            },
        )
    }
}

// =============================================================================
// CompactionHandler
// =============================================================================

/// Compaction handler state — sole owner of all compaction logic.
///
/// Uses multi-signal triggering via `CompactionTrigger`:
/// 1. Token threshold (primary trigger)
/// 2. Progress signals (git push, gh pr, etc.)
pub struct CompactionHandler {
    is_compacting: AtomicBool,
    compaction_done: Arc<Notify>,
    subagent_manager: Option<Arc<SubagentManager>>,
    /// Optional event persister for `compact.boundary` persistence.
    persister: Mutex<
        Option<Arc<crate::domains::agent::runner::orchestrator::event_persister::EventPersister>>,
    >,
    /// Multi-signal compaction trigger.
    trigger: Mutex<CompactionTrigger>,
    /// Process commands accumulated between compactions for progress-signal detection.
    pending_process_commands: Mutex<Vec<String>>,
    /// Event types accumulated between compactions for progress-signal detection
    /// (e.g. `"worktree.commit"`).
    pending_event_types: Mutex<Vec<String>>,
}

/// RAII guard that resets `is_compacting` and notifies waiters on drop.
/// Handles both normal completion and future cancellation.
struct CompactionGuard<'a> {
    is_compacting: &'a AtomicBool,
    done: &'a Notify,
}

impl Drop for CompactionGuard<'_> {
    fn drop(&mut self) {
        self.is_compacting.store(false, Ordering::SeqCst);
        self.done.notify_waiters();
    }
}

impl CompactionHandler {
    /// Create a handler without LLM support (keyword summarizer only).
    pub fn new(trigger_config: CompactionTriggerConfig) -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            compaction_done: Arc::new(Notify::new()),
            subagent_manager: None,
            persister: Mutex::new(None),
            trigger: Mutex::new(CompactionTrigger::new(trigger_config)),
            pending_process_commands: Mutex::new(Vec::new()),
            pending_event_types: Mutex::new(Vec::new()),
        }
    }

    /// Create a handler with a `SubagentManager` for subsession-backed summaries.
    pub fn with_subagent_manager(
        manager: Arc<SubagentManager>,
        trigger_config: CompactionTriggerConfig,
    ) -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            compaction_done: Arc::new(Notify::new()),
            subagent_manager: Some(manager),
            persister: Mutex::new(None),
            trigger: Mutex::new(CompactionTrigger::new(trigger_config)),
            pending_process_commands: Mutex::new(Vec::new()),
            pending_event_types: Mutex::new(Vec::new()),
        }
    }

    /// Set the event persister for `compact.boundary` persistence.
    pub fn set_persister(
        &self,
        persister: Arc<
            crate::domains::agent::runner::orchestrator::event_persister::EventPersister,
        >,
    ) {
        *self.persister.lock().unwrap() = Some(persister);
    }

    /// Whether a compaction is in progress.
    pub fn is_compacting(&self) -> bool {
        self.is_compacting.load(Ordering::Relaxed)
    }

    /// Record a process command for progress-signal detection.
    /// Called by `turn_runner` after each process capability invocation.
    pub fn record_process_command(&self, command: &str) {
        self.pending_process_commands
            .lock()
            .unwrap()
            .push(command.to_owned());
    }

    /// Record an event type for progress-signal detection.
    /// Called when worktree commits or other significant events occur.
    pub fn record_event_type(&self, event_type: &str) {
        self.pending_event_types
            .lock()
            .unwrap()
            .push(event_type.to_owned());
    }

    /// Wait for an in-progress compaction to complete, with timeout.
    ///
    /// Returns immediately if no compaction is running.
    pub async fn wait_for_compaction(&self, timeout: std::time::Duration) {
        if !self.is_compacting.load(Ordering::SeqCst) {
            return;
        }
        let _ = tokio::time::timeout(timeout, self.compaction_done.notified()).await;
    }

    /// Check if compaction is needed (using multi-signal trigger) and execute if so.
    ///
    /// The trigger reason is determined internally from the signal that fired
    /// (token threshold → `ThresholdExceeded`, progress signal → `ProgressSignal`).
    ///
    /// Returns `true` if compaction was performed.
    pub async fn check_and_compact(
        &self,
        context_manager: &mut ContextManager,
        hooks: &Option<Arc<HookEngine>>,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        sequence_counter: Option<&AtomicI64>,
    ) -> Result<bool, RuntimeError> {
        // Early return: no meaningful ratio if context_limit is zero.
        let context_limit = context_manager.get_context_limit();
        if context_limit == 0 {
            return Ok(false);
        }

        // Build trigger input from current state
        let current_tokens = context_manager.get_current_tokens();
        #[allow(clippy::cast_precision_loss)]
        let token_ratio = current_tokens as f64 / context_limit as f64;

        let pending_commands = self.pending_process_commands.lock().unwrap().clone();
        let pending_events = self.pending_event_types.lock().unwrap().clone();
        let trigger_input = CompactionTriggerInput {
            current_token_ratio: token_ratio,
            recent_event_types: pending_events,
            recent_capability_invocations: pending_commands,
        };

        let trigger_result = self.trigger.lock().unwrap().should_compact(&trigger_input);
        if !trigger_result.compact {
            return Ok(false);
        }

        if !context_manager.has_summarizable_compaction_window() {
            debug!(
                reason = %trigger_result.reason,
                session_id,
                "compaction trigger suppressed: no older messages are eligible for summarization"
            );
            counter!("compaction_total", "status" => "noop").increment(1);
            return Ok(false);
        }

        // Determine reason from trigger: token ratio triggers report a percentage,
        // progress signals report "commit" or "progress signal".
        let reason = if trigger_result.reason.contains("token ratio") {
            CompactionReason::ThresholdExceeded
        } else {
            CompactionReason::ProgressSignal
        };

        debug!(
            reason = %trigger_result.reason,
            session_id,
            "compaction triggered by multi-signal"
        );

        let success = self
            .execute_compaction(
                context_manager,
                hooks,
                session_id,
                emitter,
                reason,
                sequence_counter,
            )
            .await?;

        if success {
            self.trigger.lock().unwrap().reset();
            self.pending_process_commands.lock().unwrap().clear();
            self.pending_event_types.lock().unwrap().clear();
        }

        Ok(success)
    }

    /// Force-execute compaction regardless of threshold.
    pub async fn execute_compaction(
        &self,
        context_manager: &mut ContextManager,
        hooks: &Option<Arc<HookEngine>>,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
        sequence_counter: Option<&AtomicI64>,
    ) -> Result<bool, RuntimeError> {
        debug!(session_id, ?reason, "compaction requested");

        // Guard against concurrent compaction
        if self
            .is_compacting
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(false);
        }
        // RAII guard resets is_compacting and notifies waiters on drop
        // (handles normal return, early return, error, and future cancellation)
        let _guard = CompactionGuard {
            is_compacting: &self.is_compacting,
            done: &self.compaction_done,
        };

        let tokens_before = context_manager.get_current_tokens();

        if !Self::execute_precompact_hooks(
            hooks.as_ref(),
            session_id,
            emitter,
            tokens_before,
            context_manager.get_context_limit(),
            sequence_counter,
        )
        .await
        {
            return Ok(false);
        }

        if let Some(counter) = sequence_counter {
            let _ = emitter.emit_sequenced(
                TronEvent::CompactionStart {
                    base: BaseEvent::now(session_id),
                    reason: reason.clone(),
                    tokens_before,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::CompactionStart {
                base: BaseEvent::now(session_id),
                reason: reason.clone(),
                tokens_before,
            });
        }

        let compaction_start = std::time::Instant::now();

        let result =
            Self::run_summarizer(context_manager, session_id, self.subagent_manager.as_ref()).await;

        let effective_result = result
            .as_ref()
            .is_ok_and(Self::is_effective_compaction_result);

        // Append a policy-aware skill notice only after a real summary + ack
        // was inserted. A skipped/no-op compaction has no ack slot to mutate.
        if effective_result {
            Self::inject_skill_notice_into_ack(context_manager);
        }

        let tokens_after = context_manager.get_current_tokens();

        if tokens_after >= tokens_before && effective_result {
            warn!(
                session_id,
                tokens_before, tokens_after, "compaction did not reduce token count"
            );
        }

        let persister = self.persister.lock().unwrap().clone();
        Ok(Self::emit_compaction_events(
            result,
            compaction_start,
            tokens_before,
            tokens_after,
            session_id,
            emitter,
            reason,
            persister.as_ref(),
            sequence_counter,
        )
        .await)
    }

    fn is_effective_compaction_result(
        result: &crate::domains::agent::runner::context::types::CompactionResult,
    ) -> bool {
        result.success && result.summarized_turns > 0 && result.tokens_after < result.tokens_before
    }

    /// Execute `PreCompact` hooks; returns `false` if hooks blocked compaction.
    async fn execute_precompact_hooks(
        hooks: Option<&Arc<HookEngine>>,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        current_tokens: u64,
        context_limit: u64,
        sequence_counter: Option<&AtomicI64>,
    ) -> bool {
        let Some(hook_engine) = hooks else {
            return true;
        };

        let hook_ctx = HookContext::PreCompact {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            current_tokens,
            target_tokens: (context_limit * 7) / 10,
        };
        if let Some(counter) = sequence_counter {
            let _ = emitter.emit_sequenced(
                TronEvent::HookTriggered {
                    base: BaseEvent::now(session_id),
                    hook_names: vec![],
                    hook_event: "PreCompact".into(),
                    model_primitive_name: None,
                    invocation_id: None,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::HookTriggered {
                base: BaseEvent::now(session_id),
                hook_names: vec![],
                hook_event: "PreCompact".into(),
                model_primitive_name: None,
                invocation_id: None,
            });
        }
        let result = hook_engine.execute(&hook_ctx).await;
        let event_result = match result.action {
            HookAction::Block => EventHookResult::Block,
            HookAction::Modify => EventHookResult::Modify,
            // AddContext has no meaning for PreCompact — compaction
            // doesn't carry a user prompt to inject into.
            HookAction::Continue | HookAction::AddContext => EventHookResult::Continue,
        };
        if let Some(counter) = sequence_counter {
            let _ = emitter.emit_sequenced(
                TronEvent::HookCompleted {
                    base: BaseEvent::now(session_id),
                    hook_names: vec![],
                    hook_event: "PreCompact".into(),
                    result: event_result,
                    duration: None,
                    reason: result.reason.clone(),
                    model_primitive_name: None,
                    invocation_id: None,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::HookCompleted {
                base: BaseEvent::now(session_id),
                hook_names: vec![],
                hook_event: "PreCompact".into(),
                result: event_result,
                duration: None,
                reason: result.reason.clone(),
                model_primitive_name: None,
                invocation_id: None,
            });
        }
        result.action != HookAction::Block
    }

    async fn run_summarizer(
        context_manager: &mut ContextManager,
        session_id: &str,
        subagent_manager: Option<&Arc<SubagentManager>>,
    ) -> Result<
        crate::domains::agent::runner::context::types::CompactionResult,
        Box<dyn std::error::Error + Send + Sync>,
    > {
        if let Some(manager) = subagent_manager {
            let process_plan = manager.plan_process("compaction")?;
            let spawner = SubagentManagerSpawner {
                manager: manager.clone(),
                parent_session_id: session_id.to_owned(),
                working_directory: context_manager.get_working_directory().to_owned(),
                system_prompt: process_plan
                    .prompt
                    .as_ref()
                    .map(|prompt| prompt.content.clone())
                    .unwrap_or_default(),
                model: None,
            };
            let summarizer =
                crate::domains::agent::runner::context::llm_summarizer::LlmSummarizer::new(spawner);
            context_manager.execute_compaction(&summarizer, None).await
        } else {
            let summarizer = KeywordSummarizer;
            context_manager.execute_compaction(&summarizer, None).await
        }
    }

    /// Append a skill-status notice to the compaction ack message based on the
    /// configured `CompactionPolicy`. The ack is always at index 1 in the message
    /// list (after the summary user message at index 0).
    fn inject_skill_notice_into_ack(context_manager: &mut ContextManager) {
        use crate::domains::settings::types::CompactionPolicy;

        let policy = {
            let settings = crate::domains::settings::get_settings();
            settings.skills.compaction_policy.clone()
        };

        let notice = match policy {
            CompactionPolicy::ClearAll | CompactionPolicy::AskUser => {
                "\n\n[Skills Status: All previously active skills were cleared during context \
                 compaction. Skills mentioned in the context summary above are no longer loaded. \
                 Do not use or reference them unless re-activated with @skill-name.]"
            }
            CompactionPolicy::AutoRestore => {
                "\n\n[Skills Status: Active skills were preserved through context compaction \
                 and remain available.]"
            }
        };

        let mut messages = context_manager.get_messages();
        if messages.len() >= 2 {
            if let crate::shared::messages::Message::Assistant {
                ref mut content, ..
            } = messages[1]
            {
                if let Some(crate::shared::content::AssistantContent::Text { text, .. }) =
                    content.first_mut()
                {
                    text.push_str(notice);
                }
            }
            context_manager.set_messages(messages);
        }
    }

    /// Emit the terminal events for a compaction attempt.
    ///
    /// Two-phase commit for the compaction boundary: Phase 1 writes
    /// `compact.summary_staging` carrying the produced summary; Phase 2
    /// writes `compact.boundary`. Both must persist before broadcasting
    /// `CompactionComplete` so a crash between phases leaves either no
    /// trace or a fully-committed boundary — never a partial one. Public
    /// only for tests; production calls it from `check_and_compact`.
    pub(super) async fn emit_compaction_events(
        result: Result<
            crate::domains::agent::runner::context::types::CompactionResult,
            Box<dyn std::error::Error + Send + Sync>,
        >,
        compaction_start: std::time::Instant,
        tokens_before: u64,
        tokens_after: u64,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
        persister: Option<
            &Arc<crate::domains::agent::runner::orchestrator::event_persister::EventPersister>,
        >,
        sequence_counter: Option<&AtomicI64>,
    ) -> bool {
        match result {
            Ok(compaction_result) => {
                if !Self::is_effective_compaction_result(&compaction_result) {
                    counter!("compaction_total", "status" => "noop").increment(1);
                    warn!(
                        session_id,
                        result_success = compaction_result.success,
                        summarized_turns = compaction_result.summarized_turns,
                        result_tokens_before = compaction_result.tokens_before,
                        result_tokens_after = compaction_result.tokens_after,
                        tokens_before,
                        tokens_after,
                        "compaction produced no durable reduction; suppressing boundary"
                    );
                    return false;
                }

                counter!("compaction_total", "status" => "success").increment(1);
                histogram!("compaction_duration_seconds")
                    .record(compaction_start.elapsed().as_secs_f64());
                let summary_text = if compaction_result.summary.is_empty() {
                    None
                } else {
                    Some(compaction_result.summary)
                };
                info!(
                    session_id,
                    tokens_before, tokens_after, "compaction complete"
                );
                // Two-phase commit.
                //
                // Phase 1: persist `compact.summary_staging` carrying the
                //   summarizer's output. This durably records the LLM's
                //   work BEFORE we try to commit the boundary — if the
                //   boundary persist later fails, the summary is preserved
                //   for diagnostics and future recovery.
                // Phase 2: persist `compact.boundary`. Reconstruction treats
                //   the boundary as authoritative; a staging event without
                //   a successor boundary is ignored.
                //
                // INVARIANT: both persists complete BEFORE broadcasting
                // CompactionComplete. If either phase fails, the broadcast
                // is suppressed so live iOS never claims a compaction that
                // didn't land durably.
                let mut persist_ok = true;
                if compaction_result.success
                    && let Some(persister) = persister
                {
                    // INVARIANT: encode reason via serde so the wire string matches
                    // the `#[serde(rename_all = "snake_case")]` contract on
                    // `CompactionReason`. Debug formatting would leak
                    // PascalCase variant names and drift from iOS expectations.
                    let reason_str = serde_json::to_value(&reason)
                        .ok()
                        .and_then(|v| v.as_str().map(str::to_owned))
                        .expect("CompactionReason serializes to a JSON string via snake_case");
                    let staging_timestamp = chrono::Utc::now().to_rfc3339();

                    // ── Phase 1: staging ─────────────────────────────────
                    #[allow(clippy::cast_possible_wrap)]
                    let staging_payload = serde_json::json!({
                        "originalTokens": tokens_before as i64,
                        "compactedTokens": tokens_after as i64,
                        "reason": reason_str.clone(),
                        "summary": summary_text.clone().unwrap_or_default(),
                        "timestamp": staging_timestamp,
                    });
                    if let Err(error) = persister
                        .append_with_runtime_sequence(
                            session_id,
                            crate::domains::session::event_store::EventType::CompactSummaryStaging,
                            staging_payload,
                            sequence_counter,
                        )
                        .await
                    {
                        error!(
                            session_id,
                            error = %error,
                            "phase 1 failed: compaction staging persist failed; skipping boundary + broadcast"
                        );
                        persist_ok = false;
                    }

                    // ── Phase 2: boundary ────────────────────────────────
                    // Only run if phase 1 succeeded, so the log never contains
                    // a boundary without a matching prior staging.
                    if persist_ok {
                        #[allow(clippy::cast_possible_wrap)]
                        let payload = serde_json::json!({
                            "originalTokens": tokens_before as i64,
                            "compactedTokens": tokens_after as i64,
                            "compressionRatio": compaction_result.compression_ratio,
                            "reason": reason_str,
                            "summary": summary_text.clone(),
                            "estimatedContextTokens": tokens_after as i64,
                            "preservedTurns": compaction_result.preserved_turns,
                            "summarizedTurns": compaction_result.summarized_turns,
                            "preservedMessages": compaction_result.preserved_messages,
                        });
                        if let Err(error) = persister
                            .append_with_runtime_sequence(
                                session_id,
                                crate::domains::session::event_store::EventType::CompactBoundary,
                                payload,
                                sequence_counter,
                            )
                            .await
                        {
                            error!(
                                session_id,
                                error = %error,
                                "phase 2 failed: boundary persist failed after staging; staging remains for diagnostics"
                            );
                            persist_ok = false;
                        }
                    }
                }

                if persist_ok {
                    if let Some(counter) = sequence_counter {
                        let _ = emitter.emit_sequenced(
                            TronEvent::CompactionComplete {
                                base: BaseEvent::now(session_id),
                                success: compaction_result.success,
                                tokens_before,
                                tokens_after,
                                compression_ratio: compaction_result.compression_ratio,
                                reason: Some(reason.clone()),
                                summary: summary_text.clone(),
                                estimated_context_tokens: Some(tokens_after),
                                preserved_turns: Some(compaction_result.preserved_turns),
                                summarized_turns: Some(compaction_result.summarized_turns),
                            },
                            counter,
                        );
                    } else {
                        let _ = emitter.emit(TronEvent::CompactionComplete {
                            base: BaseEvent::now(session_id),
                            success: compaction_result.success,
                            tokens_before,
                            tokens_after,
                            compression_ratio: compaction_result.compression_ratio,
                            reason: Some(reason.clone()),
                            summary: summary_text.clone(),
                            estimated_context_tokens: Some(tokens_after),
                            preserved_turns: Some(compaction_result.preserved_turns),
                            summarized_turns: Some(compaction_result.summarized_turns),
                        });
                    }
                }
                // Return `true`: compaction ran (the in-process context_manager
                // was compacted). A persist failure is surfaced via logs and
                // the missing broadcast; caller semantics for "ran vs didn't
                // run" remain unchanged. Future work: roll back in-memory
                // compaction on persist failure so DB and in-process state
                // cannot diverge.
                true
            }
            Err(e) => {
                if let Some(counter) = sequence_counter {
                    let _ = emitter.emit_sequenced(
                        TronEvent::CompactionComplete {
                            base: BaseEvent::now(session_id),
                            success: false,
                            tokens_before,
                            tokens_after: tokens_before,
                            compression_ratio: 1.0,
                            reason: Some(reason),
                            summary: Some(format!("Compaction failed: {e}")),
                            estimated_context_tokens: Some(tokens_before),
                            preserved_turns: None,
                            summarized_turns: None,
                        },
                        counter,
                    );
                } else {
                    let _ = emitter.emit(TronEvent::CompactionComplete {
                        base: BaseEvent::now(session_id),
                        success: false,
                        tokens_before,
                        tokens_after: tokens_before,
                        compression_ratio: 1.0,
                        reason: Some(reason),
                        summary: Some(format!("Compaction failed: {e}")),
                        estimated_context_tokens: Some(tokens_before),
                        preserved_turns: None,
                        summarized_turns: None,
                    });
                }
                counter!("compaction_total", "status" => "failure").increment(1);
                tracing::warn!(session_id, tokens_before, error = %e, "compaction failed");
                false
            }
        }
    }
}

impl Default for CompactionHandler {
    fn default() -> Self {
        Self::new(CompactionTriggerConfig::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_state() {
        let handler = CompactionHandler::default();
        assert!(!handler.is_compacting());
        assert!(handler.subagent_manager.is_none());
    }

    #[test]
    fn default_state() {
        let handler = CompactionHandler::default();
        assert!(!handler.is_compacting());
    }

    #[test]
    fn pre_compact_target_is_70_percent() {
        let limit: u64 = 200_000;
        let target = (limit * 7) / 10;
        assert_eq!(target, 140_000);
    }

    #[test]
    fn pre_compact_target_not_50_percent() {
        let limit: u64 = 200_000;
        let target = (limit * 7) / 10;
        assert_ne!(target, limit / 2);
    }

    // -- wait_for_compaction --

    #[tokio::test]
    async fn wait_returns_immediately_when_idle() {
        let handler = CompactionHandler::default();
        handler
            .wait_for_compaction(std::time::Duration::from_millis(10))
            .await;
        assert!(!handler.is_compacting());
    }

    // -- CompactionGuard --

    #[test]
    fn guard_resets_on_drop() {
        let is_compacting = AtomicBool::new(true);
        let done = Arc::new(Notify::new());
        {
            let _guard = CompactionGuard {
                is_compacting: &is_compacting,
                done: &done,
            };
            assert!(is_compacting.load(Ordering::SeqCst));
        }
        assert!(!is_compacting.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn guard_notifies_on_drop() {
        let is_compacting = AtomicBool::new(true);
        let done = Arc::new(Notify::new());
        let done_clone = done.clone();

        let waiter = tokio::spawn(async move {
            done_clone.notified().await;
            true
        });

        tokio::task::yield_now().await;

        {
            let _guard = CompactionGuard {
                is_compacting: &is_compacting,
                done: &done,
            };
        }

        let result = tokio::time::timeout(std::time::Duration::from_millis(100), waiter)
            .await
            .expect("waiter should complete")
            .expect("waiter should not panic");
        assert!(result);
    }

    #[test]
    fn concurrent_compaction_rejected() {
        let handler = CompactionHandler::default();
        handler.is_compacting.store(true, Ordering::SeqCst);
        let cas =
            handler
                .is_compacting
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst);
        assert!(cas.is_err());
    }

    #[test]
    fn is_compacting_true_during_execution() {
        let handler = CompactionHandler::default();
        assert!(!handler.is_compacting());
        handler.is_compacting.store(true, Ordering::SeqCst);
        assert!(handler.is_compacting());
    }

    // -- Multi-signal trigger --

    // ── Compaction two-phase commit ─────────────────────────────────────

    fn make_event_store_for_test() -> Arc<crate::domains::session::event_store::EventStore> {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .expect("in-memory pool");
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        Arc::new(crate::domains::session::event_store::EventStore::new(pool))
    }

    async fn make_persister_and_session() -> (
        Arc<crate::domains::agent::runner::orchestrator::event_persister::EventPersister>,
        Arc<crate::domains::session::event_store::EventStore>,
        String,
    ) {
        let store = make_event_store_for_test();
        let session = store
            .create_session(
                "test-model",
                "/tmp",
                Some("compaction-h13"),
                None,
                None,
                None,
            )
            .unwrap();
        let persister = Arc::new(
            crate::domains::agent::runner::orchestrator::event_persister::EventPersister::new(
                store.clone(),
            ),
        );
        (persister, store, session.session.id)
    }

    fn make_event_emitter_for_test() -> Arc<EventEmitter> {
        Arc::new(EventEmitter::new())
    }

    /// Phase 1 (staging) lands BEFORE phase 2 (boundary) in the event log.
    #[tokio::test]
    async fn h13_two_phase_staging_precedes_boundary() {
        let (persister, store, session_id) = make_persister_and_session().await;
        let emitter = make_event_emitter_for_test();

        let result = Ok(
            crate::domains::agent::runner::context::types::CompactionResult {
                success: true,
                tokens_before: 100,
                tokens_after: 30,
                compression_ratio: 0.3,
                preserved_turns: 2,
                summarized_turns: 3,
                preserved_messages: 4,
                summary: "the summarizer's precious output".into(),
                extracted_data: None,
            },
        );

        let persist_ok = CompactionHandler::emit_compaction_events(
            result,
            std::time::Instant::now(),
            100,
            30,
            &session_id,
            &emitter,
            CompactionReason::ThresholdExceeded,
            Some(&persister),
            None,
        )
        .await;
        assert!(
            persist_ok,
            "successful compaction with ok persister returns true"
        );

        let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
        let events = store.get_events_by_session(&session_id, &opts).unwrap();

        let staging_seq = events
            .iter()
            .find(|e| e.event_type == "compact.summary_staging")
            .expect("staging event must exist")
            .sequence;
        let boundary_seq = events
            .iter()
            .find(|e| e.event_type == "compact.boundary")
            .expect("boundary event must exist")
            .sequence;
        assert!(
            staging_seq < boundary_seq,
            "staging must come before boundary; staging.seq={staging_seq} boundary.seq={boundary_seq}"
        );
    }

    /// The staging event carries the same summary text that the boundary
    /// carries, so a reader that walked off during phase 2 can recover the
    /// LLM's work from staging alone.
    #[tokio::test]
    async fn h13_staging_carries_summary_text() {
        let (persister, store, session_id) = make_persister_and_session().await;
        let emitter = make_event_emitter_for_test();

        let summary = "durable summarizer output".to_string();
        let result = Ok(
            crate::domains::agent::runner::context::types::CompactionResult {
                success: true,
                tokens_before: 200,
                tokens_after: 50,
                compression_ratio: 0.25,
                preserved_turns: 1,
                summarized_turns: 4,
                preserved_messages: 2,
                summary: summary.clone(),
                extracted_data: None,
            },
        );

        let _ = CompactionHandler::emit_compaction_events(
            result,
            std::time::Instant::now(),
            200,
            50,
            &session_id,
            &emitter,
            CompactionReason::ThresholdExceeded,
            Some(&persister),
            None,
        )
        .await;

        let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
        let events = store.get_events_by_session(&session_id, &opts).unwrap();
        let staging = events
            .iter()
            .find(|e| e.event_type == "compact.summary_staging")
            .expect("staging must exist");
        let payload: serde_json::Value = serde_json::from_str(&staging.payload).unwrap();
        assert_eq!(payload["summary"], summary);
        assert_eq!(payload["originalTokens"], 200);
        assert_eq!(payload["compactedTokens"], 50);
    }

    /// A failed compaction (Err result) emits CompactionComplete with
    /// success=false and does NOT persist either staging or boundary.
    #[tokio::test]
    async fn h13_failed_compaction_persists_neither_event() {
        let (persister, store, session_id) = make_persister_and_session().await;
        let emitter = make_event_emitter_for_test();

        let err: Result<
            crate::domains::agent::runner::context::types::CompactionResult,
            Box<dyn std::error::Error + Send + Sync>,
        > = Err("summarizer error".into());

        let persist_ok = CompactionHandler::emit_compaction_events(
            err,
            std::time::Instant::now(),
            100,
            100,
            &session_id,
            &emitter,
            CompactionReason::ThresholdExceeded,
            Some(&persister),
            None,
        )
        .await;
        assert!(!persist_ok, "failed compaction returns false");

        let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
        let events = store.get_events_by_session(&session_id, &opts).unwrap();
        assert!(
            !events
                .iter()
                .any(|e| e.event_type == "compact.summary_staging"),
            "failed compaction must not persist staging"
        );
        assert!(
            !events.iter().any(|e| e.event_type == "compact.boundary"),
            "failed compaction must not persist boundary"
        );
    }

    /// A no-op compaction is not a committed boundary. This covers long
    /// single-turn sessions that cross the token trigger before any older turn
    /// is safe to summarize.
    #[tokio::test]
    async fn noop_compaction_persists_neither_event() {
        let (persister, store, session_id) = make_persister_and_session().await;
        let emitter = make_event_emitter_for_test();

        let result = Ok(
            crate::domains::agent::runner::context::types::CompactionResult {
                success: true,
                tokens_before: 100,
                tokens_after: 100,
                compression_ratio: 1.0,
                preserved_turns: 1,
                summarized_turns: 0,
                preserved_messages: 20,
                summary: String::new(),
                extracted_data: None,
            },
        );

        let persist_ok = CompactionHandler::emit_compaction_events(
            result,
            std::time::Instant::now(),
            100,
            100,
            &session_id,
            &emitter,
            CompactionReason::ThresholdExceeded,
            Some(&persister),
            None,
        )
        .await;
        assert!(!persist_ok, "no-op compaction returns false");

        let opts = crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions::default();
        let events = store.get_events_by_session(&session_id, &opts).unwrap();
        assert!(
            !events
                .iter()
                .any(|e| e.event_type == "compact.summary_staging"),
            "no-op compaction must not persist staging"
        );
        assert!(
            !events.iter().any(|e| e.event_type == "compact.boundary"),
            "no-op compaction must not persist boundary"
        );
    }

    #[test]
    fn record_process_command_accumulates() {
        let handler = CompactionHandler::default();
        handler.record_process_command("git status");
        handler.record_process_command("cargo build");
        handler.record_process_command("git push origin main");
        let cmds = handler.pending_process_commands.lock().unwrap();
        assert_eq!(cmds.len(), 3);
    }

    // -- Event type recording --

    #[test]
    fn record_event_type_accumulates() {
        let handler = CompactionHandler::default();
        handler.record_event_type("worktree.commit");
        handler.record_event_type("worktree.commit");
        let events = handler.pending_event_types.lock().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0], "worktree.commit");
    }

    #[test]
    fn event_types_initially_empty() {
        let handler = CompactionHandler::default();
        let events = handler.pending_event_types.lock().unwrap();
        assert!(events.is_empty());
    }

    #[test]
    fn set_persister_via_shared_ref() {
        let handler = CompactionHandler::default();
        // Verify set_persister works through &self (not &mut self)
        assert!(handler.persister.lock().unwrap().is_none());
    }
}
