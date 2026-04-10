//! `SubagentManager` — real `SubagentSpawner` implementation.
//!
//! Spawns child agents in-process, tracks their state, and forwards
//! events from child sessions to the parent session's broadcast.

use std::sync::Arc;
use std::time::Instant;

use crate::runtime::guardrails::GuardrailEngine;
use crate::runtime::hooks::engine::HookEngine;
use async_trait::async_trait;
use dashmap::DashMap;
use parking_lot::Mutex;
use serde_json::{Value, json};
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;
use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{EventStore, EventType};
use crate::llm::provider::ProviderFactory;
use crate::tools::errors::ToolError;
use crate::tools::registry::ToolRegistry;
use crate::tools::traits::{
    SubagentConfig, SubagentHandle, SubagentMode, SubagentResult, SubagentSpawner, WaitMode,
};

use crate::runtime::agent::event_emitter::EventEmitter;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::types::ReasoningLevel;

mod execution;
mod tracking;

// =============================================================================
// SpawnType — taxonomy for tracked subagents
// =============================================================================

/// Distinguishes tool-spawned agents from system-spawned `subsessions`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpawnType {
    /// Spawned by the LLM via the `SpawnSubagent` tool.
    ToolAgent,
    /// Spawned programmatically for internal tasks (compaction, memory, etc.).
    Subsession,
    /// Spawned by LLM hooks (title-gen, branch-name-gen, suggest-prompts).
    Hook,
}

impl SpawnType {
    /// Returns the wire-protocol string for this spawn type (camelCase for JSON).
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ToolAgent => "toolAgent",
            Self::Subsession => "subsession",
            Self::Hook => "hook",
        }
    }
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
    /// Timeout in milliseconds (default `30_000`).
    pub timeout_ms: u64,
    /// Blocking timeout in milliseconds — how long to wait before auto-backgrounding.
    /// `None` = immediate background (non-blocking).
    pub blocking_timeout_ms: Option<u64>,
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
    /// Spawn type for event tagging (default `Subsession`).
    pub spawn_type: SpawnType,
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
            blocking_timeout_ms: Some(30_000),
            max_turns: 1,
            max_depth: 0,
            inherit_tools: false,
            denied_tools: vec![],
            reasoning_level: Some(ReasoningLevel::Medium),
            spawn_type: SpawnType::Subsession,
        }
    }
}

/// Output from a completed subsession.
#[derive(Debug)]
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
    guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    hooks: Option<Arc<HookEngine>>,
    /// Worktree coordinator for subagent isolation (each subagent gets its own worktree).
    worktree_coordinator: std::sync::OnceLock<Arc<crate::worktree::WorktreeCoordinator>>,
    /// Self-reference for passing to child agents (set after wrapping in Arc).
    self_ref: std::sync::OnceLock<std::sync::Weak<Self>>,
    /// Weak probe for querying parent-session run state without creating an
    /// Arc cycle with `Orchestrator`. Used to decide whether non-blocking
    /// subagent completion should surface a notification on iOS.
    run_state_probe: std::sync::OnceLock<
        std::sync::Weak<dyn crate::runtime::orchestrator::orchestrator::RunStateProbe>,
    >,
    /// Tracked subagents: `child_session_id` → `TrackedSubagent`.
    subagents: DashMap<String, Arc<TrackedSubagent>>,
}

