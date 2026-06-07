use super::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, ENGINE_INTERNAL_INVOKE_SCOPE,
    EngineQueueDrainer, EnqueueInvocation, FunctionId, FunctionRevision, PromptDrainOutcome,
    PromptEngineCausality, PromptRequest, PromptRunPlan, TraceId, execute_prompt_run,
};
use crate::engine::queue::publish_queue_lifecycle_event;
use crate::shared::server::errors::CapabilityError;
use std::sync::Arc;
use tracing::debug;
use tracing::warn;

/// Check the prompt queue for the session and, if there is a pending message,
/// dequeue it and spawn a new prompt run for it.
#[allow(clippy::too_many_arguments)]
pub(crate) fn drain_prompt_queue(
    event_store: &Arc<crate::domains::session::event_store::EventStore>,
    orchestrator: &Arc<crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator>,
    session_manager: &Arc<
        crate::domains::agent::runner::orchestrator::session_manager::SessionManager,
    >,
    session_id: &str,
    model: &str,
    working_dir: &str,
    broadcast: Arc<crate::domains::agent::runner::EventEmitter>,
    provider_factory: Arc<dyn crate::domains::model::providers::provider::ProviderFactory>,
    health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
    shutdown_token: Option<tokio_util::sync::CancellationToken>,
    server_origin: String,
    engine_host: crate::engine::EngineHostHandle,
    engine_causality: Option<PromptEngineCausality>,
) -> Result<PromptDrainOutcome, CapabilityError> {
    use crate::domains::agent::prompt_queue::PromptQueueService;
    use crate::domains::settings::types::QueueDrainMode;

    let settings = crate::domains::settings::get_settings();
    let drain_mode = &settings.session.queue_drain_mode;

    // Peek at the queue — do NOT dequeue until run is confirmed.
    let pending = match PromptQueueService::get_pending_queue(event_store, session_id) {
        Ok(items) => items,
        Err(e) => {
            warn!(session_id, error = %e, "failed to query prompt queue");
            return Err(e);
        }
    };
    if pending.is_empty() {
        return Ok(PromptDrainOutcome::not_drained("empty"));
    }

    // Determine prompt text based on drain mode.
    //
    // Metadata (messageKind/confirmationDecision/answerCount) is only
    // carried in Sequential mode — batched drains combine multiple user
    // messages into a single prompt, at which point the individual
    // message kinds no longer apply to the merged content.
    let (prompt_text, items_to_dequeue, drained_metadata) = match drain_mode {
        QueueDrainMode::Sequential => {
            // One message per turn
            let item = &pending[0];
            (item.text.clone(), vec![item.clone()], item.metadata.clone())
        }
        QueueDrainMode::Batched => {
            // Combine all pending into a single prompt
            let combined = pending
                .iter()
                .map(|i| i.text.as_str())
                .collect::<Vec<_>>()
                .join("\n\n");
            (combined, pending, None)
        }
    };

    debug!(
        session_id,
        mode = ?drain_mode,
        count = items_to_dequeue.len(),
        text_preview = %prompt_text.chars().take(80).collect::<String>(),
        "auto-draining queued prompt(s)"
    );

    let run_id = uuid::Uuid::now_v7().to_string();
    let started_run = match orchestrator.begin_run(session_id, &run_id) {
        Ok(run) => run,
        Err(e) => {
            warn!(session_id, error = %e, "failed to begin run for queued prompt, messages preserved in queue");
            return Ok(PromptDrainOutcome::not_drained("busy"));
        }
    };

    // Run is registered — NOW it's safe to mark messages as processed.
    for item in &items_to_dequeue {
        if let Err(e) =
            PromptQueueService::dequeue(event_store, session_id, &item.queue_id, "processed")
        {
            warn!(session_id, queue_id = %item.queue_id, error = %e, "failed to dequeue message");
        }
        let _ = orchestrator
            .broadcast()
            .emit(crate::shared::events::TronEvent::MessageDequeued {
                base: crate::shared::events::BaseEvent::now(session_id),
                queue_id: item.queue_id.clone(),
                reason: "processed".into(),
            });
    }

    // Publish the user message so clients can render the bubble in real time.
    // In the normal flow, iOS adds the user bubble locally before the engine invocation.
    // During auto-drain, the server owns the prompt — this event is how iOS learns about it.
    let _ = orchestrator
        .broadcast()
        .emit(crate::shared::events::TronEvent::QueuedMessageSent {
            base: crate::shared::events::BaseEvent::now(session_id),
            text: prompt_text.clone(),
            queue_id: items_to_dequeue
                .first()
                .map(|i| i.queue_id.clone())
                .unwrap_or_default(),
        });

    let max_seq = event_store.get_max_sequence(session_id).unwrap_or(0);
    let sequence_counter = Some(orchestrator.ensure_sequence_counter_at_least(session_id, max_seq));

    let plan = PromptRunPlan {
        started_run,
        orchestrator: orchestrator.clone(),
        session_manager: session_manager.clone(),
        broadcast,
        provider_factory,
        health_tracker,
        event_store: event_store.clone(),
        profile_runtime,
        shutdown_token: shutdown_token.clone(),
        engine_host,
        engine_causality: engine_causality.clone(),
        sequence_counter,
        server_origin,
        run_id: run_id.clone(),
        model: model.to_string(),
        working_dir: working_dir.to_string(),
        request: PromptRequest {
            session_id: session_id.to_string(),
            prompt: prompt_text,
            reasoning_level: None,
            images: None,
            attachments: None,
            message_metadata: drained_metadata,
            engine_causality,
        },
    };

    let _handle = tokio::spawn(async move {
        execute_prompt_run(plan).await;
    });
    Ok(PromptDrainOutcome::drained(run_id, items_to_dequeue.len()))
}

