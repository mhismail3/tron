//! RPC handler modules and registration.

pub mod agent;
pub mod browser;
pub mod canvas;
pub mod communication;
pub mod context;
pub mod device;
pub mod events;
pub mod filesystem;
pub mod git;
pub mod logs;
pub mod memory;
pub mod message;
pub mod sandbox;
pub mod model;
pub mod plan;
pub mod search;
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

use crate::registry::MethodRegistry;

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

    // Agent
    registry.register("agent.prompt", agent::PromptHandler);
    registry.register("agent.abort", agent::AbortHandler);
    registry.register("agent.getState", agent::GetAgentStateHandler);

    // Model
    registry.register("model.list", model::ListModelsHandler);
    registry.register("model.switch", model::SwitchModelHandler);

    // Context
    registry.register("context.getSnapshot", context::GetSnapshotHandler);
    registry.register("context.getDetailedSnapshot", context::GetDetailedSnapshotHandler);
    registry.register("context.shouldCompact", context::ShouldCompactHandler);
    registry.register("context.previewCompaction", context::PreviewCompactionHandler);
    registry.register("context.confirmCompaction", context::ConfirmCompactionHandler);
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
    registry.register("memory.getHandoffs", memory::GetHandoffsHandler);

    // Logs
    registry.register("logs.export", logs::ExportLogsHandler);
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

    // Search
    registry.register("search.content", search::ContentSearchHandler);
    registry.register("search.events", search::EventSearchHandler);

    // Tasks (plural to match TypeScript wire format)
    registry.register("tasks.create", task::CreateTaskHandler);
    registry.register("tasks.get", task::GetTaskHandler);
    registry.register("tasks.update", task::UpdateTaskHandler);
    registry.register("tasks.list", task::ListTasksHandler);
    registry.register("tasks.delete", task::DeleteTaskHandler);
    registry.register("tasks.search", task::SearchTasksHandler);
    registry.register("tasks.getActivity", task::GetTaskActivityHandler);

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

    // Transcription
    registry.register("transcribe.audio", transcription::TranscribeAudioHandler);
    registry.register("transcribe.listModels", transcription::ListModelsHandler);
    registry.register("transcribe.downloadModel", transcription::DownloadModelHandler);

    // Device
    registry.register("device.register", device::RegisterTokenHandler);
    registry.register("device.unregister", device::UnregisterTokenHandler);

    // Plan
    registry.register("plan.enter", plan::EnterPlanHandler);
    registry.register("plan.exit", plan::ExitPlanHandler);
    registry.register("plan.getState", plan::GetPlanStateHandler);

    // Communication
    registry.register("communication.send", communication::SendHandler);
    registry.register("communication.receive", communication::ReceiveHandler);
    registry.register("communication.subscribe", communication::SubscribeHandler);
    registry.register("communication.unsubscribe", communication::UnsubscribeHandler);

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
}

/// Extract a required parameter from the params object.
pub(crate) fn require_param<'a>(
    params: Option<&'a serde_json::Value>,
    key: &str,
) -> Result<&'a serde_json::Value, crate::errors::RpcError> {
    params
        .and_then(|p| p.get(key))
        .ok_or_else(|| crate::errors::RpcError::InvalidParams {
            message: format!("Missing required parameter: {key}"),
        })
}

/// Extract a required string parameter.
pub(crate) fn require_string_param(
    params: Option<&serde_json::Value>,
    key: &str,
) -> Result<String, crate::errors::RpcError> {
    require_param(params, key)?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| crate::errors::RpcError::InvalidParams {
            message: format!("Parameter '{key}' must be a string"),
        })
}

#[cfg(test)]
pub(crate) mod test_helpers {
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Instant;

    use async_trait::async_trait;
    use parking_lot::RwLock;
    use tron_events::EventStore;
    use tron_llm::models::types::ProviderType;
    use tron_llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
    use tron_runtime::orchestrator::orchestrator::Orchestrator;
    use tron_runtime::orchestrator::session_manager::SessionManager;
    use tron_skills::registry::SkillRegistry;
    use tron_tools::registry::ToolRegistry;

    use crate::context::{AgentDeps, RpcContext};

    /// A no-op mock provider for tests.
    pub struct MockProvider;
    #[async_trait]
    impl Provider for MockProvider {
        fn provider_type(&self) -> ProviderType {
            ProviderType::Anthropic
        }
        fn model(&self) -> &str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Other {
                message: "mock provider".into(),
            })
        }
    }

    /// Build `AgentDeps` for testing with a mock provider.
    pub fn make_test_agent_deps() -> AgentDeps {
        AgentDeps {
            provider: Arc::new(MockProvider),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        }
    }

    /// Build an `RpcContext` backed by an in-memory event store.
    pub fn make_test_context() -> RpcContext {
        let pool =
            tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            tron_events::run_migrations(&conn).unwrap();
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
            transcription_engine: None,
        }
    }

    /// Build an `RpcContext` with agent deps (mock provider).
    pub fn make_test_context_with_agent_deps() -> RpcContext {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(make_test_agent_deps());
        ctx
    }

    /// Build an `RpcContext` with task tables (same DB as events).
    pub fn make_test_context_with_tasks() -> RpcContext {
        let pool =
            tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            tron_events::run_migrations(&conn).unwrap();
            tron_tasks::migrations::run_migrations(&conn).unwrap();
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
            transcription_engine: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::MethodRegistry;

    #[test]
    fn register_all_populates_registry() {
        let mut reg = MethodRegistry::new();
        register_all(&mut reg);
        assert!(reg.has_method("system.ping"));
        assert!(reg.has_method("session.create"));
        assert!(reg.has_method("agent.prompt"));
        assert!(reg.has_method("git.clone"));
    }

    #[test]
    fn register_all_method_count() {
        let mut reg = MethodRegistry::new();
        register_all(&mut reg);
        assert_eq!(
            reg.methods().len(),
            101,
            "expected 101 methods, got {}",
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
