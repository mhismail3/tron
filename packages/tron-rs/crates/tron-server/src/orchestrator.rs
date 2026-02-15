//! Agent orchestrator — connects the engine to the server.
//!
//! The `AgentOrchestrator` trait defines the interface for running agent prompts,
//! aborting active runs, and querying agent state. `EngineOrchestrator` is the
//! production implementation that wires `AgentRunner` to the server's RPC handlers.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use dashmap::DashMap;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;

use tron_core::events::{AgentEvent, PersistenceEventType};
use tron_core::ids::{AgentId, SessionId, WorkspaceId};
use tron_core::messages::Message;
use tron_core::provider::LlmProvider;
use tron_engine::context::{ContextConfig, ContextManager};
use tron_engine::error::EngineError;
use tron_engine::hooks::HookEngine;
use tron_engine::runner::{AgentRunner, RunnerConfig, TurnRunner};
use tron_engine::tools::create_default_registry;
use tron_store::events::EventRepo;
use tron_store::sessions::SessionRepo;
use tron_store::Database;

/// Parameters for starting an agent run.
#[derive(Debug, Clone)]
pub struct PromptParams {
    pub session_id: SessionId,
    pub prompt: String,
    pub workspace_id: WorkspaceId,
}

/// Result of accepting a prompt.
#[derive(Debug, Clone)]
pub struct PromptResult {
    pub run_id: String,
}

/// Current agent state for a session.
#[derive(Debug, Clone)]
pub struct AgentState {
    pub is_running: bool,
    pub current_turn: u32,
}

/// Trait for orchestrating agent runs.
#[async_trait]
pub trait AgentOrchestrator: Send + Sync {
    async fn prompt(&self, params: PromptParams) -> Result<PromptResult, EngineError>;
    fn abort(&self, session_id: &SessionId) -> bool;
    fn state(&self, session_id: &SessionId) -> AgentState;
    fn abort_all(&self) -> usize;
}

/// Tracks an active agent run.
struct ActiveRun {
    cancel: CancellationToken,
    turn: Arc<AtomicU32>,
    _started_at: Instant,
}

/// Production orchestrator backed by the engine crates.
pub struct EngineOrchestrator {
    provider: Arc<dyn LlmProvider>,
    db: Database,
    event_tx: broadcast::Sender<AgentEvent>,
    hook_engine: Arc<HookEngine>,
    active_runs: Arc<DashMap<SessionId, ActiveRun>>,
}

impl EngineOrchestrator {
    pub fn new(
        provider: Arc<dyn LlmProvider>,
        db: Database,
        event_tx: broadcast::Sender<AgentEvent>,
        hook_engine: Arc<HookEngine>,
    ) -> Self {
        Self {
            provider,
            db,
            event_tx,
            hook_engine,
            active_runs: Arc::new(DashMap::new()),
        }
    }
}

