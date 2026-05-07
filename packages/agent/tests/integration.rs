//! End-to-end integration tests using a real WebSocket client.

use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::{SinkExt, StreamExt, stream};
use parking_lot::RwLock;
use serde_json::{Value, json};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use tron::core::content::AssistantContent;
use tron::core::events::{AssistantMessage, BaseEvent, StreamEvent, TronEvent};
use tron::core::messages::TokenUsage;
use tron::events::{ConnectionConfig, EventStore};
use tron::llm::models::types::Provider as ProviderKind;
use tron::llm::provider::{
    Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
};
use tron::runtime::orchestrator::orchestrator::Orchestrator;
use tron::runtime::orchestrator::session_manager::SessionManager;
use tron::server::config::ServerConfig;
use tron::server::server::TronServer;
use tron::server::services::context::{AgentDeps, ServerCapabilityContext};
use tron::server::transport::json_rpc::registry::JsonRpcTransportRegistry;
use tron::server::transport::json_rpc::types::JsonRpcEvent;
use tron::server::websocket::event_bridge::EventBridge;
use tron::skills::registry::SkillRegistry;
use tron::tools::registry::ToolRegistry;

const TIMEOUT: Duration = Duration::from_secs(5);
static TEST_PATH_COUNTER: AtomicU64 = AtomicU64::new(0);
static TEST_SERVER_AUTH_PATHS: LazyLock<Mutex<HashMap<String, PathBuf>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

fn unique_test_path(name: &str, extension: &str) -> PathBuf {
    let id = TEST_PATH_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "tron-integration-{name}-{}-{id}.{extension}",
        std::process::id()
    ))
}

fn unique_settings_path() -> PathBuf {
    let dir = unique_test_path("tron-home", "dir");
    let home = dir.join(".tron");
    tron::core::constitution::ensure_tron_home_at(&home).unwrap();
    home.join(tron::core::paths::dirs::PROFILES)
        .join(tron::core::profile::USER_PROFILE)
        .join(tron::core::paths::files::PROFILE_TOML)
}

fn unique_runtime_path(name: &str, extension: &str) -> PathBuf {
    let path = unique_test_path(name, extension);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    path
}

fn unique_event_store() -> Arc<EventStore> {
    let db_path = unique_runtime_path("events", "db");
    let pool = tron::events::new_file(&db_path.to_string_lossy(), &ConnectionConfig::default())
        .unwrap_or_else(|error| panic!("failed to open {}: {error}", db_path.display()));
    {
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();
    }
    Arc::new(EventStore::new(pool))
}

fn profile_runtime_for_settings_path(path: &std::path::Path) -> Arc<tron::runtime::ProfileRuntime> {
    let home = path
        .ancestors()
        .nth(3)
        .expect("settings path must be profiles/user/profile.toml");
    Arc::new(tron::runtime::ProfileRuntime::load(home).unwrap())
}

/// Boot a test server and return the WS URL + shutdown handle.
async fn boot_server_without_deps() -> (String, Arc<TronServer>) {
    let event_store = unique_event_store();

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));
    let settings_path = unique_settings_path();
    tron::settings::reload_settings_from_path(&settings_path).unwrap();

    let capability_context = ServerCapabilityContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        skill_registry,
        memory_registry: Arc::new(parking_lot::Mutex::new(
            tron::runtime::memory::MemoryRegistry::new(),
        )),
        profile_runtime: profile_runtime_for_settings_path(&settings_path),
        settings_path,
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        codex_app_server: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::server::services::session_context::ContextArtifactsService::new(),
        ),
        auth_path: unique_runtime_path("auth", "json"),
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(tron::runtime::hooks::abort_tracker::HookAbortTracker::new()),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(0)),
        onboarded_marker_path: unique_runtime_path("onboarded", "marker"),
        release_fetcher: None,
        updater_state_path: unique_runtime_path("updater-state", "json"),
    };

    let mut registry = JsonRpcTransportRegistry::new();
    tron::server::transport::json_rpc::bindings::register_all(&mut registry);

    let config = ServerConfig::default(); // port 0 = auto-assign
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(
        config,
        registry,
        capability_context,
        metrics_handle,
    ));
    tron::server::transport::json_rpc::engine_transport::register_engine_transport_for_context(
        server.capability_context(),
        server.registry(),
    )
    .expect("integration RPC engine bridge should register");
    tron::server::engine_runtime::EngineRuntimeServices::start(&server);

    let bridge = EventBridge::new(
        orchestrator.subscribe(),
        server.broadcast().clone(),
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    )
    .with_engine_streams(server.capability_context().engine_host.clone());
    let _bridge_handle = tokio::spawn(bridge.run());

    let (addr, _handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/ws");
    register_server_auth_path(&ws_url, &server.capability_context().auth_path);

    (ws_url, server)
}

