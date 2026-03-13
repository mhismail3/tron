use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{Instrument, info, info_span};
use tron_core::events::{BaseEvent, TronEvent};
use tron_events::{AppendOptions, EventType};
use tron_llm::provider::ProviderFactory;
use tron_tools::registry::ToolRegistry;

use super::{SubagentManager, SubagentResult, TrackedSubagent, elapsed_ms, truncate};
use crate::agent::event_emitter::EventEmitter;
use crate::guardrails::GuardrailEngine;
use crate::hooks::engine::HookEngine;
use crate::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::orchestrator::agent_runner;
use crate::orchestrator::session_manager::SessionManager;
use crate::types::ReasoningLevel;
use crate::types::{AgentConfig as AgentCfg, RunContext};
use tron_events::EventStore;

pub(super) struct SubsessionTaskLaunch {
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) event_store: Arc<EventStore>,
    pub(super) broadcast: Arc<EventEmitter>,
    pub(super) provider_factory: Arc<dyn ProviderFactory>,
    pub(super) hooks: Option<Arc<HookEngine>>,
    pub(super) worktree_coordinator: Option<Arc<tron_worktree::WorktreeCoordinator>>,
    pub(super) child_subagent_manager: Option<Arc<SubagentManager>>,
    pub(super) child_session_id: String,
    pub(super) parent_session_id: String,
    pub(super) task: String,
    pub(super) model: String,
    pub(super) system_prompt: String,
    pub(super) working_directory: String,
    pub(super) max_turns: u32,
    pub(super) subagent_max_depth: u32,
    pub(super) reasoning_level: Option<ReasoningLevel>,
    pub(super) tracker: Arc<TrackedSubagent>,
    pub(super) cancel: CancellationToken,
    pub(super) tools: ToolRegistry,
}

pub(super) struct ToolAgentTaskLaunch {
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) event_store: Arc<EventStore>,
    pub(super) broadcast: Arc<EventEmitter>,
    pub(super) provider_factory: Arc<dyn ProviderFactory>,
    pub(super) guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    pub(super) hooks: Option<Arc<HookEngine>>,
    pub(super) worktree_coordinator: Option<Arc<tron_worktree::WorktreeCoordinator>>,
    pub(super) child_subagent_manager: Option<Arc<SubagentManager>>,
    pub(super) child_session_id: String,
    pub(super) parent_session_id: String,
    pub(super) task: String,
    pub(super) model: String,
    pub(super) system_prompt: Option<String>,
    pub(super) working_directory: String,
    pub(super) max_turns: u32,
    pub(super) subagent_depth: u32,
    pub(super) subagent_max_depth: u32,
    pub(super) blocking: bool,
    pub(super) tracker: Arc<TrackedSubagent>,
    pub(super) cancel: CancellationToken,
    pub(super) tools: ToolRegistry,
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

pub(super) fn spawn_tool_agent_task(params: ToolAgentTaskLaunch) {
    let session_id = params.child_session_id.clone();
    let parent_session_id = params.parent_session_id.clone();
    let depth = params.subagent_depth;
    let span = info_span!(
        "subagent",
        session_id = %session_id,
        parent_session_id = %parent_session_id,
        depth,
        spawn_type = "tool_agent",
    );
    drop(tokio::spawn(run_tool_agent_task(params).instrument(span)));
}