pub(crate) async fn enqueue_prompt_queue_drain(
    engine_host: &crate::engine::EngineHostHandle,
    session_id: &str,
    completed_run_id: &str,
    causality: Option<&PromptEngineCausality>,
) {
    let function_id = match FunctionId::new("agent::prompt_queue_drain") {
        Ok(id) => id,
        Err(error) => {
            warn!(session_id, error = %error, "invalid prompt queue drain function id");
            return;
        }
    };
    let mut authority_scopes = causality
        .map(|causality| causality.context.authority_scopes.clone())
        .unwrap_or_else(|| vec!["agent.write".to_owned()]);
    for scope in ["agent.write", ENGINE_INTERNAL_INVOKE_SCOPE] {
        if !authority_scopes.iter().any(|existing| existing == scope) {
            authority_scopes.push(scope.to_owned());
        }
    }
    let Some(target_revision) = target_revision_for_queue_drain(engine_host, causality).await
    else {
        warn!(
            session_id,
            completed_run_id,
            "failed to resolve prompt queue drain revision; skipping auto-drain enqueue"
        );
        return;
    };
    let item = engine_host
        .enqueue_invocation(EnqueueInvocation {
            queue: "agent".to_owned(),
            function_id,
            target_revision: Some(target_revision),
            payload: serde_json::json!({
                "sessionId": session_id,
                "completedRunId": completed_run_id,
            }),
            actor_id: causality
                .map(|causality| causality.context.actor_id.clone())
                .unwrap_or_else(|| ActorId::new("system").expect("valid static actor id")),
            actor_kind: causality
                .map(|causality| causality.context.actor_kind.clone())
                .unwrap_or(ActorKind::System),
            authority_grant_id: causality
                .map(|causality| causality.context.authority_grant_id.clone())
                .unwrap_or_else(|| {
                    AuthorityGrantId::new("prompt-runtime").expect("valid static grant id")
                }),
            authority_scopes,
            runtime_metadata: causality
                .map(|causality| causality.context.runtime_metadata.clone())
                .unwrap_or_default(),
            trace_id: causality
                .map(|causality| causality.context.trace_id.clone())
                .unwrap_or_else(TraceId::generate),
            parent_invocation_id: causality
                .and_then(|causality| causality.parent_invocation_id.clone()),
            trigger_id: causality.and_then(|causality| causality.context.trigger_id.clone()),
            session_id: Some(session_id.to_owned()),
            workspace_id: causality.and_then(|causality| causality.context.workspace_id.clone()),
            idempotency_key: Some(format!(
                "agent.prompt.queue_drain:{session_id}:{completed_run_id}"
            )),
        })
        .await;
    let item = match item {
        Ok(item) => item,
        Err(error) => {
            warn!(session_id, error = %error, "failed to enqueue prompt queue drain");
            return;
        }
    };
    publish_queue_lifecycle_event(engine_host, "enqueue", &item, None).await;
    let host = engine_host.clone();
    let receipt = item.receipt_id.clone();
    drop(tokio::spawn(async move {
        let _ = EngineQueueDrainer::drain_receipt(&host, &receipt, "agent-prompt-auto-drain").await;
    }));
}

async fn target_revision_for_queue_drain(
    engine_host: &crate::engine::EngineHostHandle,
    causality: Option<&PromptEngineCausality>,
) -> Option<FunctionRevision> {
    let function_id = FunctionId::new("agent::prompt_queue_drain").ok()?;
    let mut actor = ActorContext::new(
        causality
            .map(|causality| causality.context.actor_id.clone())
            .unwrap_or_else(|| ActorId::new("system").expect("valid static actor id")),
        causality
            .map(|causality| causality.context.actor_kind.clone())
            .unwrap_or(ActorKind::System),
        causality
            .map(|causality| causality.context.authority_grant_id.clone())
            .unwrap_or_else(|| {
                AuthorityGrantId::new("prompt-runtime").expect("valid static grant id")
            }),
    );
    actor.authority_scopes = causality
        .map(|causality| causality.context.authority_scopes.clone())
        .unwrap_or_else(|| vec!["agent.write".to_owned()]);
    for scope in ["agent.write", ENGINE_INTERNAL_INVOKE_SCOPE] {
        if !actor
            .authority_scopes
            .iter()
            .any(|existing| existing == scope)
        {
            actor.authority_scopes.push(scope.to_owned());
        }
    }
    actor.session_id = causality.and_then(|causality| causality.context.session_id.clone());
    actor.workspace_id = causality.and_then(|causality| causality.context.workspace_id.clone());
    match engine_host
        .inspect_function(&function_id, Some(&actor))
        .await
    {
        Ok(function) => Some(function.revision),
        Err(error) => {
            warn!(error = %error, "failed to inspect prompt queue drain revision");
            None
        }
    }
}
