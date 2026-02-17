//! SubagentManager — real `SubagentSpawner` implementation.
//!
//! Spawns child agents in-process, tracks their state, and forwards
//! events from child sessions to the parent session's broadcast.

use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use dashmap::DashMap;
use parking_lot::Mutex;
use serde_json::{json, Value};
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;
use tracing::{info, info_span, Instrument};
use tron_core::events::{BaseEvent, TronEvent};
use tron_events::{EventStore, EventType};
use crate::guardrails::GuardrailEngine;
use crate::hooks::engine::HookEngine;
use tron_llm::provider::ProviderFactory;
use tron_tools::errors::ToolError;
use tron_tools::registry::ToolRegistry;
use tron_tools::traits::{
    SubagentConfig, SubagentHandle, SubagentMode, SubagentResult, SubagentSpawner, WaitMode,
};

use crate::agent::event_emitter::EventEmitter;
use crate::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::orchestrator::agent_runner;
use crate::orchestrator::session_manager::SessionManager;
use crate::types::{AgentConfig as AgentCfg, ReasoningLevel, RunContext};

// =============================================================================
// SpawnType — taxonomy for tracked subagents
// =============================================================================

/// Distinguishes tool-spawned agents from system-spawned subsessions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpawnType {
    /// Spawned by the LLM via the SpawnSubagent tool.
    ToolAgent,
    /// Spawned programmatically for internal tasks (ledger, compaction, etc.).
    Subsession,
}

// =============================================================================
// SubsessionConfig / SubsessionOutput — subsession API types
// =============================================================================

/// Configuration for a system-spawned subsession.
pub struct SubsessionConfig {
    /// Parent session ID (for audit trail).
    pub parent_session_id: String,
    /// User message content sent to the subsession.
    pub task: String,
    /// Override model (None = parent's model via provider).
    pub model: Option<String>,
    /// Custom system prompt for the subsession.
    pub system_prompt: String,
    /// Working directory for the child agent.
    pub working_directory: String,
    /// Timeout in milliseconds (default 30_000).
    pub timeout_ms: u64,
    /// If true, wait for completion; if false, return immediately with session_id.
    pub blocking: bool,
    /// Maximum LLM turns (default 1).
    pub max_turns: u32,
    /// Maximum subagent nesting depth (default 0 = no nesting).
    pub max_depth: u32,
    /// Whether to inherit tools from the parent's tool factory (default false).
    pub inherit_tools: bool,
    /// Tools to deny from the inherited set.
    pub denied_tools: Vec<String>,
    /// Reasoning effort level (default Some(Medium)).
    pub reasoning_level: Option<ReasoningLevel>,
}

impl Default for SubsessionConfig {
    fn default() -> Self {
        Self {
            parent_session_id: String::new(),
            task: String::new(),
            model: None,
            system_prompt: String::new(),
            working_directory: "/tmp".into(),
            timeout_ms: 30_000,
            blocking: true,
            max_turns: 1,
            max_depth: 0,
            inherit_tools: false,
            denied_tools: vec![],
            reasoning_level: Some(ReasoningLevel::Medium),
        }
    }
}

/// Output from a completed subsession.
pub struct SubsessionOutput {
    /// Child session ID.
    pub session_id: String,
    /// Full assistant text response.
    pub output: String,
    /// Token usage from the run.
    pub token_usage: Option<Value>,
    /// Wall-clock duration.
    pub duration_ms: u64,
}

/// Internal tracking for a running subagent.
struct TrackedSubagent {
    parent_session_id: String,
    task: String,
    model: String,
    depth: u32,
    spawn_type: SpawnType,
    started_at: Instant,
    done: Notify,
    result: Mutex<Option<SubagentResult>>,
    cancel: CancellationToken,
}

/// Real `SubagentSpawner` implementation for in-process subagent execution.
pub struct SubagentManager {
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    broadcast: Arc<EventEmitter>,
    provider_factory: Arc<dyn ProviderFactory>,
    tool_factory: tokio::sync::OnceCell<Arc<dyn Fn() -> ToolRegistry + Send + Sync>>,
    guardrails: Option<Arc<std::sync::Mutex<GuardrailEngine>>>,
    hooks: Option<Arc<HookEngine>>,
    /// Tracked subagents: child_session_id → TrackedSubagent.
    subagents: DashMap<String, Arc<TrackedSubagent>>,
}

impl SubagentManager {
    /// Create a new `SubagentManager`.
    pub fn new(
        session_manager: Arc<SessionManager>,
        event_store: Arc<EventStore>,
        broadcast: Arc<EventEmitter>,
        provider_factory: Arc<dyn ProviderFactory>,
        guardrails: Option<Arc<std::sync::Mutex<GuardrailEngine>>>,
        hooks: Option<Arc<HookEngine>>,
    ) -> Self {
        Self {
            session_manager,
            event_store,
            broadcast,
            provider_factory,
            tool_factory: tokio::sync::OnceCell::new(),
            guardrails,
            hooks,
            subagents: DashMap::new(),
        }
    }

    /// Set the tool factory (breaks circular dependency with tool registry).
    pub fn set_tool_factory(
        &self,
        factory: Arc<dyn Fn() -> ToolRegistry + Send + Sync>,
    ) {
        let _ = self.tool_factory.set(factory);
    }

    /// Count active subagents of a given type.
    pub fn active_count_by_type(&self, spawn_type: &SpawnType) -> usize {
        self.subagents
            .iter()
            .filter(|entry| {
                entry.value().spawn_type == *spawn_type && entry.value().result.lock().is_none()
            })
            .count()
    }

    /// List active subsessions as `(session_id, task)` pairs.
    pub fn list_active_subsessions(&self) -> Vec<(String, String)> {
        self.subagents
            .iter()
            .filter(|entry| {
                entry.value().spawn_type == SpawnType::Subsession
                    && entry.value().result.lock().is_none()
            })
            .map(|entry| {
                (entry.key().clone(), entry.value().task.clone())
            })
            .collect()
    }

