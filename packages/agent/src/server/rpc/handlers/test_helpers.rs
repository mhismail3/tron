//! Shared test fixtures for RPC handler tests.
//!
//! Mock providers, factory wrappers, and an in-memory `RpcContext` builder
//! are used by every handler test module via
//! `crate::server::rpc::handlers::test_helpers::*`. Keeping the helpers in
//! their own file (instead of an inline `#[cfg(test)] mod` in `mod.rs`)
//! lets the dispatch table file stay focused on registry wiring.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use parking_lot::{Mutex, RwLock};

use crate::events::EventStore;
use crate::llm::models::types::Provider as ProviderKind;
use crate::llm::provider::{
    Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
};
use crate::runtime::memory::MemoryRegistry;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::server::rpc::context::{AgentDeps, RpcContext};
use crate::server::rpc::session_context::ContextArtifactsService;
use crate::skills::registry::SkillRegistry;
use crate::tools::registry::ToolRegistry;

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
    let orch = Arc::new(Orchestrator::new(mgr.clone()));
    RpcContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
        memory_registry: Arc::new(Mutex::new(MemoryRegistry::new())),
        settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
        agent_deps: None,
        server_start_time: Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(ContextArtifactsService::new()),
        auth_path: PathBuf::from("/tmp/tron-test-auth.json"),
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(crate::runtime::hooks::abort_tracker::HookAbortTracker::new()),
        ws_port: 9847,
        onboarded_marker_path: PathBuf::from("/tmp/tron-test-onboarded.marker"),
        release_fetcher: None,
        updater_state_path: PathBuf::from("/tmp/tron-test-updater-state.json"),
    }
}
