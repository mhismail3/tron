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
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpawnType {
    /// Spawned by the LLM via the `SpawnSubagent` tool.
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
    /// Timeout in milliseconds (default `30_000`).
    pub timeout_ms: u64,
    /// If true, wait for completion; if false, return immediately with `session_id`.
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
            subagents: DashMap::new(),
        }
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

    /// Spawn a system subsession with full configurability.
    ///
    /// Unlike `spawn()` (tool-agent path), the caller provides the system prompt
    /// directly, tools are optional, and the subsession is tracked as
    /// `SpawnType::Subsession`.
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

        let (tracker, cancel) = self.register_subagent(
            child_session_id.clone(),
            config.parent_session_id.clone(),
            task.clone(),
            SpawnType::Subsession,
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

        execution::spawn_subsession_task(execution::SubsessionTaskLaunch {
            session_manager: self.session_manager.clone(),
            event_store: self.event_store.clone(),
            broadcast: self.broadcast.clone(),
            provider_factory: self.provider_factory.clone(),
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
            tracker: tracker.clone(),
            cancel,
            tools,
        });

        if config.blocking {
            if let Some(result) = self
                .wait_for_tracker_result(&tracker, config.timeout_ms)
                .await?
            {
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
            blocking: config.blocking,
            working_directory: Some(config.working_directory.clone()),
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
                    "blocking": config.blocking,
                    "workingDirectory": config.working_directory,
                }),
                parent_id: None,
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
            blocking: config.blocking,
            tracker: tracker.clone(),
            cancel,
            tools: tool_factory(),
        });

        if config.blocking {
            if let Some(result) = self
                .wait_for_tracker_result(&tracker, config.timeout_ms)
                .await?
            {
                Ok(SubagentHandle {
                    session_id: child_session_id,
                    output: Some(result.output),
                    token_usage: result.token_usage,
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

fn truncate(s: &str, max: usize) -> &str {
    crate::core::text::truncate_str(s, max)
}

/// Convert elapsed time to milliseconds as u64 (truncation is intentional).
#[allow(clippy::cast_possible_truncation)]
fn elapsed_ms(start: &Instant) -> u64 {
    start.elapsed().as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::agent::event_emitter::EventEmitter;
    use async_trait::async_trait;
    use futures::stream;
    use crate::core::content::AssistantContent;
    use crate::core::events::{AssistantMessage, StreamEvent};
    use crate::core::messages::TokenUsage;
    use crate::llm::models::types::Provider as ProviderKind;
    use crate::llm::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };

    struct MockProvider;
    #[async_trait]
    impl Provider for MockProvider {
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock-model"
        }
        async fn stream(
            &self,
            _c: &crate::core::messages::Context,
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
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock-model"
        }
        async fn stream(
            &self,
            _c: &crate::core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Auth {
                message: "expired".into(),
            })
        }
    }

    struct ProviderCreationErrorFactory;
    #[async_trait]
    impl ProviderFactory for ProviderCreationErrorFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Err(ProviderError::Other {
                message: "provider failed".into(),
            })
        }
    }

    fn make_manager_and_store() -> (Arc<SessionManager>, Arc<EventStore>, Arc<EventEmitter>) {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
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
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
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
    async fn spawn_depth_exceeded_returns_error() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_config("deep task");
        config.current_depth = 2;
        config.max_depth = 2; // current >= max → blocked
        let err = manager.spawn(config).await.unwrap_err();
        assert!(err.to_string().contains("exceeded"));
    }

    #[tokio::test]
    async fn spawn_depth_within_limit_succeeds() {
        let (manager, _, _) = make_subagent_manager(Arc::new(MockProvider));
        let mut config = make_config("allowed task");
        config.current_depth = 1;
        config.max_depth = 3;
        let handle = manager.spawn(config).await.unwrap();
        assert!(!handle.session_id.is_empty());
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
            .wait_for_agents(&[h1.session_id, h2.session_id], WaitMode::All, 30_000)
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
            .wait_for_agents(&[h1.session_id, h2.session_id], WaitMode::Any, 30_000)
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

    #[tokio::test]
    async fn spawn_provider_creation_failure_ends_child_session() {
        let (session_mgr, store, broadcast) = make_manager_and_store();
        let manager = Arc::new(SubagentManager::new(
            session_mgr.clone(),
            store,
            broadcast,
            Arc::new(ProviderCreationErrorFactory),
            None,
            None,
        ));
        manager.set_self_ref();
        manager.set_tool_factory(Arc::new(ToolRegistry::new));

        let handle = manager.spawn(make_config("task")).await.unwrap();

        let results = manager
            .wait_for_agents(
                std::slice::from_ref(&handle.session_id),
                WaitMode::All,
                10_000,
            )
            .await
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].status, "failed");
        assert!(
            !session_mgr.is_active(&handle.session_id),
            "provider creation failure should not leave child session active"
        );
    }

    #[tokio::test]
    async fn spawn_subsession_provider_creation_failure_ends_child_session() {
        let (session_mgr, store, broadcast) = make_manager_and_store();
        let manager = Arc::new(SubagentManager::new(
            session_mgr.clone(),
            store,
            broadcast,
            Arc::new(ProviderCreationErrorFactory),
            None,
            None,
        ));
        manager.set_self_ref();
        manager.set_tool_factory(Arc::new(ToolRegistry::new));

        let result = manager
            .spawn_subsession(make_subsession_config("task", "parent-001"))
            .await
            .unwrap();

        assert_eq!(result.output, "Provider creation failed: provider failed");
        assert!(
            !session_mgr.is_active(&result.session_id),
            "provider creation failure should not leave subsession active"
        );
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
        assert_eq!(
            events.len(),
            1,
            "expected one notification event in parent session"
        );

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
        assert!(
            events.is_empty(),
            "blocking subagents should not persist notification events"
        );
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
        assert_eq!(
            spawned.len(),
            1,
            "expected subagent.spawned in parent session"
        );
        let payload: serde_json::Value = serde_json::from_str(&spawned[0].payload).unwrap();
        assert_eq!(payload["task"], "lifecycle task");

        // subagent.completed should be persisted to parent
        let completed = store
            .get_events_by_type(&parent_sid, &["subagent.completed"], None)
            .unwrap();
        assert_eq!(
            completed.len(),
            1,
            "expected subagent.completed in parent session"
        );
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
        assert!(
            events.is_empty(),
            "subsessions should not persist notification events"
        );
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
        assert!(
            !events.is_empty(),
            "expected message.assistant events after end_session flush"
        );
    }
}
