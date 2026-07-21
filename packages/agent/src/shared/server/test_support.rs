//! Shared test fixtures for server capability tests.
//!
//! Mock providers, responder factories, and an in-memory `ServerRuntimeContext` builder
//! are used by engine and service tests via
//! `crate::shared::server::test_support::*`. Keeping the helpers in
//! their own file (instead of an inline `#[cfg(test)] mod` in `mod.rs`)
//! keeps setup code out of production modules.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use async_trait::async_trait;

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::model::responder::{
    ModelResponder, ModelResponderFactory, ModelResponderInfo, ModelResponse, ModelResponseError,
    ModelResponseRequest,
};
use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::ServerRuntimeContext;

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
    crate::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

pub(crate) fn test_settings_path(home: &Path) -> PathBuf {
    crate::shared::foundation::paths::settings_path_for_home(home)
}

pub(crate) fn test_auth_path(home: &Path) -> PathBuf {
    home.join(crate::shared::foundation::paths::dirs::PROFILES)
        .join(crate::shared::foundation::paths::files::AUTH_JSON)
}

pub(crate) fn test_settings_runtime(home: &Path) -> Arc<crate::domains::settings::SettingsRuntime> {
    Arc::new(crate::domains::settings::SettingsRuntime::load(home).unwrap())
}

/// A no-op model responder for tests.
pub struct MockModelResponder {
    model: String,
}

impl MockModelResponder {
    fn new(model: impl Into<String>) -> Self {
        Self {
            model: model.into(),
        }
    }
}

#[async_trait]
impl ModelResponder for MockModelResponder {
    fn info(&self) -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::Anthropic,
            provider_name: "anthropic",
            model: self.model.clone(),
            context_window: 200_000,
        }
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        Err(ModelResponseError::other("mock provider"))
    }
}

/// Mock responder factory that creates `MockModelResponder` for any model.
pub struct MockModelResponderFactory;
#[async_trait]
impl ModelResponderFactory for MockModelResponderFactory {
    async fn create_for_model(
        &self,
        model: &str,
        _api_settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(MockModelResponder::new(model)))
    }
}

/// Mock factory that returns model-aware responders (for model-switch tests).
pub struct ModelAwareMockFactory;
#[async_trait]
impl ModelResponderFactory for ModelAwareMockFactory {
    async fn create_for_model(
        &self,
        model: &str,
        _api_settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(MockModelResponder::new(model)))
    }
}

/// Mock factory that fails for unknown providers (auth error).
pub struct StrictMockFactory;
#[async_trait]
impl ModelResponderFactory for StrictMockFactory {
    async fn create_for_model(
        &self,
        model: &str,
        _api_settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        if model.starts_with("mock") || model.starts_with("claude") {
            Ok(Arc::new(MockModelResponder::new(model)))
        } else {
            Err(ModelResponseError::auth(format!(
                "No auth for model '{model}'"
            )))
        }
    }
}

/// Build an `ServerRuntimeContext` backed by an in-memory event store.
pub fn make_test_context() -> ServerRuntimeContext {
    make_test_context_with_responder_and_autonomy(None, false)
}

pub fn make_test_context_with_responder(
    responder_factory: Option<Arc<dyn ModelResponderFactory>>,
) -> ServerRuntimeContext {
    make_test_context_with_responder_and_autonomy(responder_factory, false)
}

/// Build a fully registered test server with the worker-first provider surface
/// enabled before domain composition occurs.
pub fn make_test_context_with_autonomous_workers() -> ServerRuntimeContext {
    make_test_context_with_responder_and_autonomy(None, true)
}

fn make_test_context_with_responder_and_autonomy(
    responder_factory: Option<Arc<dyn ModelResponderFactory>>,
    autonomous_workers: bool,
) -> ServerRuntimeContext {
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
    let settings_path = test_settings_path(&home);
    let auth_path = test_auth_path(&home);
    let settings_runtime = test_settings_runtime(&home);
    if autonomous_workers {
        crate::domains::settings::config::SettingsStore::new(&settings_path)
            .update(serde_json::json!({"autonomousWorkers": true}))
            .expect("enable autonomous workers for test context");
        settings_runtime
            .reload_now("autonomous worker test context")
            .expect("reload autonomous worker test settings");
    }
    let ctx = ServerRuntimeContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        settings_path,
        settings_runtime,
        responder_factory,
        server_start_time: Instant::now(),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        auth_path,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: unique_test_path("onboarded", "marker"),
    };
    crate::transport::runtime::setup::register_server_domains_for_context(&ctx).unwrap();
    ctx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn make_test_context_owns_isolated_settings_runtime() {
        let ctx = make_test_context();
        assert!(
            ctx.settings_path.starts_with(std::env::temp_dir()),
            "test settings path must be isolated from live engine settings"
        );
        assert!(
            ctx.settings_runtime
                .home()
                .starts_with(std::env::temp_dir())
        );
        assert_eq!(
            ctx.settings_runtime
                .current()
                .settings
                .server
                .heartbeat_interval_ms,
            crate::domains::settings::TronSettings::default()
                .server
                .heartbeat_interval_ms
        );
    }
}