async fn run_subsession_task(params: SubsessionTaskLaunch) {
    let working_directory = acquire_worktree_directory(
        params.worktree_coordinator.as_ref(),
        &params.child_session_id,
        params.working_directory,
        "subsession",
    )
    .await;

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
            tools: params.tools,
            guardrails: None,
            hooks: params.hooks.clone(),
            is_unattended: true,
            denied_tools: vec![],
            subagent_depth: 0,
            subagent_max_depth: params.subagent_max_depth,
            rules_content: None,
            initial_messages: vec![],
            memory_content: None,
            rules_index: None,
            pre_activated_rules: vec![],
            subagent_manager: params.child_subagent_manager,
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
    });

    let result = agent_runner::run_agent(
        &mut agent,
        &params.task,
        RunContext {
            reasoning_level: params.reasoning_level,
            ..Default::default()
        },
        &params.hooks,
        &child_broadcast,
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
        });

        SubagentResult {
            session_id: params.child_session_id.clone(),
            output: error,
            token_usage,
            duration_ms,
            status: "failed".into(),
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
        });

        SubagentResult {
            session_id: params.child_session_id.clone(),
            output,
            token_usage,
            duration_ms,
            status: "completed".into(),
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

async fn run_tool_agent_task(params: ToolAgentTaskLaunch) {
    let working_directory = acquire_worktree_directory(
        params.worktree_coordinator.as_ref(),
        &params.child_session_id,
        params.working_directory,
        "subagent",
    )
    .await;

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
            tools: params.tools,
            guardrails: params.guardrails,
            hooks: params.hooks.clone(),
            is_unattended: true,
            denied_tools: vec![],
            subagent_depth: params.subagent_depth,
            subagent_max_depth: params.subagent_max_depth,
            rules_content: None,
            initial_messages: vec![],
            memory_content: None,
            rules_index: None,
            pre_activated_rules: vec![],
            subagent_manager: params.child_subagent_manager,
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
        RunContext::default(),
        &params.hooks,
        &child_broadcast,
    )
    .await;

    forward_cancel.cancel();
    let _ = forward_handle.await;

    let duration_ms = elapsed_ms(&params.tracker.started_at);
    let output = extract_output(&agent.context_manager().get_messages());
    let token_usage = serde_json::to_value(&result.total_token_usage).ok();
    let success = result.error.is_none();
    let result_output;

    let tracked_result = if success {
        let _ = params.broadcast.emit(TronEvent::SubagentCompleted {
            base: BaseEvent::now(&params.tracker.parent_session_id),
            subagent_session_id: params.child_session_id.clone(),
            total_turns: result.turns_executed,
            duration: duration_ms,
            full_output: Some(output.clone()),
            result_summary: Some(truncate(&output, 200).to_owned()),
            token_usage: token_usage.clone(),
            model: Some(params.model.clone()),
        });

        if !params.tracker.parent_session_id.is_empty() {
            let _ = params.event_store.append(&AppendOptions {
                session_id: &params.tracker.parent_session_id,
                event_type: EventType::SubagentCompleted,
                payload: json!({
                    "subagentSessionId": params.child_session_id,
                    "totalTurns": result.turns_executed,
                    "duration": duration_ms,
                    "fullOutput": truncate(&output, 4000),
                    "resultSummary": truncate(&output, 200),
                    "model": params.model,
                }),
                parent_id: None,
            });
        }

        result_output = output.clone();
        SubagentResult {
            session_id: params.child_session_id.clone(),
            output,
            token_usage: token_usage.clone(),
            duration_ms,
            status: "completed".into(),
        }
    } else {
        let error = result.error.unwrap_or_else(|| "Unknown error".into());
        let _ = params.broadcast.emit(TronEvent::SubagentFailed {
            base: BaseEvent::now(&params.tracker.parent_session_id),
            subagent_session_id: params.child_session_id.clone(),
            error: error.clone(),
            duration: duration_ms,
        });

        if !params.tracker.parent_session_id.is_empty() {
            let _ = params.event_store.append(&AppendOptions {
                session_id: &params.tracker.parent_session_id,
                event_type: EventType::SubagentFailed,
                payload: json!({
                    "subagentSessionId": params.child_session_id,
                    "error": error,
                    "duration": duration_ms,
                }),
                parent_id: None,
            });
        }

        result_output = error.clone();
        SubagentResult {
            session_id: params.child_session_id.clone(),
            output: error,
            token_usage: token_usage.clone(),
            duration_ms,
            status: "failed".into(),
        }
    };

    if !params.blocking && !params.tracker.parent_session_id.is_empty() {
        let payload = json!({
            "parentSessionId": params.tracker.parent_session_id,
            "subagentSessionId": params.child_session_id,
            "task": params.tracker.task,
            "resultSummary": truncate(&result_output, 200),
            "success": success,
            "totalTurns": i64::from(result.turns_executed),
            "duration": duration_ms,
            "tokenUsage": token_usage.clone().unwrap_or(json!({})),
            "completedAt": chrono::Utc::now().to_rfc3339(),
            "output": truncate(&result_output, 4000),
        });
        let _ = params.event_store.append(&AppendOptions {
            session_id: &params.tracker.parent_session_id,
            event_type: EventType::NotificationSubagentResult,
            payload,
            parent_id: None,
        });

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

async fn acquire_worktree_directory(
    coordinator: Option<&Arc<tron_worktree::WorktreeCoordinator>>,
    session_id: &str,
    working_directory: String,
    label: &str,
) -> String {
    let Some(coord) = coordinator else {
        return working_directory;
    };

    match coord
        .maybe_acquire(session_id, Path::new(&working_directory))
        .await
    {
        Ok(tron_worktree::AcquireResult::Acquired(info)) => {
            info.worktree_path.to_string_lossy().to_string()
        }
        Ok(tron_worktree::AcquireResult::Passthrough) => working_directory,
        Err(error) => {
            tracing::warn!(
                session_id = %session_id,
                error = %error,
                "{label} worktree acquisition failed, using original directory"
            );
            working_directory
        }
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
        TronEvent::ToolExecutionStart { tool_name, .. } => Some(format!("Executing {tool_name}")),
        TronEvent::ToolExecutionEnd {
            tool_name,
            duration,
            ..
        } => Some(format!("{tool_name} completed ({duration}ms)")),
        _ => None,
    }
}

fn forwarded_subagent_event(event: &TronEvent) -> Option<Value> {
    match event {
        TronEvent::MessageUpdate { content, .. } => Some(json!({
            "type": "text_delta",
            "data": { "delta": content },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::ToolExecutionStart {
            tool_call_id,
            tool_name,
            arguments,
            ..
        } => Some(json!({
            "type": "tool_start",
            "data": {
                "toolCallId": tool_call_id,
                "toolName": tool_name,
                "arguments": arguments,
            },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        })),
        TronEvent::ToolExecutionEnd {
            tool_call_id,
            tool_name,
            is_error,
            duration,
            result,
            ..
        } => {
            let result_text = result
                .as_ref()
                .map(|tool_result| match &tool_result.content {
                    tron_core::tools::ToolResultBody::Text(text) => text.clone(),
                    tron_core::tools::ToolResultBody::Blocks(blocks) => blocks
                        .iter()
                        .filter_map(|block| {
                            if let tron_core::content::ToolResultContent::Text { text } = block {
                                Some(text.as_str())
                            } else {
                                None
                            }
                        })
                        .collect::<Vec<_>>()
                        .join(""),
                });
            Some(json!({
                "type": "tool_end",
                "data": {
                    "toolCallId": tool_call_id,
                    "toolName": tool_name,
                    "success": !is_error.unwrap_or(false),
                    "result": result_text,
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

fn extract_output(messages: &[tron_core::messages::Message]) -> String {
    messages
        .iter()
        .rev()
        .find_map(|message| {
            if let tron_core::messages::Message::Assistant { content, .. } = message {
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