impl SubagentManager {
    /// Create a new `SubagentManager`.
    pub fn new(
        session_manager: Arc<SessionManager>,
        event_store: Arc<EventStore>,
        broadcast: Arc<EventEmitter>,
        provider_factory: Arc<dyn ProviderFactory>,
        guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
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
            worktree_coordinator: std::sync::OnceLock::new(),
            self_ref: std::sync::OnceLock::new(),
            run_state_probe: std::sync::OnceLock::new(),
            subagents: DashMap::new(),
        }
    }

    /// Store a weak reference to the `RunStateProbe` (typically the
    /// orchestrator). Must be called once after both `SubagentManager` and
    /// `Orchestrator` are wrapped in Arcs. Without this, notification routing
    /// defaults to `notify=true` (safe — user sees every completion).
    pub fn set_run_state_probe(
        &self,
        probe: std::sync::Weak<dyn crate::runtime::orchestrator::orchestrator::RunStateProbe>,
    ) {
        let _ = self.run_state_probe.set(probe);
    }

    /// Clone the run-state probe for passing into execution tasks.
    fn probe_clone(
        &self,
    ) -> Option<std::sync::Weak<dyn crate::runtime::orchestrator::orchestrator::RunStateProbe>>
    {
        self.run_state_probe.get().cloned()
    }

    /// Store a weak self-reference so child agents can receive `Arc<SubagentManager>`.
    /// Must be called once after wrapping in `Arc`.
    pub fn set_self_ref(self: &Arc<Self>) {
        let _ = self.self_ref.set(Arc::downgrade(self));
    }

    /// Upgrade the weak self-reference to an Arc (returns None if dropped).
    fn arc_self(&self) -> Option<Arc<Self>> {
        self.self_ref.get().and_then(std::sync::Weak::upgrade)
    }

    /// Set the worktree coordinator for subagent isolation.
    pub fn set_worktree_coordinator(&self, coordinator: Arc<crate::worktree::WorktreeCoordinator>) {
        let _ = self.worktree_coordinator.set(coordinator);
    }

    /// Set the tool factory (breaks circular dependency with tool registry).
    pub fn set_tool_factory(&self, factory: Arc<dyn Fn() -> ToolRegistry + Send + Sync>) {
        let _ = self.tool_factory.set(factory);
    }

    /// Spawn a system subsession for programmatic tasks (hooks, compaction, memory).
    ///
    /// Unlike `spawn()` (tool-agent path), the caller provides the system prompt
    /// directly, tools are optional, and the subsession is tracked as
    /// `SpawnType::Subsession`.
    ///
    /// Returns `Err` if the subsession fails for any reason (provider error,
    /// provider creation failure, session resume failure, agent cancellation).
    /// Callers should handle `Err` gracefully by falling back to defaults or
    /// skipping the operation.
    #[allow(clippy::too_many_lines)]
    pub async fn spawn_subsession(
        &self,
        config: SubsessionConfig,
    ) -> Result<SubsessionOutput, ToolError> {
        let model = config
            .model
            .as_deref()
            .unwrap_or(crate::llm::model_ids::SUBAGENT_MODEL);
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

        let spawn_type = config.spawn_type;
        let (tracker, cancel) = self.register_subagent(
            child_session_id.clone(),
            config.parent_session_id.clone(),
            task.clone(),
            spawn_type,
        );

        // 3. Emit SubagentSpawned on broadcast
        let _ = self.broadcast.emit(TronEvent::SubagentSpawned {
            base: BaseEvent::now(&config.parent_session_id),
            subagent_session_id: child_session_id.clone(),
            task: task.clone(),
            model: model.to_owned(),
            max_turns: config.max_turns,
            spawn_depth: 0,
            tool_call_id: None,
            blocking_timeout_ms: config.blocking_timeout_ms,
            working_directory: Some(config.working_directory.clone()),
            spawn_type: Some(spawn_type.as_str().to_owned()),
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

        execution::spawn_subsession_task(execution::SubsessionTaskLaunch {
            session_manager: self.session_manager.clone(),
            event_store: self.event_store.clone(),
            broadcast: self.broadcast.clone(),
            provider_factory: self.provider_factory.clone(),
            guardrails: self.guardrails.clone(),
            hooks: self.hooks.clone(),
            worktree_coordinator: self.worktree_coordinator.get().cloned(),
            child_subagent_manager: self.arc_self(),
            child_session_id: child_session_id.clone(),
            parent_session_id: config.parent_session_id.clone(),
            task,
            model: model.to_owned(),
            system_prompt: config.system_prompt.clone(),
            working_directory: config.working_directory.clone(),
            max_turns: config.max_turns,
            subagent_max_depth: config.max_depth,
            reasoning_level: config.reasoning_level,
            spawn_type: spawn_type.as_str().to_owned(),
            tracker: tracker.clone(),
            cancel,
            tools,
        });

        if let Some(timeout) = config.blocking_timeout_ms {
            if let Some(result) = self
                .wait_for_tracker_result(&tracker, timeout)
                .await?
            {
                if result.status == "failed" {
                    return Err(ToolError::Internal {
                        message: result.output,
                    });
                }
                Ok(SubsessionOutput {
                    session_id: child_session_id,
                    output: result.output,
                    token_usage: result.token_usage,
                    duration_ms: result.duration_ms,
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
    #[allow(clippy::too_many_lines)]
    async fn spawn(&self, config: SubagentConfig) -> Result<SubagentHandle, ToolError> {
        // Validate mode
        if config.mode == SubagentMode::Tmux {
            return Err(ToolError::Validation {
                message: "Tmux mode is not yet supported. Use inProcess mode.".into(),
            });
        }

        // Depth check
        if config.max_depth > 0 && config.current_depth >= config.max_depth {
            return Err(ToolError::Validation {
                message: format!(
                    "Maximum subagent depth ({}) exceeded (current: {})",
                    config.max_depth, config.current_depth
                ),
            });
        }
        if config.current_depth > 0 && config.max_depth == 0 {
            return Err(ToolError::Validation {
                message: "Subagent nesting is not allowed".into(),
            });
        }

        let tool_factory = self.tool_factory.get().ok_or_else(|| ToolError::Internal {
            message: "SubagentManager tool factory not initialized".into(),
        })?;

        let model = config
            .model
            .as_deref()
            .unwrap_or(crate::llm::model_ids::SUBAGENT_MODEL);
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
                if parent_sid.is_empty() {
                    "parent-placeholder"
                } else {
                    &parent_sid
                },
                "inProcess",
                &task,
            )
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to create subagent session: {e}"),
            })?;

        let (tracker, cancel) = self.register_subagent(
            child_session_id.clone(),
            parent_sid.clone(),
            task.clone(),
            SpawnType::ToolAgent,
        );

        // 3. Emit SubagentSpawned on broadcast (routed to parent session for iOS)
        let _ = self.broadcast.emit(TronEvent::SubagentSpawned {
            base: BaseEvent::now(&parent_sid),
            subagent_session_id: child_session_id.clone(),
            task: task.clone(),
            model: model.to_owned(),
            max_turns: config.max_turns,
            spawn_depth: config.current_depth,
            tool_call_id: config.tool_call_id.clone(),
            blocking_timeout_ms: config.blocking_timeout_ms,
            working_directory: Some(config.working_directory.clone()),
            spawn_type: Some(SpawnType::ToolAgent.as_str().to_owned()),
        });

        // Persist subagent.spawned to parent session (iOS reconstructs from this on resume)
        if !parent_sid.is_empty() {
            let _ = self.event_store.append(&crate::events::AppendOptions {
                session_id: &parent_sid,
                event_type: EventType::SubagentSpawned,
                payload: json!({
                    "subagentSessionId": child_session_id,
                    "task": task,
                    "model": model,
                    "maxTurns": config.max_turns,
                    "spawnDepth": config.current_depth,
                    "toolCallId": config.tool_call_id,
                    "blockingTimeoutMs": config.blocking_timeout_ms,
                    "workingDirectory": config.working_directory,
                    "spawnType": SpawnType::ToolAgent.as_str(),
                }),
                parent_id: None,
                sequence: None,
            });
        }

        execution::spawn_tool_agent_task(execution::ToolAgentTaskLaunch {
            session_manager: self.session_manager.clone(),
            event_store: self.event_store.clone(),
            broadcast: self.broadcast.clone(),
            provider_factory: self.provider_factory.clone(),
            guardrails: self.guardrails.clone(),
            hooks: self.hooks.clone(),
            worktree_coordinator: self.worktree_coordinator.get().cloned(),
            child_subagent_manager: self.arc_self(),
            child_session_id: child_session_id.clone(),
            parent_session_id: parent_sid.clone(),
            task: task.clone(),
            model: model.to_owned(),
            system_prompt: config.system_prompt.clone(),
            working_directory: config.working_directory.clone(),
            max_turns: config.max_turns,
            subagent_depth: config.current_depth,
            subagent_max_depth: config.max_depth,
            blocking_timeout_ms: config.blocking_timeout_ms,
            tracker: tracker.clone(),
            cancel,
            tools: tool_factory(),
            denied_tools: config.denied_tools.clone(),
            run_state_probe: self.probe_clone(),
            spawn_type: SpawnType::ToolAgent.as_str().to_owned(),
        });

        if let Some(timeout) = config.blocking_timeout_ms {
            let effective_timeout = if timeout > 0 { timeout } else { config.timeout_ms };
            if let Some(result) = self
                .wait_for_tracker_result(&tracker, effective_timeout)
                .await?
            {
                let success = result.status == "completed";
                Ok(SubagentHandle {
                    session_id: child_session_id,
                    output: Some(result.output),
                    token_usage: result.token_usage,
                    turns_executed: Some(result.turns_executed),
                    success: Some(success),
                })
            } else {
                Ok(SubagentHandle {
                    session_id: child_session_id,
                    output: None,
                    token_usage: None,
                    turns_executed: None,
                    success: None,
                })
            }
        } else {
            Ok(SubagentHandle {
                session_id: child_session_id,
                output: None,
                token_usage: None,
                turns_executed: None,
                success: None,
            })
        }
    }

    async fn wait_for_agents(
        &self,
        session_ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<SubagentResult>, ToolError> {
        self.wait_for_agents_impl(session_ids, mode, timeout_ms)
            .await
    }
}

#[async_trait]
impl crate::tools::traits::SubagentOps for SubagentManager {
    fn list_active_jobs(&self, parent_session_id: &str) -> Vec<crate::tools::traits::JobInfo> {
        self.list_active_jobs(parent_session_id)
    }

    fn cancel_subagent(&self, session_id: &str) -> Result<(), ToolError> {
        self.cancel_subagent(session_id)
    }

    async fn wait_for_agents(
        &self,
        session_ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<crate::tools::traits::SubagentResult>, ToolError> {
        self.wait_for_agents_impl(session_ids, mode, timeout_ms)
            .await
    }

    fn get_subagent_result(&self, session_id: &str) -> Option<crate::tools::traits::SubagentResult> {
        self.subagents
            .get(session_id)
            .and_then(|t| t.result.lock().clone())
    }
}

fn truncate(s: &str, max: usize) -> &str {
    crate::core::text::truncate_str(s, max)
}

/// Convert elapsed time to milliseconds as u64 (truncation is intentional).
#[allow(clippy::cast_possible_truncation)]
fn elapsed_ms(start: &Instant) -> u64 {
    start.elapsed().as_millis() as u64
}


#[cfg(test)]
#[path = "subagent_manager_tests.rs"]
mod tests;
