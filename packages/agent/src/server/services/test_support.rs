//! Shared test fixtures for server capability tests.
//!
//! Mock providers, factory wrappers, and an in-memory `ServerCapabilityContext` builder
//! are used by engine and service tests via
//! `crate::server::services::test_support::*`. Keeping the helpers in
//! their own file (instead of an inline `#[cfg(test)] mod` in `mod.rs`)
//! keeps setup code out of production modules.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
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
use crate::server::services::context::{AgentDeps, ServerCapabilityContext};
use crate::server::services::session_context::ContextArtifactsService;
use crate::skills::registry::SkillRegistry;
use crate::tools::registry::ToolRegistry;

static TEST_PATH_COUNTER: AtomicU64 = AtomicU64::new(0);

pub(crate) fn unique_test_path(name: &str, extension: &str) -> PathBuf {
    let id = TEST_PATH_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "tron-test-{name}-{}-{id}.{extension}",
        std::process::id()
    ))
}

pub(crate) fn unique_tron_home() -> PathBuf {
    let dir = unique_test_path("tron-home", "dir");
    let home = dir.join(".tron");
    crate::core::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

pub(crate) fn test_user_profile_path(home: &Path) -> PathBuf {
    home.join(crate::core::paths::dirs::PROFILES)
        .join(crate::core::profile::USER_PROFILE)
        .join(crate::core::paths::files::PROFILE_TOML)
}

pub(crate) fn test_auth_path(home: &Path) -> PathBuf {
    home.join(crate::core::paths::dirs::PROFILES)
        .join(crate::core::paths::files::AUTH_JSON)
}

pub(crate) fn test_profile_runtime(home: &Path) -> Arc<crate::runtime::ProfileRuntime> {
    Arc::new(crate::runtime::ProfileRuntime::load(home).unwrap())
}

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

/// Build `AgentDeps` for testing with a mock provider factory.
pub fn make_test_agent_deps() -> AgentDeps {
    AgentDeps {
        provider_factory: Arc::new(MockProviderFactory),
        tool_factory: Arc::new(ToolRegistry::new),
        guardrails: None,
    }
}

/// Build an `ServerCapabilityContext` backed by an in-memory event store.
pub fn make_test_context() -> ServerCapabilityContext {
    let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::events::run_migrations(&conn).unwrap();
    }
    let store = Arc::new(EventStore::new(pool));
    let mgr = Arc::new(SessionManager::new(store.clone()));
    let orch = Arc::new(Orchestrator::new(mgr.clone()));
    let home = unique_tron_home();
    let settings_path = test_user_profile_path(&home);
    let auth_path = test_auth_path(&home);
    let profile_runtime = test_profile_runtime(&home);
    let ctx = ServerCapabilityContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
        memory_registry: Arc::new(Mutex::new(MemoryRegistry::new())),
        settings_path,
        profile_runtime,
        agent_deps: None,
        server_start_time: Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        codex_app_server: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(ContextArtifactsService::new()),
        auth_path,
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(crate::runtime::hooks::abort_tracker::HookAbortTracker::new()),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: unique_test_path("onboarded", "marker"),
        release_fetcher: None,
        updater_state_path: unique_test_path("updater-state", "json"),
    };
    let mut registry =
        crate::server::transport::json_rpc::registry::JsonRpcTransportRegistry::new();
    crate::server::transport::json_rpc::bindings::register_all(&mut registry);
    crate::server::transport::json_rpc::engine_methods::register_engine_json_rpc_for_context(
        &ctx, &registry,
    )
    .unwrap();
    ctx
}
