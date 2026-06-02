use std::sync::Arc;

use tracing::{debug, warn};

use super::agent_build::{BuiltPromptAgent, build_prompt_agent};
use super::completion::{PromptRunCompletion, finalize_prompt_run};
use super::context::load_prompt_context_bundle;
use super::hooks::{
    apply_user_prompt_submit_hook, build_prompt_hooks, fire_session_start_hook,
    fire_worktree_acquired_hook,
};
use super::worktree::{emit_prompt_worktree_failure, resolve_prompt_worktree};
use super::{
    PromptRequest, PromptRunCleanup, PromptRunPlan, RunContext, ShutdownCancelForwarder,
    build_user_content_override, build_user_event_payload, collect_pending_skill_payloads,
    persist_user_message_event, prepare_skill_context_from_session, resume_prompt_session,
    run_agent, should_acquire_worktree_for_source,
};

pub(crate) async fn execute_prompt_run(plan: PromptRunPlan) {
    let PromptRunPlan {
        started_run,
        orchestrator,
        session_manager,
        broadcast,
        provider_factory,
        guardrails,
        health_tracker,
        event_store,
        context_artifacts,
        skill_registry,
        memory_registry,
        profile_runtime,
        subagent_manager,
        shutdown_token,
        worktree_coordinator,
        process_manager,
        job_manager,
        output_buffer_registry,
        hook_abort_tracker,
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

    let hooks = build_prompt_hooks(
        &subagent_manager,
        &broadcast,
        &event_store,
        &worktree_coordinator,
        &hook_abort_tracker,
        &working_dir,
    );

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
    let worktree_info = worktree_resolution.worktree_info;
    let working_dir = worktree_resolution.working_dir;
    let freshly_acquired_worktree = worktree_resolution.freshly_acquired;

    let context_policy = session_plan.runtime_context_policy();
    let prompt_context = load_prompt_context_bundle(
        context_artifacts.clone(),
        engine_host.clone(),
        event_store.clone(),
        memory_registry.clone(),
        &session_id,
        &working_dir,
        settings.as_ref().clone(),
        !state.messages.is_empty(),
        source.clone(),
        &context_policy,
        worktree_info.as_ref(),
        &resolved_profile,
    )
    .await;

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
        guardrails,
        health_tracker,
        process_manager,
        job_manager,
        output_buffer_registry,
        subagent_manager.clone(),
        hooks.clone(),
        engine_host.clone(),
        &broadcast,
        settings.as_ref(),
        &session_plan,
        &session_id,
        &profile,
        &model,
        &working_dir,
        server_origin,
        prompt_context.combined_rules.clone(),
        messages,
        initial_turn_count,
        prompt_context.memory.clone(),
        prompt_context.rules_index.clone(),
        prompt_context.pre_activated_rules.clone(),
        prompt_context.resolved_workspace_id.clone(),
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
    let skills_payload = {
        let registry = skill_registry.read();
        collect_pending_skill_payloads(&event_store, &session_id, Some(&*registry))
    };
    let mut user_event_payload = build_user_event_payload(
        &prompt,
        images.as_deref(),
        attachments.as_deref(),
        message_metadata.as_ref(),
        skills_payload.as_ref(),
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

    {
        let mut registry = skill_registry.write();
        let _ = registry.refresh_if_stale(&working_dir);
    }
    let skill_result = match prepare_skill_context_from_session(
        skill_registry.clone(),
        event_store.clone(),
        session_id.clone(),
    )
    .await
    {
        Ok(result) => result,
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to build skill context from session"
            );
            crate::domains::agent::runtime::runtime::SkillContextResult {
                skill_activation_context: None,
                skill_context: None,
                skill_removal_context: None,
            }
        }
    };

    let skill_index_context = build_skill_index_context(
        &skill_registry,
        skill_result.skill_context.as_ref(),
        &context_policy,
    );
    let volatile_tokens = prompt_context.volatile_tokens(
        skill_result.skill_context.as_ref(),
        skill_result.skill_removal_context.as_ref(),
        &context_policy,
    );

    let mut run_context = RunContext {
        reasoning_level: reasoning_level.and_then(|level| {
            crate::domains::agent::runner::types::ReasoningLevel::from_str_loose(&level)
        }),
        skill_index_context,
        skill_activation_context: skill_result.skill_activation_context,
        skill_context: skill_result.skill_context,
        skill_removal_context: skill_result.skill_removal_context,
        job_results: prompt_context.job_results_context.clone(),
        profile_name: Some(profile.clone()),
        resolved_profile: Some(resolved_profile.clone()),
        user_content_override,
        volatile_tokens,
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

    fire_worktree_acquired_hook(
        &hooks,
        &session_id,
        worktree_info.as_ref(),
        freshly_acquired_worktree,
    )
    .await;
    fire_session_start_hook(&hooks, &session_id, &working_dir).await;
    let (effective_prompt, hook_context) =
        apply_user_prompt_submit_hook(&hooks, &session_id, &prompt).await;
    run_context.hook_context = hook_context;

    debug!(session_id = %session_id, "[hooks] all hooks returned, calling run_agent");
    let result = run_agent(
        &mut agent,
        &effective_prompt,
        run_context,
        &hooks,
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

fn build_skill_index_context(
    skill_registry: &Arc<parking_lot::RwLock<crate::domains::skills::registry::SkillRegistry>>,
    skill_context: Option<&String>,
    context_policy: &crate::domains::agent::runner::context::local_policy::ContextPolicy,
) -> Option<String> {
    if context_policy.strip_skill_index() {
        return None;
    }

    let settings = crate::domains::settings::get_settings();
    let should_show = match &settings.skills.show_index {
        crate::domains::settings::types::ShowIndex::Always => true,
        crate::domains::settings::types::ShowIndex::Never => false,
        crate::domains::settings::types::ShowIndex::WhenNoActiveSkills => skill_context.is_none(),
    };
    if !should_show {
        return None;
    }

    let registry = skill_registry.read();
    let all_skills = registry.list(None);
    let index = crate::domains::skills::injector::build_skill_index(&all_skills);
    if index.is_empty() { None } else { Some(index) }
}
