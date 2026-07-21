use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use tracing::{info, trace, warn};

use super::agent_build::{BuiltPromptAgent, build_prompt_agent};
use super::completion::{PromptRunCompletion, finalize_prompt_run, publish_terminal_lifecycle};
use super::{
    PromptRequest, PromptRunCleanup, PromptRunPlan, RunContext, SessionTitleGenerationRequest,
    ShutdownCancelForwarder, build_user_content_override, build_user_event_payload,
    persist_user_message_event, resume_prompt_session, run_agent, spawn_session_title_generation,
};
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::shared::protocol::events::{BaseEvent, error_event};
use crate::shared::server::failure::FailureEnvelope;
use crate::shared::server::failure::FailureOrigin;

pub(crate) async fn execute_prompt_run(plan: PromptRunPlan) {
    let PromptRunPlan {
        started_run,
        orchestrator,
        session_manager,
        responder_factory,
        settings,
        event_store,
        shutdown_token,
        shutdown_coordinator,
        engine_host,
        server_origin,
        run_id,
        model,
        working_dir,
        request,
        ..
    } = plan;
    let broadcast = orchestrator.broadcast().clone();
    let PromptRequest {
        session_id,
        prompt,
        reasoning_level,
        attachments,
        engine_causality,
    } = request;
    let inherited_trace_id = engine_causality
        .as_ref()
        .map(|causality| causality.context.trace_id.as_str())
        .unwrap_or("none");
    let parent_invocation_id = engine_causality
        .as_ref()
        .and_then(|causality| causality.parent_invocation_id.as_ref())
        .map(|id| id.as_str())
        .unwrap_or("none");
    let attachment_count = attachments.as_ref().map_or(0, |items| items.len());

    info!(
        component = "agent.runtime",
        agent_event = "prompt_run_started",
        session_id = %session_id,
        run_id = %run_id,
        model = %model,
        trace_id = %inherited_trace_id,
        parent_invocation_id = %parent_invocation_id,
        attachment_count,
        has_reasoning_level = reasoning_level.is_some(),
        "agent prompt run started"
    );

    let mut run_cleanup =
        PromptRunCleanup::new(started_run, session_manager.clone(), session_id.clone());
    let cancel_token = run_cleanup.cancel_token();
    let _shutdown_forwarder = ShutdownCancelForwarder::new(shutdown_token, cancel_token.clone());
    let title_responder_factory = responder_factory.clone();

    let state = match resume_prompt_session(
        session_manager.clone(),
        event_store.clone(),
        broadcast.clone(),
        session_id.clone(),
    )
    .await
    {
        Ok(state) => state,
        Err(error) => {
            warn!(
                session_id = %session_id,
                run_id = %run_id,
                error = %error,
                "failed to reconstruct session; aborting prompt run"
            );
            let failure = error.to_failure(FailureOrigin::AgentRuntime);
            terminate_prompt_failure(&mut run_cleanup, &broadcast, &session_id, &failure, None);
            return;
        }
    };
    trace!(
        component = "agent.runtime",
        agent_event = "session_state_resolved",
        session_id = %session_id,
        run_id = %run_id,
        message_count = state.messages.len(),
        turn_count = state.turn_count,
        had_working_directory = state.working_directory.is_some(),
        "agent session state resolved"
    );

    let mut user_event_payload = build_user_event_payload(&prompt, attachments.as_deref());
    if let Some(object) = user_event_payload.as_object_mut() {
        object.insert("runId".to_owned(), serde_json::json!(run_id.clone()));
        if let Some(causality) = engine_causality.as_ref() {
            object.insert(
                "traceId".to_owned(),
                serde_json::json!(causality.context.trace_id.as_str()),
            );
            object.insert(
                "parentInvocationId".to_owned(),
                serde_json::json!(
                    causality
                        .parent_invocation_id
                        .as_ref()
                        .map(|id| id.as_str())
                ),
            );
        }
    }
    let user_event = match persist_user_message_event(
        event_store.clone(),
        session_id.clone(),
        user_event_payload,
    )
    .await
    {
        Ok(event) => event,
        Err(error) => {
            warn!(
                session_id = %session_id,
                run_id = %run_id,
                error = %error,
                "failed to persist message.user event; aborting prompt run"
            );
            let failure = error.to_failure(FailureOrigin::EventStore);
            terminate_prompt_failure(&mut run_cleanup, &broadcast, &session_id, &failure, None);
            return;
        }
    };
    if !orchestrator.commit_run_admission(&session_id, &run_id, user_event.sequence) {
        warn!(
            session_id = %session_id,
            run_id = %run_id,
            "prompt admission lost run ownership after durable user message"
        );
        return;
    }
    info!(
        component = "agent.runtime",
        agent_event = "user_message_persisted",
        session_id = %session_id,
        run_id = %run_id,
        persisted = true,
        "agent user message persistence completed"
    );

    let durable_sequence_high_water = match event_store.get_max_sequence(&session_id) {
        Ok(sequence) => sequence,
        Err(error) => {
            warn!(
                session_id = %session_id,
                run_id = %run_id,
                error = %error,
                "failed to resolve durable sequence high-water; aborting prompt run"
            );
            let failure = crate::domains::agent::r#loop::errors::RuntimeError::Persistence(
                format!("failed to resolve durable sequence high-water: {error}"),
            )
            .to_failure()
            .with_session_id(Some(session_id.clone()));
            terminate_prompt_failure(&mut run_cleanup, &broadcast, &session_id, &failure, None);
            return;
        }
    };
    if durable_sequence_high_water == i64::MAX {
        warn!(
            session_id = %session_id,
            run_id = %run_id,
            "durable sequence exhausted; aborting prompt run"
        );
        let failure = crate::domains::agent::r#loop::errors::RuntimeError::Persistence(format!(
            "event sequence exhausted for session {session_id}"
        ))
        .to_failure()
        .with_session_id(Some(session_id.clone()));
        terminate_prompt_failure(&mut run_cleanup, &broadcast, &session_id, &failure, None);
        return;
    }
    let sequence_counter = Some(
        orchestrator.ensure_sequence_counter_at_least(&session_id, durable_sequence_high_water),
    );

    let persister = Arc::new(EventPersister::new(event_store.clone()));

    let working_dir = state.working_directory.clone().unwrap_or(working_dir);
    let resolved_workspace_id = event_store
        .get_session(&session_id)
        .ok()
        .flatten()
        .map(|session| session.workspace_id)
        .filter(|id| !id.is_empty());
    let messages = state.messages.clone();
    let initial_turn_offset = match resolve_turn_offset(&event_store, &session_id, state.turn_count)
    {
        Ok(offset) => offset,
        Err(error) => {
            warn!(
                session_id = %session_id,
                run_id = %run_id,
                error = %error,
                "failed to resolve durable turn high-water; aborting prompt run"
            );
            let failure = error.to_failure().with_session_id(Some(session_id.clone()));
            terminate_prompt_failure(
                &mut run_cleanup,
                &broadcast,
                &session_id,
                &failure,
                sequence_counter.as_deref(),
            );
            return;
        }
    };
    let model_for_error = model.clone();
    let BuiltPromptAgent {
        mut agent,
        provider_type,
    } = match build_prompt_agent(
        responder_factory,
        engine_host.clone(),
        orchestrator.invocation_abort_registry().clone(),
        &settings,
        &session_id,
        &model,
        &working_dir,
        server_origin.clone(),
        messages,
        initial_turn_offset,
        resolved_workspace_id.clone(),
    )
    .await
    {
        Ok(built) => built,
        Err(failure) => {
            terminate_prompt_failure(
                &mut run_cleanup,
                &broadcast,
                &session_id,
                &failure,
                sequence_counter.as_deref(),
            );
            return;
        }
    };
    info!(
        component = "agent.runtime",
        agent_event = "prompt_agent_built",
        session_id = %session_id,
        run_id = %run_id,
        provider_type = %provider_type,
        model = %model,
        workspace_id = resolved_workspace_id.as_deref().unwrap_or("none"),
        initial_turn_offset,
        "agent runtime built prompt agent"
    );

    agent.set_abort_token(cancel_token);
    agent.set_persister(Some(persister.clone()));
    agent.set_compaction_session_manager(session_manager.clone());
    orchestrator.register_compaction_handler(&session_id, agent.compaction_handler().clone());
    spawn_session_title_generation(
        title_responder_factory,
        event_store.clone(),
        broadcast.clone(),
        shutdown_coordinator,
        SessionTitleGenerationRequest {
            session_id: session_id.clone(),
            model: model.clone(),
            api_settings: settings.api.clone(),
            prompt: prompt.clone(),
            working_dir: working_dir.clone(),
            server_origin: server_origin.clone(),
        },
    );

    let user_content_override =
        build_user_content_override(&prompt, &model, attachments.as_deref());

    let run_context = RunContext {
        reasoning_level: reasoning_level.and_then(|level| {
            crate::domains::agent::r#loop::types::ReasoningLevel::from_str_canonical(&level)
        }),
        user_content_override,
        run_id: Some(run_id.clone()),
        engine_trace_id: engine_causality
            .as_ref()
            .map(|causality| causality.context.trace_id.clone()),
        parent_invocation_id: engine_causality
            .as_ref()
            .and_then(|causality| causality.parent_invocation_id.clone()),
        worker_causal_depth: engine_causality
            .as_ref()
            .map(|causality| causality.context.trigger_depth())
            .unwrap_or(0),
        ..Default::default()
    };

    info!(
        component = "agent.runtime",
        agent_event = "agent_loop_entered",
        session_id = %session_id,
        run_id = %run_id,
        trace_id = %inherited_trace_id,
        parent_invocation_id = %parent_invocation_id,
        "calling primitive agent loop"
    );
    let result = run_agent(
        &mut agent,
        &prompt,
        run_context,
        &broadcast,
        sequence_counter.clone(),
    )
    .await;
    orchestrator.remove_compaction_handler(&session_id);

    finalize_prompt_run(PromptRunCompletion {
        result,
        run_cleanup: &mut run_cleanup,
        event_store,
        broadcast,
        engine_host,
        engine_causality,
        session_id,
        run_id,
        provider_type,
        model_for_error,
        sequence_counter,
    })
    .await;
}

