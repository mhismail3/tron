//! Prompt-run completion and recovery.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use tracing::{info, warn};

use super::{
    PromptEngineCausality, PromptRunCleanup, load_session_update_event,
    publish_prompt_runtime_stream,
};
use crate::domains::agent::r#loop::errors::StopReason;
use crate::engine::{ActorId, ActorKind, CausalContext, FunctionId, Invocation, TraceId};
use crate::shared::protocol::events::{BaseEvent, TronEvent, error_event};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::failure::{
    FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_RUN_ERROR,
};

pub(super) struct PromptRunCompletion<'a> {
    pub(super) result: crate::domains::agent::r#loop::types::RunResult,
    pub(super) run_cleanup: &'a mut PromptRunCleanup,
    pub(super) event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub(super) broadcast: Arc<crate::domains::agent::r#loop::EventEmitter>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) engine_causality: Option<PromptEngineCausality>,
    pub(super) session_id: String,
    pub(super) run_id: String,
    pub(super) provider_type: String,
    pub(super) model_for_error: String,
    pub(super) user_prompt: Option<String>,
    pub(super) delivery_wake_ids: Vec<String>,
    pub(super) shutdown_requested: bool,
    pub(super) sequence_counter: Option<Arc<AtomicI64>>,
}

pub(super) async fn finalize_prompt_run(args: PromptRunCompletion<'_>) {
    let PromptRunCompletion {
        result,
        run_cleanup,
        event_store,
        broadcast,
        engine_host,
        engine_causality,
        session_id,
        run_id,
        provider_type,
        model_for_error,
        user_prompt,
        delivery_wake_ids,
        shutdown_requested,
        sequence_counter,
    } = args;

    info!(
        component = "agent.runtime",
        agent_event = "prompt_run_finalizing",
        session_id = %session_id,
        run_id = %run_id,
        provider_type = %provider_type,
        turns_executed = result.turns_executed,
        interrupted = result.interrupted,
        stop_reason = ?result.stop_reason,
        has_error = result.error.is_some(),
        "agent prompt run finalizing"
    );
    if result.interrupted && !shutdown_requested {
        let demotion = event_store
            .demote_leased_agent_wakes(&session_id, &run_id)
            .and_then(|_| event_store.demote_agent_wakes(&session_id, &delivery_wake_ids));
        if let Err(error) = demotion {
            warn!(
                session_id,
                error = %error,
                "failed to demote delivery wakes owned by the cancelled run"
            );
        }
    } else if result.error.is_some()
        && !delivery_wake_ids.is_empty()
        && event_store
            .record_agent_wake_failure(
                &session_id,
                &delivery_wake_ids,
                result
                    .error
                    .as_deref()
                    .unwrap_or("delivery-only run failed"),
            )
            .unwrap_or(false)
    {
        tracing::error!(
            session_id,
            "agent delivery wake exhausted retries and was demoted to passive"
        );
    }
    if let Err(error) = event_store.stale_run_scoped_deliveries(
        crate::domains::session::event_store::AgentDeliverySourceKind::Continuity,
        &run_id,
    ) {
        warn!(
            session_id,
            run_id,
            error = %error,
            "failed to stale late run-scoped continuity delivery"
        );
    }
    // INVARIANT: the active-run slot owns every event that consumes its shared
    // sequence counter. Publish the final session metadata first. Terminal
    // error/idle/ready events and matching run release then share one registry
    // boundary, so event-triggered prompt admission cannot observe SessionBusy
    // and no old terminal event can race a replacement run.
    let title_exchange = if let Some(prompt) = user_prompt {
        load_title_exchange_if_eligible(
            &result,
            engine_causality
                .as_ref()
                .and_then(|causality| causality.context.origin_worker_id()),
            event_store.clone(),
            &session_id,
            prompt,
        )
        .await
    } else {
        None
    };
    emit_session_update(
        &event_store,
        &broadcast,
        &session_id,
        sequence_counter.as_deref(),
    )
    .await;
    let terminal_failure =
        run_error_event_if_needed(&session_id, &provider_type, &model_for_error, &result);
    let released = run_cleanup.release_with_terminal(|| {
        publish_terminal_lifecycle(
            &broadcast,
            &session_id,
            result.error.clone(),
            sequence_counter.as_deref(),
            terminal_failure,
        );
    });
    if released && !shutdown_requested {
        invoke_pending_delivery_wake(&engine_host, &session_id).await;
    }

    info!(
        component = "agent.runtime",
        agent_event = "prompt_run_completed",
        session_id = %session_id,
        run_id = %run_id,
        stop_reason = ?result.stop_reason,
        turns = result.turns_executed,
        interrupted = result.interrupted,
        has_error = result.error.is_some(),
        "prompt run completed"
    );
    publish_prompt_runtime_stream(
        &engine_host,
        engine_causality.as_ref(),
        &session_id,
        "completed",
        serde_json::json!({
            "runId": run_id,
            "turnsExecuted": result.turns_executed,
            "interrupted": result.interrupted,
            "stopReason": format!("{:?}", result.stop_reason),
            "error": result.error,
        }),
    )
    .await;
    if let Some((user_prompt, assistant_response)) = title_exchange {
        invoke_session_title_hook(
            &engine_host,
            engine_causality.as_ref(),
            &session_id,
            &run_id,
            user_prompt,
            assistant_response,
        )
        .await;
    }
}

