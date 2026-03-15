//! RPC handler modules and registration.
//!
//! Handlers are grouped into three registration sets:
//!
//! ## `register_core` — Session and agent lifecycle
//!
//! `system` (ping, info, shutdown), `session` (CRUD, fork, archive),
//! `agent` (prompt, abort, state), `model` (list, switch), `context`
//! (snapshot, compaction), `events` (history, subscribe), `settings`,
//! `tool` (result), `message`, `memory` (ledger, search), `logs`
//!
//! ## `register_capabilities` — Domain features
//!
//! `skills` (list, get, refresh), `filesystem` (list, read, mkdir),
//! `task`/`projects`/`areas` (CRUD), `tree` (visualization, branches)
//!
//! ## `register_platform` — Platform-specific
//!
//! `browser` (stream), `canvas`, `worktree` (git), `transcription`,
//! `device` (push tokens), `notifications` (inbox), `plan`,
//! `communication`, `voice_notes`, `git`, `sandbox`

pub mod agent;
pub mod browser;
pub mod canvas;
pub mod communication;
pub mod context;
pub mod cron;
pub mod device;
pub mod events;
pub mod filesystem;
pub mod git;
pub mod logs;
pub mod memory;
pub mod message;
pub mod model;
pub mod notifications;
pub mod plan;
pub mod sandbox;
pub mod session;
pub mod settings;
pub mod skills;
pub mod system;
pub mod task;
pub mod tool;
pub mod transcription;
pub mod tree;
pub mod voice_notes;
pub mod worktree;

use crate::server::rpc::registry::MethodRegistry;

/// Register all RPC handlers with the registry.
#[allow(clippy::too_many_lines)]
pub fn register_all(registry: &mut MethodRegistry) {
    register_core(registry);
    register_capabilities(registry);
    register_platform(registry);
}

fn register_core(registry: &mut MethodRegistry) {
    // System
    registry.register("system.ping", system::PingHandler);
    registry.register("system.getInfo", system::GetInfoHandler);
    registry.register("system.shutdown", system::ShutdownHandler);

    // Session
    registry.register("session.create", session::CreateSessionHandler);
    registry.register("session.resume", session::ResumeSessionHandler);
    registry.register("session.list", session::ListSessionsHandler);
    registry.register("session.delete", session::DeleteSessionHandler);
    registry.register("session.fork", session::ForkSessionHandler);
    registry.register("session.getHead", session::GetHeadHandler);
    registry.register("session.getState", session::GetStateHandler);
    registry.register("session.getHistory", session::GetHistoryHandler);
    registry.register("session.archive", session::ArchiveSessionHandler);
    registry.register("session.unarchive", session::UnarchiveSessionHandler);
    registry.register("session.getChat", session::GetChatSessionHandler);
    registry.register("session.resetChat", session::ResetChatSessionHandler);

    // Agent
    registry.register("agent.prompt", agent::PromptHandler);
    registry.register("agent.abort", agent::AbortHandler);
    registry.register("agent.getState", agent::GetAgentStateHandler);

    // Model
    registry.register("model.list", model::ListModelsHandler);
    registry.register("model.switch", model::SwitchModelHandler);
    registry.register("config.setReasoningLevel", model::SetReasoningLevelHandler);

    // Context
    registry.register("context.getSnapshot", context::GetSnapshotHandler);
    registry.register(
        "context.getDetailedSnapshot",
        context::GetDetailedSnapshotHandler,
    );
    registry.register("context.shouldCompact", context::ShouldCompactHandler);
    registry.register(
        "context.previewCompaction",
        context::PreviewCompactionHandler,
    );
    registry.register(
        "context.confirmCompaction",
        context::ConfirmCompactionHandler,
    );
    registry.register("context.canAcceptTurn", context::CanAcceptTurnHandler);
    registry.register("context.clear", context::ClearHandler);
    registry.register("context.compact", context::CompactHandler);

    // Events
    registry.register("events.getHistory", events::GetHistoryHandler);
    registry.register("events.getSince", events::GetSinceHandler);
    registry.register("events.subscribe", events::SubscribeHandler);
    registry.register("events.unsubscribe", events::UnsubscribeHandler);
    registry.register("events.append", events::AppendHandler);

    // Settings
    registry.register("settings.get", settings::GetSettingsHandler);
    registry.register("settings.update", settings::UpdateSettingsHandler);

    // Tool
    registry.register("tool.result", tool::ToolResultHandler);

    // Message
    registry.register("message.delete", message::DeleteMessageHandler);

    // Memory
    registry.register("memory.getLedger", memory::GetLedgerHandler);
    registry.register("memory.updateLedger", memory::UpdateLedgerHandler);
    registry.register("memory.search", memory::SearchMemoryHandler);

    // Logs
    registry.register("logs.ingest", logs::IngestLogsHandler);
}

