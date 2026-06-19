use std::sync::Arc;

use tracing::{info, trace, warn};

use super::agent_build::{BuiltPromptAgent, build_prompt_agent};
use super::completion::{PromptRunCompletion, finalize_prompt_run};
use super::context::load_agent_state_context;
use super::{
    PromptRequest, PromptRunCleanup, PromptRunPlan, RunContext, SessionTitleGenerationRequest,
    ShutdownCancelForwarder, build_user_content_override, build_user_event_payload,
    persist_user_message_event, resume_prompt_session, run_agent, spawn_session_title_generation,
};

pub(crate) async fn execute_prompt_run(plan: PromptRunPlan) {
    let PromptRunPlan {
        started_run,
        orchestrator,
        session_manager,
        broadcast,
        responder_factory,
        event_store,
        shutdown_token,
        shutdown_coordinator,
        engine_host,
        engine_causality,
        sequence_counter,
        server_origin,
        run_id,
        model,
        working_dir,
        request,
        ..
    } = plan;
    let PromptRequest {
        session_id,
        prompt,
        reasoning_level,
        attachments,
        engine_causality: _,
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

    let _ = session_manager.mark_processing(&session_id);
    let mut run_cleanup =
        PromptRunCleanup::new(started_run, session_manager.clone(), session_id.clone());
    let cancel_token = run_cleanup.cancel_token();
    let _shutdown_forwarder = ShutdownCancelForwarder::new(shutdown_token, cancel_token.clone());
    let settings = crate::domains::settings::get_settings();
    let title_responder_factory = responder_factory.clone();

    let (state, persister) = match resume_prompt_session(
        session_manager.clone(),
        session_id.clone(),
    )
    .await
    {
        Ok(active) => (active.state, active.persister),
        Err(error) => {
            warn!(session_id = %session_id, error = %error, "failed to resume session, starting fresh");
            let fresh_state =
                crate::domains::agent::r#loop::orchestrator::session_reconstructor::ReconstructedState {
                    model: model.clone(),
                    working_directory: Some(working_dir.clone()),
                    ..Default::default()
                };
            let fresh_persister = Arc::new(
                crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister::new(
                    event_store.clone(),
                ),
            );
            (fresh_state, fresh_persister)
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

    let working_dir = state.working_directory.clone().unwrap_or(working_dir);
    let resolved_workspace_id = event_store
        .get_session(&session_id)
        .ok()
        .flatten()
        .map(|session| session.workspace_id)
        .filter(|id| !id.is_empty());
    let agent_state_context =
        load_agent_state_context(&engine_host, &session_id, resolved_workspace_id.as_deref()).await;
    trace!(
        component = "agent.runtime",
        agent_event = "agent_state_context_loaded",
        session_id = %session_id,
        run_id = %run_id,
        workspace_id = resolved_workspace_id.as_deref().unwrap_or("none"),
        has_agent_state_context = agent_state_context.is_some(),
        "agent state context loaded"
    );

    let messages = state.messages.clone();
    let initial_turn_count = event_store
        .get_session(&session_id)
        .ok()
        .flatten()
        .map_or(state.turn_count, |session| {
            u32::try_from(session.turn_count).unwrap_or(state.turn_count)
        });
    let model_for_error = model.clone();
    let BuiltPromptAgent {
        mut agent,
        provider_type,
    } = match build_prompt_agent(
        responder_factory,
        engine_host.clone(),
        &broadcast,
        settings.as_ref(),
        &session_id,
        &model,
        &working_dir,
        server_origin.clone(),
        messages,
        initial_turn_count,
        resolved_workspace_id.clone(),
    )
    .await
    {
        Ok(built) => built,
        Err(()) => return,
    };
    info!(
        component = "agent.runtime",
        agent_event = "prompt_agent_built",
        session_id = %session_id,
        run_id = %run_id,
        provider_type = %provider_type,
        model = %model,
        workspace_id = resolved_workspace_id.as_deref().unwrap_or("none"),
        initial_turn_count,
        "agent runtime built prompt agent"
    );

    agent.set_abort_token(cancel_token);
    agent.set_persister(Some(persister.clone()));
    agent.set_invocation_abort_registry(orchestrator.invocation_abort_registry().clone());
    orchestrator.register_compaction_handler(&session_id, agent.compaction_handler().clone());
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
    let user_message_persisted = match persist_user_message_event(
        event_store.clone(),
        session_id.clone(),
        user_event_payload,
    )
    .await
    {
        Ok(()) => true,
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to persist message.user event"
            );
            false
        }
    };
    info!(
        component = "agent.runtime",
        agent_event = "user_message_persisted",
        session_id = %session_id,
        run_id = %run_id,
        persisted = user_message_persisted,
        "agent user message persistence completed"
    );
    if user_message_persisted {
        spawn_session_title_generation(
            title_responder_factory,
            event_store.clone(),
            broadcast.clone(),
            shutdown_coordinator,
            SessionTitleGenerationRequest {
                session_id: session_id.clone(),
                model: model.clone(),
                prompt: prompt.clone(),
                working_dir: working_dir.clone(),
                server_origin: server_origin.clone(),
            },
        );
    }

    let user_content_override =
        build_user_content_override(&prompt, &model, attachments.as_deref());

    let run_context = RunContext {
        reasoning_level: reasoning_level.and_then(|level| {
            crate::domains::agent::r#loop::types::ReasoningLevel::from_str_canonical(&level)
        }),
        agent_state_context,
        user_content_override,
        run_id: Some(run_id.clone()),
        engine_trace_id: engine_causality
            .as_ref()
            .map(|causality| causality.context.trace_id.clone()),
        parent_invocation_id: engine_causality
            .as_ref()
            .and_then(|causality| causality.parent_invocation_id.clone()),
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
        sequence_counter,
    )
    .await;
    orchestrator.remove_compaction_handler(&session_id);

    finalize_prompt_run(PromptRunCompletion {
        result,
        persister,
        run_cleanup: &mut run_cleanup,
        session_manager,
        event_store,
        broadcast,
        engine_host,
        engine_causality,
        session_id,
        run_id,
        provider_type,
        model_for_error,
    })
    .await;
}
