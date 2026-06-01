use std::path::Path;
use std::sync::Arc;

use crate::domains::model::providers::provider::ProviderFactory;
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::events::{BaseEvent, TronEvent};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{Instrument, info, info_span};

use super::{SubagentManager, SubagentResult, TrackedSubagent, elapsed_ms, truncate};
use crate::domains::agent::lineage::subagent_result_resource_id;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::guardrails::GuardrailEngine;
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::agent::runner::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::domains::agent::runner::orchestrator::agent_runner;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::agent::runner::types::ReasoningLevel;
use crate::domains::agent::runner::types::{AgentConfig as AgentCfg, RunContext};
use crate::domains::session::event_store::EventStore;

pub(super) struct SubsessionTaskLaunch {
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) event_store: Arc<EventStore>,
    pub(super) broadcast: Arc<EventEmitter>,
    pub(super) provider_factory: Arc<dyn ProviderFactory>,
    pub(super) guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    pub(super) hooks: Option<Arc<HookEngine>>,
    pub(super) worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
    pub(super) child_subagent_manager: Option<Arc<SubagentManager>>,
    pub(super) process_plan: crate::domains::agent::runner::ProcessExecutionPlan,
    pub(super) child_session_id: String,
    pub(super) parent_session_id: String,
    pub(super) task: String,
    pub(super) model: String,
    pub(super) system_prompt: String,
    pub(super) working_directory: String,
    pub(super) max_turns: u32,
    pub(super) subagent_max_depth: u32,
    pub(super) reasoning_level: Option<ReasoningLevel>,
    pub(super) spawn_type: String,
    pub(super) tracker: Arc<TrackedSubagent>,
    pub(super) cancel: CancellationToken,
    pub(super) capability_execution_policy: crate::shared::profile::CapabilityExecutionPolicySpec,
    pub(super) engine_host: Option<crate::engine::EngineHostHandle>,
}

pub(super) struct CapabilityAgentTaskLaunch {
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) event_store: Arc<EventStore>,
    pub(super) broadcast: Arc<EventEmitter>,
    pub(super) provider_factory: Arc<dyn ProviderFactory>,
    pub(super) guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    pub(super) hooks: Option<Arc<HookEngine>>,
    pub(super) worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
    pub(super) child_subagent_manager: Option<Arc<SubagentManager>>,
    pub(super) process_plan: crate::domains::agent::runner::ProcessExecutionPlan,
    pub(super) child_session_id: String,
    pub(super) parent_session_id: String,
    pub(super) task: String,
    pub(super) model: String,
    pub(super) system_prompt: Option<String>,
    pub(super) working_directory: String,
    pub(super) max_turns: u32,
    pub(super) subagent_depth: u32,
    pub(super) subagent_max_depth: u32,
    pub(super) blocking_timeout_ms: Option<u64>,
    pub(super) tracker: Arc<TrackedSubagent>,
    pub(super) cancel: CancellationToken,
    pub(super) denied_contracts: Vec<String>,
    /// Optional weak probe to query whether the parent session has an active
    /// agent run. Used to compute the `notify` field on
    /// `SubagentResultAvailable` (notify=true when parent is idle).
    pub(super) run_state_probe: Option<
        std::sync::Weak<
            dyn crate::domains::agent::runner::orchestrator::orchestrator::RunStateProbe,
        >,
    >,
    pub(super) spawn_type: String,
    pub(super) engine_host: Option<crate::engine::EngineHostHandle>,
}

fn capability_execution_policy_with_denials(
    base: &crate::shared::profile::CapabilityExecutionPolicySpec,
    denied_contracts: &[String],
) -> crate::shared::profile::CapabilityExecutionPolicySpec {
    let mut policy = base.clone();
    policy
        .denied_contracts
        .extend(denied_contracts.iter().cloned());
    policy
}

pub(super) fn spawn_subsession_task(params: SubsessionTaskLaunch) {
    let session_id = params.child_session_id.clone();
    let parent_session_id = params.parent_session_id.clone();
    let span = info_span!(
        "subsession",
        session_id = %session_id,
        parent_session_id = %parent_session_id,
        spawn_type = "subsession",
    );
    drop(tokio::spawn(run_subsession_task(params).instrument(span)));
}