fn register_capabilities(registry: &mut MethodRegistry) {
    // Skills
    registry.register("skill.list", skills::ListSkillsHandler);
    registry.register("skill.get", skills::GetSkillHandler);
    registry.register("skill.refresh", skills::RefreshSkillsHandler);
    registry.register("skill.remove", skills::RemoveSkillHandler);

    // Filesystem
    registry.register("filesystem.listDir", filesystem::ListDirHandler);
    registry.register("filesystem.getHome", filesystem::GetHomeHandler);
    registry.register("filesystem.createDir", filesystem::CreateDirHandler);
    registry.register("file.read", filesystem::ReadFileHandler);

    // Tasks (plural to match TypeScript wire format)
    registry.register("tasks.create", task::CreateTaskHandler);
    registry.register("tasks.get", task::GetTaskHandler);
    registry.register("tasks.update", task::UpdateTaskHandler);
    registry.register("tasks.list", task::ListTasksHandler);
    registry.register("tasks.delete", task::DeleteTaskHandler);
    registry.register("tasks.search", task::SearchTasksHandler);
    registry.register("tasks.getActivity", task::GetTaskActivityHandler);
    registry.register("tasks.batchDelete", task::BatchDeleteTasksHandler);
    registry.register("tasks.batchUpdate", task::BatchUpdateTasksHandler);
    registry.register("tasks.batchCreate", task::BatchCreateTasksHandler);

    // Projects (plural to match TypeScript wire format)
    registry.register("projects.create", task::CreateProjectHandler);
    registry.register("projects.list", task::ListProjectsHandler);
    registry.register("projects.get", task::GetProjectHandler);
    registry.register("projects.update", task::UpdateProjectHandler);
    registry.register("projects.delete", task::DeleteProjectHandler);
    registry.register("projects.getDetails", task::GetProjectDetailsHandler);

    // Areas (plural to match TypeScript wire format)
    registry.register("areas.create", task::CreateAreaHandler);
    registry.register("areas.list", task::ListAreasHandler);
    registry.register("areas.get", task::GetAreaHandler);
    registry.register("areas.update", task::UpdateAreaHandler);
    registry.register("areas.delete", task::DeleteAreaHandler);

    // Tree
    registry.register("tree.getVisualization", tree::GetVisualizationHandler);
    registry.register("tree.getBranches", tree::GetBranchesHandler);
    registry.register("tree.getSubtree", tree::GetSubtreeHandler);
    registry.register("tree.getAncestors", tree::GetAncestorsHandler);
    registry.register("tree.compareBranches", tree::CompareBranchesHandler);
}