#[async_trait]
impl AgentOrchestrator for EngineOrchestrator {
    async fn prompt(&self, params: PromptParams) -> Result<PromptResult, EngineError> {
        // Reject if session already has an active run
        if self.active_runs.contains_key(&params.session_id) {
            return Err(EngineError::Internal(
                "Session already has an active agent run".into(),
            ));
        }

        // Look up session to get working directory and model
        let sess_repo = SessionRepo::new(self.db.clone());
        let session = sess_repo
            .get(&params.session_id)
            .map_err(|e| EngineError::SessionNotFound(e.to_string()))?;

        let working_directory = PathBuf::from(&session.working_directory);

        // Persist user message event
        let event_repo = EventRepo::new(self.db.clone());
        if let Err(e) = event_repo.append(
            &params.session_id,
            &params.workspace_id,
            PersistenceEventType::MessageUser,
            serde_json::json!({"text": &params.prompt}),
        ) {
            tracing::error!(error = %e, "Failed to persist user message event");
        }

        let run_id = uuid::Uuid::now_v7().to_string();
        let cancel = CancellationToken::new();
        let turn_counter = Arc::new(AtomicU32::new(0));

        self.active_runs.insert(
            params.session_id.clone(),
            ActiveRun {
                cancel: cancel.clone(),
                turn: Arc::clone(&turn_counter),
                _started_at: Instant::now(),
            },
        );

        // Reconstruct message history
        let mut messages = event_repo
            .reconstruct_messages(&params.session_id)
            .unwrap_or_default();
        messages.push(Message::user_text(&params.prompt));

        // Build engine components
        let tool_registry = Arc::new(create_default_registry(Some(self.db.clone())));

        let turn_runner = TurnRunner::new(
            Arc::clone(&self.provider),
            tool_registry,
            Arc::clone(&self.hook_engine),
            self.db.clone(),
            self.event_tx.clone(),
            working_directory.clone(),
        );

        let runner_config = RunnerConfig::default();
        let agent_runner = AgentRunner::new(turn_runner, runner_config, self.event_tx.clone());

        let context_config = ContextConfig {
            project_root: working_directory.clone(),
            working_directory,
            ..Default::default()
        };
        let context_manager = ContextManager::with_database(context_config, self.db.clone());

        let session_id = params.session_id.clone();
        let workspace_id = params.workspace_id.clone();
        let event_tx = self.event_tx.clone();
        let active_runs = self.active_runs.clone();
        let agent_id = AgentId::new();

        // Spawn background task
        tokio::spawn(async move {
            let result = agent_runner
                .run(
                    &context_manager,
                    &mut messages,
                    &session_id,
                    &agent_id,
                    &workspace_id,
                    &cancel,
                )
                .await;

            if let Err(ref e) = result {
                tracing::warn!(session_id = %session_id, error = %e, "Agent run failed");
            }

            // Emit agent.complete then agent.ready (ordering is critical for iOS)
            if event_tx
                .send(AgentEvent::AgentComplete {
                    session_id: session_id.clone(),
                    agent_id: agent_id.clone(),
                })
                .is_err()
            {
                tracing::warn!("No event receivers for agent.complete");
            }

            if event_tx
                .send(AgentEvent::AgentReady {
                    session_id: session_id.clone(),
                    agent_id,
                })
                .is_err()
            {
                tracing::warn!("No event receivers for agent.ready");
            }

            // Remove from active runs
            active_runs.remove(&session_id);
        });

        Ok(PromptResult { run_id })
    }

    fn abort(&self, session_id: &SessionId) -> bool {
        if let Some((_, run)) = self.active_runs.remove(session_id) {
            run.cancel.cancel();
            true
        } else {
            false
        }
    }

    fn state(&self, session_id: &SessionId) -> AgentState {
        match self.active_runs.get(session_id) {
            Some(run) => AgentState {
                is_running: true,
                current_turn: run.turn.load(Ordering::Relaxed),
            },
            None => AgentState {
                is_running: false,
                current_turn: 0,
            },
        }
    }

    fn abort_all(&self) -> usize {
        let count = self.active_runs.len();
        for entry in self.active_runs.iter() {
            entry.value().cancel.cancel();
        }
        self.active_runs.clear();
        count
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use tron_llm::mock::{MockProvider, MockResponse};
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

    fn make_orchestrator(
        db: Database,
        event_tx: broadcast::Sender<AgentEvent>,
        responses: Vec<MockResponse>,
    ) -> EngineOrchestrator {
        let provider = Arc::new(MockProvider::new(responses));
        let hook_engine = Arc::new(HookEngine::new());
        EngineOrchestrator::new(provider, db, event_tx, hook_engine)
    }

    // -- MockOrchestrator for handler testing --

    /// A simple mock orchestrator for testing handlers without the real engine.
    pub struct MockOrchestrator {
        prompt_result: std::sync::Mutex<Option<Result<PromptResult, EngineError>>>,
        abort_result: std::sync::atomic::AtomicBool,
        agent_state: std::sync::Mutex<AgentState>,
    }

    impl Default for MockOrchestrator {
        fn default() -> Self {
            Self::new()
        }
    }

    impl MockOrchestrator {
        pub fn new() -> Self {
            Self {
                prompt_result: std::sync::Mutex::new(Some(Ok(PromptResult {
                    run_id: "mock-run-id".into(),
                }))),
                abort_result: std::sync::atomic::AtomicBool::new(true),
                agent_state: std::sync::Mutex::new(AgentState {
                    is_running: false,
                    current_turn: 0,
                }),
            }
        }

        pub fn with_prompt_error(error_msg: &str) -> Self {
            Self {
                prompt_result: std::sync::Mutex::new(Some(Err(EngineError::Internal(
                    error_msg.into(),
                )))),
                abort_result: std::sync::atomic::AtomicBool::new(false),
                agent_state: std::sync::Mutex::new(AgentState {
                    is_running: false,
                    current_turn: 0,
                }),
            }
        }

        pub fn with_running_state(turn: u32) -> Self {
            Self {
                prompt_result: std::sync::Mutex::new(Some(Ok(PromptResult {
                    run_id: "mock-run-id".into(),
                }))),
                abort_result: std::sync::atomic::AtomicBool::new(true),
                agent_state: std::sync::Mutex::new(AgentState {
                    is_running: true,
                    current_turn: turn,
                }),
            }
        }
    }

    #[async_trait]
    impl AgentOrchestrator for MockOrchestrator {
        async fn prompt(&self, _params: PromptParams) -> Result<PromptResult, EngineError> {
            self.prompt_result
                .lock()
                .unwrap()
                .take()
                .unwrap_or(Ok(PromptResult {
                    run_id: "mock-run-id".into(),
                }))
        }

        fn abort(&self, _session_id: &SessionId) -> bool {
            self.abort_result
                .load(std::sync::atomic::Ordering::Relaxed)
        }

        fn state(&self, _session_id: &SessionId) -> AgentState {
            self.agent_state.lock().unwrap().clone()
        }

        fn abort_all(&self) -> usize {
            0
        }
    }

    // -- EngineOrchestrator tests --

    #[tokio::test]
    async fn prompt_returns_run_id() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![MockResponse::stream_text("Hello!")]);

