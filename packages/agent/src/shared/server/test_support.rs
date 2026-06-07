//! Shared test fixtures for server capability tests.
//!
//! Mock providers, factory wrappers, and an in-memory `ServerRuntimeContext` builder
//! are used by engine and service tests via
//! `crate::shared::server::test_support::*`. Keeping the helpers in
//! their own file (instead of an inline `#[cfg(test)] mod` in `mod.rs`)
//! keeps setup code out of production modules.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use async_trait::async_trait;

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::model::providers::models::types::Provider as ProviderKind;
use crate::domains::model::providers::provider::{
    Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
};
use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::{AgentDeps, ServerRuntimeContext};

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
    crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

pub(crate) fn test_user_profile_path(home: &Path) -> PathBuf {
    home.join(crate::shared::paths::dirs::PROFILES)
        .join(crate::shared::profile::USER_PROFILE)
        .join(crate::shared::paths::files::PROFILE_TOML)
}

pub(crate) fn test_auth_path(home: &Path) -> PathBuf {
    home.join(crate::shared::paths::dirs::PROFILES)
        .join(crate::shared::paths::files::AUTH_JSON)
}

pub(crate) fn test_profile_runtime(
    home: &Path,
) -> Arc<crate::domains::agent::runner::ProfileRuntime> {
    Arc::new(crate::domains::agent::runner::ProfileRuntime::load(home).unwrap())
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
        _c: &crate::shared::messages::Context,
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
        _c: &crate::shared::messages::Context,
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
    }
}

/// Build an `ServerRuntimeContext` backed by an in-memory event store.
pub fn make_test_context() -> ServerRuntimeContext {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    let store = Arc::new(EventStore::new(pool));
    let mgr = Arc::new(SessionManager::new(store.clone()));
    let orch = Arc::new(Orchestrator::new(mgr.clone()));
    let home = unique_tron_home();
    let settings_path = test_user_profile_path(&home);
    let auth_path = test_auth_path(&home);
    let profile_runtime = test_profile_runtime(&home);
    let settings = crate::domains::settings::load_settings_from_path(&settings_path)
        .expect("test profile settings should load from isolated Tron home");
    crate::domains::settings::init_settings(settings);
    let ctx = ServerRuntimeContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        settings_path,
        profile_runtime,
        agent_deps: None,
        server_start_time: Instant::now(),
        health_tracker: Arc::new(crate::domains::model::providers::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        auth_path,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: unique_test_path("onboarded", "marker"),
        release_fetcher: None,
        updater_state_path: unique_test_path("updater-state", "json"),
    };
    crate::transport::setup::register_server_domains_for_context(&ctx).unwrap();
    ctx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn make_test_context_seeds_global_settings_from_isolated_profile() {
        let _guard = crate::domains::settings::test_settings_lock()
            .lock()
            .expect("settings test lock");
        crate::domains::settings::reset_settings();

        let ctx = make_test_context();
        assert!(
            ctx.settings_path.starts_with(std::env::temp_dir()),
            "test settings path must be isolated from the live user profile"
        );

        let settings = crate::domains::settings::get_settings();
        assert_eq!(
            settings.name,
            crate::domains::settings::TronSettings::default().name
        );
    }
}