    /// Spawn a system subsession with full configurability.
    ///
    /// Unlike `spawn()` (tool-agent path), the caller provides the system prompt
    /// directly, tools are optional, and the subsession is tracked as
    /// `SpawnType::Subsession`.
    pub async fn spawn_subsession(
        &self,
        config: SubsessionConfig,
    ) -> Result<SubsessionOutput, ToolError> {
        let model = config
            .model
            .as_deref()
            .unwrap_or(tron_llm::model_ids::SUBAGENT_MODEL);
        let task = config.task.clone();

        // 1. Create child session
        let title = format!("Subsession: {}", truncate(&task, 60));
        let child_session_id = self
            .session_manager
            .create_session_for_subagent(
                model,
                &config.working_directory,
                Some(&title),
                &config.parent_session_id,
                "subsession",
                &task,
            )
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to create subsession: {e}"),
            })?;

        // 2. Register tracking
        let cancel = CancellationToken::new();
        let tracker = Arc::new(TrackedSubagent {
            parent_session_id: config.parent_session_id.clone(),
            task: task.clone(),
            model: model.to_owned(),
            depth: 0,
            spawn_type: SpawnType::Subsession,
            started_at: Instant::now(),
            done: Notify::new(),
            result: Mutex::new(None),
            cancel: cancel.clone(),
        });

        let _ = self
            .subagents
            .insert(child_session_id.clone(), tracker.clone());

        // 3. Emit SubagentSpawned on broadcast
        let _ = self.broadcast.emit(TronEvent::SubagentSpawned {
            base: BaseEvent::now(&config.parent_session_id),
            subagent_session_id: child_session_id.clone(),
            task: task.clone(),
            model: model.to_owned(),
            max_turns: config.max_turns,
            spawn_depth: 0,
            tool_call_id: None,
            blocking: config.blocking,
            working_directory: Some(config.working_directory.clone()),
        });

        // 4. Build tools
        let tools = if config.inherit_tools {
            if let Some(factory) = self.tool_factory.get() {
                let mut registry = factory();
                for name in &config.denied_tools {
                    let _ = registry.remove(name);
                }
                registry
            } else {
                ToolRegistry::new()
            }
        } else {
            ToolRegistry::new()
        };

        // 5. Spawn execution task
        let session_mgr = self.session_manager.clone();
        let event_store = self.event_store.clone();
        let broadcast = self.broadcast.clone();
        let provider_factory = self.provider_factory.clone();
        let hooks = self.hooks.clone();
        let child_sid = child_session_id.clone();
        let max_turns = config.max_turns;
        let model_owned = model.to_owned();
        let system_prompt = config.system_prompt.clone();
        let working_directory = config.working_directory.clone();
        let subagent_max_depth = config.max_depth;
        let reasoning_level = config.reasoning_level;
        let parent_session_id = config.parent_session_id.clone();
        let tracker_clone = tracker.clone();

        let subsession_span = info_span!(
            "subsession",
            session_id = %child_session_id,
            parent_session_id = %parent_session_id,
            spawn_type = "subsession",
        );
        let _ = tokio::spawn(async move {
            let provider = match provider_factory.create_for_model(&model_owned).await {
                Ok(p) => p,
                Err(e) => {
                    tracing::warn!(model = %model_owned, error = %e, "subsession provider creation failed");
                    *tracker_clone.result.lock() = Some(SubagentResult {
                        session_id: child_sid.clone(),
                        output: format!("Provider creation failed: {e}"),
                        token_usage: None,
                        duration_ms: tracker_clone.started_at.elapsed().as_millis() as u64,
                        status: "failed".into(),
                    });
                    tracker_clone.done.notify_waiters();
                    return;
                }
            };

            let child_broadcast = Arc::new(EventEmitter::new());

            let agent_config = AgentCfg {
                model: model_owned.clone(),
                system_prompt: Some(system_prompt),
                max_turns,
                enable_thinking: true,
                working_directory: Some(working_directory),
                ..AgentCfg::default()
            };

            let mut agent = AgentFactory::create_agent(
                agent_config,
                child_sid.clone(),
                CreateAgentOpts {
                    provider,
                    tools,
                    guardrails: None,
                    hooks: hooks.clone(),
                    is_subagent: true,
                    denied_tools: vec![],
                    subagent_depth: 0,
                    subagent_max_depth: subagent_max_depth,
                    rules_content: None,
                    initial_messages: vec![],
                    memory_content: None,
                    rules_index: None,
                    pre_activated_rules: vec![],
                },
            );

            agent.set_abort_token(cancel);

            // Use the session's persister (created by SessionManager in create_session_for_subagent)
            let active = session_mgr
                .resume_session(&child_sid)
                .expect("just-created subsession must be in active_sessions");
            let persister = active.context.persister.clone();
            agent.set_persister(Some(persister));

            // Persist message.user — matching regular session flow
            let _ = event_store.append(&tron_events::AppendOptions {
                session_id: &child_sid,
                event_type: EventType::MessageUser,
                payload: json!({"content": task}),
                parent_id: None,
            });

            // Run the agent
            let result = agent_runner::run_agent(
                &mut agent,
                &task,
                RunContext {
                    reasoning_level,
                    ..Default::default()
                },
                &hooks,
                &child_broadcast,
            )
            .await;

            let duration_ms = tracker_clone.started_at.elapsed().as_millis() as u64;

            // Extract output from agent's last assistant message
            let output = {
                let messages = agent.context_manager().get_messages();
                messages
                    .iter()
                    .rev()
                    .find_map(|m| {
                        if let tron_core::messages::Message::Assistant { content, .. } = m {
                            let text: String = content
                                .iter()
                                .filter_map(|c| c.as_text())
                                .collect::<Vec<_>>()
                                .join("");
                            if text.is_empty() { None } else { Some(text) }
                        } else {
                            None
                        }
                    })
                    .unwrap_or_default()
            };

            let token_usage = serde_json::to_value(&result.total_token_usage).ok();

            if result.error.is_some() {
                let error = result.error.unwrap_or_else(|| "Unknown error".into());
                let _ = broadcast.emit(TronEvent::SubagentFailed {
                    base: BaseEvent::now(&parent_session_id),
                    subagent_session_id: child_sid.clone(),
                    error: error.clone(),
                    duration: duration_ms,
                });

                *tracker_clone.result.lock() = Some(SubagentResult {
                    session_id: child_sid.clone(),
                    output: error,
                    token_usage,
                    duration_ms,
                    status: "failed".into(),
                });
            } else {
                let _ = broadcast.emit(TronEvent::SubagentCompleted {
                    base: BaseEvent::now(&parent_session_id),
                    subagent_session_id: child_sid.clone(),
                    total_turns: result.turns_executed,
                    duration: duration_ms,
                    full_output: Some(output.clone()),
                    result_summary: Some(truncate(&output, 200).to_owned()),
                    token_usage: token_usage.clone(),
                    model: Some(model_owned.clone()),
                });

                *tracker_clone.result.lock() = Some(SubagentResult {
                    session_id: child_sid.clone(),
                    output,
                    token_usage,
                    duration_ms,
                    status: "completed".into(),
                });
            }

            tracker_clone.done.notify_waiters();

            let _ = session_mgr.end_session(&child_sid).await;

            info!(
                child_session = child_sid,
                turns = result.turns_executed,
                duration_ms,
                "subsession execution finished"
            );
        }.instrument(subsession_span));

        // 6. If blocking, wait for completion
        if config.blocking {
            let timeout = std::time::Duration::from_millis(config.timeout_ms);
            let wait_result = tokio::time::timeout(timeout, tracker.done.notified()).await;

            if wait_result.is_err() {
                tracker.cancel.cancel();
                return Err(ToolError::Timeout {
                    timeout_ms: config.timeout_ms,
                });
            }

            let result = tracker.result.lock().clone();
            if let Some(r) = result {
                Ok(SubsessionOutput {
                    session_id: child_session_id,
                    output: r.output,
                    token_usage: r.token_usage,
                    duration_ms: r.duration_ms,
                })
            } else {
                Ok(SubsessionOutput {
                    session_id: child_session_id,
                    output: String::new(),
                    token_usage: None,
                    duration_ms: 0,
                })
            }
        } else {
            Ok(SubsessionOutput {
                session_id: child_session_id,
                output: String::new(),
                token_usage: None,
                duration_ms: 0,
            })
        }
    }
}

