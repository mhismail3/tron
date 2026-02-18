//! RPC dependency-injection context.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use parking_lot::RwLock;
use tron_embeddings::EmbeddingController;
use tron_events::{ConnectionPool, EventStore};
use tron_llm::ProviderHealthTracker;
use tron_llm::provider::ProviderFactory;
use tron_runtime::guardrails::GuardrailEngine;
use tron_runtime::hooks::engine::HookEngine;
use tron_runtime::orchestrator::orchestrator::Orchestrator;
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_runtime::orchestrator::subagent_manager::SubagentManager;
use tron_skills::registry::SkillRegistry;
use tron_tools::registry::ToolRegistry;
use tron_transcription::TranscriptionEngine;

use crate::shutdown::ShutdownCoordinator;

/// Dependencies needed to create and run agents.
pub struct AgentDeps {
    /// Factory that creates a fresh LLM provider per request (reads current model + auth).
    pub provider_factory: Arc<dyn ProviderFactory>,
    /// Factory that creates a fresh tool registry per agent.
    pub tool_factory: Arc<dyn Fn() -> ToolRegistry + Send + Sync>,
    /// Guardrail engine (optional).
    pub guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Hook engine (optional).
    pub hooks: Option<Arc<HookEngine>>,
}

/// Shared context passed to every RPC handler.
pub struct RpcContext {
    /// Multi-session orchestrator.
    pub orchestrator: Arc<Orchestrator>,
    /// Session lifecycle manager.
    pub session_manager: Arc<SessionManager>,
    /// Event store for direct event queries.
    pub event_store: Arc<EventStore>,
    /// Skill registry (read/write).
    pub skill_registry: Arc<RwLock<SkillRegistry>>,
    /// Connection pool for task tables (same DB as events).
    pub task_pool: Option<ConnectionPool>,
    /// Path to settings JSON file.
    pub settings_path: PathBuf,
    /// Agent execution dependencies (None = prompt handler returns error).
    pub agent_deps: Option<AgentDeps>,
    /// When the server started (for uptime calculation).
    pub server_start_time: Instant,
    /// Browser service for CDP-based browser automation (None = browser not available).
    pub browser_service: Option<Arc<tron_tools::cdp::service::BrowserService>>,
    /// Native transcription engine (None = sidecar fallback).
    pub transcription_engine: Option<Arc<TranscriptionEngine>>,
    /// Embedding controller for vector search (None = embeddings not loaded).
    pub embedding_controller: Option<Arc<tokio::sync::Mutex<EmbeddingController>>>,
    /// Subagent manager for spawning subsessions (None = fallback to keyword summarizer).
    pub subagent_manager: Option<Arc<SubagentManager>>,
    /// Provider health tracker for rolling-window error rate monitoring.
    pub health_tracker: Arc<ProviderHealthTracker>,
    /// Shutdown coordinator for registering background task handles.
    pub shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::{
        ModelAwareMockFactory, StrictMockFactory, make_test_agent_deps, make_test_context,
        make_test_context_with_tasks,
    };

    #[test]
    fn context_has_server_start_time() {
        let ctx = make_test_context();
        let elapsed = ctx.server_start_time.elapsed();
        assert!(elapsed.as_secs() < 5);
    }

    #[test]
    fn server_start_time_allows_uptime_calc() {
        let ctx = make_test_context();
        let uptime = std::time::Instant::now() - ctx.server_start_time;
        assert!(uptime.as_secs() < 5);
    }

    #[test]
    fn context_has_orchestrator() {
        let ctx = make_test_context();
        assert_eq!(ctx.orchestrator.max_concurrent_sessions(), 10);
    }

    #[test]
    fn context_has_session_manager() {
        let ctx = make_test_context();
        assert_eq!(ctx.session_manager.active_count(), 0);
    }

    #[tokio::test]
    async fn context_session_manager_matches_orchestrator() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();
        assert_eq!(ctx.orchestrator.active_session_count(), 1);
    }

    #[test]
    fn context_has_event_store() {
        let ctx = make_test_context();
        let result = ctx.event_store.list_workspaces();
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn context_event_store_matches_session_manager() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();
        let session = ctx.event_store.get_session(&sid).unwrap();
        assert!(session.is_some());
    }

    #[test]
    fn context_has_skill_registry() {
        let ctx = make_test_context();
        let guard = ctx.skill_registry.read();
        assert_eq!(guard.list(None).len(), 0);
    }

    #[test]
    fn context_skill_registry_writable() {
        let ctx = make_test_context();
        let _guard = ctx.skill_registry.write();
    }

    #[test]
    fn context_has_settings_path() {
        let ctx = make_test_context();
        assert!(!ctx.settings_path.as_os_str().is_empty());
    }

    #[tokio::test]
    async fn context_event_store_operations_work() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();

        let event = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: serde_json::json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();
        assert_eq!(event.session_id, sid);
    }

    #[test]
    fn make_test_context_populates_all_fields() {
        let ctx = make_test_context();
        assert_eq!(ctx.orchestrator.max_concurrent_sessions(), 10);
        assert_eq!(ctx.session_manager.active_count(), 0);
        assert!(ctx.event_store.list_workspaces().is_ok());
        assert_eq!(ctx.skill_registry.read().list(None).len(), 0);
        assert!(ctx.task_pool.is_none());
        assert!(!ctx.settings_path.as_os_str().is_empty());
    }

    #[test]
    fn make_test_context_with_tasks_has_pool() {
        let ctx = make_test_context_with_tasks();
        assert!(ctx.task_pool.is_some());
        let pool = ctx.task_pool.as_ref().unwrap();
        let conn = pool.get().unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tasks", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 0);
    }

    // ── AgentDeps tests ──

    #[test]
    fn context_without_agent_deps_backward_compat() {
        let ctx = make_test_context();
        assert!(ctx.agent_deps.is_none());
    }

    #[test]
    fn context_with_agent_deps() {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(make_test_agent_deps());
        assert!(ctx.agent_deps.is_some());
    }

    #[test]
    fn agent_deps_provider_factory_accessible() {
        let deps = make_test_agent_deps();
        assert!(Arc::strong_count(&deps.provider_factory) >= 1);
    }

    #[tokio::test]
    async fn agent_deps_factory_creates_provider() {
        let deps = make_test_agent_deps();
        let provider = deps
            .provider_factory
            .create_for_model("claude-opus-4-6")
            .await
            .unwrap();
        assert_eq!(provider.model(), "mock");
    }

    #[tokio::test]
    async fn model_aware_factory_returns_correct_model() {
        let factory = ModelAwareMockFactory;
        let p1 = factory.create_for_model("claude-opus-4-6").await.unwrap();
        let p2 = factory.create_for_model("gpt-5.3-codex").await.unwrap();
        assert_eq!(p1.model(), "claude-opus-4-6");
        assert_eq!(p2.model(), "gpt-5.3-codex");
    }

    #[tokio::test]
    async fn strict_factory_rejects_unknown_model() {
        let factory = StrictMockFactory;
        let result = factory.create_for_model("unknown-model").await;
        match result {
            Err(e) => assert_eq!(e.category(), "auth"),
            Ok(_) => panic!("expected auth error"),
        }
    }

    #[test]
    fn agent_deps_tool_factory_creates_registry() {
        let deps = make_test_agent_deps();
        let registry = (deps.tool_factory)();
        assert!(registry.is_empty());
    }

    #[test]
    fn agent_deps_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AgentDeps>();
    }
}