async fn invoke_pending_delivery_wake(
    engine_host: &crate::engine::EngineHostHandle,
    session_id: &str,
) {
    let Ok(actor_id) = ActorId::new("system:agent-delivery-release") else {
        return;
    };
    let Ok(function_id) = FunctionId::new("agent::delivery_wake") else {
        return;
    };
    let causal = CausalContext::new(actor_id, ActorKind::System, TraceId::generate())
        .with_session_id(session_id.to_owned())
        .with_idempotency_key(format!(
            "agent-delivery-release:{session_id}:{}",
            uuid::Uuid::now_v7()
        ));
    let outcome = engine_host
        .invoke(Invocation::new_sync(
            function_id,
            serde_json::json!({"sessionId":session_id}),
            causal,
        ))
        .await;
    if let Some(error) = outcome.error {
        warn!(
            session_id,
            error = %error,
            "failed to reconsider pending agent wake after run release"
        );
    }
}

fn title_hook_is_eligible(
    result: &crate::domains::agent::r#loop::types::RunResult,
    origin_worker_id: Option<&str>,
) -> bool {
    result.error.is_none()
        && !result.interrupted
        && matches!(
            result.stop_reason,
            StopReason::EndTurn | StopReason::NoToolInvocationDrafts
        )
        && origin_worker_id.is_none()
}

async fn load_title_exchange_if_eligible(
    result: &crate::domains::agent::r#loop::types::RunResult,
    origin_worker_id: Option<&str>,
    event_store: Arc<crate::domains::session::event_store::EventStore>,
    session_id: &str,
    user_prompt: String,
) -> Option<(String, String)> {
    if !title_hook_is_eligible(result, origin_worker_id) {
        return None;
    }
    let preview_session_id = session_id.to_owned();
    let assistant_response = run_blocking_task("agent.prompt.session_title_preview", move || {
        let Some(session) = event_store
            .get_session(&preview_session_id)
            .map_err(|error| crate::shared::server::errors::ToolError::Internal {
                message: error.to_string(),
            })?
        else {
            return Ok(None);
        };
        if session.is_worker_session()
            || session
                .title
                .as_deref()
                .is_some_and(|title| !title.trim().is_empty())
        {
            return Ok(None);
        }
        let session_ids = [preview_session_id.as_str()];
        event_store
            .get_session_message_previews(&session_ids)
            .map(|mut previews| {
                Some(
                    previews
                        .remove(&preview_session_id)
                        .and_then(|preview| preview.last_assistant_response)
                        .unwrap_or_default(),
                )
            })
            .map_err(|error| crate::shared::server::errors::ToolError::Internal {
                message: error.to_string(),
            })
    })
    .await;
    let assistant_response = match assistant_response {
        Ok(Some(assistant_response)) => assistant_response,
        Ok(None) => return None,
        Err(error) => {
            warn!(
                session_id,
                error = %error,
                "failed to load assistant preview for automatic session title"
            );
            return None;
        }
    };
    Some((
        truncate_title_context(&user_prompt),
        truncate_title_context(&assistant_response),
    ))
}

async fn invoke_session_title_hook(
    engine_host: &crate::engine::EngineHostHandle,
    engine_causality: Option<&PromptEngineCausality>,
    session_id: &str,
    run_id: &str,
    user_prompt: String,
    assistant_response: String,
) {
    let Ok(actor_id) = ActorId::new("system:session-title") else {
        return;
    };
    let trace_id = engine_causality
        .map(|causality| causality.context.trace_id.clone())
        .unwrap_or_else(TraceId::generate);
    let mut causal = CausalContext::new(actor_id, ActorKind::System, trace_id)
        .with_session_id(session_id.to_owned())
        .with_trigger_depth(
            engine_causality.map_or(0, |causality| causality.context.trigger_depth()),
        )
        .with_idempotency_key(format!("session-title:{session_id}:{run_id}"));
    if let Some(parent) = engine_causality.map(|causality| causality.invocation_id.clone()) {
        causal = causal.with_parent_invocation(parent);
    }
    let Ok(function_id) = FunctionId::new(crate::domains::worker_kernel::SESSION_TITLE_FUNCTION)
    else {
        return;
    };
    let outcome = engine_host
        .invoke(Invocation::new_sync(
            function_id,
            serde_json::json!({
                "userPrompt":user_prompt,
                "assistantResponse":assistant_response,
            }),
            causal,
        ))
        .await;
    if let Some(error) = outcome.error {
        warn!(
            session_id,
            run_id,
            error = %error,
            "automatic session-title worker failed after successful prompt completion"
        );
    }
}

