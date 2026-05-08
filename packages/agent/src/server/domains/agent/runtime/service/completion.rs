//! Prompt-run completion, recovery, and follow-up queue handoff.

use std::sync::Arc;

use tracing::{debug, warn};

use super::{
    PromptEngineCausality, PromptRunCleanup, enqueue_prompt_queue_drain, load_session_update_data,
    publish_prompt_runtime_stream, retain_eligible,
};
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};

pub(super) struct PromptRunCompletion<'a> {
    pub(super) result: crate::runtime::types::RunResult,
    pub(super) persister: Arc<crate::runtime::orchestrator::event_persister::EventPersister>,
    pub(super) run_cleanup: &'a mut PromptRunCleanup,
    pub(super) session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    pub(super) event_store: Arc<crate::events::EventStore>,
    pub(super) broadcast: Arc<crate::runtime::EventEmitter>,
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
    maybe_fire_auto_retain(
        &result,
        &engine_host,
        engine_causality.as_ref(),
        &session_id,
        &run_id,
    );

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
        }),
    )
    .await;

    // Auto-drain is hidden engine queue work. Completion only enqueues the
    // drain capability, so queue handoff, trace propagation, and idempotency
    // remain visible through the engine ledger and stream records.
    enqueue_prompt_queue_drain(
        &engine_host,
        &session_id,
        &run_id,
        engine_causality.as_ref(),
    )
    .await;
}

async fn persist_interrupted_if_needed(
    persister: &Arc<crate::runtime::orchestrator::event_persister::EventPersister>,
    session_id: &str,
    result: &crate::runtime::types::RunResult,
) {
    if !result.interrupted {
        return;
    }
    if let Err(error) = persister
        .append(
            session_id,
            crate::events::EventType::NotificationInterrupted,
            serde_json::json!({
                "timestamp": chrono::Utc::now().to_rfc3339(),
                "turn": result.turns_executed,
            }),
        )
        .await
    {
        tracing::error!(
            session_id = %session_id,
            error = %error,
            "failed to persist notification.interrupted"
        );
    }
    let _ = persister.flush().await;
}

fn emit_run_error_if_needed(
    broadcast: &Arc<crate::runtime::EventEmitter>,
    session_id: &str,
    provider_type: &str,
    model_for_error: &str,
    result: &crate::runtime::types::RunResult,
) {
    let Some(ref error_message) = result.error else {
        return;
    };
    let parsed = crate::core::errors::parse::parse_error(error_message);
    let _ = broadcast.emit(crate::core::events::TronEvent::Error {
        base: crate::core::events::BaseEvent::now(session_id),
        error: error_message.clone(),
        context: None,
        code: None,
        provider: Some(provider_type.to_owned()),
        category: Some(parsed.category.to_string()),
        suggestion: parsed.suggestion,
        retryable: Some(parsed.is_retryable),
        status_code: None,
        error_type: Some(parsed.category.to_string()),
        model: Some(model_for_error.to_owned()),
    });
}

fn maybe_fire_auto_retain(
    result: &crate::runtime::types::RunResult,
    engine_host: &crate::engine::EngineHostHandle,
    engine_causality: Option<&PromptEngineCausality>,
    session_id: &str,
    run_id: &str,
) {
    if result.error.is_some() || result.interrupted || !retain_eligible(&result.stop_reason) {
        return;
    }
    let function_id = match FunctionId::new("memory::auto_retain_fire") {
        Ok(function_id) => function_id,
        Err(error) => {
            warn!(session_id, run_id, error = %error, "invalid auto-retain function id");
            return;
        }
    };
    let mut context = engine_causality
        .map(|causality| causality.context.clone())
        .unwrap_or_else(|| {
            CausalContext::new(
                ActorId::new("system").expect("valid static actor id"),
                ActorKind::System,
                AuthorityGrantId::new("agent-runtime").expect("valid static grant id"),
                TraceId::generate(),
            )
        });
    for scope in ["memory.write", ENGINE_INTERNAL_INVOKE_SCOPE] {
        if !context
            .authority_scopes
            .iter()
            .any(|existing| existing == scope)
        {
            context.authority_scopes.push(scope.to_owned());
        }
    }
    context.session_id = Some(session_id.to_owned());
    context.parent_invocation_id =
        engine_causality.and_then(|causality| causality.parent_invocation_id.clone());
    context.idempotency_key = Some(format!("memory.auto_retain:{session_id}:{run_id}"));
    let host = engine_host.clone();
    let payload = serde_json::json!({
        "sessionId": session_id,
        "runId": run_id,
        "workspaceId": context.workspace_id.clone(),
    });
    drop(tokio::spawn(async move {
        let result = host
            .invoke(Invocation::new_sync(function_id.clone(), payload, context))
            .await;
        if let Some(error) = result.error {
            warn!(function_id = %function_id, error = %error, "auto-retain engine invocation failed");
        }
    }));
}

async fn emit_session_update(
    session_manager: &Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    event_store: &Arc<crate::events::EventStore>,
    broadcast: &Arc<crate::runtime::EventEmitter>,
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
            let _ = broadcast.emit(crate::core::events::TronEvent::SessionUpdated {
                base: crate::core::events::BaseEvent::now(session_id),
                title: update.session.title.clone(),
                model: Some(update.session.latest_model.clone()),
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