pub(super) fn spawn_capability_agent_task(params: CapabilityAgentTaskLaunch) {
    let session_id = params.child_session_id.clone();
    let parent_session_id = params.parent_session_id.clone();
    let depth = params.subagent_depth;
    let span = info_span!(
        "subagent",
        session_id = %session_id,
        parent_session_id = %parent_session_id,
        depth,
        spawn_type = "capability_agent",
    );
    drop(tokio::spawn(
        run_capability_agent_task(params).instrument(span),
    ));
}

async fn run_subsession_task(params: SubsessionTaskLaunch) {
    let working_directory = match acquire_worktree_directory(
        params.worktree_coordinator.as_ref(),
        &params.child_session_id,
        params.working_directory,
        "subsession",
    )
    .await
    {
        Ok(working_directory) => working_directory,
        Err(error) => {
            tracing::warn!(
                child_session_id = %params.child_session_id,
                parent_session_id = %params.parent_session_id,
                error = %error,
                "subsession stopped before model execution because worktree isolation failed"
            );
            complete_failure(
                &params.session_manager,
                &params.tracker,
                &params.child_session_id,
                error,
            )
            .await;
            return;
        }
    };

    let provider = match params
        .provider_factory
        .create_for_model(&params.model)
        .await
    {
        Ok(provider) => provider,
        Err(error) => {
            tracing::warn!(model = %params.model, error = %error, "subsession provider creation failed");
            complete_failure(
                &params.session_manager,
                &params.tracker,
                &params.child_session_id,
                format!("Provider creation failed: {error}"),
            )
            .await;
            return;
        }
    };

    let child_broadcast = Arc::new(EventEmitter::new());

    let agent_config = AgentCfg {
        model: params.model.clone(),
        system_prompt: Some(params.system_prompt),
        max_turns: params.max_turns,
        enable_thinking: true,
        working_directory: Some(working_directory),
        ..AgentCfg::default()
    };

    let mut agent = AgentFactory::create_agent(
        agent_config,
        params.child_session_id.clone(),
        CreateAgentOpts {
            provider,
            context_policy: params.process_plan.runtime_context_policy(),
            primitive_surface_policy: params.process_plan.primitive_surface_policy.clone(),
            capability_execution_policy: params.capability_execution_policy.clone(),
            guardrails: params.guardrails,
            hooks: params.hooks.clone(),
            is_unattended: true,
            denied_primitives: Vec::new(),
            subagent_depth: 0,
            subagent_max_depth: params.subagent_max_depth,
            rules_content: None,
            initial_messages: vec![],
            memory_content: None,
            rules_index: None,
            pre_activated_rules: vec![],
            initial_turn_count: 0,
            subagent_manager: params.child_subagent_manager,
            compaction_trigger_config:
                crate::domains::agent::runner::context::types::CompactionTriggerConfig::default(),
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            engine_host: params.engine_host.clone(),
        },
    );

    agent.set_abort_token(params.cancel);

    let active = match params
        .session_manager
        .resume_session(&params.child_session_id)
    {
        Ok(active) => active,
        Err(error) => {
            complete_failure(
                &params.session_manager,
                &params.tracker,
                &params.child_session_id,
                format!("Failed to resume subsession: {error}"),
            )
            .await;
            return;
        }
    };
    let persister = active.context.persister.clone();
    agent.set_persister(Some(persister));

    let _ = params.event_store.append(&AppendOptions {
        session_id: &params.child_session_id,
        event_type: EventType::MessageUser,
        payload: json!({"content": params.task}),
        parent_id: None,
        sequence: None,
    });

    let result = agent_runner::run_agent(
        &mut agent,
        &params.task,
        RunContext {
            reasoning_level: params.reasoning_level,
            profile_name: Some(params.process_plan.resolved_profile.name.clone()),
            resolved_profile: Some(params.process_plan.resolved_profile.clone()),
            ..Default::default()
        },
        &params.hooks,
        &child_broadcast,
        None,
    )
    .await;

    let duration_ms = elapsed_ms(&params.tracker.started_at);
    let output = extract_output(&agent.context_manager().get_messages());
    let token_usage = serde_json::to_value(&result.total_token_usage).ok();

    let tracked_result = if let Some(error) = result.error {
        let _ = params.broadcast.emit(TronEvent::SubagentFailed {
            base: BaseEvent::now(&params.parent_session_id),
            subagent_session_id: params.child_session_id.clone(),
            error: error.clone(),
            duration: duration_ms,
            spawn_type: Some(params.spawn_type.clone()),
        });

        SubagentResult {
            session_id: params.child_session_id.clone(),
            output: error,
            token_usage,
            duration_ms,
            status: "failed".into(),
            turns_executed: result.turns_executed,
        }
    } else {
        let _ = params.broadcast.emit(TronEvent::SubagentCompleted {
            base: BaseEvent::now(&params.parent_session_id),
            subagent_session_id: params.child_session_id.clone(),
            total_turns: result.turns_executed,
            duration: duration_ms,
            full_output: Some(output.clone()),
            result_summary: Some(truncate(&output, 200).to_owned()),
            token_usage: token_usage.clone(),
            model: Some(params.model.clone()),
            spawn_type: Some(params.spawn_type.clone()),
        });

        SubagentResult {
            session_id: params.child_session_id.clone(),
            output,
            token_usage,
            duration_ms,
            status: "completed".into(),
            turns_executed: result.turns_executed,
        }
    };

    complete_with_result(
        &params.session_manager,
        &params.tracker,
        &params.child_session_id,
        tracked_result,
    )
    .await;

    info!(
        child_session = params.child_session_id,
        turns = result.turns_executed,
        duration_ms,
        "subsession execution finished"
    );
}

