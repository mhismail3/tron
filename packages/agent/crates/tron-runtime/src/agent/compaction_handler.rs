//! Compaction handler — sole owner of compaction logic.
//!
//! Uses multi-signal triggering: token threshold, turn count fallback,
//! and progress signals (git push, gh pr, etc.). Runs at pre-turn.

use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::Notify;

use crate::context::context_manager::ContextManager;
use crate::context::summarizer::KeywordSummarizer;
use crate::hooks::engine::HookEngine;
use crate::hooks::types::{HookAction, HookContext};
use async_trait::async_trait;
use tron_core::events::HookResult as EventHookResult;
use tron_core::events::{BaseEvent, CompactionReason, TronEvent};
use tron_events::memory::trigger::CompactionTrigger;
use tron_events::memory::types::{CompactionTriggerConfig, CompactionTriggerInput};

use metrics::{counter, histogram};
use tracing::{debug, info};

use crate::agent::event_emitter::EventEmitter;
use crate::errors::RuntimeError;
use crate::orchestrator::subagent_manager::{SubagentManager, SubsessionConfig};
use crate::types::ReasoningLevel;

// =============================================================================
// SubagentManagerSpawner — the single SubsessionSpawner implementation
// =============================================================================

/// [`SubsessionSpawner`](crate::context::llm_summarizer::SubsessionSpawner) that
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
impl crate::context::llm_summarizer::SubsessionSpawner for SubagentManagerSpawner {
    async fn spawn_summarizer(
        &self,
        task: &str,
    ) -> crate::context::llm_summarizer::SubsessionResult {
        match self
            .manager
            .spawn_subsession(SubsessionConfig {
                parent_session_id: self.parent_session_id.clone(),
                task: task.to_owned(),
                model: self.model.clone(),
                system_prompt: self.system_prompt.clone(),
                working_directory: self.working_directory.clone(),
                inherit_tools: false,
                max_turns: 1,
                max_depth: 0,
                reasoning_level: Some(ReasoningLevel::Medium),
                ..SubsessionConfig::default()
            })
            .await
        {
            Ok(result) => crate::context::llm_summarizer::SubsessionResult {
                success: true,
                output: Some(result.output),
                error: None,
            },
            Err(e) => crate::context::llm_summarizer::SubsessionResult {
                success: false,
                output: None,
                error: Some(e.to_string()),
            },
        }
    }
}

// =============================================================================
// SubagentContentSummarizer — ContentSummarizer for WebFetch
// =============================================================================

/// [`ContentSummarizer`](tron_tools::traits::ContentSummarizer) that wraps
/// `SubagentManager::spawn_subsession()` to summarize web page content via Haiku.
pub struct SubagentContentSummarizer {
    /// The subagent manager to spawn through.
    pub manager: Arc<SubagentManager>,
}

#[async_trait]
impl tron_tools::traits::ContentSummarizer for SubagentContentSummarizer {
    async fn summarize(
        &self,
        task: &str,
        parent_session_id: &str,
    ) -> Result<tron_tools::traits::SummarizerResult, tron_tools::errors::ToolError> {
        let result = self
            .manager
            .spawn_subsession(SubsessionConfig {
                parent_session_id: parent_session_id.to_owned(),
                task: task.to_owned(),
                model: None, // defaults to SUBAGENT_MODEL (Haiku 4.5)
                system_prompt: "You are a web content summarizer. Answer questions concisely based on the provided content.".into(),
                working_directory: "/tmp".into(),
                inherit_tools: false,
                max_turns: 1,
                max_depth: 0,
                reasoning_level: None,
                ..SubsessionConfig::default()
            })
            .await
            .map_err(|e| tron_tools::errors::ToolError::Internal {
                message: format!("Summarizer subsession failed: {e}"),
            })?;

        Ok(tron_tools::traits::SummarizerResult {
            answer: result.output,
            session_id: result.session_id,
        })
    }
}

// =============================================================================
// CompactionHandler
// =============================================================================

