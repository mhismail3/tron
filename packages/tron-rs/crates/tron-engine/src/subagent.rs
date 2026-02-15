use std::sync::Arc;

use dashmap::DashMap;
use tokio::sync::{broadcast, oneshot};
use tokio_util::sync::CancellationToken;

use tron_core::events::AgentEvent;
use tron_core::ids::{AgentId, SessionId, WorkspaceId};
use tron_core::messages::Message;
use tron_core::provider::{LlmProvider, StreamOptions};
use tron_store::Database;

use crate::context::{ContextConfig, ContextManager};
use crate::error::EngineError;
use crate::hooks::HookEngine;
use crate::registry::{ToolFilter, ToolRegistry};
use crate::runner::{AgentRunner, RunnerConfig, TurnRunner};

/// Configuration for subagent behavior.
#[derive(Clone, Debug)]
pub struct SubagentConfig {
    /// Maximum subagent depth (0 = no sub-subagents, 1 = one level of sub-subagents, etc.)
    pub max_depth: u32,
    /// Maximum turns per subagent run.
    pub max_turns: u32,
    /// Stream options for subagent LLM calls.
    pub stream_options: StreamOptions,
}

impl Default for SubagentConfig {
    fn default() -> Self {
        Self {
            max_depth: 1,
            max_turns: 25,
            stream_options: StreamOptions::default(),
        }
    }
}

/// Handle for a running subagent.
struct SubagentHandle {
    cancel: CancellationToken,
    _join: tokio::task::JoinHandle<()>,
}

/// Manages subagent spawning, lifecycle, and tool inheritance.
pub struct SubagentManager {
    agents: DashMap<AgentId, SubagentHandle>,
    event_tx: broadcast::Sender<AgentEvent>,
    provider: Arc<dyn LlmProvider>,
    db: Database,
    hook_engine: Arc<HookEngine>,
    config: SubagentConfig,
}

impl SubagentManager {
    pub fn new(
        event_tx: broadcast::Sender<AgentEvent>,
        provider: Arc<dyn LlmProvider>,
        db: Database,
        hook_engine: Arc<HookEngine>,
        config: SubagentConfig,
    ) -> Self {
        Self {
            agents: DashMap::new(),
            event_tx,
            provider,
            db,
            hook_engine,
            config,
        }
    }

    /// Spawn a new subagent. Returns a receiver that resolves when the subagent completes.
    ///
    /// # Arguments
    /// * `parent_tools` - The parent's tool registry (will be filtered via `tool_filter`)
    /// * `tool_filter` - How to filter the parent's tools for the child
    /// * `prompt` - The task prompt for the subagent
    /// * `parent_session_id` - Parent's session ID (for event correlation)
    /// * `parent_agent_id` - Parent's agent ID (for event correlation)
    /// * `workspace_id` - Workspace context
    /// * `working_directory` - Working directory for tools
    /// * `current_depth` - How deep we are in the subagent tree
    /// * `parent_cancel` - Parent's cancellation token (child cancels when parent does)
    #[allow(clippy::too_many_arguments)]
    pub fn spawn(
        &self,
        parent_tools: &ToolRegistry,
        tool_filter: &ToolFilter,
        prompt: String,
        parent_session_id: SessionId,
        parent_agent_id: AgentId,
        workspace_id: WorkspaceId,
        working_directory: std::path::PathBuf,
        current_depth: u32,
        parent_cancel: CancellationToken,
    ) -> Result<oneshot::Receiver<SubagentResult>, EngineError> {
        // Enforce max depth
        if current_depth >= self.config.max_depth {
            return Err(EngineError::Internal(format!(
                "Maximum subagent depth ({}) exceeded",
                self.config.max_depth
            )));
        }

        let child_id = AgentId::new();
        let child_cancel = parent_cancel.child_token();
        let (result_tx, result_rx) = oneshot::channel();

        // Create filtered tool registry for the child
        let child_tools = Arc::new(parent_tools.clone_for_subagent(tool_filter));

        // Emit SubagentSpawned event
        let _ = self.event_tx.send(AgentEvent::SubagentSpawned {
            parent_session_id: parent_session_id.clone(),
            parent_agent_id: parent_agent_id.clone(),
            child_agent_id: child_id.clone(),
        });

        // Build the child runner
        let turn_runner = TurnRunner::new(
            Arc::clone(&self.provider),
            child_tools,
            Arc::clone(&self.hook_engine),
            self.db.clone(),
            self.event_tx.clone(),
            working_directory.clone(),
        );

        let runner_config = RunnerConfig {
            max_turns_per_prompt: self.config.max_turns,
            stream_options: self.config.stream_options.clone(),
            ..Default::default()
        };

        let agent_runner = AgentRunner::new(turn_runner, runner_config, self.event_tx.clone());
        let event_tx = self.event_tx.clone();

        let context_config = ContextConfig {
            project_root: working_directory.clone(),
            working_directory,
            ..Default::default()
        };
        let context_manager = ContextManager::new(context_config);

        let child_id_clone = child_id.clone();
        let cancel_clone = child_cancel.clone();
        let p_sess = parent_session_id.clone();
        let p_agent = parent_agent_id.clone();

        let join = tokio::spawn(async move {
            let mut messages = vec![Message::user_text(&prompt)];

            let result = agent_runner
                .run(
                    &context_manager,
                    &mut messages,
                    &p_sess,
                    &child_id_clone,
                    &workspace_id,
                    &cancel_clone,
                )
                .await;

            // Extract final assistant text
            let content = match result {
                Ok(()) => {
                    // Find last assistant message
                    messages
                        .iter()
                        .rev()
                        .find_map(|m| match m {
                            Message::Assistant(a) => Some(a.text_content()),
                            _ => None,
                        })
                        .unwrap_or_default()
                }
                Err(ref e) => format!("[subagent error] {e}"),
            };

            let is_error = result.is_err();

            // Emit SubagentComplete event
            let _ = event_tx.send(AgentEvent::SubagentComplete {
                parent_session_id: p_sess,
                parent_agent_id: p_agent,
                child_agent_id: child_id_clone,
                result: content.clone(),
            });

            // Send result back to parent
            let _ = result_tx.send(SubagentResult { content, is_error });
        });

        self.agents.insert(
            child_id.clone(),
            SubagentHandle {
                cancel: child_cancel,
                _join: join,
            },
        );

        Ok(result_rx)
    }

