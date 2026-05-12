//! `SubagentManager` — real `SubagentSpawner` implementation.
//!
//! Spawns child agents in-process, tracks their state, and forwards
//! events from child sessions to the parent session's broadcast.

use std::sync::Arc;
use std::time::Instant;

use crate::domains::agent::runner::guardrails::GuardrailEngine;
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::capability_support::implementations::errors::ToolError;
use crate::domains::capability_support::implementations::traits::{
    SubagentConfig, SubagentHandle, SubagentMode, SubagentResult, SubagentSpawner, WaitMode,
};
use crate::domains::model::providers::provider::ProviderFactory;
use crate::domains::session::event_store::{EventStore, EventType};
use crate::shared::events::{BaseEvent, TronEvent};
use async_trait::async_trait;
use dashmap::DashMap;
use parking_lot::Mutex;
use serde_json::{Value, json};
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::agent::runner::types::ReasoningLevel;

mod execution;
mod tracking;

// =============================================================================
// SpawnType — taxonomy for tracked subagents
// =============================================================================

/// Distinguishes tool-spawned agents from system-spawned `subsessions`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpawnType {
    /// Spawned by the LLM through the `agent::spawn_subagent` capability.
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
    /// Profile process id that defines prompt/model/tool/permission policy.
    pub process_id: Option<String>,
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
    /// Whether to inherit capabilities from the parent's live catalog policy (default false).
    pub inherit_capabilities: bool,
    /// Tools to deny from the inherited set.
    pub denied_capabilities: Vec<String>,
    /// Optional strict allowlist — when `Some`, ONLY these capabilities are kept
    /// (applied after `denied_capabilities`). Future-proof: newly registered tools
    /// will not leak into a restricted subagent.
    pub allowed_capabilities: Option<Vec<String>>,
    /// Reasoning effort level (default Some(Medium)).
    pub reasoning_level: Option<ReasoningLevel>,
    /// Spawn type for event tagging (default `Subsession`).
    pub spawn_type: SpawnType,
}