/// Boot the default test server with a provider that stays active briefly so
/// busy-session behavior is observable in integration tests.
async fn boot_server() -> (String, Arc<TronServer>) {
    boot_server_with_provider(Arc::new(LaggyTextProvider::new("ok"))).await
}

// ── Mock Providers ──

struct TextOnlyProvider {
    text: String,
}
impl TextOnlyProvider {
    fn new(text: &str) -> Self {
        Self {
            text: text.to_owned(),
        }
    }
}
#[async_trait]
impl Provider for TextOnlyProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let text = self.text.clone();
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: text.clone(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(&text)],
                    token_usage: Some(TokenUsage {
                        input_tokens: 10,
                        output_tokens: 5,
                        ..Default::default()
                    }),
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(Box::pin(stream::iter(events)))
    }
}

struct LaggyTextProvider {
    text: String,
}
impl LaggyTextProvider {
    fn new(text: &str) -> Self {
        Self {
            text: text.to_owned(),
        }
    }
}
#[async_trait]
impl Provider for LaggyTextProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let text = self.text.clone();
        let s = async_stream::stream! {
            yield Ok(StreamEvent::Start);
            yield Ok(StreamEvent::TextDelta { delta: text.clone() });
            tokio::time::sleep(Duration::from_millis(500)).await;
            yield Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(&text)],
                    token_usage: Some(TokenUsage::default()),
                },
                stop_reason: "end_turn".into(),
            });
        };
        Ok(Box::pin(s))
    }
}

struct ErrorProvider;
#[async_trait]
impl Provider for ErrorProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        Err(ProviderError::Auth {
            message: "token expired".into(),
        })
    }
}

struct SlowProvider;
#[async_trait]
impl Provider for SlowProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let s = async_stream::stream! {
            yield Ok(StreamEvent::Start);
            yield Ok(StreamEvent::TextDelta { delta: "partial...".into() });
            tokio::time::sleep(Duration::from_secs(30)).await;
            yield Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("partial...")],
                    token_usage: Some(TokenUsage::default()),
                },
                stop_reason: "end_turn".into(),
            });
        };
        Ok(Box::pin(s))
    }
}

struct PanicThenTextProvider {
    has_panicked: AtomicBool,
    text: String,
}

impl PanicThenTextProvider {
    fn new(text: &str) -> Self {
        Self {
            has_panicked: AtomicBool::new(false),
            text: text.to_owned(),
        }
    }
}

#[async_trait]
impl Provider for PanicThenTextProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn model(&self) -> &'static str {
        "mock"
    }

    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        assert!(
            self.has_panicked.swap(true, Ordering::SeqCst),
            "provider panicked"
        );

        let text = self.text.clone();
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: text.clone(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(&text)],
                    token_usage: Some(TokenUsage::default()),
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(Box::pin(stream::iter(events)))
    }
}

/// Factory that always returns the same provider instance.
struct FixedProviderFactory(Arc<dyn Provider>);
#[async_trait]
impl ProviderFactory for FixedProviderFactory {
    async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        Ok(self.0.clone())
    }
}

/// Boot a test server with an injected LLM provider.
async fn boot_server_with_provider(provider: Arc<dyn Provider>) -> (String, Arc<TronServer>) {
    let (ws_url, server, _handles) = boot_server_with_provider_and_handles(provider).await;
    (ws_url, server)
}