async fn run_capability_agent_task(params: CapabilityAgentTaskLaunch) {
    let working_directory = match acquire_worktree_directory(
        params.worktree_coordinator.as_ref(),
        &params.child_session_id,
        params.working_directory,
        "subagent",
    )
    .await
    {
        Ok(working_directory) => working_directory,
        Err(error) => {
            tracing::warn!(
                child_session_id = %params.child_session_id,
                parent_session_id = %params.parent_session_id,
                error = %error,
                "subagent stopped before model execution because worktree isolation failed"
            );
            complete_failure(
                &params.session_manager,
                &params.tracker,
                &params.child_session_id,
                error,
            )
            .await;
            return;
        }
    };

    let provider = match params
        .provider_factory
        .create_for_model(&params.model)
        .await
    {
        Ok(provider) => provider,
        Err(error) => {
            tracing::warn!(model = %params.model, error = %error, "subagent provider creation failed");
            complete_failure(
                &params.session_manager,
                &params.tracker,
                &params.child_session_id,
                format!("Provider creation failed: {error}"),
            )
            .await;
            return;
        }
    };

    let child_broadcast = Arc::new(EventEmitter::new());

    let agent_config = AgentCfg {
        model: params.model.clone(),
        system_prompt: params.system_prompt,
        max_turns: params.max_turns,
        enable_thinking: true,
        working_directory: Some(working_directory),
        ..AgentCfg::default()
    };

    let mut agent = AgentFactory::create_agent(
        agent_config,
        params.child_session_id.clone(),
        CreateAgentOpts {
            provider,
            context_policy: params.process_plan.runtime_context_policy(),
            primitive_surface_policy: params.process_plan.primitive_surface_policy.clone(),
            capability_execution_policy: capability_execution_policy_with_denials(
                &params.process_plan.capability_execution_policy,
                &params.denied_contracts,
            ),
            guardrails: params.guardrails,
            hooks: params.hooks.clone(),
            is_unattended: true,
            denied_primitives: Vec::new(),
            subagent_depth: params.subagent_depth,
            subagent_max_depth: params.subagent_max_depth,
            rules_content: None,
            initial_messages: vec![],
            memory_content: None,
            rules_index: None,
            pre_activated_rules: vec![],
            initial_turn_count: 0,
            subagent_manager: params.child_subagent_manager,
            compaction_trigger_config:
                crate::domains::agent::runner::context::types::CompactionTriggerConfig::default(),
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            engine_host: params.engine_host.clone(),
        },
    );

    agent.set_abort_token(params.cancel);

    let active = match params
        .session_manager
        .resume_session(&params.child_session_id)
    {
        Ok(active) => active,
        Err(error) => {
            complete_failure(
                &params.session_manager,
                &params.tracker,
                &params.child_session_id,
                format!("Failed to resume subagent session: {error}"),
            )
            .await;
            return;
        }
    };
    let persister = active.context.persister.clone();
    agent.set_persister(Some(persister));

    let _ = params.event_store.append(&AppendOptions {
        session_id: &params.child_session_id,
        event_type: EventType::MessageUser,
        payload: json!({"content": params.task}),
        parent_id: None,
        sequence: None,
    });

    let (forward_cancel, forward_handle) = spawn_child_event_forwarder(
        child_broadcast.as_ref(),
        params.broadcast.clone(),
        params.child_session_id.clone(),
        params.parent_session_id.clone(),
    );

    let result = agent_runner::run_agent(
        &mut agent,
        &params.task,
        RunContext {
            profile_name: Some(params.process_plan.resolved_profile.name.clone()),
            resolved_profile: Some(params.process_plan.resolved_profile.clone()),
            ..Default::default()
        },
        &params.hooks,
        &child_broadcast,
        None,
    )
    .await;

    forward_cancel.cancel();
    let _ = forward_handle.await;

    let duration_ms = elapsed_ms(&params.tracker.started_at);
    let output = extract_output(&agent.context_manager().get_messages());
    let token_usage = serde_json::to_value(&result.total_token_usage).ok();
    let success = result.error.is_none();
    let result_output;

    // INVARIANT: persist EventType::Subagent{Completed,Failed} BEFORE
    // broadcasting the corresponding TronEvent. Otherwise the broadcast
    // could reach iOS without a matching row in the parent session's
    // event log; session reconstruction on reconnect would show no
    // record that the subagent ever finished.
    let tracked_result = if success {
        if !params.tracker.parent_session_id.is_empty() {
            let persist_result = params.event_store.append(&AppendOptions {
                session_id: &params.tracker.parent_session_id,
                event_type: EventType::SubagentCompleted,
                payload: json!({
                    "subagentSessionId": params.child_session_id,
                    "totalTurns": result.turns_executed,
                    "duration": duration_ms,
                    "fullOutput": truncate(&output, 4000),
                    "resultSummary": truncate(&output, 200),
                    "model": params.model,
                    "spawnType": params.spawn_type,
                }),
                parent_id: None,
                sequence: None,
            });
            if let Err(error) = persist_result {
                tracing::error!(
                    parent_session = %params.tracker.parent_session_id,
                    child_session = %params.child_session_id,
                    error = %error,
                    "failed to persist subagent.completed event; skipping broadcast"
                );
            } else {
                let _ = params.broadcast.emit(TronEvent::SubagentCompleted {
                    base: BaseEvent::now(&params.tracker.parent_session_id),
                    subagent_session_id: params.child_session_id.clone(),
                    total_turns: result.turns_executed,
                    duration: duration_ms,
                    full_output: Some(output.clone()),
                    result_summary: Some(truncate(&output, 200).to_owned()),
                    token_usage: token_usage.clone(),
                    model: Some(params.model.clone()),
                    spawn_type: Some(params.spawn_type.clone()),
                });
            }
        } else {
            // No parent session → broadcast only; nothing to persist against.
            let _ = params.broadcast.emit(TronEvent::SubagentCompleted {
                base: BaseEvent::now(&params.tracker.parent_session_id),
                subagent_session_id: params.child_session_id.clone(),
                total_turns: result.turns_executed,
                duration: duration_ms,
                full_output: Some(output.clone()),
                result_summary: Some(truncate(&output, 200).to_owned()),
                token_usage: token_usage.clone(),
                model: Some(params.model.clone()),
                spawn_type: Some(params.spawn_type.clone()),
            });
        }

        result_output = output.clone();
        SubagentResult {
            session_id: params.child_session_id.clone(),
            output,
            token_usage: token_usage.clone(),
            duration_ms,
            status: "completed".into(),
            turns_executed: result.turns_executed,
        }
    } else {
        let error = result.error.unwrap_or_else(|| "Unknown error".into());

        if !params.tracker.parent_session_id.is_empty() {
            let persist_result = params.event_store.append(&AppendOptions {
                session_id: &params.tracker.parent_session_id,
                event_type: EventType::SubagentFailed,
                payload: json!({
                    "subagentSessionId": params.child_session_id,
                    "error": error,
                    "duration": duration_ms,
                    "spawnType": params.spawn_type,
                }),
                parent_id: None,
                sequence: None,
            });
            if let Err(persist_err) = persist_result {
                tracing::error!(
                    parent_session = %params.tracker.parent_session_id,
                    child_session = %params.child_session_id,
                    error = %persist_err,
                    "failed to persist subagent.failed event; skipping broadcast"
                );
            } else {
                let _ = params.broadcast.emit(TronEvent::SubagentFailed {
                    base: BaseEvent::now(&params.tracker.parent_session_id),
                    subagent_session_id: params.child_session_id.clone(),
                    error: error.clone(),
                    duration: duration_ms,
                    spawn_type: Some(params.spawn_type.clone()),
                });
            }
        } else {
            // No parent session → broadcast only.
            let _ = params.broadcast.emit(TronEvent::SubagentFailed {
                base: BaseEvent::now(&params.tracker.parent_session_id),
                subagent_session_id: params.child_session_id.clone(),
                error: error.clone(),
                duration: duration_ms,
                spawn_type: Some(params.spawn_type.clone()),
            });
        }

        result_output = error.clone();
        SubagentResult {
            session_id: params.child_session_id.clone(),
            output: error,
            token_usage: token_usage.clone(),
            duration_ms,
            status: "failed".into(),
            turns_executed: result.turns_executed,
        }
    };

    if !params.tracker.parent_session_id.is_empty() {
        create_subagent_agent_result_resource(
            params.engine_host.as_ref(),
            &params.tracker.parent_session_id,
            &params.child_session_id,
            &params.tracker.task,
            &result_output,
            success,
            result.turns_executed,
            duration_ms,
            token_usage.clone(),
            &params.spawn_type,
        )
        .await;
    }

    if params.blocking_timeout_ms.is_none() && !params.tracker.parent_session_id.is_empty() {
        // Compute `notify`: iOS should show a user-facing notification only
        // when the parent session is idle. If the parent is currently running
        // an agent turn, the backend delivers results via system-prompt
        // injection, so no iOS notification is needed. Defaults to `true`
        // (safe — user sees completion) if the probe is unavailable.
        let parent_active = params
            .run_state_probe
            .as_ref()
            .and_then(std::sync::Weak::upgrade)
            .is_some_and(|p| p.has_active_run(&params.tracker.parent_session_id));
        let notify = !parent_active;

        let _ = params.broadcast.emit(TronEvent::SubagentResultAvailable {
            base: BaseEvent::now(&params.tracker.parent_session_id),
            parent_session_id: params.tracker.parent_session_id.clone(),
            subagent_session_id: params.child_session_id.clone(),
            task: params.tracker.task.clone(),
            result_summary: truncate(&result_output, 200).to_owned(),
            success,
            total_turns: result.turns_executed,
            duration: duration_ms,
            token_usage,
            error: if success {
                None
            } else {
                Some(result_output.clone())
            },
            completed_at: chrono::Utc::now().to_rfc3339(),
            notify,
        });
    }

    complete_with_result(
        &params.session_manager,
        &params.tracker,
        &params.child_session_id,
        tracked_result,
    )
    .await;

    info!(
        child_session = params.child_session_id,
        turns = result.turns_executed,
        duration_ms,
        "subagent execution finished"
    );
}

