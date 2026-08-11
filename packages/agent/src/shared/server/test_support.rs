//! Shared test fixtures for server tool tests.
//!
//! Mock providers, responder factories, and in-memory `ServerRuntimeContext` builders
//! are used by engine and service tests via
//! `crate::shared::server::test_support::*`. Keeping the helpers in
//! their own file (instead of an inline `#[cfg(test)] mod` in `mod.rs`)
//! keeps setup code out of production modules. Worker-runtime tests receive the
//! exact runtime bound into the test engine catalog so nested tool calls cannot
//! accidentally cross between unrelated temporary stores.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use async_trait::async_trait;
use serde_json::{Value, json};

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
    crate::shared::foundation::home::ensure_tron_home_at(&home).unwrap();
    home
}

pub(crate) fn test_settings_path(home: &Path) -> PathBuf {
    crate::shared::foundation::paths::settings_path_for_home(home)
}

pub(crate) fn test_auth_path(home: &Path) -> PathBuf {
    crate::shared::foundation::paths::auth_path_for_home(home)
}

/// Build an isolated Engine host with the mandatory provider-turn services
/// installed.
///
/// Most agent-loop tests intentionally do not construct a full Worker Runtime,
/// but every production provider turn performs the internal Team Context read.
/// Keeping that canonical contract in this shared fixture prevents bare test
/// hosts from accidentally exercising a weaker turn protocol.
pub(crate) fn new_agent_test_engine_host() -> crate::engine::EngineHostHandle {
    let host = crate::engine::EngineHostHandle::new_in_memory().expect("test engine host");
    register_agent_team_context(&host);
    host
}

/// Install the canonical Team Context definition with deterministic empty-team
/// data for a test-owned host.
pub(crate) fn register_agent_team_context(host: &crate::engine::EngineHostHandle) {
    const FUNCTION_ID: &str = "worker_kernel::agent_team_context";
    let definition = crate::domains::worker_kernel::test_function_definitions()
        .expect("worker-kernel contracts")
        .into_iter()
        .find(|definition| definition.id.as_str() == FUNCTION_ID)
        .expect("canonical agent Team Context contract");
    host.register_function_for_setup(definition, Arc::new(EmptyAgentTeamContextHandler))
        .expect("register agent Team Context test handler");
}

struct EmptyAgentTeamContextHandler;

#[async_trait]
impl crate::engine::InProcessFunctionHandler for EmptyAgentTeamContextHandler {
    async fn invoke(&self, invocation: crate::engine::Invocation) -> crate::engine::Result<Value> {
        let session_id = invocation
            .payload
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or("test-session");
        Ok(json!({
            "self": {
                "agentId": format!("test-agent:{session_id}"),
                "name": "Test agent",
                "role": "general",
                "owningSessionLabel": session_id,
                "relationship": "self",
                "status": "idle",
                "capabilities": [],
                "taskPreview": "",
                "canMessage": true,
                "canManage": true
            },
            "parent": null,
            "activeAssignment": null,
            "children": [],
            "correspondents": [],
            "unread": [],
            "authority": {},
            "resourceClaims": [],
            "budgets": {},
            "overflowCount": 0
        }))
    }
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
    make_test_context_with_responder(None)
}

pub fn make_test_context_with_responder(
    responder_factory: Option<Arc<dyn ModelResponderFactory>>,
) -> ServerRuntimeContext {
    let home = unique_tron_home();
    let ctx = build_test_context(&home, responder_factory);
    crate::transport::runtime::setup::register_server_domains_for_context(&ctx).unwrap();
    ctx
}

pub(crate) fn make_test_context_and_worker_runtime_at(
    home: &Path,
    responder_factory: Option<Arc<dyn ModelResponderFactory>>,
) -> (
    ServerRuntimeContext,
    Arc<crate::domains::worker_kernel::WorkerRuntime>,
) {
    crate::shared::foundation::home::ensure_tron_home_at(home).unwrap();
    let ctx = build_test_context(home, responder_factory);
    let activation = crate::domains::registration::register_domains_for_context(&ctx).unwrap();
    let worker_runtime = activation.into_worker_kernel_without_activation();
    (ctx, worker_runtime)
}

fn build_test_context(
    home: &Path,
    responder_factory: Option<Arc<dyn ModelResponderFactory>>,
) -> ServerRuntimeContext {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::ensure_schema(&conn).unwrap();
    }
    let store = Arc::new(EventStore::new(pool));
    let mgr = Arc::new(SessionManager::new(store.clone()));
    let orch = Arc::new(Orchestrator::new(mgr.clone()));
    let settings_path = test_settings_path(home);
    let auth_path = test_auth_path(home);
    let settings_runtime = test_settings_runtime(home);
    let terminal_service = crate::domains::terminal::TerminalService::new_with_root(
        store.clone(),
        home.join("internal/terminal"),
    );
    ServerRuntimeContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        terminal_service,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        settings_path,
        settings_runtime,
        responder_factory,
        server_start_time: Instant::now(),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        auth_path,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
    }
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