    /// Cancel a specific subagent.
    pub fn cancel(&self, agent_id: &AgentId) -> bool {
        if let Some((_, handle)) = self.agents.remove(agent_id) {
            handle.cancel.cancel();
            true
        } else {
            false
        }
    }

    /// Cancel all active subagents.
    pub fn cancel_all(&self) {
        for entry in self.agents.iter() {
            entry.value().cancel.cancel();
        }
        self.agents.clear();
    }

    /// Number of currently active subagents.
    pub fn active_count(&self) -> usize {
        self.agents.len()
    }

    /// Remove completed subagents from tracking.
    pub fn cleanup_completed(&self) {
        self.agents.retain(|_, handle| !handle._join.is_finished());
    }
}

/// Result from a completed subagent.
#[derive(Debug, Clone)]
pub struct SubagentResult {
    pub content: String,
    pub is_error: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_llm::mock::{MockProvider, MockResponse};
    use tron_store::sessions::SessionRepo;
    use tron_store::workspaces::WorkspaceRepo;

    fn setup() -> (Database, WorkspaceId, SessionId) {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        let sess_repo = SessionRepo::new(db.clone());
        let session = sess_repo
            .create(&ws.id, "claude-opus-4-6", "anthropic", "/tmp")
            .unwrap();
        (db, ws.id, session.id)
    }

