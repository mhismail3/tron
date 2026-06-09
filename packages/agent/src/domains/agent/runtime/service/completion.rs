//! Prompt-run completion and recovery.

use std::sync::Arc;

use tracing::{debug, warn};

use super::{
    PromptEngineCausality, PromptRunCleanup, load_session_update_data,
    publish_prompt_runtime_stream,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::protocol::events::{BaseEvent, error_event};
use crate::shared::server::failure::{
    FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_CANCELLED, RUNTIME_RUN_ERROR,
};

pub(super) struct PromptRunCompletion<'a> {
    pub(super) result: crate::domains::agent::r#loop::types::RunResult,
    pub(super) persister:
        Arc<crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister>,
    pub(super) run_cleanup: &'a mut PromptRunCleanup,
    pub(super) session_manager:
        Arc<crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager>,
    pub(super) event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub(super) broadcast: Arc<crate::domains::agent::r#loop::EventEmitter>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) engine_causality: Option<PromptEngineCausality>,
    pub(super) session_id: String,
    pub(super) run_id: String,
    pub(super) provider_type: String,
    pub(super) model_for_error: String,
}

pub(super) async fn finalize_prompt_run(args: PromptRunCompletion<'_>) {
    let PromptRunCompletion {
        result,
        persister,
        run_cleanup,
        session_manager,
        event_store,
        broadcast,
        engine_host,
        engine_causality,
        session_id,
        run_id,
        provider_type,
        model_for_error,
    } = args;

    let _ = persister.flush().await;
    persist_interrupted_if_needed(&persister, &session_id, &result).await;
    emit_run_error_if_needed(
        &broadcast,
        &session_id,
        &provider_type,
        &model_for_error,
        &result,
    );
    let agent_result_refs = create_agent_result_resource(
        &engine_host,
        engine_causality.as_ref(),
        &session_id,
        &run_id,
        &result,
    )
    .await;

    run_cleanup.release();
    emit_session_update(&session_manager, &event_store, &broadcast, &session_id).await;

    debug!(
        session_id = %session_id,
        run_id = %run_id,
        stop_reason = ?result.stop_reason,
        turns = result.turns_executed,
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
            "resourceRefs": agent_result_refs.unwrap_or_default(),
        }),
    )
    .await;
}

async fn create_agent_result_resource(
    engine_host: &crate::engine::EngineHostHandle,
    causality: Option<&PromptEngineCausality>,
    session_id: &str,
    run_id: &str,
    result: &crate::domains::agent::r#loop::types::RunResult,
) -> Option<Vec<serde_json::Value>> {
    let mut context = causality
        .map(|causality| causality.context.clone())
        .unwrap_or_else(|| {
            CausalContext::new(
                ActorId::new("system:agent").expect("valid actor id"),
                ActorKind::System,
                AuthorityGrantId::new("engine-system").expect("valid grant"),
                TraceId::generate(),
            )
        });
    context.actor_id = ActorId::new("system:agent").expect("valid actor id");
    context.actor_kind = ActorKind::System;
    context.authority_grant_id = AuthorityGrantId::new("engine-system").expect("valid grant");
    if context.session_id.is_none() {
        context = context.with_session_id(session_id.to_owned());
    }
    if let Some(causality) = causality {
        context = context.with_parent_invocation(causality.invocation_id.clone());
    }
    context = context
        .with_scope("resource.write")
        .with_idempotency_key(format!("agent-result:{run_id}"));
    let payload = serde_json::json!({
        "kind": "agent_result",
        "scope": "session",
        "sessionId": session_id,
        "payload": {
            "message": result.error.clone().unwrap_or_default(),
            "promotedRefs": [],
            "decisionRefs": [],
            "subgoalRefs": [],
            "stopReason": format!("{:?}", result.stop_reason),
            "tokenUsage": &result.total_token_usage,
            "metadata": {
                "runId": run_id,
                "turnsExecuted": result.turns_executed,
                "interrupted": result.interrupted,
                "lastContextWindowTokens": result.last_context_window_tokens
            }
        }
    });
    let invocation = Invocation::new_sync(
        FunctionId::new("resource::create").expect("valid function id"),
        payload,
        context,
    );
    let result = engine_host.invoke(invocation).await;
    if let Some(error) = result.error {
        warn!(?error, run_id, "failed to create agent_result resource");
        return None;
    }
    result.value.and_then(|value| {
        value
            .get("resourceRefs")
            .and_then(serde_json::Value::as_array)
            .cloned()
    })
}

async fn persist_interrupted_if_needed(
    persister: &Arc<crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister>,
    session_id: &str,
    result: &crate::domains::agent::r#loop::types::RunResult,
) {
    if !result.interrupted {
        return;
    }
    if let Err(error) = persister
        .append(
            session_id,
            crate::domains::session::event_store::EventType::TurnFailed,
            serde_json::json!({
                "turn": result.turns_executed,
                "error": "Interrupted by user",
                "code": RUNTIME_CANCELLED,
                "category": FailureCategory::Cancelled.as_str(),
                "retryable": false,
                "recoverable": true,
                "origin": FailureOrigin::AgentRuntime.as_str(),
                "partialContent": null,
            }),
        )
        .await
    {
        tracing::error!(
            session_id = %session_id,
            error = %error,
            "failed to persist interrupted turn failure"
        );
    }
    let _ = persister.flush().await;
}

fn emit_run_error_if_needed(
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    session_id: &str,
    provider_type: &str,
    model_for_error: &str,
    result: &crate::domains::agent::r#loop::types::RunResult,
) {
    let Some(ref error_message) = result.error else {
        return;
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
    let _ = broadcast.emit(error_event(BaseEvent::now(session_id), &failure, None));
}

async fn emit_session_update(
    session_manager: &Arc<
        crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager,
    >,
    event_store: &Arc<crate::domains::session::event_store::EventStore>,
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    session_id: &str,
) {
    match load_session_update_data(
        session_manager.clone(),
        event_store.clone(),
        session_id.to_owned(),
    )
    .await
    {
        Ok(Some(update)) => {
            let _ = broadcast.emit(crate::shared::protocol::events::TronEvent::SessionUpdated {
                base: crate::shared::protocol::events::BaseEvent::now(session_id),
                title: update.session.title.clone(),
                model: Some(update.session.latest_model.clone()),
                event_count: Some(update.session.event_count),
                turn_count: Some(update.session.turn_count),
                message_count: Some(update.session.message_count),
                input_tokens: Some(update.session.total_input_tokens),
                output_tokens: Some(update.session.total_output_tokens),
                last_turn_input_tokens: Some(update.session.last_turn_input_tokens),
                cache_read_tokens: Some(update.session.total_cache_read_tokens),
                cache_creation_tokens: Some(update.session.total_cache_creation_tokens),
                cost: Some(update.session.total_cost),
                last_activity: update.session.last_activity_at.clone(),
                is_active: false,
                last_user_prompt: update
                    .preview
                    .as_ref()
                    .and_then(|preview| preview.last_user_prompt.clone()),
                last_assistant_response: update
                    .preview
                    .as_ref()
                    .and_then(|preview| preview.last_assistant_response.clone()),
                parent_session_id: update.session.parent_session_id.clone(),
                activity_lines: Some(update.activity_lines),
            });
        }
        Ok(None) => {}
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to load session update data"
            );
        }
    }
}