async fn boot_server_with_provider_and_handles(
    provider: Arc<dyn Provider>,
) -> (String, Arc<TronServer>, Vec<JoinHandle<()>>) {
    let event_store = unique_event_store();

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));
    let settings_path = unique_settings_path();
    tron::settings::reload_settings_from_path(&settings_path).unwrap();

    let capability_context = ServerCapabilityContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        skill_registry,
        memory_registry: Arc::new(parking_lot::Mutex::new(
            tron::runtime::memory::MemoryRegistry::new(),
        )),
        profile_runtime: profile_runtime_for_settings_path(&settings_path),
        settings_path,
        agent_deps: Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(provider)),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
        }),
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        codex_app_server: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::server::services::session_context::ContextArtifactsService::new(),
        ),
        auth_path: unique_runtime_path("auth", "json"),
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(tron::runtime::hooks::abort_tracker::HookAbortTracker::new()),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(0)),
        onboarded_marker_path: unique_runtime_path("onboarded", "marker"),
        release_fetcher: None,
        updater_state_path: unique_runtime_path("updater-state", "json"),
    };

    let mut registry = JsonRpcTransportRegistry::new();
    tron::server::transport::json_rpc::bindings::register_all(&mut registry);

    let config = ServerConfig::default();
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(
        config,
        registry,
        capability_context,
        metrics_handle,
    ));
    tron::server::transport::json_rpc::engine_transport::register_engine_transport_for_context(
        server.capability_context(),
        server.registry(),
    )
    .expect("integration RPC engine bridge should register");
    tron::server::engine_runtime::EngineRuntimeServices::start(&server);

    let bridge = EventBridge::new(
        orchestrator.subscribe(),
        server.broadcast().clone(),
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    )
    .with_engine_streams(server.capability_context().engine_host.clone());
    let bridge_handle = tokio::spawn(bridge.run());

    let (addr, server_handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/ws");
    register_server_auth_path(&ws_url, &server.capability_context().auth_path);

    (ws_url, server, vec![bridge_handle, server_handle])
}

/// Connect and skip the initial system.connected message.
async fn connect(url: &str) -> WsStream {
    let auth_path = TEST_SERVER_AUTH_PATHS
        .lock()
        .unwrap()
        .get(url)
        .cloned()
        .expect("test server auth path should be registered before connect");
    let token = tron::server::onboarding::load_or_create_bearer_token(&auth_path).unwrap();
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {token}").parse().unwrap());
    let (ws, _) = connect_async(request).await.unwrap();
    ws
}

fn register_server_auth_path(url: &str, auth_path: &std::path::Path) {
    let _ = tron::server::onboarding::load_or_create_bearer_token(auth_path).unwrap();
    TEST_SERVER_AUTH_PATHS
        .lock()
        .unwrap()
        .insert(url.to_owned(), auth_path.to_path_buf());
}

/// Read the next text message as JSON.
async fn read_json(ws: &mut WsStream) -> Value {
    loop {
        let msg = timeout(TIMEOUT, ws.next())
            .await
            .expect("timeout waiting for message")
            .expect("stream closed")
            .expect("ws error");
        if let Message::Text(text) = msg {
            return serde_json::from_str(&text).unwrap();
        }
    }
}

/// Send a JSON-RPC request and read the response.
async fn rpc_call(ws: &mut WsStream, id: u64, method: &str, params: Option<Value>) -> Value {
    let (response, _) = rpc_call_with_interleaved_events(ws, id, method, params).await;
    response
}

async fn rpc_call_with_interleaved_events(
    ws: &mut WsStream,
    id: u64,
    method: &str,
    params: Option<Value>,
) -> (Value, Vec<Value>) {
    if method.contains("::") {
        return engine_invoke_call_with_interleaved_events(ws, id, method, params).await;
    }
    raw_rpc_call_with_interleaved_events(ws, id, method, params).await
}

async fn raw_rpc_call_with_interleaved_events(
    ws: &mut WsStream,
    id: u64,
    method: &str,
    params: Option<Value>,
) -> (Value, Vec<Value>) {
    let id_str = format!("r{id}");
    let mut req = json!({"id": id_str, "method": method});
    if method == "engine.invoke" {
        req["params"] = params.unwrap_or_else(|| json!({}));
    } else if let Some(p) = params {
        req["params"] = p;
    }
    ws.send(Message::text(req.to_string())).await.unwrap();

    // Read until we get a response with matching id
    let mut interleaved = Vec::new();
    loop {
        let parsed = read_json(ws).await;
        if parsed.get("id").and_then(|v| v.as_str()) == Some(&id_str) {
            return (parsed, interleaved);
        }
        interleaved.push(parsed);
    }
}