async fn create_subagent_agent_result_resource(
    engine_host: Option<&crate::engine::EngineHostHandle>,
    parent_session_id: &str,
    child_session_id: &str,
    task: &str,
    output: &str,
    success: bool,
    turns_executed: u32,
    duration_ms: u64,
    token_usage: Option<Value>,
    spawn_type: &str,
) {
    let Some(engine_host) = engine_host else {
        return;
    };
    let session_id = if parent_session_id.is_empty() {
        child_session_id
    } else {
        parent_session_id
    };
    let context = CausalContext::new(
        ActorId::new("system:subagent").expect("valid actor id"),
        ActorKind::System,
        AuthorityGrantId::new("engine-system").expect("valid grant"),
        TraceId::generate(),
    )
    .with_session_id(session_id.to_owned())
    .with_scope(ENGINE_INTERNAL_INVOKE_SCOPE)
    .with_scope("resource.write")
    .with_idempotency_key(format!("subagent-agent-result:{child_session_id}"));
    let payload = json!({
        "kind": "agent_result",
        "resourceId": subagent_result_resource_id(child_session_id),
        "scope": "session",
        "sessionId": session_id,
        "lifecycle": "final",
        "payload": {
            "message": truncate(output, 4000),
            "promotedRefs": [],
            "decisionRefs": [],
            "subgoalRefs": [],
            "stopReason": if success { "completed" } else { "failed" },
            "tokenUsage": token_usage.unwrap_or_else(|| json!({})),
            "metadata": {
                "parentSessionId": parent_session_id,
                "subagentSessionId": child_session_id,
                "task": task,
                "success": success,
                "turnsExecuted": turns_executed,
                "durationMs": duration_ms,
                "spawnType": spawn_type
            }
        }
    });
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("resource::create").expect("valid function id"),
            payload,
            context,
        ))
        .await;
    if let Some(error) = result.error {
        tracing::warn!(
            parent_session_id,
            child_session_id,
            error = %error,
            "failed to create resource-native subagent agent_result"
        );
    }
}