#[async_trait]
impl SubagentSpawner for SubagentManager {
    async fn spawn(&self, config: SubagentConfig) -> Result<SubagentHandle, ToolError> {
        // Validate mode
        if config.mode == SubagentMode::Tmux {
            return Err(ToolError::Validation {
                message: "Tmux mode is not yet supported. Use inProcess mode.".into(),
            });
        }

        // Depth check: current_depth > 0 means we're inside a subagent
        if config.current_depth > 0 && config.max_depth == 0 {
            return Err(ToolError::Validation {
                message: "Subagent nesting is not allowed at this depth.".into(),
            });
        }

        let tool_factory = self.tool_factory.get().ok_or_else(|| ToolError::Internal {
            message: "SubagentManager tool factory not initialized".into(),
        })?;

        let model = config
            .model
            .as_deref()
            .unwrap_or(tron_llm::model_ids::SUBAGENT_MODEL);
        let task = config.task.clone();
        let parent_sid = config.parent_session_id.clone().unwrap_or_default();

        // 1. Create child session
        let title = format!("Subagent: {}", truncate(&task, 60));
        let workspace = &config.working_directory;
        let child_session_id = self
            .session_manager
            .create_session_for_subagent(
                model,
                workspace,
                Some(&title),
                if parent_sid.is_empty() { "parent-placeholder" } else { &parent_sid },
                "inProcess",
                &task,
            )
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to create subagent session: {e}"),
            })?;

        // 2. Register tracking
        let cancel = CancellationToken::new();
        let tracker = Arc::new(TrackedSubagent {
            parent_session_id: parent_sid.clone(),
            task: task.clone(),
            model: model.to_owned(),
            depth: config.current_depth,
            spawn_type: SpawnType::ToolAgent,
            started_at: Instant::now(),
            done: Notify::new(),
            result: Mutex::new(None),
            cancel: cancel.clone(),
        });

        let _ = self.subagents
            .insert(child_session_id.clone(), tracker.clone());

        // 3. Emit SubagentSpawned on broadcast (routed to parent session for iOS)
        let _ = self.broadcast.emit(TronEvent::SubagentSpawned {
            base: BaseEvent::now(&parent_sid),
            subagent_session_id: child_session_id.clone(),
            task: task.clone(),
            model: model.to_owned(),
            max_turns: config.max_turns,
            spawn_depth: config.current_depth,
            tool_call_id: config.tool_call_id.clone(),
            blocking: config.blocking,
            working_directory: Some(config.working_directory.clone()),
        });

        // Persist subagent.spawned to parent session (iOS reconstructs from this on resume)
        if !parent_sid.is_empty() {
            let _ = self.event_store.append(&tron_events::AppendOptions {
                session_id: &parent_sid,
                event_type: EventType::SubagentSpawned,
                payload: json!({
                    "subagentSessionId": child_session_id,
                    "task": task,
                    "model": model,
                    "maxTurns": config.max_turns,
                    "spawnDepth": config.current_depth,
                    "toolCallId": config.tool_call_id,
                    "blocking": config.blocking,
                    "workingDirectory": config.working_directory,
                }),
                parent_id: None,
            });
        }

        // 4. Spawn execution task
        let session_mgr = self.session_manager.clone();
        let event_store = self.event_store.clone();
        let broadcast = self.broadcast.clone();
        let provider_factory = self.provider_factory.clone();
        let tools = tool_factory();
        let guardrails = self.guardrails.clone();
        let hooks = self.hooks.clone();
        let child_sid = child_session_id.clone();
        let max_turns = config.max_turns;
        let model_owned = model.to_owned();
        let system_prompt = config.system_prompt.clone();
        let working_directory = config.working_directory.clone();
        let subagent_max_depth = config.max_depth;
        let subagent_depth = config.current_depth;
        let blocking = config.blocking;
        let tracker_clone = tracker.clone();

        let subagent_span = info_span!(
            "subagent",
            session_id = %child_session_id,
            parent_session_id = %parent_sid,
            depth = subagent_depth,
            spawn_type = "tool_agent",
        );
        let _ = tokio::spawn(async move {
            let provider = match provider_factory.create_for_model(&model_owned).await {
                Ok(p) => p,
                Err(e) => {
                    tracing::warn!(model = %model_owned, error = %e, "subagent provider creation failed");
                    *tracker_clone.result.lock() = Some(SubagentResult {
                        session_id: child_sid.clone(),
                        output: format!("Provider creation failed: {e}"),
                        token_usage: None,
                        duration_ms: tracker_clone.started_at.elapsed().as_millis() as u64,
                        status: "failed".into(),
                    });
                    tracker_clone.done.notify_waiters();
                    return;
                }
            };

            let child_broadcast = Arc::new(EventEmitter::new());

            // Build agent
            let agent_config = AgentCfg {
                model: model_owned.clone(),
                system_prompt,
                max_turns,
                enable_thinking: true,
                working_directory: Some(working_directory),
                ..AgentCfg::default()
            };

            let mut agent = AgentFactory::create_agent(
                agent_config,
                child_sid.clone(),
                CreateAgentOpts {
                    provider,
                    tools,
                    guardrails,
                    hooks: hooks.clone(),
                    is_subagent: true,
                    denied_tools: vec![],
                    subagent_depth,
                    subagent_max_depth,
                    rules_content: None,
                    initial_messages: vec![],
                    memory_content: None,
                    rules_index: None,
                    pre_activated_rules: vec![],
                },
            );

            agent.set_abort_token(cancel);

            // Use the session's persister (created by SessionManager in create_session_for_subagent)
            let active = session_mgr
                .resume_session(&child_sid)
                .expect("just-created subagent session must be in active_sessions");
            let persister = active.context.persister.clone();
            agent.set_persister(Some(persister));

            // Persist message.user — matching regular session flow
            let _ = event_store.append(&tron_events::AppendOptions {
                session_id: &child_sid,
                event_type: EventType::MessageUser,
                payload: json!({"content": task}),
                parent_id: None,
            });

            // Subscribe to child events for forwarding to parent broadcast.
            // Child event persistence is handled by the agent's EventPersister (via turn_runner).
            let mut child_rx = child_broadcast.subscribe();
            let forward_broadcast = broadcast.clone();
            let forward_child_sid = child_sid.clone();
            let forward_parent_sid = parent_sid.clone();
            let forward_cancel = CancellationToken::new();
            let forward_cancel_clone = forward_cancel.clone();

            let forward_handle = tokio::spawn(async move {
                let mut current_turn: u32 = 0;
                loop {
                    tokio::select! {
                        event = child_rx.recv() => {
                            match event {
                                Ok(ref e) => {
                                    // Track current turn
                                    if let TronEvent::TurnStart { turn, .. } = e {
                                        current_turn = *turn;
                                    }
                                    // Forward selected events as status updates
                                    let activity = match e {
                                        TronEvent::TurnStart { turn, .. } => {
                                            Some(format!("Turn {turn} started"))
                                        }
                                        TronEvent::ToolExecutionStart { tool_name, .. } => {
                                            Some(format!("Executing {tool_name}"))
                                        }
                                        TronEvent::ToolExecutionEnd { tool_name, duration, .. } => {
                                            Some(format!("{tool_name} completed ({duration}ms)"))
                                        }
                                        _ => None,
                                    };
                                    if let Some(activity_text) = activity {
                                        let _ = forward_broadcast.emit(TronEvent::SubagentStatusUpdate {
                                            base: BaseEvent::now(&forward_parent_sid),
                                            subagent_session_id: forward_child_sid.clone(),
                                            status: "running".into(),
                                            current_turn,
                                            activity: Some(activity_text),
                                        });
                                    }

                                    // Forward streaming events as SubagentEvent (iOS detail sheet)
                                    let forwarded_event = match e {
                                        TronEvent::MessageUpdate { content, .. } => Some(json!({
                                            "type": "text_delta",
                                            "data": { "delta": content },
                                            "timestamp": chrono::Utc::now().to_rfc3339(),
                                        })),
                                        TronEvent::ToolExecutionStart { tool_call_id, tool_name, arguments, .. } => Some(json!({
                                            "type": "tool_start",
                                            "data": {
                                                "toolCallId": tool_call_id,
                                                "toolName": tool_name,
                                                "arguments": arguments,
                                            },
                                            "timestamp": chrono::Utc::now().to_rfc3339(),
                                        })),
                                        TronEvent::ToolExecutionEnd { tool_call_id, tool_name, is_error, duration, result, .. } => {
                                            let result_text = result.as_ref().map(|r| {
                                                match &r.content {
                                                    tron_core::tools::ToolResultBody::Text(s) => s.clone(),
                                                    tron_core::tools::ToolResultBody::Blocks(blocks) => {
                                                        blocks.iter().filter_map(|b| {
                                                            if let tron_core::content::ToolResultContent::Text { text } = b {
                                                                Some(text.as_str())
                                                            } else {
                                                                None
                                                            }
                                                        }).collect::<Vec<_>>().join("")
                                                    }
                                                }
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
                                        },
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
                                    };
                                    if let Some(event_data) = forwarded_event {
                                        let _ = forward_broadcast.emit(TronEvent::SubagentEvent {
                                            base: BaseEvent::now(&forward_parent_sid),
                                            subagent_session_id: forward_child_sid.clone(),
                                            event: event_data,
                                        });
                                    }

                                    // Child event persistence is handled by the agent's
                                    // own EventPersister (via turn_runner) — not here.
                                }
                                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                            }
                        }
                        () = forward_cancel_clone.cancelled() => {
                            // Drain remaining
                            while let Ok(ref _event) = child_rx.try_recv() {}
                            break;
                        }
                    }
                }
            });

            // Run the agent
            let result = agent_runner::run_agent(
                &mut agent,
                &task,
                RunContext::default(),
                &hooks,
                &child_broadcast,
            )
            .await;

            // Stop forwarding
            forward_cancel.cancel();
            let _ = forward_handle.await;

            let duration_ms = tracker_clone.started_at.elapsed().as_millis() as u64;

            // Extract output from agent's last assistant message
            let output = {
                let messages = agent.context_manager().get_messages();
                messages
                    .iter()
                    .rev()
                    .find_map(|m| {
                        if let tron_core::messages::Message::Assistant { content, .. } = m {
                            let text: String = content
                                .iter()
                                .filter_map(|c| c.as_text())
                                .collect::<Vec<_>>()
                                .join("");
                            if text.is_empty() { None } else { Some(text) }
                        } else {
                            None
                        }
                    })
                    .unwrap_or_default()
            };

            let token_usage = serde_json::to_value(&result.total_token_usage).ok();

            let success = result.error.is_none();
            let result_output;

            if !success {
                let error = result.error.unwrap_or_else(|| "Unknown error".into());
                // Emit SubagentFailed (routed to parent session)
                let _ = broadcast.emit(TronEvent::SubagentFailed {
                    base: BaseEvent::now(&tracker_clone.parent_session_id),
                    subagent_session_id: child_sid.clone(),
                    error: error.clone(),
                    duration: duration_ms,
                });

                // Persist subagent.failed to parent session
                if !tracker_clone.parent_session_id.is_empty() {
                    let _ = event_store.append(&tron_events::AppendOptions {
                        session_id: &tracker_clone.parent_session_id,
                        event_type: EventType::SubagentFailed,
                        payload: json!({
                            "subagentSessionId": child_sid,
                            "error": error,
                            "duration": duration_ms,
                        }),
                        parent_id: None,
                    });
                }

                result_output = error.clone();
                *tracker_clone.result.lock() = Some(SubagentResult {
                    session_id: child_sid.clone(),
                    output: error,
                    token_usage: token_usage.clone(),
                    duration_ms,
                    status: "failed".into(),
                });
            } else {
                // Emit SubagentCompleted (routed to parent session)
                let _ = broadcast.emit(TronEvent::SubagentCompleted {
                    base: BaseEvent::now(&tracker_clone.parent_session_id),
                    subagent_session_id: child_sid.clone(),
                    total_turns: result.turns_executed,
                    duration: duration_ms,
                    full_output: Some(output.clone()),
                    result_summary: Some(truncate(&output, 200).to_owned()),
                    token_usage: token_usage.clone(),
                    model: Some(model_owned.clone()),
                });

                // Persist subagent.completed to parent session
                if !tracker_clone.parent_session_id.is_empty() {
                    let _ = event_store.append(&tron_events::AppendOptions {
                        session_id: &tracker_clone.parent_session_id,
                        event_type: EventType::SubagentCompleted,
                        payload: json!({
                            "subagentSessionId": child_sid,
                            "totalTurns": result.turns_executed,
                            "duration": duration_ms,
                            "fullOutput": truncate(&output, 4000),
                            "resultSummary": truncate(&output, 200),
                            "model": model_owned,
                        }),
                        parent_id: None,
                    });
                }

                result_output = output.clone();
                *tracker_clone.result.lock() = Some(SubagentResult {
                    session_id: child_sid.clone(),
                    output,
                    token_usage: token_usage.clone(),
                    duration_ms,
                    status: "completed".into(),
                });
            }

            // Persist notification.subagent_result to parent session's event store
            // Only for non-blocking subagents (blocking results go directly to tool output)
            if !blocking && !tracker_clone.parent_session_id.is_empty() {
                let payload = json!({
                    "parentSessionId": tracker_clone.parent_session_id,
                    "subagentSessionId": child_sid,
                    "task": tracker_clone.task,
                    "resultSummary": truncate(&result_output, 200),
                    "success": success,
                    "totalTurns": result.turns_executed as i64,
                    "duration": duration_ms as i64,
                    "tokenUsage": token_usage.clone().unwrap_or(json!({})),
                    "completedAt": chrono::Utc::now().to_rfc3339(),
                    "output": truncate(&result_output, 4000),
                });
                let _ = event_store.append(&tron_events::AppendOptions {
                    session_id: &tracker_clone.parent_session_id,
                    event_type: EventType::NotificationSubagentResult,
                    payload,
                    parent_id: None,
                });

                // Broadcast SubagentResultAvailable for live WebSocket clients
                let _ = broadcast.emit(TronEvent::SubagentResultAvailable {
                    base: BaseEvent::now(&tracker_clone.parent_session_id),
                    parent_session_id: tracker_clone.parent_session_id.clone(),
                    subagent_session_id: child_sid.clone(),
                    task: tracker_clone.task.clone(),
                    result_summary: truncate(&result_output, 200).to_owned(),
                    success,
                    total_turns: result.turns_executed,
                    duration: duration_ms,
                    token_usage,
                    error: if success { None } else { Some(result_output.clone()) },
                    completed_at: chrono::Utc::now().to_rfc3339(),
                });
            }

            tracker_clone.done.notify_waiters();

            // End the child session
            let _ = session_mgr.end_session(&child_sid).await;

            info!(
                child_session = child_sid,
                turns = result.turns_executed,
                duration_ms,
                "subagent execution finished"
            );
        }.instrument(subagent_span));

        // 5. If blocking, wait for completion
        if config.blocking {
            let timeout = std::time::Duration::from_millis(config.timeout_ms);
            let wait_result = tokio::time::timeout(timeout, tracker.done.notified()).await;

            if wait_result.is_err() {
                tracker.cancel.cancel();
                return Err(ToolError::Timeout {
                    timeout_ms: config.timeout_ms,
                });
            }

            let result = tracker.result.lock().clone();
            if let Some(r) = result {
                Ok(SubagentHandle {
                    session_id: child_session_id,
                    output: Some(r.output),
                    token_usage: r.token_usage,
                })
            } else {
                Ok(SubagentHandle {
                    session_id: child_session_id,
                    output: None,
                    token_usage: None,
                })
            }
        } else {
            Ok(SubagentHandle {
                session_id: child_session_id,
                output: None,
                token_usage: None,
            })
        }
    }

    async fn query_agent(
        &self,
        session_id: &str,
        query_type: &str,
        limit: Option<u32>,
    ) -> Result<Value, ToolError> {
        match query_type {
            "status" => {
                if let Some(tracker) = self.subagents.get(session_id) {
                    let result = tracker.result.lock().clone();
                    let duration_ms =
                        tracker.started_at.elapsed().as_millis() as u64;
                    let status = if result.is_some() {
                        result.as_ref().map_or("unknown", |r| r.status.as_str())
                    } else {
                        "running"
                    };
                    Ok(json!({
                        "sessionId": session_id,
                        "status": status,
                        "task": tracker.task,
                        "model": tracker.model,
                        "durationMs": duration_ms,
                        "depth": tracker.depth,
                    }))
                } else {
                    // Fall back to DB
                    let session = self
                        .event_store
                        .get_session(session_id)
                        .map_err(|e| ToolError::Internal {
                            message: format!("Failed to query session: {e}"),
                        })?;
                    if let Some(s) = session {
                        Ok(json!({
                            "sessionId": s.id,
                            "status": if s.ended_at.is_some() { "completed" } else { "unknown" },
                            "model": s.latest_model,
                            "task": s.spawn_task,
                        }))
                    } else {
                        Err(ToolError::Validation {
                            message: format!("Session not found: {session_id}"),
                        })
                    }
                }
            }
            "output" => {
                if let Some(tracker) = self.subagents.get(session_id) {
                    let result = tracker.result.lock().clone();
                    if let Some(r) = result {
                        Ok(json!({ "output": r.output }))
                    } else {
                        Ok(json!({ "output": null, "status": "running" }))
                    }
                } else {
                    Ok(json!({ "output": null, "status": "not_tracked" }))
                }
            }
            "events" => {
                let event_limit = limit.unwrap_or(20);
                let opts = tron_events::sqlite::repositories::event::ListEventsOptions {
                    limit: Some(i64::from(event_limit)),
                    offset: None,
                };
                let events = self
                    .event_store
                    .get_events_by_session(session_id, &opts)
                    .map_err(|e| ToolError::Internal {
                        message: format!("Failed to get events: {e}"),
                    })?;
                let summaries: Vec<Value> = events
                    .iter()
                    .map(|e| {
                        json!({
                            "id": e.id,
                            "type": e.event_type,
                            "timestamp": e.timestamp,
                        })
                    })
                    .collect();
                Ok(json!({ "events": summaries }))
            }
            "logs" => Ok(json!({ "logs": [] })),
            _ => Err(ToolError::Validation {
                message: format!("Invalid query type: {query_type}"),
            }),
        }
    }

    async fn wait_for_agents(
        &self,
        session_ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<SubagentResult>, ToolError> {
        if session_ids.is_empty() {
            return Err(ToolError::Validation {
                message: "No session IDs provided".into(),
            });
        }

        let timeout = std::time::Duration::from_millis(timeout_ms);
        let deadline = Instant::now() + timeout;

        match mode {
            WaitMode::All => {
                let mut results = Vec::with_capacity(session_ids.len());
                for sid in session_ids {
                    let tracker = self.subagents.get(sid).ok_or_else(|| {
                        ToolError::Validation {
                            message: format!("Unknown subagent session: {sid}"),
                        }
                    })?;

                    // Check if already done
                    {
                        let result = tracker.result.lock().clone();
                        if let Some(r) = result {
                            results.push(r);
                            continue;
                        }
                    }

                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(ToolError::Timeout { timeout_ms });
                    }

                    let wait = tokio::time::timeout(remaining, tracker.done.notified()).await;
                    if wait.is_err() {
                        return Err(ToolError::Timeout { timeout_ms });
                    }

                    let result = tracker.result.lock().clone().unwrap_or_else(|| {
                        SubagentResult {
                            session_id: sid.clone(),
                            output: String::new(),
                            token_usage: None,
                            duration_ms: 0,
                            status: "unknown".into(),
                        }
                    });
                    results.push(result);
                }
                Ok(results)
            }
            WaitMode::Any => {
                // Build futures for all trackers
                let trackers: Vec<_> = session_ids
                    .iter()
                    .map(|sid| {
                        self.subagents
                            .get(sid)
                            .map(|t| (sid.clone(), t.clone()))
                    })
                    .collect::<Option<Vec<_>>>()
                    .ok_or_else(|| ToolError::Validation {
                        message: "One or more unknown subagent sessions".into(),
                    })?;

                // Check if any already done
                for (_sid, tracker) in &trackers {
                    let result = tracker.result.lock().clone();
                    if let Some(r) = result {
                        return Ok(vec![r]);
                    }
                }

                // Race all notified futures
                let (result_tx, mut result_rx) = tokio::sync::mpsc::channel(1);
                for (sid, tracker) in trackers {
                    let tx = result_tx.clone();
                    let tracker = tracker.clone();
                    let sid = sid.clone();
                    let _ = tokio::spawn(async move {
                        tracker.done.notified().await;
                        let result =
                            tracker.result.lock().clone().unwrap_or_else(|| {
                                SubagentResult {
                                    session_id: sid,
                                    output: String::new(),
                                    token_usage: None,
                                    duration_ms: 0,
                                    status: "unknown".into(),
                                }
                            });
                        let _ = tx.send(result).await;
                    });
                }
                drop(result_tx);

                match tokio::time::timeout(timeout, result_rx.recv()).await {
                    Ok(Some(result)) => Ok(vec![result]),
                    Ok(None) => Err(ToolError::Internal {
                        message: "All wait tasks completed without result".into(),
                    }),
                    Err(_) => Err(ToolError::Timeout { timeout_ms }),
                }
            }
        }
    }
}