/// Compaction handler state — sole owner of all compaction logic.
///
/// Uses multi-signal triggering via `CompactionTrigger`:
/// 1. Token threshold (safety net)
/// 2. Progress signals (git push, gh pr, etc.)
/// 3. Turn count fallback (shorter in alert zone)
pub struct CompactionHandler {
    is_compacting: AtomicBool,
    compaction_done: Arc<Notify>,
    subagent_manager: Option<Arc<SubagentManager>>,
    /// Optional event persister for `compact.boundary` persistence.
    persister: Option<Arc<crate::orchestrator::event_persister::EventPersister>>,
    /// Multi-signal compaction trigger.
    trigger: Mutex<CompactionTrigger>,
    /// Bash commands accumulated between compactions for progress-signal detection.
    pending_bash_commands: Mutex<Vec<String>>,
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
    pub fn new() -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            compaction_done: Arc::new(Notify::new()),
            subagent_manager: None,
            persister: None,
            trigger: Mutex::new(CompactionTrigger::new(CompactionTriggerConfig::default())),
            pending_bash_commands: Mutex::new(Vec::new()),
        }
    }

    /// Create a handler with a `SubagentManager` for subsession-backed summaries.
    pub fn with_subagent_manager(manager: Arc<SubagentManager>) -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            compaction_done: Arc::new(Notify::new()),
            subagent_manager: Some(manager),
            persister: None,
            trigger: Mutex::new(CompactionTrigger::new(CompactionTriggerConfig::default())),
            pending_bash_commands: Mutex::new(Vec::new()),
        }
    }

    /// Set the event persister for `compact.boundary` persistence.
    pub fn set_persister(
        &mut self,
        persister: Arc<crate::orchestrator::event_persister::EventPersister>,
    ) {
        self.persister = Some(persister);
    }

    /// Whether a compaction is in progress.
    pub fn is_compacting(&self) -> bool {
        self.is_compacting.load(Ordering::Relaxed)
    }

    /// Record a bash command for progress-signal detection.
    /// Called by turn_runner after each bash tool execution.
    pub fn record_bash_command(&self, command: &str) {
        self.pending_bash_commands
            .lock()
            .unwrap()
            .push(command.to_owned());
    }

    /// Get the current turn count since last compaction.
    pub fn turns_since_compaction(&self) -> u32 {
        self.trigger.lock().unwrap().turns_since_compaction()
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
    /// Returns `true` if compaction was performed.
    pub async fn check_and_compact(
        &self,
        context_manager: &mut ContextManager,
        hooks: &Option<Arc<HookEngine>>,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
    ) -> Result<bool, RuntimeError> {
        // Build trigger input from current state
        let current_tokens = context_manager.get_current_tokens();
        let context_limit = context_manager.get_context_limit();
        #[allow(clippy::cast_precision_loss)]
        let token_ratio = if context_limit > 0 {
            current_tokens as f64 / context_limit as f64
        } else {
            0.0
        };

        let pending_commands = self.pending_bash_commands.lock().unwrap().clone();
        let trigger_input = CompactionTriggerInput {
            current_token_ratio: token_ratio,
            recent_event_types: Vec::new(), // No DB event access at pre-turn
            recent_tool_calls: pending_commands,
        };

        let trigger_result = self.trigger.lock().unwrap().should_compact(&trigger_input);
        if !trigger_result.compact {
            return Ok(false);
        }

        debug!(
            reason = %trigger_result.reason,
            session_id,
            "compaction triggered by multi-signal"
        );

        let success = self
            .execute_compaction(context_manager, hooks, session_id, emitter, reason)
            .await?;

        if success {
            self.trigger.lock().unwrap().reset();
            self.pending_bash_commands.lock().unwrap().clear();
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
        )
        .await
        {
            return Ok(false);
        }

        let _ = emitter.emit(TronEvent::CompactionStart {
            base: BaseEvent::now(session_id),
            reason: reason.clone(),
            tokens_before,
        });

        let compaction_start = std::time::Instant::now();

        let result =
            Self::run_summarizer(context_manager, session_id, self.subagent_manager.as_ref()).await;

        Ok(Self::emit_compaction_events(
            result,
            compaction_start,
            tokens_before,
            context_manager.get_current_tokens(),
            session_id,
            emitter,
            reason,
            self.persister.as_ref(),
        ))
    }

    /// Execute `PreCompact` hooks; returns `false` if hooks blocked compaction.
    async fn execute_precompact_hooks(
        hooks: Option<&Arc<HookEngine>>,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        current_tokens: u64,
        context_limit: u64,
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
        let _ = emitter.emit(TronEvent::HookTriggered {
            base: BaseEvent::now(session_id),
            hook_names: vec![],
            hook_event: "PreCompact".into(),
            tool_name: None,
            tool_call_id: None,
        });
        let result = hook_engine.execute(&hook_ctx).await;
        let event_result = match result.action {
            HookAction::Block => EventHookResult::Block,
            HookAction::Modify => EventHookResult::Modify,
            HookAction::Continue => EventHookResult::Continue,
        };
        let _ = emitter.emit(TronEvent::HookCompleted {
            base: BaseEvent::now(session_id),
            hook_names: vec![],
            hook_event: "PreCompact".into(),
            result: event_result,
            duration: None,
            reason: result.reason.clone(),
            tool_name: None,
            tool_call_id: None,
        });
        result.action != HookAction::Block
    }

    async fn run_summarizer(
        context_manager: &mut ContextManager,
        session_id: &str,
        subagent_manager: Option<&Arc<SubagentManager>>,
    ) -> Result<crate::context::types::CompactionResult, Box<dyn std::error::Error + Send + Sync>>
    {
        if let Some(manager) = subagent_manager {
            let spawner = SubagentManagerSpawner {
                manager: manager.clone(),
                parent_session_id: session_id.to_owned(),
                working_directory: context_manager.get_working_directory().to_owned(),
                system_prompt: crate::context::system_prompts::COMPACTION_SUMMARIZER_PROMPT
                    .to_string(),
                model: None,
            };
            let summarizer = crate::context::llm_summarizer::LlmSummarizer::new(spawner);
            context_manager.execute_compaction(&summarizer, None).await
        } else {
            let summarizer = KeywordSummarizer;
            context_manager.execute_compaction(&summarizer, None).await
        }
    }

    fn emit_compaction_events(
        result: Result<
            crate::context::types::CompactionResult,
            Box<dyn std::error::Error + Send + Sync>,
        >,
        compaction_start: std::time::Instant,
        tokens_before: u64,
        tokens_after: u64,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
        persister: Option<&Arc<crate::orchestrator::event_persister::EventPersister>>,
    ) -> bool {
        match result {
            Ok(compaction_result) => {
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
                let _ = emitter.emit(TronEvent::CompactionComplete {
                    base: BaseEvent::now(session_id),
                    success: compaction_result.success,
                    tokens_before,
                    tokens_after,
                    compression_ratio: compaction_result.compression_ratio,
                    reason: Some(reason.clone()),
                    summary: summary_text.clone(),
                    estimated_context_tokens: Some(tokens_after),
                });

                if compaction_result.success
                    && let Some(persister) = persister
                {
                    let reason_str = format!("{reason:?}");
                    #[allow(clippy::cast_possible_wrap)]
                    let payload = serde_json::json!({
                        "originalTokens": tokens_before as i64,
                        "compactedTokens": tokens_after as i64,
                        "compressionRatio": compaction_result.compression_ratio,
                        "reason": reason_str,
                        "summary": summary_text,
                        "estimatedContextTokens": tokens_after as i64,
                    });
                    persister.append_fire_and_forget(
                        session_id,
                        tron_events::EventType::CompactBoundary,
                        payload,
                    );
                }
                true
            }
            Err(e) => {
                let _ = emitter.emit(TronEvent::CompactionComplete {
                    base: BaseEvent::now(session_id),
                    success: false,
                    tokens_before,
                    tokens_after: tokens_before,
                    compression_ratio: 1.0,
                    reason: Some(reason),
                    summary: Some(format!("Compaction failed: {e}")),
                    estimated_context_tokens: Some(tokens_before),
                });
                counter!("compaction_total", "status" => "failure").increment(1);
                tracing::warn!(session_id, tokens_before, error = %e, "compaction failed");
                false
            }
        }
    }
}

impl Default for CompactionHandler {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_state() {
        let handler = CompactionHandler::new();
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
        let handler = CompactionHandler::new();
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
        let handler = CompactionHandler::new();
        handler.is_compacting.store(true, Ordering::SeqCst);
        let cas =
            handler
                .is_compacting
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst);
        assert!(cas.is_err());
    }

    #[test]
    fn is_compacting_true_during_execution() {
        let handler = CompactionHandler::new();
        assert!(!handler.is_compacting());
        handler.is_compacting.store(true, Ordering::SeqCst);
        assert!(handler.is_compacting());
    }

    // -- Multi-signal trigger --

    #[test]
    fn record_bash_command_accumulates() {
        let handler = CompactionHandler::new();
        handler.record_bash_command("git status");
        handler.record_bash_command("cargo build");
        handler.record_bash_command("git push origin main");
        let cmds = handler.pending_bash_commands.lock().unwrap();
        assert_eq!(cmds.len(), 3);
    }

    #[test]
    fn turns_since_compaction_starts_at_zero() {
        let handler = CompactionHandler::new();
        assert_eq!(handler.turns_since_compaction(), 0);
    }
}