        let result = orch
            .prompt(PromptParams {
                session_id: sess_id,
                prompt: "Say hello".into(),
                workspace_id: ws_id,
            })
            .await;

        assert!(result.is_ok());
        let pr = result.unwrap();
        assert!(!pr.run_id.is_empty());
    }

    #[tokio::test]
    async fn prompt_rejects_nonexistent_session() {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![]);

        let result = orch
            .prompt(PromptParams {
                session_id: SessionId::new(),
                prompt: "hello".into(),
                workspace_id: ws.id,
            })
            .await;

        assert!(matches!(result, Err(EngineError::SessionNotFound(_))));
    }

    #[tokio::test]
    async fn prompt_rejects_double_run() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);

        // Use a slow response so the first run is still active
        let orch = make_orchestrator(
            db,
            tx,
            vec![
                MockResponse::stream_text("slow response"),
                MockResponse::stream_text("second response"),
            ],
        );

        let first = orch
            .prompt(PromptParams {
                session_id: sess_id.clone(),
                prompt: "first".into(),
                workspace_id: ws_id.clone(),
            })
            .await;
        assert!(first.is_ok());

        // Immediately try a second prompt for the same session
        let second = orch
            .prompt(PromptParams {
                session_id: sess_id,
                prompt: "second".into(),
                workspace_id: ws_id,
            })
            .await;
        assert!(matches!(second, Err(EngineError::Internal(_))));
    }

    #[tokio::test]
    async fn prompt_sets_running_state() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![MockResponse::stream_text("response")]);

        // Before prompt: idle
        let state = orch.state(&sess_id);
        assert!(!state.is_running);

        let _ = orch
            .prompt(PromptParams {
                session_id: sess_id.clone(),
                prompt: "hello".into(),
                workspace_id: ws_id,
            })
            .await;

        // Immediately after prompt (task spawned but not yet finished): running
        // Note: this is racy, but the DashMap insert happens synchronously before spawn returns
        // Give a tiny moment for the spawned task to start
        let state = orch.state(&sess_id);
        assert!(state.is_running);
    }

    #[tokio::test]
    async fn prompt_clears_state_after_completion() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![MockResponse::stream_text("done")]);

        let _ = orch
            .prompt(PromptParams {
                session_id: sess_id.clone(),
                prompt: "hello".into(),
                workspace_id: ws_id,
            })
            .await;

        // Wait for the background task to complete
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        let state = orch.state(&sess_id);
        assert!(!state.is_running);
    }

    #[tokio::test]
    async fn prompt_emits_complete_then_ready() {
        let (db, ws_id, sess_id) = setup();
        let (tx, mut rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![MockResponse::stream_text("hello")]);

        let _ = orch
            .prompt(PromptParams {
                session_id: sess_id,
                prompt: "hi".into(),
                workspace_id: ws_id,
            })
            .await;

        // Collect events until we see agent_ready
        let mut event_types = Vec::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        while let Ok(Ok(event)) = tokio::time::timeout_at(deadline, rx.recv()).await {
            let et = event.event_type().to_string();
            event_types.push(et.clone());
            if et == "agent_ready" {
                break;
            }
        }

        // Verify ordering: agent_complete must appear before agent_ready
        let complete_idx = event_types
            .iter()
            .position(|e| e == "agent_complete")
            .expect("agent_complete not found");
        let ready_idx = event_types
            .iter()
            .position(|e| e == "agent_ready")
            .expect("agent_ready not found");
        assert!(
            complete_idx < ready_idx,
            "agent_complete ({complete_idx}) must precede agent_ready ({ready_idx})"
        );
    }

    #[tokio::test]
    async fn abort_cancels_active_run() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![MockResponse::stream_text("slow")]);

        let _ = orch
            .prompt(PromptParams {
                session_id: sess_id.clone(),
                prompt: "hello".into(),
                workspace_id: ws_id,
            })
            .await;

        let aborted = orch.abort(&sess_id);
        assert!(aborted);

        // After abort, state should eventually become idle
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        let state = orch.state(&sess_id);
        assert!(!state.is_running);
    }

    #[tokio::test]
    async fn abort_returns_false_when_idle() {
        let db = Database::in_memory().unwrap();
        let (tx, _rx) = broadcast::channel::<AgentEvent>(100);
        let orch = make_orchestrator(db, tx, vec![]);
        assert!(!orch.abort(&SessionId::new()));
    }

    #[tokio::test]
    async fn state_returns_idle_when_no_run() {
        let db = Database::in_memory().unwrap();
        let (tx, _rx) = broadcast::channel::<AgentEvent>(100);
        let orch = make_orchestrator(db, tx, vec![]);

        let state = orch.state(&SessionId::new());
        assert!(!state.is_running);
        assert_eq!(state.current_turn, 0);
    }

    #[tokio::test]
    async fn abort_all_cancels_everything() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![MockResponse::stream_text("slow")]);

        let _ = orch
            .prompt(PromptParams {
                session_id: sess_id,
                prompt: "hello".into(),
                workspace_id: ws_id,
            })
            .await;

        let count = orch.abort_all();
        assert_eq!(count, 1);

        // Active runs cleared
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        assert_eq!(orch.active_runs.len(), 0);
    }

    #[tokio::test]
    async fn abort_all_returns_zero_when_empty() {
        let db = Database::in_memory().unwrap();
        let (tx, _rx) = broadcast::channel::<AgentEvent>(100);
        let orch = make_orchestrator(db, tx, vec![]);
        assert_eq!(orch.abort_all(), 0);
    }

    // -- MockOrchestrator tests --

    #[tokio::test]
    async fn mock_orchestrator_prompt_succeeds() {
        let mock = MockOrchestrator::new();
        let result = mock
            .prompt(PromptParams {
                session_id: SessionId::new(),
                prompt: "hello".into(),
                workspace_id: WorkspaceId::new(),
            })
            .await;
        assert!(result.is_ok());
        assert_eq!(result.unwrap().run_id, "mock-run-id");
    }

    #[tokio::test]
    async fn mock_orchestrator_prompt_error() {
        let mock = MockOrchestrator::with_prompt_error("test error");
        let result = mock
            .prompt(PromptParams {
                session_id: SessionId::new(),
                prompt: "hello".into(),
                workspace_id: WorkspaceId::new(),
            })
            .await;
        assert!(result.is_err());
    }

    #[test]
    fn mock_orchestrator_state() {
        let mock = MockOrchestrator::with_running_state(3);
        let state = mock.state(&SessionId::new());
        assert!(state.is_running);
        assert_eq!(state.current_turn, 3);
    }

    #[test]
    fn mock_orchestrator_abort() {
        let mock = MockOrchestrator::new();
        assert!(mock.abort(&SessionId::new()));
    }

    #[tokio::test]
    async fn prompt_persists_user_message_event() {
        let (db, ws_id, sess_id) = setup();
        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db.clone(), tx, vec![MockResponse::stream_text("ok")]);

        let _ = orch
            .prompt(PromptParams {
                session_id: sess_id.clone(),
                prompt: "Test prompt".into(),
                workspace_id: ws_id,
            })
            .await;

        // Check that a user message event was persisted
        let event_repo = EventRepo::new(db);
        let events = event_repo.list(&sess_id, None, None).unwrap();
        assert!(
            events.iter().any(|e| e.event_type == "message_user"),
            "Expected message_user event in {:?}",
            events.iter().map(|e| &e.event_type).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn working_directory_from_session() {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        let sess_repo = SessionRepo::new(db.clone());
        // Create session with a specific working directory
        let session = sess_repo
            .create(&ws.id, "claude-opus-4-6", "anthropic", "/home/user/project")
            .unwrap();

        let (tx, _rx) = broadcast::channel(100);
        let orch = make_orchestrator(db, tx, vec![MockResponse::stream_text("done")]);

        // This should succeed (working dir from session, not hardcoded /tmp)
        let result = orch
            .prompt(PromptParams {
                session_id: session.id,
                prompt: "hello".into(),
                workspace_id: ws.id,
            })
            .await;
        assert!(result.is_ok());
    }
}