fn truncate(s: &str, max: usize) -> &str {
    tron_core::text::truncate_str(s, max)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::event_emitter::EventEmitter;
    use async_trait::async_trait;
    use futures::stream;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::ProviderType;
    use tron_llm::provider::{Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream};

    struct MockProvider;
    #[async_trait]
    impl Provider for MockProvider {
        fn provider_type(&self) -> ProviderType {
            ProviderType::Anthropic
        }
        fn model(&self) -> &str {
            "mock-model"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let s = stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: "Done".into(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("Done")],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ]);
            Ok(Box::pin(s))
        }
    }

    struct ErrorProvider;
    #[async_trait]
    impl Provider for ErrorProvider {
        fn provider_type(&self) -> ProviderType {
            ProviderType::Anthropic
        }
        fn model(&self) -> &str {
            "mock-model"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Auth {
                message: "expired".into(),
            })
        }
    }

    fn make_manager_and_store() -> (Arc<SessionManager>, Arc<EventStore>, Arc<EventEmitter>) {
        let pool =
            tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store.clone()));
        let broadcast = Arc::new(EventEmitter::new());
        (mgr, store, broadcast)
    }

    struct MockProviderFactoryFor<P: Provider + Default + 'static>(std::marker::PhantomData<P>);
    impl<P: Provider + Default + 'static> MockProviderFactoryFor<P> {
        fn new() -> Self {
            Self(std::marker::PhantomData)
        }
    }
    #[async_trait]
    impl<P: Provider + Default + 'static> ProviderFactory for MockProviderFactoryFor<P> {
        async fn create_for_model(
            &self,
            _model: &str,
        ) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(Arc::new(P::default()))
        }
    }

    impl Default for MockProvider {
        fn default() -> Self {
            Self
        }
    }

    impl Default for ErrorProvider {
        fn default() -> Self {
            Self
        }
    }

    fn make_subagent_manager(
        provider: Arc<dyn Provider>,
    ) -> (SubagentManager, Arc<SessionManager>, Arc<EventStore>) {
        // Wrap the provider in a simple factory that always returns it
        struct FixedProviderFactory(Arc<dyn Provider>);
        #[async_trait]
        impl ProviderFactory for FixedProviderFactory {
            async fn create_for_model(
                &self,
                _model: &str,
            ) -> Result<Arc<dyn Provider>, ProviderError> {
                Ok(self.0.clone())
            }
        }

        let (mgr, store, broadcast) = make_manager_and_store();
        let manager = SubagentManager::new(
            mgr.clone(),
            store.clone(),
            broadcast,
            Arc::new(FixedProviderFactory(provider)),
            None,
            None,
        );
        manager.set_tool_factory(Arc::new(ToolRegistry::new));
        (manager, mgr, store)
    }

    fn make_config(task: &str) -> SubagentConfig {
        SubagentConfig {
            task: task.into(),
            mode: SubagentMode::InProcess,
            blocking: true,
            model: None,
            parent_session_id: None,
            system_prompt: None,
            working_directory: "/tmp".into(),
            max_turns: 5,
            timeout_ms: 10_000,
            tool_denials: None,
            skills: None,
            max_depth: 0,
            current_depth: 0,
            tool_call_id: None,
        }
    }

    #[tokio::test]
    async fn spawn_creates_session_and_tracks() {
        let (manager, _mgr, store) = make_subagent_manager(Arc::new(MockProvider));
        let config = make_config("test task");
        let handle = manager.spawn(config).await.unwrap();

        assert!(!handle.session_id.is_empty());
        // Session should exist in DB
        let session = store.get_session(&handle.session_id).unwrap();
        assert!(session.is_some());
    }

    #[tokio::test]
    async fn spawn_blocking_returns_output() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let config = make_config("test task");
        let handle = manager.spawn(config).await.unwrap();

        assert!(handle.output.is_some());
        assert!(!handle.output.as_ref().unwrap().is_empty());
    }

    #[tokio::test]
    async fn spawn_nonblocking_returns_immediately() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_config("test task");
        config.blocking = false;
        let handle = manager.spawn(config).await.unwrap();

        assert!(!handle.session_id.is_empty());
        assert!(handle.output.is_none());
    }

    #[tokio::test]
    async fn spawn_tmux_mode_rejected() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_config("test task");
        config.mode = SubagentMode::Tmux;
        let err = manager.spawn(config).await.unwrap_err();
        assert!(err.to_string().contains("Tmux"));
    }

    #[tokio::test]
    async fn spawn_depth_zero_blocks_nesting() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_config("nested task");
        config.current_depth = 1;
        config.max_depth = 0;
        let err = manager.spawn(config).await.unwrap_err();
        assert!(err.to_string().contains("nesting"));
    }

    #[tokio::test]
    async fn spawn_depth_one_allows_nesting() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_config("nested task");
        config.current_depth = 1;
        config.max_depth = 2;
        let handle = manager.spawn(config).await.unwrap();
        assert!(!handle.session_id.is_empty());
    }

    #[tokio::test]
    async fn query_agent_status_running() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_config("test task");
        config.blocking = false;
        let handle = manager.spawn(config).await.unwrap();

        // Query immediately (may still be running or completed)
        let result = manager
            .query_agent(&handle.session_id, "status", None)
            .await
            .unwrap();
        assert!(result.get("sessionId").is_some());
        assert!(result.get("status").is_some());
    }

    #[tokio::test]
    async fn query_agent_output_after_completion() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let config = make_config("test task");
        let handle = manager.spawn(config).await.unwrap();

        let result = manager
            .query_agent(&handle.session_id, "output", None)
            .await
            .unwrap();
        assert!(result.get("output").is_some());
    }

    #[tokio::test]
    async fn query_agent_invalid_type() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let err = manager
            .query_agent("any", "invalid", None)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("Invalid query type"));
    }

    #[tokio::test]
    async fn wait_all_waits_for_all() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));

        let mut c1 = make_config("task 1");
        c1.blocking = false;
        let h1 = manager.spawn(c1).await.unwrap();

        let mut c2 = make_config("task 2");
        c2.blocking = false;
        let h2 = manager.spawn(c2).await.unwrap();

        let results = manager
            .wait_for_agents(
                &[h1.session_id, h2.session_id],
                WaitMode::All,
                30_000,
            )
            .await
            .unwrap();

        assert_eq!(results.len(), 2);
    }

    #[tokio::test]
    async fn wait_any_returns_first() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));

        let mut c1 = make_config("task 1");
        c1.blocking = false;
        let h1 = manager.spawn(c1).await.unwrap();

        let mut c2 = make_config("task 2");
        c2.blocking = false;
        let h2 = manager.spawn(c2).await.unwrap();

        let results = manager
            .wait_for_agents(
                &[h1.session_id, h2.session_id],
                WaitMode::Any,
                30_000,
            )
            .await
            .unwrap();

        assert_eq!(results.len(), 1);
    }

    #[tokio::test]
    async fn wait_empty_session_ids_error() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let err = manager
            .wait_for_agents(&[], WaitMode::All, 5000)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("No session IDs"));
    }

    #[tokio::test]
    async fn subagent_completion_emits_events() {
        let (mgr, store, broadcast) = make_manager_and_store();
        let manager = SubagentManager::new(
            mgr.clone(),
            store.clone(),
            broadcast.clone(),
            Arc::new(MockProviderFactoryFor::<MockProvider>::new()),
            None,
            None,
        );
        manager.set_tool_factory(Arc::new(ToolRegistry::new));

        let mut rx = broadcast.subscribe();
        let config = make_config("test task");
        let _handle = manager.spawn(config).await.unwrap();

        // Collect emitted events
        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        assert!(
            event_types.contains(&"subagent_spawned".to_owned()),
            "expected subagent_spawned, got: {event_types:?}"
        );
        // Should have either completed or failed
        let has_terminal = event_types.contains(&"subagent_completed".to_owned())
            || event_types.contains(&"subagent_failed".to_owned());
        assert!(
            has_terminal,
            "expected subagent_completed or subagent_failed, got: {event_types:?}"
        );
    }

    #[tokio::test]
    async fn spawn_error_provider_reports_failure() {
        let (manager, _, _) = make_subagent_manager(Arc::new(ErrorProvider));
        let config = make_config("test task");
        let handle = manager.spawn(config).await.unwrap();

        // Blocking spawn with error provider should still return a handle
        // The output will contain error info
        assert!(!handle.session_id.is_empty());
    }

    #[tokio::test]
    async fn truncate_helper() {
        assert_eq!(truncate("hello", 10), "hello");
        assert_eq!(truncate("hello world", 5), "hello");
    }

    #[tokio::test]
    async fn query_agent_logs_returns_empty() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let result = manager.query_agent("any", "logs", None).await.unwrap();
        assert_eq!(result["logs"], json!([]));
    }

    // ── SpawnType tests ──

    #[test]
    fn spawn_type_enum_variants() {
        assert_ne!(SpawnType::ToolAgent, SpawnType::Subsession);
        assert_eq!(SpawnType::ToolAgent, SpawnType::ToolAgent);
        assert_eq!(SpawnType::Subsession, SpawnType::Subsession);
    }

    #[test]
    fn spawn_type_debug() {
        let s = format!("{:?}", SpawnType::ToolAgent);
        assert!(s.contains("ToolAgent"));
    }

    // ── SubsessionConfig defaults ──

    #[test]
    fn subsession_config_defaults() {
        let config = SubsessionConfig::default();
        assert!(config.parent_session_id.is_empty());
        assert!(config.task.is_empty());
        assert!(config.model.is_none());
        assert!(config.system_prompt.is_empty());
        assert_eq!(config.timeout_ms, 30_000);
        assert!(config.blocking);
        assert_eq!(config.max_turns, 1);
        assert_eq!(config.max_depth, 0);
        assert!(!config.inherit_tools);
        assert!(config.denied_tools.is_empty());
        assert_eq!(config.reasoning_level, Some(ReasoningLevel::Medium));
    }

    // ── Query helpers ──

    #[tokio::test]
    async fn active_count_by_type_tool_agent() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        // Spawn a blocking tool agent (completes immediately)
        let config = make_config("test task");
        let _handle = manager.spawn(config).await.unwrap();

        // After blocking spawn completes, should be 0 active ToolAgents
        assert_eq!(manager.active_count_by_type(&SpawnType::ToolAgent), 0);
        assert_eq!(manager.active_count_by_type(&SpawnType::Subsession), 0);
    }

    #[tokio::test]
    async fn list_active_subsessions_empty() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        assert!(manager.list_active_subsessions().is_empty());
    }

    // ── spawn_subsession tests ──

    fn make_subsession_config(task: &str, parent: &str) -> SubsessionConfig {
        SubsessionConfig {
            parent_session_id: parent.into(),
            task: task.into(),
            system_prompt: "You are a summarizer.".into(),
            working_directory: "/tmp".into(),
            ..SubsessionConfig::default()
        }
    }

    #[tokio::test]
    async fn spawn_subsession_blocking_returns_output() {
        let (manager, _, store) = make_subagent_manager(Arc::new(MockProvider));
        let config = make_subsession_config("summarize this", "parent-001");
        let result = manager.spawn_subsession(config).await.unwrap();

        assert!(!result.session_id.is_empty());
        assert!(!result.output.is_empty());
        assert!(result.duration_ms > 0 || result.output == "Done");

        // Session should exist in DB with spawn_type = subsession
        let session = store.get_session(&result.session_id).unwrap();
        assert!(session.is_some());
        let s = session.unwrap();
        assert_eq!(s.spawn_type.as_deref(), Some("subsession"));
    }

    #[tokio::test]
    async fn spawn_subsession_nonblocking_returns_session_id() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_subsession_config("summarize", "parent-001");
        config.blocking = false;
        let result = manager.spawn_subsession(config).await.unwrap();

        assert!(!result.session_id.is_empty());
        // Non-blocking: output is empty initially
        assert!(result.output.is_empty());
    }

    #[tokio::test]
    async fn spawn_subsession_no_tools_by_default() {
        // Default inherit_tools = false, so subsession should have empty tool registry
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let config = make_subsession_config("summarize", "parent-001");
        let result = manager.spawn_subsession(config).await.unwrap();
        assert!(!result.session_id.is_empty());
    }

    #[tokio::test]
    async fn spawn_subsession_inherit_tools() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_subsession_config("summarize", "parent-001");
        config.inherit_tools = true;
        let result = manager.spawn_subsession(config).await.unwrap();
        assert!(!result.session_id.is_empty());
    }

    #[tokio::test]
    async fn spawn_subsession_emits_events() {
        let (mgr, store, broadcast) = make_manager_and_store();
        let manager = SubagentManager::new(
            mgr.clone(),
            store.clone(),
            broadcast.clone(),
            Arc::new(MockProviderFactoryFor::<MockProvider>::new()),
            None,
            None,
        );
        manager.set_tool_factory(Arc::new(ToolRegistry::new));

        let mut rx = broadcast.subscribe();
        let config = make_subsession_config("summarize", "parent-001");
        let _result = manager.spawn_subsession(config).await.unwrap();

        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        assert!(
            event_types.contains(&"subagent_spawned".to_owned()),
            "expected subagent_spawned, got: {event_types:?}"
        );
        let has_terminal = event_types.contains(&"subagent_completed".to_owned())
            || event_types.contains(&"subagent_failed".to_owned());
        assert!(
            has_terminal,
            "expected terminal event, got: {event_types:?}"
        );
    }

    #[tokio::test]
    async fn spawn_subsession_tracked_as_subsession_type() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_subsession_config("summarize", "parent-001");
        config.blocking = false;
        let result = manager.spawn_subsession(config).await.unwrap();

        // Check tracker has Subsession type
        if let Some(tracker) = manager.subagents.get(&result.session_id) {
            assert_eq!(tracker.spawn_type, SpawnType::Subsession);
        }
    }

    #[tokio::test]
    async fn spawn_subsession_error_provider() {
        let (manager, _, _) = make_subagent_manager(Arc::new(ErrorProvider));
        let config = make_subsession_config("summarize", "parent-001");
        let result = manager.spawn_subsession(config).await.unwrap();
        // Should still complete (blocking) — output may contain error info
        assert!(!result.session_id.is_empty());
    }

    // ── notification.subagent_result persistence tests ──

    #[tokio::test]
    async fn spawn_nonblocking_persists_notification_to_parent_session() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(MockProvider));

        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();

        let mut config = make_config("research task");
        config.parent_session_id = Some(parent_sid.clone());
        config.blocking = false;
        let handle = manager.spawn(config).await.unwrap();

        // Wait for non-blocking agent to finish
        let _ = manager
            .wait_for_agents(&[handle.session_id], WaitMode::All, 10_000)
            .await
            .unwrap();

        // Check the parent session for notification.subagent_result events
        let events = store
            .get_events_by_type(&parent_sid, &["notification.subagent_result"], None)
            .unwrap();
        assert_eq!(events.len(), 1, "expected one notification event in parent session");

        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["parentSessionId"], parent_sid);
        assert_eq!(payload["task"], "research task");
        assert_eq!(payload["success"], true);
        assert!(payload["output"].is_string());
    }

    #[tokio::test]
    async fn spawn_no_parent_session_id_skips_notification() {
        let (manager, _, store) = make_subagent_manager(Arc::new(MockProvider));

        // No parent_session_id set (None → empty string)
        let config = make_config("test task");
        let handle = manager.spawn(config).await.unwrap();

        // No notification events anywhere (parent_session_id was empty)
        let events = store
            .get_events_by_type(&handle.session_id, &["notification.subagent_result"], None)
            .unwrap();
        assert!(events.is_empty());
    }

    #[tokio::test]
    async fn spawn_nonblocking_failed_persists_notification_with_success_false() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(ErrorProvider));

        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();

        let mut config = make_config("failing task");
        config.parent_session_id = Some(parent_sid.clone());
        config.blocking = false;
        let handle = manager.spawn(config).await.unwrap();

        // Wait for non-blocking agent to finish
        let _ = manager
            .wait_for_agents(&[handle.session_id], WaitMode::All, 10_000)
            .await
            .unwrap();

        let events = store
            .get_events_by_type(&parent_sid, &["notification.subagent_result"], None)
            .unwrap();
        assert_eq!(events.len(), 1);

        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["success"], false);
    }

    #[tokio::test]
    async fn spawn_blocking_skips_notification() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(MockProvider));

        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();

        let mut config = make_config("blocking task");
        config.parent_session_id = Some(parent_sid.clone());
        config.blocking = true;
        let _handle = manager.spawn(config).await.unwrap();

        // Blocking subagents should NOT persist notification.subagent_result
        let events = store
            .get_events_by_type(&parent_sid, &["notification.subagent_result"], None)
            .unwrap();
        assert!(events.is_empty(), "blocking subagents should not persist notification events");
    }

    #[tokio::test]
    async fn spawn_persists_lifecycle_events_to_parent() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(MockProvider));

        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();

        let mut config = make_config("lifecycle task");
        config.parent_session_id = Some(parent_sid.clone());
        let _handle = manager.spawn(config).await.unwrap();

        // subagent.spawned should be persisted to parent
        let spawned = store
            .get_events_by_type(&parent_sid, &["subagent.spawned"], None)
            .unwrap();
        assert_eq!(spawned.len(), 1, "expected subagent.spawned in parent session");
        let payload: serde_json::Value = serde_json::from_str(&spawned[0].payload).unwrap();
        assert_eq!(payload["task"], "lifecycle task");

        // subagent.completed should be persisted to parent
        let completed = store
            .get_events_by_type(&parent_sid, &["subagent.completed"], None)
            .unwrap();
        assert_eq!(completed.len(), 1, "expected subagent.completed in parent session");
        let payload: serde_json::Value = serde_json::from_str(&completed[0].payload).unwrap();
        assert!(payload["subagentSessionId"].is_string());
        assert!(payload["totalTurns"].is_number());
    }

    #[tokio::test]
    async fn spawn_failed_persists_lifecycle_events_to_parent() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(ErrorProvider));

        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();

        let mut config = make_config("failing lifecycle task");
        config.parent_session_id = Some(parent_sid.clone());
        let _handle = manager.spawn(config).await.unwrap();

        // subagent.spawned should be persisted
        let spawned = store
            .get_events_by_type(&parent_sid, &["subagent.spawned"], None)
            .unwrap();
        assert_eq!(spawned.len(), 1);

        // subagent.failed should be persisted
        let failed = store
            .get_events_by_type(&parent_sid, &["subagent.failed"], None)
            .unwrap();
        assert_eq!(failed.len(), 1);
        let payload: serde_json::Value = serde_json::from_str(&failed[0].payload).unwrap();
        assert!(payload["error"].is_string());
    }

    #[tokio::test]
    async fn subsession_does_not_persist_notification() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(MockProvider));

        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();

        let config = make_subsession_config("summarize", &parent_sid);
        let _result = manager.spawn_subsession(config).await.unwrap();

        // Subsessions should NOT persist notification.subagent_result
        let events = store
            .get_events_by_type(&parent_sid, &["notification.subagent_result"], None)
            .unwrap();
        assert!(events.is_empty(), "subsessions should not persist notification events");
    }

    // ── message.user persistence tests ──

    #[tokio::test]
    async fn spawn_persists_message_user_to_child_session() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(MockProvider));
        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();
        let mut config = make_config("research task");
        config.parent_session_id = Some(parent_sid);
        let handle = manager.spawn(config).await.unwrap();

        let events = store
            .get_events_by_type(&handle.session_id, &["message.user"], None)
            .unwrap();
        assert_eq!(events.len(), 1, "expected message.user in child session");
        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["content"], "research task");
    }

    #[tokio::test]
    async fn spawn_subsession_persists_message_user_to_child_session() {
        let (manager, _, store) = make_subagent_manager(Arc::new(MockProvider));
        let config = make_subsession_config("summarize this", "parent-001");
        let result = manager.spawn_subsession(config).await.unwrap();

        let events = store
            .get_events_by_type(&result.session_id, &["message.user"], None)
            .unwrap();
        assert_eq!(events.len(), 1, "expected message.user in child session");
        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["content"], "summarize this");
    }

    #[tokio::test]
    async fn spawn_end_session_flushes_persisted_events() {
        let (manager, session_mgr, store) = make_subagent_manager(Arc::new(MockProvider));
        let parent_sid = session_mgr
            .create_session("mock-model", "/tmp", None)
            .unwrap();
        let mut config = make_config("test task");
        config.parent_session_id = Some(parent_sid);
        let handle = manager.spawn(config).await.unwrap();

        // After blocking spawn completes (which calls end_session), events should exist
        let events = store
            .get_events_by_type(&handle.session_id, &["message.assistant"], None)
            .unwrap();
        assert!(!events.is_empty(), "expected message.assistant events after end_session flush");
    }
}
