//! Compaction handler for primitive-loop context windows.

use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};

use tokio::sync::Notify;

use crate::domains::agent::context::compaction_trigger::CompactionTrigger;
use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::context::summarizer::KeywordSummarizer;
use crate::domains::agent::context::types::{CompactionTriggerConfig, CompactionTriggerInput};
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::shared::protocol::events::{BaseEvent, CompactionReason, TronEvent};
use metrics::{counter, histogram};
use tracing::{debug, warn};

pub struct CompactionHandler {
    is_compacting: AtomicBool,
    compaction_done: Arc<Notify>,
    persister: Mutex<
        Option<Arc<crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister>>,
    >,
    trigger: Mutex<CompactionTrigger>,
}

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
    pub fn new(trigger_config: CompactionTriggerConfig) -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            compaction_done: Arc::new(Notify::new()),
            persister: Mutex::new(None),
            trigger: Mutex::new(CompactionTrigger::new(trigger_config)),
        }
    }

    pub fn set_persister(
        &self,
        persister: Arc<
            crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister,
        >,
    ) {
        *self.persister.lock().unwrap() = Some(persister);
    }

    pub fn is_compacting(&self) -> bool {
        self.is_compacting.load(Ordering::Relaxed)
    }

    pub async fn wait_for_compaction(&self, timeout: std::time::Duration) {
        if !self.is_compacting.load(Ordering::SeqCst) {
            return;
        }
        let _ = tokio::time::timeout(timeout, self.compaction_done.notified()).await;
    }

    pub async fn check_and_compact(
        &self,
        context_manager: &mut ContextManager,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        sequence_counter: Option<&AtomicI64>,
    ) -> Result<bool, RuntimeError> {
        let context_limit = context_manager.get_context_limit();
        if context_limit == 0 {
            return Ok(false);
        }

        let current_tokens = context_manager.get_current_tokens();
        #[allow(clippy::cast_precision_loss)]
        let token_ratio = current_tokens as f64 / context_limit as f64;
        let trigger_result = self
            .trigger
            .lock()
            .unwrap()
            .should_compact(&CompactionTriggerInput {
                current_token_ratio: token_ratio,
                recent_event_types: Vec::new(),
                recent_capability_invocations: Vec::new(),
            });
        if !trigger_result.compact {
            return Ok(false);
        }

        if !context_manager.has_summarizable_compaction_window() {
            counter!("compaction_total", "status" => "noop").increment(1);
            return Ok(false);
        }

        debug!(
            reason = %trigger_result.reason,
            session_id,
            "compaction triggered"
        );

        let success = self
            .execute_compaction(
                context_manager,
                session_id,
                emitter,
                CompactionReason::ThresholdExceeded,
                sequence_counter,
            )
            .await?;
        if success {
            self.trigger.lock().unwrap().reset();
        }
        Ok(success)
    }

    pub async fn execute_compaction(
        &self,
        context_manager: &mut ContextManager,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
        sequence_counter: Option<&AtomicI64>,
    ) -> Result<bool, RuntimeError> {
        if self
            .is_compacting
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Ok(false);
        }
        let _guard = CompactionGuard {
            is_compacting: &self.is_compacting,
            done: &self.compaction_done,
        };

        let tokens_before = context_manager.get_current_tokens();
        emit_start(
            emitter,
            session_id,
            reason.clone(),
            tokens_before,
            sequence_counter,
        );

        let compaction_start = std::time::Instant::now();
        let summarizer = KeywordSummarizer;
        let result = context_manager.execute_compaction(&summarizer, None).await;
        let effective_result = result.as_ref().is_ok_and(is_effective_compaction_result);
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

    pub(super) async fn emit_compaction_events(
        result: Result<
            crate::domains::agent::context::types::CompactionResult,
            Box<dyn std::error::Error + Send + Sync>,
        >,
        compaction_start: std::time::Instant,
        tokens_before: u64,
        tokens_after: u64,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
        persister: Option<
            &Arc<crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister>,
        >,
        sequence_counter: Option<&AtomicI64>,
    ) -> bool {
        match result {
            Ok(compaction_result) => {
                if !is_effective_compaction_result(&compaction_result) {
                    counter!("compaction_total", "status" => "noop").increment(1);
                    emit_complete(
                        emitter,
                        session_id,
                        false,
                        tokens_before,
                        tokens_before,
                        1.0,
                        Some(reason),
                        Some("Compaction skipped: no durable context reduction.".to_owned()),
                        sequence_counter,
                    );
                    return false;
                }

                let duration = compaction_start.elapsed().as_millis();
                counter!("compaction_total", "status" => "success").increment(1);
                histogram!("compaction_duration_seconds").record(duration as f64 / 1000.0);

                if let Some(persister) = persister {
                    let payload = serde_json::json!({
                        "summary": compaction_result.summary,
                        "tokensBefore": tokens_before,
                        "tokensAfter": tokens_after,
                        "reason": format!("{reason:?}")
                    });
                    let _ = persister
                        .append_with_runtime_sequence(
                            session_id,
                            crate::domains::session::event_store::EventType::CompactBoundary,
                            payload,
                            sequence_counter,
                        )
                        .await;
                }

                emit_complete(
                    emitter,
                    session_id,
                    true,
                    tokens_before,
                    tokens_after,
                    compaction_result.compression_ratio,
                    Some(reason),
                    Some(compaction_result.summary),
                    sequence_counter,
                );
                true
            }
            Err(error) => {
                counter!("compaction_total", "status" => "error").increment(1);
                emit_complete(
                    emitter,
                    session_id,
                    false,
                    tokens_before,
                    tokens_after,
                    1.0,
                    Some(reason),
                    Some(format!("Compaction failed: {error}")),
                    sequence_counter,
                );
                false
            }
        }
    }
}

fn is_effective_compaction_result(
    result: &crate::domains::agent::context::types::CompactionResult,
) -> bool {
    result.success && result.summarized_turns > 0 && result.tokens_after < result.tokens_before
}

fn emit_start(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    reason: CompactionReason,
    tokens_before: u64,
    sequence_counter: Option<&AtomicI64>,
) {
    let event = TronEvent::CompactionStart {
        base: BaseEvent::now(session_id),
        reason,
        tokens_before,
    };
    if let Some(counter) = sequence_counter {
        let _ = emitter.emit_sequenced(event, counter);
    } else {
        let _ = emitter.emit(event);
    }
}

#[allow(clippy::too_many_arguments)]
fn emit_complete(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    success: bool,
    tokens_before: u64,
    tokens_after: u64,
    compression_ratio: f64,
    reason: Option<CompactionReason>,
    summary: Option<String>,
    sequence_counter: Option<&AtomicI64>,
) {
    let event = TronEvent::CompactionComplete {
        base: BaseEvent::now(session_id),
        success,
        tokens_before,
        tokens_after,
        compression_ratio,
        reason,
        summary,
        estimated_context_tokens: Some(tokens_after),
        preserved_turns: None,
        summarized_turns: None,
    };
    if let Some(counter) = sequence_counter {
        let _ = emitter.emit_sequenced(event, counter);
    } else {
        let _ = emitter.emit(event);
    }
}

#[cfg(test)]
mod tests;