impl Default for SubsessionConfig {
    fn default() -> Self {
        Self {
            parent_session_id: String::new(),
            process_id: None,
            task: String::new(),
            model: None,
            system_prompt: String::new(),
            working_directory: "/tmp".into(),
            timeout_ms: 30_000,
            blocking_timeout_ms: Some(30_000),
            max_turns: 1,
            max_depth: 0,
            inherit_capabilities: false,
            denied_capabilities: vec![],
            allowed_capabilities: None,
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
    profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
    guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    hooks: Option<Arc<HookEngine>>,
    /// Worktree coordinator for subagent isolation (each subagent gets its own worktree).
    worktree_coordinator: std::sync::OnceLock<Arc<crate::domains::worktree::WorktreeCoordinator>>,
    /// Engine host used by child agents to resolve live provider tool schemas
    /// and route tool execution through canonical capabilities.
    engine_host: std::sync::OnceLock<crate::engine::EngineHostHandle>,
    /// Self-reference for passing to child agents (set after wrapping in Arc).
    self_ref: std::sync::OnceLock<std::sync::Weak<Self>>,
    /// Weak probe for querying parent-session run state without creating an
    /// Arc cycle with `Orchestrator`. Used to decide whether non-blocking
    /// subagent completion should surface a notification on iOS.
    run_state_probe: std::sync::OnceLock<
        std::sync::Weak<
            dyn crate::domains::agent::runner::orchestrator::orchestrator::RunStateProbe,
        >,
    >,
    /// Tracked subagents: `child_session_id` → `TrackedSubagent`.
    subagents: DashMap<String, Arc<TrackedSubagent>>,
    /// Skill registry used to resolve `SubagentConfig.skills` names to
    /// metadata so frontmatter `deniedCapabilities` / `allowedCapabilities` can be
    /// enforced on the spawned child. INVARIANT: if unset, `skills` on a
    /// `SubagentConfig` are silently ignored (documented as a wiring
    /// pitfall — see `main.rs::build_services` for the canonical setup).
    skill_registry: std::sync::OnceLock<
        Arc<parking_lot::RwLock<crate::domains::skills::registry::SkillRegistry>>,
    >,
}

impl SubagentManager {
    /// Create a new `SubagentManager`.
    pub fn new(
        session_manager: Arc<SessionManager>,
        event_store: Arc<EventStore>,
        broadcast: Arc<EventEmitter>,
        provider_factory: Arc<dyn ProviderFactory>,
        profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
        guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
        hooks: Option<Arc<HookEngine>>,
    ) -> Self {
        Self {
            session_manager,
            event_store,
            broadcast,
            provider_factory,
            profile_runtime,
            guardrails,
            hooks,
            worktree_coordinator: std::sync::OnceLock::new(),
            engine_host: std::sync::OnceLock::new(),
            self_ref: std::sync::OnceLock::new(),
            run_state_probe: std::sync::OnceLock::new(),
            subagents: DashMap::new(),
            skill_registry: std::sync::OnceLock::new(),
        }
    }

    /// Store a weak reference to the `RunStateProbe` (typically the
    /// orchestrator). Must be called once after both `SubagentManager` and
    /// `Orchestrator` are wrapped in Arcs. Without this, notification routing
    /// defaults to `notify=true` (safe — user sees every completion).
    pub fn set_run_state_probe(
        &self,
        probe: std::sync::Weak<
            dyn crate::domains::agent::runner::orchestrator::orchestrator::RunStateProbe,
        >,
    ) {
        let _ = self.run_state_probe.set(probe);
    }

    /// Clone the run-state probe for passing into execution tasks.
    fn probe_clone(
        &self,
    ) -> Option<
        std::sync::Weak<
            dyn crate::domains::agent::runner::orchestrator::orchestrator::RunStateProbe,
        >,
    > {
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
    pub fn set_worktree_coordinator(
        &self,
        coordinator: Arc<crate::domains::worktree::WorktreeCoordinator>,
    ) {
        let _ = self.worktree_coordinator.set(coordinator);
    }

    /// Set the shared engine host for subagents.
    pub fn set_engine_host(&self, host: crate::engine::EngineHostHandle) {
        let _ = self.engine_host.set(host);
    }

    /// Wire the skill registry so that `SubagentConfig.skills` names can be
    /// resolved to frontmatter-derived tool denials at spawn time.
    ///
    /// INVARIANT: If this setter is not called, `SubagentConfig.skills` is
    /// silently no-op'd (skills contribute no tool denials). This matches
    /// the `Option<SkillRegistry>` contract in [`compute_denied_capabilities`] and
    /// keeps skill wiring opt-in for isolated tests and minimal runtimes.
    pub fn set_skill_registry(
        &self,
        registry: Arc<parking_lot::RwLock<crate::domains::skills::registry::SkillRegistry>>,
    ) {
        let _ = self.skill_registry.set(registry);
    }

    /// Resolve a subprocess plan from the current compiled profile snapshot.
    pub fn plan_process(
        &self,
        process_id: &str,
    ) -> Result<crate::domains::agent::runner::ProcessExecutionPlan, ToolError> {
        self.profile_runtime
            .plan_process(process_id, None)
            .map_err(|error| ToolError::Internal {
                message: format!("Failed to plan process `{process_id}`: {error}"),
            })
    }

    /// Compute the full `denied_capabilities` list for a spawned subagent by
    /// unioning explicit denials (from the LLM's `deniedCapabilities` param) with
    /// any denials implied by `skills[*]` frontmatter (`deniedCapabilities` /
    /// inverted `allowedCapabilities`).
    ///
    /// Unknown skill names are silently skipped — the LLM may have
    /// hallucinated one, and we should not fail the spawn for that.
    /// Duplicates are deduplicated automatically (order is not preserved).
    pub(crate) fn compute_denied_capabilities(
        &self,
        explicit_denied: &[String],
        skills: Option<&[String]>,
        all_tool_names: &[String],
    ) -> Vec<String> {
        let mut denied: std::collections::HashSet<String> =
            explicit_denied.iter().cloned().collect();

        if let (Some(skill_names), Some(registry_lock)) = (skills, self.skill_registry.get()) {
            let registry = registry_lock.read();
            for name in skill_names {
                let Some(meta) = registry.get(name) else {
                    continue;
                };
                if let Some(cfg) = crate::domains::skills::denials::skill_frontmatter_to_denials(
                    &meta.frontmatter,
                    all_tool_names,
                ) {
                    for tool in cfg.denied_capabilities {
                        let _ = denied.insert(tool);
                    }
                }
            }
        }

        denied.into_iter().collect()
    }

    async fn current_tool_names(&self, session_id: &str) -> Vec<String> {
        let Some(host) = self.engine_host.get() else {
            return Vec::new();
        };
        match crate::domains::capability_support::implementations::capability_surface::list_model_tool_names(
            host, session_id, None,
        )
        .await
        {
            Ok(names) => names,
            Err(error) => {
                tracing::warn!(error = %error, "failed to read live capability catalog for subagent policy");
                Vec::new()
            }
        }
    }

    /// Spawn a system subsession for programmatic tasks (hooks, compaction, memory).
    ///
    /// Unlike `spawn()` (tool-agent path), the caller provides the system prompt
    /// directly, capabilities are optional, and the subsession is tracked as
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
            .unwrap_or(crate::domains::model::providers::model_ids::SUBAGENT_MODEL);
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
        let process_id = config
            .process_id
            .as_deref()
            .unwrap_or("spawnSubagent.inProcess");
        let process_plan = self.plan_process(process_id)?;
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

        let mut capability_policy = process_plan.capability_policy.clone();
        if config.inherit_capabilities {
            capability_policy.allowed_capabilities = config.allowed_capabilities.clone();
        } else {
            capability_policy.allowed_capabilities = Some(Vec::new());
        }

        execution::spawn_subsession_task(execution::SubsessionTaskLaunch {
            session_manager: self.session_manager.clone(),
            event_store: self.event_store.clone(),
            broadcast: self.broadcast.clone(),
            provider_factory: self.provider_factory.clone(),
            guardrails: self.guardrails.clone(),
            hooks: self.hooks.clone(),
            worktree_coordinator: self.worktree_coordinator.get().cloned(),
            child_subagent_manager: self.arc_self(),
            process_plan,
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
            capability_policy,
            denied_capabilities: config.denied_capabilities.clone(),
            engine_host: self.engine_host.get().cloned(),
        });

        if let Some(timeout) = config.blocking_timeout_ms {
            if let Some(result) = self.wait_for_tracker_result(&tracker, timeout).await? {
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

        // Depth eligibility is enforced by the spawning engine capability
        // before this service is called. `config.max_depth` is the child
        // agent's remaining child-spawn budget; zero means the child is a
        // leaf agent and is valid.

        let all_tool_names = self
            .current_tool_names(config.parent_session_id.as_deref().unwrap_or("subagent"))
            .await;

        // INVARIANT: subagent denied_capabilities = union(explicit_deniedCapabilities,
        // each skill's frontmatter denials). AgentFactory applies this merged
        // policy to the live catalog tool surface for the child agent. Without
        // this merge, skills with `deniedCapabilities: [...]` or `allowedCapabilities: [...]`
        // frontmatter would not affect the child agent's model-visible tools.
        let merged_denied_capabilities = self.compute_denied_capabilities(
            &config.denied_capabilities,
            config.skills.as_deref(),
            &all_tool_names,
        );

        let model = config
            .model
            .as_deref()
            .unwrap_or(crate::domains::model::providers::model_ids::SUBAGENT_MODEL);
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

        // INVARIANT: persist subagent.spawned to the parent session
        // BEFORE broadcasting SubagentSpawned. If persist fails, iOS
        // would render a "subagent spawned" event that the parent's
        // history doesn't record; reconstruction on reconnect would
        // show no trace of the spawn.
        let broadcast_event = TronEvent::SubagentSpawned {
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
        };

        if parent_sid.is_empty() {
            // No parent session → broadcast only; nothing to persist against.
            let _ = self.broadcast.emit(broadcast_event);
        } else {
            let persist_result =
                self.event_store
                    .append(&crate::domains::session::event_store::AppendOptions {
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
            if let Err(error) = persist_result {
                tracing::error!(
                    parent_session = %parent_sid,
                    child_session = %child_session_id,
                    error = %error,
                    "failed to persist subagent.spawned event; skipping broadcast"
                );
            } else {
                let _ = self.broadcast.emit(broadcast_event);
            }
        }

        let process_plan = self.plan_process("spawnSubagent.inProcess")?;
        let system_prompt = config.system_prompt.clone().or_else(|| {
            process_plan
                .prompt
                .as_ref()
                .map(|prompt| prompt.content.clone())
        });

        execution::spawn_tool_agent_task(execution::ToolAgentTaskLaunch {
            session_manager: self.session_manager.clone(),
            event_store: self.event_store.clone(),
            broadcast: self.broadcast.clone(),
            provider_factory: self.provider_factory.clone(),
            guardrails: self.guardrails.clone(),
            hooks: self.hooks.clone(),
            worktree_coordinator: self.worktree_coordinator.get().cloned(),
            child_subagent_manager: self.arc_self(),
            process_plan,
            child_session_id: child_session_id.clone(),
            parent_session_id: parent_sid.clone(),
            task: task.clone(),
            model: model.to_owned(),
            system_prompt,
            working_directory: config.working_directory.clone(),
            max_turns: config.max_turns,
            subagent_depth: config.current_depth,
            subagent_max_depth: config.max_depth,
            blocking_timeout_ms: config.blocking_timeout_ms,
            tracker: tracker.clone(),
            cancel,
            denied_capabilities: merged_denied_capabilities,
            run_state_probe: self.probe_clone(),
            spawn_type: SpawnType::ToolAgent.as_str().to_owned(),
            engine_host: self.engine_host.get().cloned(),
        });

        if let Some(timeout) = config.blocking_timeout_ms {
            let effective_timeout = if timeout > 0 {
                timeout
            } else {
                config.timeout_ms
            };
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
impl crate::domains::capability_support::implementations::traits::SubagentOps for SubagentManager {
    fn list_active_jobs(
        &self,
        parent_session_id: &str,
    ) -> Vec<crate::domains::capability_support::implementations::traits::JobInfo> {
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
    ) -> Result<
        Vec<crate::domains::capability_support::implementations::traits::SubagentResult>,
        ToolError,
    > {
        self.wait_for_agents_impl(session_ids, mode, timeout_ms)
            .await
    }

    fn get_subagent_result(
        &self,
        session_id: &str,
    ) -> Option<crate::domains::capability_support::implementations::traits::SubagentResult> {
        self.subagents
            .get(session_id)
            .and_then(|t| t.result.lock().clone())
    }
}

fn truncate(s: &str, max: usize) -> &str {
    crate::shared::text::truncate_str(s, max)
}

/// Convert elapsed time to milliseconds as u64 (truncation is intentional).
#[allow(clippy::cast_possible_truncation)]
fn elapsed_ms(start: &Instant) -> u64 {
    start.elapsed().as_millis() as u64
}

#[cfg(test)]
#[path = "subagent_manager_tests.rs"]
mod tests;