fn terminate_prompt_failure(
    run_cleanup: &mut PromptRunCleanup,
    broadcast: &Arc<crate::domains::agent::r#loop::EventEmitter>,
    session_id: &str,
    failure: &FailureEnvelope,
    sequence_counter: Option<&AtomicI64>,
) {
    let terminal_error = failure.message.clone();
    let event = error_event(BaseEvent::now(session_id), failure, None);
    let _ = run_cleanup.release_with_terminal(|| {
        publish_terminal_lifecycle(
            broadcast,
            session_id,
            Some(terminal_error),
            sequence_counter,
            Some(event),
        );
    });
}

fn resolve_turn_offset(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    reconstructed_turn_count: u32,
) -> Result<u32, crate::domains::agent::r#loop::errors::RuntimeError> {
    let session = event_store
        .get_session(session_id)
        .map_err(|error| {
            crate::domains::agent::r#loop::errors::RuntimeError::Persistence(error.to_string())
        })?
        .ok_or_else(|| {
            crate::domains::agent::r#loop::errors::RuntimeError::SessionNotFound(
                session_id.to_owned(),
            )
        })?;
    let completed_turn_count = u32::try_from(session.turn_count).map_err(|_| {
        crate::domains::agent::r#loop::errors::RuntimeError::Persistence(format!(
            "invalid completed turn count {} for session {session_id}",
            session.turn_count
        ))
    })?;
    let latest_started_turn = event_store
        .get_max_turn_by_type(
            session_id,
            crate::domains::session::event_store::EventType::StreamTurnStart,
        )
        .map_err(|error| {
            crate::domains::agent::r#loop::errors::RuntimeError::Persistence(error.to_string())
        })?
        .unwrap_or(0);
    let turn_offset = reconstructed_turn_count
        .max(completed_turn_count)
        .max(latest_started_turn);
    if turn_offset == u32::MAX {
        return Err(
            crate::domains::agent::r#loop::errors::RuntimeError::Internal(format!(
                "session turn ordinal exhausted for {session_id}"
            )),
        );
    }
    Ok(turn_offset)
}

#[cfg(test)]
#[path = "execute_tests.rs"]
mod tests;