fn register_platform(registry: &mut MethodRegistry) {
    // Browser
    registry.register("browser.startStream", browser::StartStreamHandler);
    registry.register("browser.stopStream", browser::StopStreamHandler);
    registry.register("browser.getStatus", browser::GetStatusHandler);

    // Canvas
    registry.register("canvas.get", canvas::GetCanvasHandler);

    // Worktree
    registry.register("worktree.getStatus", worktree::GetStatusHandler);
    registry.register("worktree.commit", worktree::CommitHandler);
    registry.register("worktree.merge", worktree::MergeHandler);
    registry.register("worktree.list", worktree::ListHandler);
    registry.register("worktree.getDiff", worktree::GetDiffHandler);
    registry.register("worktree.acquire", worktree::AcquireHandler);
    registry.register("worktree.release", worktree::ReleaseHandler);
    registry.register(
        "worktree.listSessionBranches",
        worktree::ListSessionBranchesHandler,
    );
    registry.register(
        "worktree.getCommittedDiff",
        worktree::GetCommittedDiffHandler,
    );

    // Transcription
    registry.register("transcribe.audio", transcription::TranscribeAudioHandler);
    registry.register("transcribe.listModels", transcription::ListModelsHandler);
    registry.register(
        "transcribe.downloadModel",
        transcription::DownloadModelHandler,
    );

    // Device
    registry.register("device.register", device::RegisterTokenHandler);
    registry.register("device.unregister", device::UnregisterTokenHandler);
    registry.register("device.respond", device::DeviceRespondHandler);

    // Plan
    registry.register("plan.enter", plan::EnterPlanHandler);
    registry.register("plan.exit", plan::ExitPlanHandler);
    registry.register("plan.getState", plan::GetPlanStateHandler);

    // Communication
    registry.register("communication.send", communication::SendHandler);
    registry.register("communication.receive", communication::ReceiveHandler);
    registry.register("communication.subscribe", communication::SubscribeHandler);
    registry.register(
        "communication.unsubscribe",
        communication::UnsubscribeHandler,
    );

    // Voice Notes
    registry.register("voiceNotes.save", voice_notes::SaveHandler);
    registry.register("voiceNotes.list", voice_notes::ListHandler);
    registry.register("voiceNotes.delete", voice_notes::DeleteHandler);

    // Git
    registry.register("git.clone", git::CloneHandler);

    // Sandbox
    registry.register("sandbox.listContainers", sandbox::ListContainersHandler);
    registry.register("sandbox.startContainer", sandbox::StartContainerHandler);
    registry.register("sandbox.stopContainer", sandbox::StopContainerHandler);
    registry.register("sandbox.killContainer", sandbox::KillContainerHandler);
    registry.register("sandbox.removeContainer", sandbox::RemoveContainerHandler);

    // Notifications
    registry.register("notifications.list", notifications::ListHandler);
    registry.register("notifications.markRead", notifications::MarkReadHandler);
    registry.register(
        "notifications.markAllRead",
        notifications::MarkAllReadHandler,
    );

    // Cron
    registry.register("cron.list", cron::ListHandler);
    registry.register("cron.get", cron::GetHandler);
    registry.register("cron.create", cron::CreateHandler);
    registry.register("cron.update", cron::UpdateHandler);
    registry.register("cron.delete", cron::DeleteHandler);
    registry.register("cron.run", cron::RunHandler);
    registry.register("cron.status", cron::StatusHandler);
    registry.register("cron.getRuns", cron::GetRunsHandler);
}

/// Extract a required parameter from the params object.
pub(crate) fn require_param<'a>(
    params: Option<&'a serde_json::Value>,
    key: &str,
) -> Result<&'a serde_json::Value, crate::server::rpc::errors::RpcError> {
    params
        .and_then(|p| p.get(key))
        .ok_or_else(|| crate::server::rpc::errors::RpcError::InvalidParams {
            message: format!("Missing required parameter: {key}"),
        })
}

/// Extract a required string parameter.
pub(crate) fn require_string_param(
    params: Option<&serde_json::Value>,
    key: &str,
) -> Result<String, crate::server::rpc::errors::RpcError> {
    require_param(params, key)?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| crate::server::rpc::errors::RpcError::InvalidParams {
            message: format!("Parameter '{key}' must be a string"),
        })
}

/// Extract an optional string parameter.
pub(crate) fn opt_string(params: Option<&serde_json::Value>, key: &str) -> Option<String> {
    params
        .and_then(|p| p.get(key))
        .and_then(|v| v.as_str())
        .map(ToOwned::to_owned)
}

/// Extract an optional u64 parameter, returning `default` if absent or wrong type.
pub(crate) fn opt_u64(params: Option<&serde_json::Value>, key: &str, default: u64) -> u64 {
    params
        .and_then(|p| p.get(key))
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(default)
}

/// Extract an optional bool parameter.
pub(crate) fn opt_bool(params: Option<&serde_json::Value>, key: &str) -> Option<bool> {
    params
        .and_then(|p| p.get(key))
        .and_then(serde_json::Value::as_bool)
}

/// Extract an optional array parameter.
pub(crate) fn opt_array<'a>(
    params: Option<&'a serde_json::Value>,
    key: &str,
) -> Option<&'a Vec<serde_json::Value>> {
    params.and_then(|p| p.get(key)).and_then(|v| v.as_array())
}

#[cfg(test)]
pub(crate) mod test_helpers {
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Instant;

