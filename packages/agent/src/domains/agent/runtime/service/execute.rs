use std::sync::Arc;

use tracing::{debug, warn};

use super::agent_build::{BuiltPromptAgent, build_prompt_agent};
use super::completion::{PromptRunCompletion, finalize_prompt_run};
use super::context::load_agent_state_context;
use super::worktree::{emit_prompt_worktree_failure, resolve_prompt_worktree};
use super::{
    PromptRequest, PromptRunCleanup, PromptRunPlan, RunContext, ShutdownCancelForwarder,
    build_user_content_override, build_user_event_payload, persist_user_message_event,
    resume_prompt_session, run_agent, should_acquire_worktree_for_source,
};

pub(crate) async fn execute_prompt_run(plan: PromptRunPlan) {
    let PromptRunPlan {
        started_run,
        orchestrator,
        session_manager,
        broadcast,
        provider_factory,
        health_tracker,
        event_store,
        profile_runtime,
        shutdown_token,
        worktree_coordinator,
        engine_host,
        engine_causality,
        sequence_counter,
        server_origin,
        run_id,
        source,
        profile,
        model,
        working_dir,
        request,
        ..
    } = plan;

    let session_plan =
        match profile_runtime.plan_session(crate::domains::agent::runner::SessionPlanRequest {
            requested_profile: Some(profile.clone()),
            model: model.clone(),
            source: source.clone(),
            entrypoint: None,
        }) {
            Ok(plan) => plan,
            Err(error) => {
                warn!(
                    session_id = %request.session_id,
                    profile = %profile,
                    error = %error,
                    "failed to resolve session profile"
                );
                let _ = broadcast.emit(crate::shared::events::TronEvent::Error {
                    base: crate::shared::events::BaseEvent::now(&request.session_id),
                    error: format!("Session profile `{profile}` is invalid: {error}"),
                    context: None,
                    code: Some("PROFILE_INVALID".into()),
                    provider: None,
                    category: Some("profile".into()),
                    suggestion: Some(
                        "Repair the profile or create a new session with a valid profile.".into(),
                    ),
                    retryable: Some(false),
                    status_code: None,
                    error_type: Some("profile".into()),
                    model: Some(model),
                });
                return;
            }
        };
    let resolved_profile = session_plan.resolved_profile.clone();

    let is_chat = profile == crate::shared::profile::CHAT_PROFILE
        || !should_acquire_worktree_for_source(source.as_deref());

    let PromptRequest {
        session_id,
        prompt,
        reasoning_level,
        images,
        attachments,
        message_metadata,
        engine_causality: _,
    } = request;

    let _ = session_manager.mark_processing(&session_id);
    let mut run_cleanup =
        PromptRunCleanup::new(started_run, session_manager.clone(), session_id.clone());
    let cancel_token = run_cleanup.cancel_token();
    let _shutdown_forwarder = ShutdownCancelForwarder::new(shutdown_token, cancel_token.clone());
    let settings = crate::domains::settings::get_settings();

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
                crate::domains::agent::runner::orchestrator::session_reconstructor::ReconstructedState {
                    model: model.clone(),
                    working_directory: Some(working_dir.clone()),
                    ..Default::default()
                };
            let fresh_persister = Arc::new(
                crate::domains::agent::runner::orchestrator::event_persister::EventPersister::new(
                    event_store.clone(),
                ),
            );
            (fresh_state, fresh_persister)
        }
    };

    let worktree_resolution = match resolve_prompt_worktree(
        is_chat,
        state.worktree_path.as_deref(),
        &worktree_coordinator,
        &event_store,
        &session_id,
        working_dir,
    )
    .await
    {
        Ok(resolution) => resolution,
        Err(message) => {
            emit_prompt_worktree_failure(broadcast.as_ref(), &session_id, &model, message);
            return;
        }
    };
    let working_dir = worktree_resolution.working_dir;
    let resolved_workspace_id = event_store
        .get_session(&session_id)
        .ok()
        .flatten()
        .map(|session| session.workspace_id)
        .filter(|id| !id.is_empty());
    let agent_state_context =
        load_agent_state_context(&engine_host, &session_id, resolved_workspace_id.as_deref()).await;

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
        provider_factory,
        health_tracker,
        engine_host.clone(),
        &broadcast,
        settings.as_ref(),
        &session_id,
        &model,
        &working_dir,
        server_origin,
        messages,
        initial_turn_count,
        resolved_workspace_id.clone(),
    )
    .await
    {
        Ok(built) => built,
        Err(()) => return,
    };

    agent.set_abort_token(cancel_token);
    agent.set_persister(Some(persister.clone()));
    agent.set_invocation_abort_registry(orchestrator.invocation_abort_registry().clone());
    orchestrator.register_compaction_handler(&session_id, agent.compaction_handler().clone());
    let mut user_event_payload = build_user_event_payload(
        &prompt,
        images.as_deref(),
        attachments.as_deref(),
        message_metadata.as_ref(),
    );
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
            object.insert(
                "catalogRevision".to_owned(),
                serde_json::json!(causality.context.catalog_revision.0),
            );
        }
    }
    if let Err(error) =
        persist_user_message_event(event_store.clone(), session_id.clone(), user_event_payload)
            .await
    {
        warn!(
            session_id = %session_id,
            error = %error,
            "failed to persist message.user event"
        );
    }

    let user_content_override =
        build_user_content_override(&prompt, &model, images.as_deref(), attachments.as_deref());

    let run_context = RunContext {
        reasoning_level: reasoning_level.and_then(|level| {
            crate::domains::agent::runner::types::ReasoningLevel::from_str_loose(&level)
        }),
        agent_state_context,
        profile_name: Some(profile.clone()),
        resolved_profile: Some(resolved_profile.clone()),
        user_content_override,
        run_id: Some(run_id.clone()),
        engine_trace_id: engine_causality
            .as_ref()
            .map(|causality| causality.context.trace_id.clone()),
        parent_invocation_id: engine_causality
            .as_ref()
            .and_then(|causality| causality.parent_invocation_id.clone()),
        engine_catalog_revision: engine_causality
            .as_ref()
            .map(|causality| causality.context.catalog_revision),
        ..Default::default()
    };

    debug!(session_id = %session_id, "calling primitive agent loop");
    let result = run_agent(
        &mut agent,
        &prompt,
        run_context,
        &None,
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