async fn acquire_worktree_directory(
    coordinator: Option<&Arc<crate::domains::worktree::WorktreeCoordinator>>,
    session_id: &str,
    working_directory: String,
    label: &str,
) -> Result<String, String> {
    let Some(coord) = coordinator else {
        return Ok(working_directory);
    };

    match coord
        .maybe_acquire(session_id, Path::new(&working_directory))
        .await
    {
        Ok(crate::domains::worktree::AcquireResult::Acquired(info)) => {
            Ok(info.worktree_path.to_string_lossy().to_string())
        }
        Ok(crate::domains::worktree::AcquireResult::Deferred(reason)) => {
            tracing::debug!(
                session_id = %session_id,
                reason = ?reason,
                "{label} worktree isolation intentionally deferred"
            );
            Ok(working_directory)
        }
        Ok(crate::domains::worktree::AcquireResult::Passthrough) => Ok(working_directory),
        Err(error) => Err(format!("{label} worktree acquisition failed: {error}")),
    }
}

fn spawn_child_event_forwarder(
    child_broadcast: &EventEmitter,
    forward_broadcast: Arc<EventEmitter>,
    child_session_id: String,
    parent_session_id: String,
) -> (CancellationToken, tokio::task::JoinHandle<()>) {
    let mut child_rx = child_broadcast.subscribe();
    let forward_cancel = CancellationToken::new();
    let forward_cancel_clone = forward_cancel.clone();

    let handle = tokio::spawn(async move {
        let mut current_turn: u32 = 0;
        loop {
            tokio::select! {
                event = child_rx.recv() => {
                    match event {
                        Ok(ref event) => {
                            if let TronEvent::TurnStart { turn, .. } = event {
                                current_turn = *turn;
                            }

                            if let Some(activity) = activity_text(event) {
                                let _ = forward_broadcast.emit(TronEvent::SubagentStatusUpdate {
                                    base: BaseEvent::now(&parent_session_id),
                                    subagent_session_id: child_session_id.clone(),
                                    status: "running".into(),
                                    current_turn,
                                    activity: Some(activity),
                                });
                            }

                            if let Some(forwarded_event) = forwarded_subagent_event(event) {
                                let _ = forward_broadcast.emit(TronEvent::SubagentEvent {
                                    base: BaseEvent::now(&parent_session_id),
                                    subagent_session_id: child_session_id.clone(),
                                    event: forwarded_event,
                                });
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => {
                            metrics::counter!("broadcast_lagged_events_total", "source" => "subagent_forward")
                                .increment(count);
                        }
                    }
                }
                () = forward_cancel_clone.cancelled() => {
                    while let Ok(_event) = child_rx.try_recv() {}
                    break;
                }
            }
        }
    });

    (forward_cancel, handle)
}

fn activity_text(event: &TronEvent) -> Option<String> {
    match event {
        TronEvent::TurnStart { turn, .. } => Some(format!("Turn {turn} started")),
        TronEvent::CapabilityInvocationStarted {
            model_primitive_name,
            ..
        } => Some(format!("Executing {model_primitive_name}")),
        TronEvent::CapabilityInvocationCompleted {
            model_primitive_name,
            duration,
            ..
        } => Some(format!("{model_primitive_name} completed ({duration}ms)")),
        _ => None,
    }
}

fn forwarded_subagent_event(event: &TronEvent) -> Option<Value> {
    match event {
        TronEvent::MessageUpdate { content, .. } => Some(json!({
            "type": "agent.text_delta",
            "data": { "delta": content },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::CapabilityInvocationStarted {
            invocation_id,
            model_primitive_name,
            arguments,
            ..
        } => Some(json!({
            "type": "capability.invocation.started",
            "data": {
                "invocationId": invocation_id,
                "modelPrimitiveName": model_primitive_name,
                "arguments": arguments,
            },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::CapabilityInvocationCompleted {
            invocation_id,
            model_primitive_name,
            is_error,
            duration,
            result,
            ..
        } => {
            let result_text =
                result
                    .as_ref()
                    .map(|capability_result| match &capability_result.content {
                        crate::shared::model_capabilities::CapabilityResultBody::Text(text) => {
                            text.clone()
                        }
                        crate::shared::model_capabilities::CapabilityResultBody::Blocks(blocks) => {
                            blocks
                                .iter()
                                .filter_map(|block| {
                                    if let crate::shared::content::CapabilityResultContent::Text {
                                        text,
                                    } = block
                                    {
                                        Some(text.as_str())
                                    } else {
                                        None
                                    }
                                })
                                .collect::<Vec<_>>()
                                .join("")
                        }
                    });
            Some(json!({
                "type": "capability.invocation.completed",
                "data": {
                    "invocationId": invocation_id,
                    "modelPrimitiveName": model_primitive_name,
                    "isError": is_error.unwrap_or(false),
                    "content": result_text.unwrap_or_default(),
                    "duration": duration,
                },
                "timestamp": chrono::Utc::now().to_rfc3339(),
            }))
        }
        TronEvent::TurnStart { turn, .. } => Some(json!({
            "type": "turn_start",
            "data": { "turn": turn },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::TurnEnd { turn, .. } => Some(json!({
            "type": "turn_end",
            "data": { "turn": turn },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        _ => None,
    }
}

fn extract_output(messages: &[crate::shared::messages::Message]) -> String {
    messages
        .iter()
        .rev()
        .find_map(|message| {
            if let crate::shared::messages::Message::Assistant { content, .. } = message {
                let text: String = content
                    .iter()
                    .filter_map(|item| item.as_text())
                    .collect::<Vec<_>>()
                    .join("");
                if text.is_empty() { None } else { Some(text) }
            } else {
                None
            }
        })
        .unwrap_or_default()
}

async fn complete_failure(
    session_manager: &SessionManager,
    tracker: &Arc<TrackedSubagent>,
    child_session_id: &str,
    output: String,
) {
    complete_with_result(
        session_manager,
        tracker,
        child_session_id,
        SubagentResult {
            session_id: child_session_id.to_owned(),
            output,
            token_usage: None,
            duration_ms: elapsed_ms(&tracker.started_at),
            status: "failed".into(),
            turns_executed: 0,
        },
    )
    .await;
}

async fn complete_with_result(
    session_manager: &SessionManager,
    tracker: &Arc<TrackedSubagent>,
    child_session_id: &str,
    result: SubagentResult,
) {
    *tracker.result.lock() = Some(result);

    if let Err(error) = session_manager.end_session(child_session_id).await {
        tracing::warn!(
            session_id = %child_session_id,
            error = %error,
            "failed to end subagent session during cleanup"
        );
    }

    tracker.done.notify_waiters();
}