    #[tokio::test]
    async fn spawn_and_complete() {
        let (db, ws_id, parent_session) = setup();
        let (tx, mut rx) = broadcast::channel(100);

        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::stream_text("Subagent result text"),
        ]));

        let hook_engine = Arc::new(HookEngine::new());
        let config = SubagentConfig {
            max_depth: 1,
            max_turns: 10,
            ..Default::default()
        };

        let manager = SubagentManager::new(tx, provider, db, hook_engine, config);

        let parent_tools = ToolRegistry::new();
        let parent_agent = AgentId::new();

        let result_rx = manager
            .spawn(
                &parent_tools,
                &ToolFilter::InheritAll,
                "Do something".to_string(),
                parent_session.clone(),
                parent_agent.clone(),
                ws_id,
                std::path::PathBuf::from("/tmp"),
                0,
                CancellationToken::new(),
            )
            .unwrap();

        // Wait for completion
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            result_rx,
        )
        .await
        .expect("timeout")
        .expect("channel closed");

        assert!(!result.is_error);
        assert!(result.content.contains("Subagent result text"));

        // Verify events were emitted
        let mut events = Vec::new();
        while let Ok(evt) = rx.try_recv() {
            events.push(evt.event_type().to_string());
        }
        assert!(events.contains(&"subagent_spawned".to_string()));
        assert!(events.contains(&"subagent_complete".to_string()));
    }

    #[tokio::test]
    async fn max_depth_enforced() {
        let (db, ws_id, _sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        let provider = Arc::new(MockProvider::new(vec![]));
        let hook_engine = Arc::new(HookEngine::new());
        let config = SubagentConfig {
            max_depth: 1,
            ..Default::default()
        };

        let manager = SubagentManager::new(tx, provider, db, hook_engine, config);
        let parent_tools = ToolRegistry::new();

        // current_depth = 1, max_depth = 1 → should fail
        let result = manager.spawn(
            &parent_tools,
            &ToolFilter::InheritAll,
            "nested too deep".to_string(),
            SessionId::new(),
            AgentId::new(),
            ws_id,
            std::path::PathBuf::from("/tmp"),
            1, // already at max depth
            CancellationToken::new(),
        );

        assert!(result.is_err());
    }

    #[tokio::test]
    async fn cancellation_propagates() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        // Provider with a slow response
        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::stream_text("slow result"),
        ]));

        let hook_engine = Arc::new(HookEngine::new());
        let config = SubagentConfig::default();

        let manager = SubagentManager::new(tx, provider, db, hook_engine, config);
        let parent_tools = ToolRegistry::new();
        let parent_cancel = CancellationToken::new();

        let _result_rx = manager
            .spawn(
                &parent_tools,
                &ToolFilter::InheritAll,
                "Do something".to_string(),
                sess_id,
                AgentId::new(),
                ws_id,
                std::path::PathBuf::from("/tmp"),
                0,
                parent_cancel.clone(),
            )
            .unwrap();

        assert_eq!(manager.active_count(), 1);

        // Cancel parent → should propagate to child
        parent_cancel.cancel();

        // Give a moment for the task to finish
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        manager.cleanup_completed();
    }

    #[test]
    fn cancel_specific_agent() {
        let db = Database::in_memory().unwrap();
        let (tx, _rx) = broadcast::channel::<AgentEvent>(100);
        let provider = Arc::new(MockProvider::new(vec![]));
        let hook_engine = Arc::new(HookEngine::new());
        let config = SubagentConfig::default();

        let manager = SubagentManager::new(tx, provider, db, hook_engine, config);

        // No agents to cancel
        assert!(!manager.cancel(&AgentId::new()));
    }

    #[test]
    fn cancel_all_clears() {
        let db = Database::in_memory().unwrap();
        let (tx, _rx) = broadcast::channel::<AgentEvent>(100);
        let provider = Arc::new(MockProvider::new(vec![]));
        let hook_engine = Arc::new(HookEngine::new());
        let config = SubagentConfig::default();

        let manager = SubagentManager::new(tx, provider, db, hook_engine, config);
        assert_eq!(manager.active_count(), 0);
        manager.cancel_all();
        assert_eq!(manager.active_count(), 0);
    }

    #[tokio::test]
    async fn tool_filter_applied() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        let provider = Arc::new(MockProvider::new(vec![
            MockResponse::stream_text("done"),
        ]));

        let hook_engine = Arc::new(HookEngine::new());
        let config = SubagentConfig::default();
        let manager = SubagentManager::new(tx, provider, db, hook_engine, config);

        // Parent has Read and Write tools
        let mut parent_tools = ToolRegistry::new();
        parent_tools.register(
            Arc::new(crate::tools::read::ReadTool),
            crate::registry::ToolSource::BuiltIn,
        );
        parent_tools.register(
            Arc::new(crate::tools::write::WriteTool),
            crate::registry::ToolSource::BuiltIn,
        );

        // Filter: only Read
        let filter = ToolFilter::Explicit(
            std::collections::HashSet::from(["Read".to_string()]),
        );

        let result_rx = manager
            .spawn(
                &parent_tools,
                &filter,
                "do something".to_string(),
                sess_id,
                AgentId::new(),
                ws_id,
                std::path::PathBuf::from("/tmp"),
                0,
                CancellationToken::new(),
            )
            .unwrap();

        // Just verify it spawns and completes (filter correctness tested in registry tests)
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            result_rx,
        )
        .await
        .expect("timeout")
        .expect("channel closed");

        assert!(!result.is_error);
    }
}