    use async_trait::async_trait;
    use parking_lot::RwLock;
    use crate::events::EventStore;
    use crate::llm::models::types::Provider as ProviderKind;
    use crate::llm::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };
    use crate::runtime::orchestrator::orchestrator::Orchestrator;
    use crate::runtime::orchestrator::session_manager::SessionManager;
    use crate::skills::registry::SkillRegistry;
    use crate::tools::registry::ToolRegistry;

    use crate::server::rpc::context::{AgentDeps, RpcContext};
    use crate::server::rpc::session_context::ContextArtifactsService;

    /// A no-op mock provider for tests.
    pub struct MockProvider;
    #[async_trait]
    impl Provider for MockProvider {
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &crate::core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Other {
                message: "mock provider".into(),
            })
        }
    }

    /// Mock provider factory that creates `MockProvider` for any model.
    pub struct MockProviderFactory;
    #[async_trait]
    impl ProviderFactory for MockProviderFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(Arc::new(MockProvider))
        }
    }

    /// Mock factory that returns model-aware providers (for model-switch tests).
    pub struct ModelAwareMockFactory;
    #[async_trait]
    impl ProviderFactory for ModelAwareMockFactory {
        async fn create_for_model(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(Arc::new(ModelAwareMockProvider(model.to_owned())))
        }
    }

    /// A mock provider that remembers which model it was created for.
    pub struct ModelAwareMockProvider(pub String);
    #[async_trait]
    impl Provider for ModelAwareMockProvider {
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &str {
            &self.0
        }
        async fn stream(
            &self,
            _c: &crate::core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Other {
                message: "mock".into(),
            })
        }
    }

    /// Mock factory that fails for unknown providers (auth error).
    pub struct StrictMockFactory;
    #[async_trait]
    impl ProviderFactory for StrictMockFactory {
        async fn create_for_model(&self, model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            if model.starts_with("mock") || model.starts_with("claude") {
                Ok(Arc::new(MockProvider))
            } else {
                Err(ProviderError::Auth {
                    message: format!("No auth for model '{model}'"),
                })
            }
        }
    }

    /// Factory wrapper: always returns the same pre-built provider.
    /// Useful in tests that need a specific provider instance.
    pub struct FixedProviderFactory(pub Arc<dyn Provider>);
    #[async_trait]
    impl ProviderFactory for FixedProviderFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(self.0.clone())
        }
    }

    /// Build `AgentDeps` for testing with a mock provider factory.
    pub fn make_test_agent_deps() -> AgentDeps {
        AgentDeps {
            provider_factory: Arc::new(MockProviderFactory),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        }
    }

    /// Build an `RpcContext` backed by an in-memory event store.
    pub fn make_test_context() -> RpcContext {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store.clone()));
        let orch = Arc::new(Orchestrator::new(mgr.clone(), 10));
        RpcContext {
            orchestrator: orch,
            session_manager: mgr,
            event_store: store,
            skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
            task_pool: None,
            settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
            agent_deps: None,
            server_start_time: Instant::now(),
            browser_service: None,
            transcription_engine: Arc::new(std::sync::OnceLock::new()),
            embedding_controller: None,
            subagent_manager: None,
            health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            worktree_coordinator: None,
            device_request_broker: None,
            context_artifacts: Arc::new(ContextArtifactsService::new()),
        }
    }

    /// Build an `RpcContext` with task tables (same DB as events).
    pub fn make_test_context_with_tasks() -> RpcContext {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
            crate::runtime::tasks::migrations::run_migrations(&conn).unwrap();
        }
        let task_pool = pool.clone();
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store.clone()));
        let orch = Arc::new(Orchestrator::new(mgr.clone(), 10));

        RpcContext {
            orchestrator: orch,
            session_manager: mgr,
            event_store: store,
            skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
            task_pool: Some(task_pool),
            settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
            agent_deps: None,
            server_start_time: Instant::now(),
            browser_service: None,
            transcription_engine: Arc::new(std::sync::OnceLock::new()),
            embedding_controller: None,
            subagent_manager: None,
            health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            worktree_coordinator: None,
            device_request_broker: None,
            context_artifacts: Arc::new(ContextArtifactsService::new()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::registry::MethodRegistry;

    #[test]
    fn register_all_populates_registry() {
        let mut reg = MethodRegistry::new();
        register_all(&mut reg);
        assert!(reg.has_method("system.ping"));
        assert!(reg.has_method("session.create"));
        assert!(reg.has_method("agent.prompt"));
        assert!(reg.has_method("git.clone"));
        assert!(!reg.has_method("memory.getHandoffs"));
    }

    #[test]
    fn register_all_method_count() {
        let mut reg = MethodRegistry::new();
        register_all(&mut reg);
        assert_eq!(
            reg.methods().len(),
            122,
            "expected 122 methods, got {}",
            reg.methods().len()
        );
    }

    #[test]
    fn require_param_present() {
        let params = Some(serde_json::json!({"name": "alice"}));
        let val = require_param(params.as_ref(), "name").unwrap();
        assert_eq!(val, "alice");
    }

    #[test]
    fn require_param_missing() {
        let params = Some(serde_json::json!({"other": 1}));
        let err = require_param(params.as_ref(), "name").unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[test]
    fn require_param_none_params() {
        let err = require_param(None, "name").unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    // ── opt_string ──

    #[test]
    fn opt_string_present() {
        let p = Some(serde_json::json!({"name": "alice"}));
        assert_eq!(opt_string(p.as_ref(), "name"), Some("alice".to_owned()));
    }

    #[test]
    fn opt_string_missing_key() {
        let p = Some(serde_json::json!({"other": 1}));
        assert_eq!(opt_string(p.as_ref(), "name"), None);
    }

    #[test]
    fn opt_string_null_params() {
        assert_eq!(opt_string(None, "name"), None);
    }

    #[test]
    fn opt_string_wrong_type() {
        let p = Some(serde_json::json!({"name": 42}));
        assert_eq!(opt_string(p.as_ref(), "name"), None);
    }

    #[test]
    fn opt_string_null_value() {
        let p = Some(serde_json::json!({"name": null}));
        assert_eq!(opt_string(p.as_ref(), "name"), None);
    }

    // ── opt_u64 ──

    #[test]
    fn opt_u64_present() {
        let p = Some(serde_json::json!({"limit": 50}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 50);
    }

    #[test]
    fn opt_u64_missing_uses_default() {
        let p = Some(serde_json::json!({"other": 1}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 20);
    }

    #[test]
    fn opt_u64_null_params_uses_default() {
        assert_eq!(opt_u64(None, "limit", 20), 20);
    }

    #[test]
    fn opt_u64_wrong_type_uses_default() {
        let p = Some(serde_json::json!({"limit": "fifty"}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 20);
    }

    #[test]
    fn opt_u64_negative_uses_default() {
        let p = Some(serde_json::json!({"limit": -5}));
        assert_eq!(opt_u64(p.as_ref(), "limit", 20), 20);
    }

    // ── opt_bool ──

    #[test]
    fn opt_bool_true() {
        let p = Some(serde_json::json!({"enabled": true}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), Some(true));
    }

    #[test]
    fn opt_bool_false() {
        let p = Some(serde_json::json!({"enabled": false}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), Some(false));
    }

    #[test]
    fn opt_bool_missing() {
        let p = Some(serde_json::json!({"other": 1}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), None);
    }

    #[test]
    fn opt_bool_null_params() {
        assert_eq!(opt_bool(None, "enabled"), None);
    }

    #[test]
    fn opt_bool_wrong_type() {
        let p = Some(serde_json::json!({"enabled": "yes"}));
        assert_eq!(opt_bool(p.as_ref(), "enabled"), None);
    }

    // ── opt_array ──

    #[test]
    fn opt_array_present() {
        let p = Some(serde_json::json!({"tags": ["a", "b"]}));
        assert!(opt_array(p.as_ref(), "tags").is_some());
        assert_eq!(opt_array(p.as_ref(), "tags").unwrap().len(), 2);
    }

    #[test]
    fn opt_array_null_params() {
        assert!(opt_array(None, "tags").is_none());
    }

    #[test]
    fn opt_array_missing() {
        let p = Some(serde_json::json!({"other": 1}));
        assert!(opt_array(p.as_ref(), "tags").is_none());
    }

    #[test]
    fn opt_array_wrong_type() {
        let p = Some(serde_json::json!({"tags": "not-an-array"}));
        assert!(opt_array(p.as_ref(), "tags").is_none());
    }

    // ── to_json_value ──

    #[test]
    fn to_json_value_ok() {
        use crate::server::rpc::errors::to_json_value;
        let v = to_json_value(&vec!["a", "b"]).unwrap();
        assert!(v.is_array());
    }

    #[test]
    fn require_string_param_ok() {
        let params = Some(serde_json::json!({"id": "abc"}));
        let val = require_string_param(params.as_ref(), "id").unwrap();
        assert_eq!(val, "abc");
    }

    #[test]
    fn require_string_param_wrong_type() {
        let params = Some(serde_json::json!({"id": 42}));
        let err = require_string_param(params.as_ref(), "id").unwrap_err();
        assert!(err.to_string().contains("must be a string"));
    }
}
