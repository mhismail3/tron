//! Compaction handler for primitive-loop context windows.
//!
//! The handler owns the runtime commit boundary for compaction. A summarizer
//! strategy may be injected, but an effective compaction is not committed unless
//! the server records the session-owned compact boundary first. If persistence
//! is unavailable or fails, the handler restores the pre-compaction context
//! checkpoint and emits a failed live event. Turn cancellation is handled inside this owner: if Stop arrives
//! while the summarizer is awaited, the handler restores its checkpoint and
//! pairs the already-emitted start with a failed completion before returning
//! `RuntimeError::Cancelled` to the turn runner.

use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};

use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use crate::domains::agent::context::compaction_trigger::CompactionTrigger;
use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::context::summarizer::{KeywordSummarizer, Summarizer};
use crate::domains::agent::context::types::{CompactionTriggerConfig, CompactionTriggerInput};
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::EventType;
use crate::shared::protocol::events::{BaseEvent, CompactionReason, TronEvent};
use metrics::{counter, histogram};
use serde_json::json;
use tracing::{debug, warn};

pub struct CompactionHandler {
    is_compacting: AtomicBool,
    compaction_done: Arc<Notify>,
    persister: Mutex<
        Option<Arc<crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister>>,
    >,
    session_manager: Mutex<Option<Arc<SessionManager>>>,
    trigger: Mutex<CompactionTrigger>,
    summarizer: Arc<dyn Summarizer>,
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
        Self::with_summarizer(trigger_config, Arc::new(KeywordSummarizer::new()))
    }

    /// Build a compaction handler with an explicit summarizer strategy.
    ///
    /// Production uses [`KeywordSummarizer`] through [`Self::new`]. This
    /// constructor keeps the loop boundary replaceable so a future
    /// engine-owned compaction strategy can be injected without changing
    /// context-control records, session persistence, or iOS presentation code.
    /// Replacement strategies still commit through the same server-owned proof
    /// path; the strategy seam is summary generation, not custody.
    pub fn with_summarizer(
        trigger_config: CompactionTriggerConfig,
        summarizer: Arc<dyn Summarizer>,
    ) -> Self {
        Self {
            is_compacting: AtomicBool::new(false),
            compaction_done: Arc::new(Notify::new()),
            persister: Mutex::new(None),
            session_manager: Mutex::new(None),
            trigger: Mutex::new(CompactionTrigger::new(trigger_config)),
            summarizer,
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

    pub(crate) fn set_session_manager(&self, session_manager: Arc<SessionManager>) {
        *self.session_manager.lock().unwrap() = Some(session_manager);
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
        cancel: &CancellationToken,
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
            .execute_compaction_inner(
                context_manager,
                session_id,
                emitter,
                CompactionReason::ThresholdExceeded,
                sequence_counter,
                Some(cancel),
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
        self.execute_compaction_inner(
            context_manager,
            session_id,
            emitter,
            reason,
            sequence_counter,
            None,
        )
        .await
    }

    async fn execute_compaction_inner(
        &self,
        context_manager: &mut ContextManager,
        session_id: &str,
        emitter: &Arc<EventEmitter>,
        reason: CompactionReason,
        sequence_counter: Option<&AtomicI64>,
        cancel: Option<&CancellationToken>,
    ) -> Result<bool, RuntimeError> {
        if cancel.is_some_and(CancellationToken::is_cancelled) {
            return Err(RuntimeError::Cancelled);
        }
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
        let checkpoint = context_manager.compaction_checkpoint();
        let result = if let Some(cancel) = cancel {
            tokio::select! {
                () = cancel.cancelled() => {
                    context_manager.restore_compaction_checkpoint(checkpoint);
                    emit_complete(
                        emitter,
                        session_id,
                        false,
                        tokens_before,
                        tokens_before,
                        1.0,
                        Some(reason),
                        Some("Compaction cancelled; the original context was restored.".to_owned()),
                        sequence_counter,
                    );
                    return Err(RuntimeError::Cancelled);
                }
                result = context_manager.execute_compaction(self.summarizer.as_ref(), None) => result,
            }
        } else {
            context_manager
                .execute_compaction(self.summarizer.as_ref(), None)
                .await
        };
        let effective_result = result.as_ref().is_ok_and(is_effective_compaction_result);
        let tokens_after = context_manager.get_current_tokens();

        // Once boundary persistence begins it is allowed to finish so
        // cancellation cannot drop a partially committed context transition.
        if cancel.is_some_and(CancellationToken::is_cancelled) {
            context_manager.restore_compaction_checkpoint(checkpoint);
            emit_complete(
                emitter,
                session_id,
                false,
                tokens_before,
                tokens_before,
                1.0,
                Some(reason),
                Some("Compaction cancelled; the original context was restored.".to_owned()),
                sequence_counter,
            );
            return Err(RuntimeError::Cancelled);
        }

        if tokens_after >= tokens_before && effective_result {
            warn!(
                session_id,
                tokens_before, tokens_after, "compaction did not reduce token count"
            );
        }

        let persister = self.persister.lock().unwrap().clone();
        let session_manager = self.session_manager.lock().unwrap().clone();
        let persisted = Self::emit_compaction_events(
            result,
            compaction_start,
            tokens_before,
            tokens_after,
            session_id,
            emitter,
            reason,
            session_manager.as_ref(),
            persister.as_ref(),
            sequence_counter,
        )
        .await;
        if effective_result && !persisted {
            context_manager.restore_compaction_checkpoint(checkpoint);
        }
        Ok(persisted)
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
        session_manager: Option<&Arc<SessionManager>>,
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
                let reason_label = compaction_reason_label(&reason);

                let Some(session_manager) = session_manager else {
                    counter!("compaction_total", "status" => "proof_missing").increment(1);
                    warn!(
                        session_id,
                        "compaction boundary unavailable because the session manager is not configured"
                    );
                    emit_complete(
                        emitter,
                        session_id,
                        false,
                        tokens_before,
                        tokens_before,
                        1.0,
                        Some(reason),
                        Some(
                            "Compaction failed closed: session boundary custody is unavailable."
                                .to_owned(),
                        ),
                        sequence_counter,
                    );
                    return false;
                };
                let Some(persister) = persister else {
                    counter!("compaction_total", "status" => "proof_missing").increment(1);
                    warn!(
                        session_id,
                        "compaction proof missing because event persister is not configured"
                    );
                    emit_complete(
                        emitter,
                        session_id,
                        false,
                        tokens_before,
                        tokens_before,
                        1.0,
                        Some(reason),
                        Some(
                            "Compaction failed closed: event persistence is unavailable."
                                .to_owned(),
                        ),
                        sequence_counter,
                    );
                    return false;
                };

                let boundary = persister.append_with_runtime_sequence(
                    session_id,
                    EventType::CompactBoundary,
                    json!({
                        "originalTokens": tokens_before,
                        "compactedTokens": tokens_after,
                        "compressionRatio": compaction_result.compression_ratio,
                        "reason": reason_label,
                        "summary": bounded_summary(&compaction_result.summary),
                        "estimatedContextTokens": tokens_after
                    }),
                    sequence_counter,
                );
                if let Err(error) = boundary {
                    counter!("compaction_total", "status" => "proof_error").increment(1);
                    warn!(
                        session_id,
                        error = %error,
                        "failed to record automatic compaction boundary"
                    );
                    emit_complete(
                        emitter,
                        session_id,
                        false,
                        tokens_before,
                        tokens_before,
                        1.0,
                        Some(reason),
                        Some("Compaction failed closed: boundary persistence failed.".to_owned()),
                        sequence_counter,
                    );
                    return false;
                }
                session_manager.invalidate_session(session_id);

                counter!("compaction_total", "status" => "success").increment(1);
                histogram!("compaction_duration_seconds").record(duration as f64 / 1000.0);

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

fn compaction_reason_label(reason: &CompactionReason) -> String {
    serde_json::to_value(reason)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| format!("{reason:?}"))
}

fn bounded_summary(summary: &str) -> String {
    const MAX_BYTES: usize = 4_000;
    if summary.len() <= MAX_BYTES {
        return summary.to_owned();
    }
    let end = summary
        .char_indices()
        .map(|(index, _)| index)
        .take_while(|index| *index <= MAX_BYTES)
        .last()
        .unwrap_or(0);
    summary[..end].to_owned()
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