async fn engine_invoke_call_with_interleaved_events(
    ws: &mut WsStream,
    id: u64,
    function_id: &str,
    params: Option<Value>,
) -> (Value, Vec<Value>) {
    let payload = if function_id == "system::ping" {
        params.unwrap_or_else(ping_params)
    } else {
        params.unwrap_or_else(|| json!({}))
    };
    let idempotency_key = integration_idempotency_key(id, function_id, &payload);
    let mut invoke_params = json!({
        "functionId": function_id,
        "payload": payload,
        "idempotencyKey": idempotency_key,
    });
    if let Some(session_id) = invoke_params
        .pointer("/payload/sessionId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        && let Some(object) = invoke_params.as_object_mut()
    {
        object.insert("sessionId".to_owned(), json!(session_id));
    }
    if let Some(workspace_id) = invoke_params
        .pointer("/payload/workspaceId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        && let Some(object) = invoke_params.as_object_mut()
    {
        object.insert("workspaceId".to_owned(), json!(workspace_id));
    }
    let (response, events) =
        raw_rpc_call_with_interleaved_events(ws, id, "engine.invoke", Some(invoke_params)).await;
    (unwrap_engine_invoke_response(response), events)
}

async fn publish_engine_session_event(
    server: &Arc<TronServer>,
    session_id: &str,
    event_type: &str,
    data: Value,
) {
    let event = JsonRpcEvent::new(event_type, Some(session_id.to_owned()), Some(data));
    server
        .capability_context()
        .engine_host
        .publish_stream_event(tron::engine::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({
                "__rpcEvent": event,
                "sourceEventType": event_type,
            }),
            visibility: tron::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: None,
            producer: "integration-test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .expect("publish integration stream event");
}

fn unwrap_engine_invoke_response(response: Value) -> Value {
    if response.get("success") != Some(&Value::Bool(true)) {
        return response;
    }
    let Some(child) = response.pointer("/result/child") else {
        return response;
    };
    if !child.get("error").is_none_or(Value::is_null) {
        let error = child.get("error").unwrap_or(&Value::Null);
        let kind = error
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("ENGINE_ERROR");
        let domain_code = error
            .pointer("/details/code")
            .and_then(Value::as_str)
            .filter(|_| kind == "domain_failure");
        let domain_message = error
            .pointer("/details/message")
            .filter(|_| kind == "domain_failure")
            .cloned();
        let domain_details = error
            .pointer("/details/details")
            .filter(|_| kind == "domain_failure")
            .cloned();
        return json!({
            "id": response.get("id").cloned().unwrap_or(Value::Null),
            "success": false,
            "error": {
                "code": domain_code.map_or_else(|| json!(kind), |code| json!(code)),
                "message": domain_message
                    .or_else(|| error.get("message").cloned())
                    .unwrap_or_else(|| json!("engine invocation failed")),
                "details": domain_details
                    .or_else(|| error.get("details").cloned())
                    .unwrap_or(Value::Null),
            }
        });
    }
    json!({
        "id": response.get("id").cloned().unwrap_or(Value::Null),
        "success": true,
        "result": child.get("value").cloned().unwrap_or(Value::Null),
    })
}

fn integration_idempotency_key(id: u64, function_id: &str, payload: &Value) -> String {
    let mut hasher = DefaultHasher::new();
    id.hash(&mut hasher);
    function_id.hash(&mut hasher);
    serde_json::to_string(payload)
        .unwrap_or_default()
        .hash(&mut hasher);
    format!(
        "integration:{id}:{}:{:x}",
        function_id.replace("::", "-"),
        hasher.finish()
    )
}

fn ping_params() -> Value {
    json!({
        "protocolVersion": 1,
        "clientVersion": "integration-test",
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[path = "integration/tests.rs"]
mod tests;