fn truncate_title_context(value: &str) -> String {
    value.chars().take(4_096).collect()
}

pub(super) fn publish_terminal_lifecycle(
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    session_id: &str,
    error: Option<String>,
    sequence_counter: Option<&AtomicI64>,
    failure_event: Option<TronEvent>,
) {
    emit_maybe_sequenced(
        broadcast,
        TronEvent::AgentEnd {
            base: BaseEvent::now(session_id),
            error,
        },
        sequence_counter,
    );
    if let Some(event) = failure_event {
        emit_maybe_sequenced(broadcast, event, sequence_counter);
    }
    for event in [
        TronEvent::SessionProcessingChanged {
            base: BaseEvent::now(session_id),
            is_processing: false,
        },
        TronEvent::AgentReady {
            base: BaseEvent::now(session_id),
        },
    ] {
        emit_maybe_sequenced(broadcast, event, sequence_counter);
    }
}

fn emit_maybe_sequenced(
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    event: TronEvent,
    sequence_counter: Option<&AtomicI64>,
) {
    if let Some(counter) = sequence_counter {
        let _ = broadcast.emit_sequenced(event, counter);
    } else {
        let _ = broadcast.emit(event);
    }
}

fn run_error_event_if_needed(
    session_id: &str,
    provider_type: &str,
    model_for_error: &str,
    result: &crate::domains::agent::r#loop::types::RunResult,
) -> Option<TronEvent> {
    let Some(ref error_message) = result.error else {
        return None;
    };
    let failure = FailureEnvelope::new(
        RUNTIME_RUN_ERROR,
        FailureCategory::Unknown,
        error_message.clone(),
        false,
        false,
        FailureOrigin::AgentRuntime,
    )
    .with_provider_model(provider_type, model_for_error)
    .with_details(Some(serde_json::json!({ "source": "run_result" })));
    Some(error_event(BaseEvent::now(session_id), &failure, None))
}

async fn emit_session_update(
    event_store: &Arc<crate::domains::session::event_store::EventStore>,
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    session_id: &str,
    sequence_counter: Option<&AtomicI64>,
) {
    match load_session_update_event(event_store.clone(), session_id.to_owned()).await {
        Ok(Some(event)) => {
            if let Some(counter) = sequence_counter {
                let _ = broadcast.emit_sequenced(event, counter);
            } else {
                let _ = broadcast.emit(event);
            }
        }
        Ok(None) => {}
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to load session update event"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn terminal_lifecycle_is_contiguous_and_ready_is_last() {
        let broadcast = Arc::new(crate::domains::agent::r#loop::EventEmitter::new());
        let mut events = broadcast.subscribe();
        let sequence = AtomicI64::new(10);
        let failure = FailureEnvelope::new(
            RUNTIME_RUN_ERROR,
            FailureCategory::Unknown,
            "provider stopped",
            false,
            false,
            FailureOrigin::AgentRuntime,
        );

        publish_terminal_lifecycle(
            &broadcast,
            "session-a",
            Some("provider stopped".to_owned()),
            Some(&sequence),
            Some(error_event(BaseEvent::now("session-a"), &failure, None)),
        );

        let received = [
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
        ];
        assert!(matches!(&received[0], TronEvent::AgentEnd { .. }));
        assert!(matches!(&received[1], TronEvent::Error { .. }));
        assert!(matches!(
            &received[2],
            TronEvent::SessionProcessingChanged {
                is_processing: false,
                ..
            }
        ));
        assert!(matches!(&received[3], TronEvent::AgentReady { .. }));
        assert_eq!(
            received.iter().map(TronEvent::sequence).collect::<Vec<_>>(),
            vec![Some(11), Some(12), Some(13), Some(14)]
        );
    }

    #[test]
    fn session_title_hook_runs_only_after_successful_ordinary_user_completion() {
        let success = crate::domains::agent::r#loop::types::RunResult::default();
        assert!(title_hook_is_eligible(&success, None));
        assert!(!title_hook_is_eligible(&success, Some("worker-a")));

        let mut interrupted = success.clone();
        interrupted.interrupted = true;
        assert!(!title_hook_is_eligible(&interrupted, None));

        let mut failed = success.clone();
        failed.error = Some("provider failed".to_owned());
        assert!(!title_hook_is_eligible(&failed, None));

        let mut exhausted = success;
        exhausted.stop_reason = StopReason::MaxTurns;
        assert!(!title_hook_is_eligible(&exhausted, None));
    }

    #[test]
    fn session_title_context_is_unicode_safe_and_bounded() {
        let input = "🦌".repeat(5_000);
        let projected = truncate_title_context(&input);
        assert_eq!(projected.chars().count(), 4_096);
        assert!(projected.chars().all(|character| character == '🦌'));
    }
}
