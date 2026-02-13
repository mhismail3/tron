//! Compaction handler — monitors token usage and triggers compaction.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tron_context::context_manager::ContextManager;
use tron_context::summarizer::KeywordSummarizer;
use tron_core::events::{BaseEvent, CompactionReason, TronEvent};
use tron_hooks::engine::HookEngine;
use tron_hooks::types::{HookAction, HookContext};

use crate::agent::event_emitter::EventEmitter;
use crate::errors::RuntimeError;

/// Compaction handler state.
pub struct CompactionHandler {
    is_compacting: AtomicBool,
}

impl CompactionHandler {
    /// Create a new handler.
    pub fn new() -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
        }
    }

    /// Whether a compaction is in progress.
    pub fn is_compacting(&self) -> bool {
        self.is_compacting.load(Ordering::Relaxed)
    }

    /// Check if compaction is needed and execute if so.
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
        if !context_manager.should_compact() {
            return Ok(false);
        }

        self.execute_compaction(context_manager, hooks, session_id, emitter, reason)
            .await
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
        // Guard against concurrent compaction
        if self
            .is_compacting
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(false);
        }

        let tokens_before = context_manager.get_current_tokens();

        // Execute PreCompact hooks
        if let Some(hook_engine) = hooks {
            let hook_ctx = HookContext::PreCompact {
                session_id: session_id.to_owned(),
                timestamp: chrono::Utc::now().to_rfc3339(),
                current_tokens: tokens_before,
                target_tokens: context_manager.get_context_limit() / 2,
            };
            let result = hook_engine.execute(&hook_ctx).await;
            if result.action == HookAction::Block {
                self.is_compacting.store(false, Ordering::SeqCst);
                return Ok(false);
            }
        }

        // Emit compaction start
        emitter.emit(TronEvent::CompactionStart {
            base: BaseEvent::now(session_id),
            reason: reason.clone(),
            tokens_before,
        });

        // Execute compaction using keyword summarizer as fallback
        let summarizer = KeywordSummarizer;
        let result = context_manager
            .execute_compaction(&summarizer, None)
            .await;

        self.is_compacting.store(false, Ordering::SeqCst);

        match result {
            Ok(compaction_result) => {
                let tokens_after = context_manager.get_current_tokens();
                emitter.emit(TronEvent::CompactionComplete {
                    base: BaseEvent::now(session_id),
                    success: compaction_result.success,
                    tokens_before,
                    tokens_after,
                    compression_ratio: compaction_result.compression_ratio,
                    reason: Some(reason),
                    summary: if compaction_result.summary.is_empty() {
                        None
                    } else {
                        Some(compaction_result.summary)
                    },
                    estimated_context_tokens: Some(tokens_after),
                });
                Ok(true)
            }
            Err(e) => {
                emitter.emit(TronEvent::CompactionComplete {
                    base: BaseEvent::now(session_id),
                    success: false,
                    tokens_before,
                    tokens_after: tokens_before,
                    compression_ratio: 1.0,
                    reason: Some(reason),
                    summary: Some(format!("Compaction failed: {e}")),
                    estimated_context_tokens: Some(tokens_before),
                });
                tracing::warn!("Compaction failed: {e}");
                Ok(false)
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
    }

    #[test]
    fn default_state() {
        let handler = CompactionHandler::default();
        assert!(!handler.is_compacting());
    }
}
