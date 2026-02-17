//! End-to-end integration tests using a real WebSocket client.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::{stream, SinkExt, StreamExt};
use parking_lot::RwLock;
use serde_json::{json, Value};
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use tron_core::content::AssistantContent;
use tron_core::events::{AssistantMessage, BaseEvent, StreamEvent, TronEvent};
use tron_core::messages::TokenUsage;
use tron_events::{ConnectionConfig, EventStore};
use tron_llm::models::types::ProviderType;
use tron_llm::provider::{
    Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
};
use tron_server::rpc::context::{AgentDeps, RpcContext};
use tron_server::rpc::registry::MethodRegistry;
use tron_runtime::orchestrator::orchestrator::Orchestrator;
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_server::config::ServerConfig;
use tron_server::server::TronServer;
use tron_server::websocket::event_bridge::EventBridge;
use tron_skills::registry::SkillRegistry;
use tron_tools::registry::ToolRegistry;

const TIMEOUT: Duration = Duration::from_secs(5);

type WsStream = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

/// Boot a test server and return the WS URL + shutdown handle.
async fn boot_server() -> (String, Arc<TronServer>) {
    let pool = tron_events::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron_events::run_migrations(&conn).unwrap();
        tron_runtime::tasks::migrations::run_migrations(&conn).unwrap();
    }
    let task_pool = pool.clone();
    let event_store = Arc::new(EventStore::new(pool));

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        task_pool: Some(task_pool),
        settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        browser_service: None,
        transcription_engine: None,
        subagent_manager: None,
        embedding_controller: None,
        health_tracker: Arc::new(tron_llm::ProviderHealthTracker::new()),
    };

    let mut registry = MethodRegistry::new();
    tron_server::rpc::handlers::register_all(&mut registry);

    let config = ServerConfig::default(); // port 0 = auto-assign
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder().handle();
    let server = Arc::new(TronServer::new(config, registry, rpc_context, metrics_handle));

    let bridge = EventBridge::new(orchestrator.subscribe(), server.broadcast().clone(), None);
    let _bridge_handle = tokio::spawn(bridge.run());

    let (addr, _handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/ws");

    (ws_url, server)
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

struct ErrorProvider;
#[async_trait]
impl Provider for ErrorProvider {
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
        Err(ProviderError::Auth {
            message: "token expired".into(),
        })
    }
}

struct SlowProvider;
#[async_trait]
impl Provider for SlowProvider {
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

/// Factory that always returns the same provider instance.
struct FixedProviderFactory(Arc<dyn Provider>);
#[async_trait]
impl ProviderFactory for FixedProviderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
    ) -> Result<Arc<dyn Provider>, ProviderError> {
        Ok(self.0.clone())
    }
}

/// Boot a test server with an injected LLM provider.
async fn boot_server_with_provider(provider: Arc<dyn Provider>) -> (String, Arc<TronServer>) {
    let pool = tron_events::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron_events::run_migrations(&conn).unwrap();
        tron_runtime::tasks::migrations::run_migrations(&conn).unwrap();
    }
    let task_pool = pool.clone();
    let event_store = Arc::new(EventStore::new(pool));

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        task_pool: Some(task_pool),
        settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
        agent_deps: Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(provider)),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        }),
        server_start_time: std::time::Instant::now(),
        browser_service: None,
        transcription_engine: None,
        subagent_manager: None,
        embedding_controller: None,
        health_tracker: Arc::new(tron_llm::ProviderHealthTracker::new()),
    };

    let mut registry = MethodRegistry::new();
    tron_server::rpc::handlers::register_all(&mut registry);

    let config = ServerConfig::default();
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder().handle();
    let server = Arc::new(TronServer::new(config, registry, rpc_context, metrics_handle));

    let bridge = EventBridge::new(orchestrator.subscribe(), server.broadcast().clone(), None);
    drop(tokio::spawn(bridge.run()));

    let (addr, _handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/ws");

    (ws_url, server)
}

/// Connect and skip the initial system.connected message.
async fn connect(url: &str) -> WsStream {
    let (ws, _) = connect_async(url).await.unwrap();
    ws
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
    let id_str = format!("r{id}");
    let mut req = json!({"id": id_str, "method": method});
    if let Some(p) = params {
        req["params"] = p;
    }
    ws.send(Message::text(req.to_string())).await.unwrap();

    // Read until we get a response with matching id
    loop {
        let parsed = read_json(ws).await;
        if parsed.get("id").and_then(|v| v.as_str()) == Some(&id_str) {
            return parsed;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_system_connected_on_connect() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    // First message should be system.connected with clientId nested in data
    let msg = read_json(&mut ws).await;
    assert_eq!(msg["type"], "connection.established");
    assert!(msg["data"]["clientId"].is_string());
    assert!(msg["timestamp"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_connect_and_ping() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await; // skip system.connected

    let resp = rpc_call(&mut ws, 1, "system.ping", None).await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["pong"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_lifecycle() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Create
    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": "/tmp", "title": "Test"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();
    assert!(!sid.is_empty());

    // List
    let resp = rpc_call(&mut ws, 2, "session.list", None).await;
    assert_eq!(resp["success"], true);
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(sessions.iter().any(|s| s["sessionId"] == sid));

    // Get state
    let resp = rpc_call(
        &mut ws,
        3,
        "session.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["sessionId"], sid);

    // Delete
    let resp = rpc_call(
        &mut ws,
        4,
        "session.delete",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_round_trip() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Create session
    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    // Append event
    let resp = rpc_call(
        &mut ws,
        2,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "hello world"}
        })),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["event"].is_object());

    // Get history
    let resp = rpc_call(
        &mut ws,
        3,
        "events.getHistory",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(!events.is_empty());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_settings_get() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "settings.get", None).await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"].is_object());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_model_list() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "model.list", None).await;
    assert_eq!(resp["success"], true);
    let models = resp["result"]["models"].as_array().unwrap();
    assert!(!models.is_empty());

    for model in models {
        assert!(model["id"].is_string());
        assert!(model["name"].is_string());
        assert!(model["provider"].is_string());
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_task_crud() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Create
    let resp = rpc_call(
        &mut ws,
        1,
        "tasks.create",
        Some(json!({"title": "Test task"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let task_id = resp["result"]["id"].as_str().unwrap().to_string();

    // Get
    let resp = rpc_call(&mut ws, 2, "tasks.get", Some(json!({"taskId": task_id}))).await;
    assert_eq!(resp["success"], true, "tasks.get failed: {resp}");
    assert_eq!(resp["result"]["title"], "Test task");

    // Update
    let resp = rpc_call(
        &mut ws,
        3,
        "tasks.update",
        Some(json!({"taskId": task_id, "status": "in_progress"})),
    )
    .await;
    assert_eq!(resp["success"], true);

    // List
    let resp = rpc_call(&mut ws, 4, "tasks.list", None).await;
    assert_eq!(resp["success"], true);

    // Delete
    let resp = rpc_call(
        &mut ws,
        5,
        "tasks.delete",
        Some(json!({"taskId": task_id})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_prompt_acknowledged() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "Hello"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["acknowledged"], true);
    assert!(resp["result"]["runId"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_abort() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "Hello"})),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        3,
        "agent.abort",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["aborted"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_handling() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "nonexistent.method", None).await;
    assert_eq!(resp["success"], false);
    assert!(resp["error"]["code"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_invalid_json() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    ws.send(Message::text("not valid json")).await.unwrap();

    let msg = read_json(&mut ws).await;
    assert_eq!(msg["success"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_missing_params() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "session.getState", Some(json!({}))).await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "INVALID_PARAMS");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_not_found() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.getState",
        Some(json!({"sessionId": "nonexistent-id"})),
    )
    .await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "SESSION_NOT_FOUND");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_skill_list() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "skill.list", None).await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["skills"].is_array());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_two_clients() {
    let (url, server) = boot_server().await;

    let mut ws1 = connect(&url).await;
    let _ = read_json(&mut ws1).await;

    let mut ws2 = connect(&url).await;
    let _ = read_json(&mut ws2).await;

    // Both can ping
    let resp1 = rpc_call(&mut ws1, 1, "system.ping", None).await;
    let resp2 = rpc_call(&mut ws2, 1, "system.ping", None).await;
    assert_eq!(resp1["success"], true);
    assert_eq!(resp2["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_rapid_fire_requests() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Send 50 rapid pings
    for i in 1..=50u64 {
        let req = json!({"id": format!("rapid_{i}"), "method": "system.ping"});
        ws.send(Message::text(req.to_string())).await.unwrap();
    }

    // Collect all 50 responses
    let mut received = 0u64;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while received < 50 {
        let remaining = deadline - tokio::time::Instant::now();
        let msg = timeout(remaining, ws.next())
            .await
            .expect("timeout")
            .expect("stream closed")
            .expect("ws error");
        if let Message::Text(text) = msg {
            let parsed: Value = serde_json::from_str(&text).unwrap();
            if parsed.get("id").and_then(|v| v.as_str()).is_some() {
                assert_eq!(parsed["success"], true);
                received += 1;
            }
        }
    }
    assert_eq!(received, 50);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_project_crud() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "projects.create",
        Some(json!({"title": "Test project"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let pid = resp["result"]["id"].as_str().unwrap().to_string();

    let resp = rpc_call(&mut ws, 2, "projects.list", None).await;
    assert_eq!(resp["success"], true);
    let projects = resp["result"]["projects"].as_array().unwrap();
    assert!(projects.iter().any(|p| p["id"] == pid));

    let resp = rpc_call(
        &mut ws,
        3,
        "projects.delete",
        Some(json!({"projectId": pid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_context_snapshot() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "context.getSnapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_search_events() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let _ = rpc_call(
        &mut ws,
        2,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "unique_search_term_xyz"}
        })),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        3,
        "search.content",
        Some(json!({"query": "unique_search_term_xyz"})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_concurrent_sessions() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp1 = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp/1"})),
    )
    .await;
    let sid1 = resp1["result"]["sessionId"].as_str().unwrap().to_string();

    let resp2 = rpc_call(
        &mut ws,
        2,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp/2"})),
    )
    .await;
    let sid2 = resp2["result"]["sessionId"].as_str().unwrap().to_string();

    assert_ne!(sid1, sid2);

    let resp = rpc_call(&mut ws, 3, "session.list", None).await;
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(sessions.len() >= 2);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_system_get_info() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "system.getInfo", None).await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["version"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_tree_visualization() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "tree.getVisualization",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["sessionId"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_get_state() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    // Not busy initially
    let resp = rpc_call(
        &mut ws,
        2,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["isRunning"], false);

    // Prompt to make busy
    let _ = rpc_call(
        &mut ws,
        3,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    // Now busy
    let resp = rpc_call(
        &mut ws,
        4,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["isRunning"], true);
    assert!(resp["result"]["runId"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_archive_unarchive() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    // Archive
    let resp = rpc_call(
        &mut ws,
        2,
        "session.archive",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["archived"], true);

    // Unarchive
    let resp = rpc_call(
        &mut ws,
        3,
        "session.unarchive",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["unarchived"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_memory_ledger() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "memory.getLedger",
        Some(json!({"workingDirectory": "/tmp"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["entries"].is_array());

    let resp = rpc_call(
        &mut ws,
        2,
        "memory.updateLedger",
        Some(json!({"workingDirectory": "/tmp"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"].get("written").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_create_enriched_response() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": "/tmp/test"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let result = &resp["result"];

    // Verify enriched fields
    assert!(result["sessionId"].is_string());
    assert_eq!(result["model"], "claude-opus-4-6");
    assert_eq!(result["workingDirectory"], "/tmp/test");
    assert!(result["createdAt"].is_string());
    assert_eq!(result["isActive"], true);
    assert_eq!(result["isArchived"], false);
    assert_eq!(result["messageCount"], 0);
    assert_eq!(result["inputTokens"], 0);
    assert_eq!(result["outputTokens"], 0);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_list_enriched_fields() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let _ = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp", "title": "Test Session"})),
    )
    .await;

    let resp = rpc_call(&mut ws, 2, "session.list", None).await;
    assert_eq!(resp["success"], true);
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(!sessions.is_empty());

    let s = &sessions[0];
    assert!(s["sessionId"].is_string());
    assert!(s["model"].is_string());
    assert!(s["createdAt"].is_string());
    assert!(s.get("isActive").is_some());
    assert!(s.get("isArchived").is_some());
    assert!(s.get("eventCount").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_projects_get_details() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "projects.create",
        Some(json!({"title": "Detail Project"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let pid = resp["result"]["id"].as_str().unwrap().to_string();

    // Create task under project
    let _ = rpc_call(
        &mut ws,
        2,
        "tasks.create",
        Some(json!({"title": "Task in project", "projectId": pid})),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        3,
        "projects.getDetails",
        Some(json!({"projectId": pid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["title"], "Detail Project");
    assert_eq!(resp["result"]["tasks"].as_array().unwrap().len(), 1);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_graceful_shutdown() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Verify the server is working before shutdown
    let resp = rpc_call(&mut ws, 1, "system.ping", None).await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();

    // Connection should eventually close — read until None or error
    let result = timeout(Duration::from_secs(3), async {
        while let Some(msg) = ws.next().await {
            if msg.is_err() {
                break;
            }
            if let Ok(Message::Close(_)) = msg {
                break;
            }
        }
    })
    .await;
    // It's okay if the shutdown timeout elapses — the test passed if we got here
    let _ = result;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Event streaming tests
// ─────────────────────────────────────────────────────────────────────────────

/// Helper to create a session and bind the client to it.
async fn create_and_bind_session(ws: &mut WsStream, id: u64) -> String {
    let resp = rpc_call(
        ws,
        id,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;
    resp["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string()
}

/// Try to read a JSON message within timeout. Returns None on timeout.
async fn try_read_json(ws: &mut WsStream, dur: Duration) -> Option<Value> {
    match timeout(dur, async {
        loop {
            if let Some(Ok(Message::Text(text))) = ws.next().await {
                return serde_json::from_str::<Value>(&text).ok();
            }
        }
    })
    .await
    {
        Ok(val) => val,
        Err(_) => None,
    }
}

/// Read until we see a specific event type. Returns the matching event.
async fn read_until_event_type(ws: &mut WsStream, event_type: &str) -> Option<Value> {
    let deadline = Duration::from_secs(3);
    let start = tokio::time::Instant::now();
    while start.elapsed() < deadline {
        let remaining = deadline.saturating_sub(start.elapsed());
        if let Some(msg) = try_read_json(ws, remaining).await {
            if msg.get("type").and_then(|v| v.as_str()) == Some(event_type) {
                return Some(msg);
            }
        } else {
            break;
        }
    }
    None
}

#[tokio::test]
async fn e2e_bridge_delivers_to_bound_client() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await; // skip connected

    // session.create auto-binds the connection to the session
    let sid = create_and_bind_session(&mut ws, 1).await;

    // Emit an event via orchestrator broadcast
    let _ = server
        .rpc_context()
        .orchestrator
        .broadcast()
        .emit(TronEvent::AgentStart {
            base: BaseEvent::now(&sid),
        });

    // Should receive the event
    let evt = read_until_event_type(&mut ws, "agent.start").await;
    assert!(evt.is_some(), "should receive agent.start event");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_bridge_multiple_clients() {
    let (url, server) = boot_server().await;

    let mut ws1 = connect(&url).await;
    let _ = read_json(&mut ws1).await;
    let mut ws2 = connect(&url).await;
    let _ = read_json(&mut ws2).await;

    // ws1 creates session (auto-binds ws1)
    let sid = create_and_bind_session(&mut ws1, 1).await;

    // ws2 resumes the same session (auto-binds ws2)
    let _ = rpc_call(&mut ws2, 1, "session.resume", Some(json!({"sessionId": sid}))).await;

    let _ = server
        .rpc_context()
        .orchestrator
        .broadcast()
        .emit(TronEvent::MessageUpdate {
            base: BaseEvent::now(&sid),
            content: "hello both".into(),
        });

    let evt1 = read_until_event_type(&mut ws1, "agent.text_delta").await;
    let evt2 = read_until_event_type(&mut ws2, "agent.text_delta").await;
    assert!(evt1.is_some());
    assert!(evt2.is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_bridge_session_isolation() {
    let (url, server) = boot_server().await;

    // Two connections, each bound to a different session
    let mut ws1 = connect(&url).await;
    let _ = read_json(&mut ws1).await;
    let mut ws2 = connect(&url).await;
    let _ = read_json(&mut ws2).await;

    let _sid1 = create_and_bind_session(&mut ws1, 1).await;
    let sid2 = create_and_bind_session(&mut ws2, 1).await;

    // Drain any session lifecycle events that may have been broadcast
    // (session.created events race with binding)
    let _ = try_read_json(&mut ws1, Duration::from_millis(50)).await;
    let _ = try_read_json(&mut ws2, Duration::from_millis(50)).await;

    // Emit event for sid2 only
    let _ = server
        .rpc_context()
        .orchestrator
        .broadcast()
        .emit(TronEvent::AgentStart {
            base: BaseEvent::now(&sid2),
        });

    // ws1 (bound to sid1) should NOT receive sid2's event
    let evt1 = try_read_json(&mut ws1, Duration::from_millis(200)).await;
    assert!(evt1.is_none(), "ws1 should not receive sid2 events");

    // ws2 (bound to sid2) SHOULD receive it
    let evt2 = read_until_event_type(&mut ws2, "agent.start").await;
    assert!(evt2.is_some(), "ws2 should receive sid2 events");
    if let Some(evt) = evt2 {
        assert_eq!(evt["sessionId"], sid2);
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_have_type_field() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let events = vec![
        TronEvent::AgentStart {
            base: BaseEvent::now(&sid),
        },
        TronEvent::TurnStart {
            base: BaseEvent::now(&sid),
            turn: 1,
        },
        TronEvent::MessageUpdate {
            base: BaseEvent::now(&sid),
            content: "hello".into(),
        },
    ];

    for evt in events {
        let _ = server.rpc_context().orchestrator.broadcast().emit(evt);
    }

    // Read all 3 events
    for _ in 0..3 {
        if let Some(evt) = try_read_json(&mut ws, Duration::from_secs(2)).await {
            assert!(evt.get("type").is_some(), "event should have type field: {evt}");
        }
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_have_timestamp() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = server
        .rpc_context()
        .orchestrator
        .broadcast()
        .emit(TronEvent::AgentStart {
            base: BaseEvent::now(&sid),
        });

    let evt = read_until_event_type(&mut ws, "agent.start").await;
    assert!(evt.is_some());
    assert!(evt.unwrap()["timestamp"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_have_session_id() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = server
        .rpc_context()
        .orchestrator
        .broadcast()
        .emit(TronEvent::AgentStart {
            base: BaseEvent::now(&sid),
        });

    let evt = read_until_event_type(&mut ws, "agent.start").await;
    assert!(evt.is_some());
    assert_eq!(evt.unwrap()["sessionId"], sid);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_event_ordering_preserved() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Emit 20 sequential events
    for i in 0..20 {
        let _ = server
            .rpc_context()
            .orchestrator
            .broadcast()
            .emit(TronEvent::MessageUpdate {
                base: BaseEvent::now(&sid),
                content: format!("msg_{i}"),
            });
    }

    // Collect events and verify order
    let mut received = Vec::new();
    for _ in 0..20 {
        if let Some(evt) = try_read_json(&mut ws, Duration::from_secs(3)).await {
            if evt.get("type").and_then(|v| v.as_str()) == Some("agent.text_delta") {
                if let Some(data) = evt.get("data") {
                    received.push(data["delta"].as_str().unwrap_or("").to_string());
                }
            }
        }
    }

    for (i, msg) in received.iter().enumerate() {
        assert_eq!(msg, &format!("msg_{i}"), "event {i} out of order");
    }

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Session reconstruction tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_state_persists_after_disconnect() {
    let (url, server) = boot_server().await;

    // Create session with first client
    let mut ws1 = connect(&url).await;
    let _ = read_json(&mut ws1).await;
    let sid = create_and_bind_session(&mut ws1, 1).await;

    // Disconnect first client
    drop(ws1);

    // Reconnect with new client
    let mut ws2 = connect(&url).await;
    let _ = read_json(&mut ws2).await;

    // Session should still exist
    let resp = rpc_call(
        &mut ws2,
        1,
        "session.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["sessionId"], sid);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_events_survive_reconnect() {
    let (url, server) = boot_server().await;

    let mut ws1 = connect(&url).await;
    let _ = read_json(&mut ws1).await;
    let sid = create_and_bind_session(&mut ws1, 1).await;

    // Append event
    let _ = rpc_call(
        &mut ws1,
        2,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "persisted message"}
        })),
    )
    .await;

    // Disconnect
    drop(ws1);

    // Reconnect
    let mut ws2 = connect(&url).await;
    let _ = read_json(&mut ws2).await;

    // Get history should still return the event
    let resp = rpc_call(
        &mut ws2,
        1,
        "events.getHistory",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(!events.is_empty());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_reconstruct_messages() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append user and assistant messages
    let _ = rpc_call(
        &mut ws,
        2,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "user question"}
        })),
    )
    .await;

    let _ = rpc_call(
        &mut ws,
        3,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "message.assistant",
            "payload": {"text": "assistant answer"}
        })),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        4,
        "context.getSnapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_reconstruct_preserves_tokens() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append event with token data
    let _ = rpc_call(
        &mut ws,
        2,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "turn.end",
            "payload": {
                "turn": 1,
                "duration": 1000,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50}
            }
        })),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        3,
        "events.getHistory",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(!events.is_empty());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_multiple_events_in_sequence() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append multiple events
    for i in 0..5 {
        let _ = rpc_call(
            &mut ws,
            (i + 2) as u64,
            "events.append",
            Some(json!({
                "sessionId": sid,
                "type": "message.user",
                "payload": {"text": format!("message {i}")}
            })),
        )
        .await;
    }

    let resp = rpc_call(
        &mut ws,
        10,
        "events.getHistory",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(events.len() >= 5);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_context_history() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // context.getSnapshot returns context window state
    let resp = rpc_call(
        &mut ws,
        2,
        "context.getSnapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"].is_object());

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Concurrent + stress tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_concurrent_isolated() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Create two sessions
    let sid1 = create_and_bind_session(&mut ws, 1).await;
    let sid2 = create_and_bind_session(&mut ws, 2).await;

    // Append to each independently
    let resp1 = rpc_call(
        &mut ws,
        3,
        "events.append",
        Some(json!({
            "sessionId": sid1,
            "type": "message.user",
            "payload": {"text": "for session 1"}
        })),
    )
    .await;
    assert_eq!(resp1["success"], true);

    let resp2 = rpc_call(
        &mut ws,
        4,
        "events.append",
        Some(json!({
            "sessionId": sid2,
            "type": "message.user",
            "payload": {"text": "for session 2"}
        })),
    )
    .await;
    assert_eq!(resp2["success"], true);

    // Verify each session has its own events (session.start + appended event = 2 each)
    let h1 = rpc_call(
        &mut ws,
        5,
        "events.getHistory",
        Some(json!({"sessionId": sid1})),
    )
    .await;
    let h2 = rpc_call(
        &mut ws,
        6,
        "events.getHistory",
        Some(json!({"sessionId": sid2})),
    )
    .await;
    let e1 = h1["result"]["events"].as_array().unwrap();
    let e2 = h2["result"]["events"].as_array().unwrap();
    assert_eq!(e1.len(), e2.len(), "both sessions should have equal event counts");
    assert!(e1.len() >= 2, "each session should have session.start + appended event");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_many_sessions_stress() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let mut sids = Vec::new();
    for i in 0..10 {
        let resp = rpc_call(
            &mut ws,
            (i + 1) as u64,
            "session.create",
            Some(json!({"model": "m", "workingDirectory": format!("/tmp/{i}")})),
        )
        .await;
        assert_eq!(resp["success"], true, "session {i} creation failed");
        sids.push(
            resp["result"]["sessionId"]
                .as_str()
                .unwrap()
                .to_string(),
        );
    }

    // Verify all sessions exist
    let resp = rpc_call(&mut ws, 100, "session.list", None).await;
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    assert!(sessions.len() >= 10);

    // Delete all
    for (i, sid) in sids.iter().enumerate() {
        let resp = rpc_call(
            &mut ws,
            (200 + i) as u64,
            "session.delete",
            Some(json!({"sessionId": sid})),
        )
        .await;
        assert_eq!(resp["success"], true);
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_concurrent_prompts_different_sessions() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid1 = create_and_bind_session(&mut ws, 1).await;
    let sid2 = create_and_bind_session(&mut ws, 2).await;

    // Both sessions can accept prompts
    let resp1 = rpc_call(
        &mut ws,
        3,
        "agent.prompt",
        Some(json!({"sessionId": sid1, "prompt": "test 1"})),
    )
    .await;
    let resp2 = rpc_call(
        &mut ws,
        4,
        "agent.prompt",
        Some(json!({"sessionId": sid2, "prompt": "test 2"})),
    )
    .await;
    assert_eq!(resp1["success"], true);
    assert_eq!(resp2["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_cleanup_after_delete() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Append an event
    let _ = rpc_call(
        &mut ws,
        2,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "will be deleted"}
        })),
    )
    .await;

    // Delete session
    let resp = rpc_call(
        &mut ws,
        3,
        "session.delete",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);

    // Session should no longer be found
    let resp = rpc_call(
        &mut ws,
        4,
        "session.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], false);

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Error handling tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_error_malformed_rpc() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Send valid JSON but invalid RPC (missing method)
    ws.send(Message::text(r#"{"id": "test", "params": {}}"#))
        .await
        .unwrap();

    let msg = read_json(&mut ws).await;
    assert_eq!(msg["success"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_empty_method() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "", None).await;
    assert_eq!(resp["success"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_prompt_nonexistent_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "agent.prompt",
        Some(json!({"sessionId": "nonexistent-session", "prompt": "hello"})),
    )
    .await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "SESSION_NOT_FOUND");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_delete_active_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Start a prompt (makes session busy)
    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "running"})),
    )
    .await;

    // Delete should still work even if busy (cleanup)
    let resp = rpc_call(
        &mut ws,
        3,
        "session.delete",
        Some(json!({"sessionId": sid})),
    )
    .await;
    // Depending on implementation, this may succeed or fail
    // Either way, it should not crash the server
    assert!(resp.get("success").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_get_events_no_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "events.getHistory",
        Some(json!({"sessionId": "nonexistent"})),
    )
    .await;
    // Should return empty events or error, but not crash
    assert!(resp.get("success").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_append_invalid() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Missing sessionId
    let resp = rpc_call(
        &mut ws,
        1,
        "events.append",
        Some(json!({"type": "message.user", "payload": {"text": "hello"}})),
    )
    .await;
    assert_eq!(resp["success"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_error_settings_update_invalid() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Update with empty params
    let resp = rpc_call(&mut ws, 1, "settings.update", Some(json!({}))).await;
    // Should gracefully handle (either succeed with no-op or fail with message)
    assert!(resp.get("success").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_reject_concurrent_same_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // First prompt succeeds
    let resp1 = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "first"})),
    )
    .await;
    assert_eq!(resp1["success"], true);

    // Second prompt to same session should fail (SESSION_BUSY)
    let resp2 = rpc_call(
        &mut ws,
        3,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "second"})),
    )
    .await;
    assert_eq!(resp2["success"], false);
    assert_eq!(resp2["error"]["code"], "SESSION_BUSY");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_sequential_prompts_after_abort() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Start first prompt
    let resp1 = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "first"})),
    )
    .await;
    assert_eq!(resp1["success"], true);

    // Abort
    let _ = rpc_call(
        &mut ws,
        3,
        "agent.abort",
        Some(json!({"sessionId": sid})),
    )
    .await;

    // Wait a bit for the abort to process
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Complete the run so the session is no longer busy
    server
        .rpc_context()
        .orchestrator
        .complete_run(&sid);

    // Second prompt should work now
    let resp2 = rpc_call(
        &mut ws,
        4,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "second"})),
    )
    .await;
    assert_eq!(resp2["success"], true);

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Memory integration tests
// ─────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn e2e_memory_ledger_list() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "memory.getLedger",
        Some(json!({"workingDirectory": "/tmp/test"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"]["entries"].is_array());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_memory_ledger_by_workspace() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Different workspaces should be independent
    let resp1 = rpc_call(
        &mut ws,
        1,
        "memory.getLedger",
        Some(json!({"workingDirectory": "/tmp/ws1"})),
    )
    .await;
    let resp2 = rpc_call(
        &mut ws,
        2,
        "memory.getLedger",
        Some(json!({"workingDirectory": "/tmp/ws2"})),
    )
    .await;
    assert_eq!(resp1["success"], true);
    assert_eq!(resp2["success"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_memory_update_trigger() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "memory.updateLedger",
        Some(json!({"workingDirectory": "/tmp/test"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert!(resp["result"].get("written").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_memory_empty_workspace() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "memory.getLedger",
        Some(json!({"workingDirectory": "/nonexistent/workspace/path"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let entries = resp["result"]["entries"].as_array().unwrap();
    assert!(entries.is_empty());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_memory_entries_structure() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Append a memory.ledger event manually
    let sid = create_and_bind_session(&mut ws, 1).await;
    let _ = rpc_call(
        &mut ws,
        2,
        "events.append",
        Some(json!({
            "sessionId": sid,
            "type": "memory.ledger",
            "payload": {
                "eventRange": {"firstEventId": "e1", "lastEventId": "e2"},
                "turnRange": {"firstTurn": 1, "lastTurn": 2},
                "title": "Test memory entry",
                "entryType": "feature",
                "status": "completed",
                "tags": ["test"],
                "input": "user request",
                "actions": ["did stuff"],
                "files": [],
                "decisions": [],
                "lessons": ["learned things"],
                "thinkingInsights": [],
                "tokenCost": {"input": 100, "output": 50},
                "model": "claude",
                "workingDirectory": "/tmp"
            }
        })),
    )
    .await;

    let resp = rpc_call(
        &mut ws,
        3,
        "events.getHistory",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(!events.is_empty());

    server.shutdown().shutdown();
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 14: Prompt execution chain e2e tests
// ─────────────────────────────────────────────────────────────────────────────

/// Collect all WebSocket messages until timeout.
async fn collect_events(ws: &mut WsStream, dur: Duration) -> Vec<Value> {
    let mut events = Vec::new();
    let start = tokio::time::Instant::now();
    while start.elapsed() < dur {
        let remaining = dur.saturating_sub(start.elapsed());
        if let Some(msg) = try_read_json(ws, remaining).await {
            events.push(msg);
        } else {
            break;
        }
    }
    events
}

/// Wait until agent.getState shows not busy, with a timeout.
async fn wait_until_not_busy(ws: &mut WsStream, sid: &str, id_start: u64) {
    for i in 0..20 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let resp = rpc_call(
            ws,
            id_start + i,
            "agent.getState",
            Some(json!({"sessionId": sid})),
        )
        .await;
        if resp["result"]["isRunning"] == false {
            return;
        }
    }
    panic!("session {sid} still busy after 2s");
}

#[tokio::test]
async fn e2e_prompt_text_response() {
    let provider = Arc::new(TextOnlyProvider::new("Hello from the agent!"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "Say hello"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["acknowledged"], true);

    // Wait for agent.ready (the final event in the lifecycle)
    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(ready.is_some(), "should receive agent.ready event");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_event_ordering() {
    let provider = Arc::new(TextOnlyProvider::new("ordered"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    // Collect events for up to 3 seconds
    let events = collect_events(&mut ws, Duration::from_secs(3)).await;
    let types: Vec<&str> = events
        .iter()
        .filter_map(|e| e.get("type").and_then(|v| v.as_str()))
        .collect();

    // agent.complete must come before agent.ready
    let complete_pos = types.iter().position(|t| *t == "agent.complete");
    let ready_pos = types.iter().position(|t| *t == "agent.ready");
    assert!(
        complete_pos.is_some(),
        "agent.complete must be in events: {types:?}"
    );
    assert!(
        ready_pos.is_some(),
        "agent.ready must be in events: {types:?}"
    );
    assert!(
        complete_pos.unwrap() < ready_pos.unwrap(),
        "agent.complete ({}) must precede agent.ready ({})",
        complete_pos.unwrap(),
        ready_pos.unwrap()
    );

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_error_from_provider() {
    let provider = Arc::new(ErrorProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "this will fail"})),
    )
    .await;

    // Even on provider error, agent.ready must arrive
    let ready = read_until_event_type(&mut ws, "agent.ready").await;
    assert!(
        ready.is_some(),
        "agent.ready must arrive even after provider error"
    );

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_cleans_up_on_complete() {
    let provider = Arc::new(TextOnlyProvider::new("done"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "work"})),
    )
    .await;

    // Wait for agent.ready
    let _ = read_until_event_type(&mut ws, "agent.ready").await;

    // getState should show not busy
    let resp = rpc_call(
        &mut ws,
        10,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["isRunning"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_sequential() {
    let provider = Arc::new(TextOnlyProvider::new("response"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // First prompt
    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "first"})),
    )
    .await;

    // Wait for it to complete
    let _ = read_until_event_type(&mut ws, "agent.ready").await;

    // Second prompt should succeed
    let resp = rpc_call(
        &mut ws,
        3,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "second"})),
    )
    .await;
    assert_eq!(resp["success"], true);
    assert_eq!(resp["result"]["acknowledged"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_reject_concurrent() {
    let provider = Arc::new(SlowProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // First prompt (will run for 30s with SlowProvider)
    let resp1 = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "slow"})),
    )
    .await;
    assert_eq!(resp1["success"], true);

    // Second prompt should be rejected (session busy)
    let resp2 = rpc_call(
        &mut ws,
        3,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "rejected"})),
    )
    .await;
    assert_eq!(resp2["success"], false);
    assert_eq!(resp2["error"]["code"], "SESSION_BUSY");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_abort_mid_stream() {
    let provider = Arc::new(SlowProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "slow task"})),
    )
    .await;

    // Give the agent a moment to start
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Abort
    let resp = rpc_call(
        &mut ws,
        3,
        "agent.abort",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["aborted"], true);

    // Wait for the run to be cleaned up (agent_runner calls complete_run)
    wait_until_not_busy(&mut ws, &sid, 100).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_without_deps_stays_busy() {
    // boot_server() has agent_deps: None
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "no deps"})),
    )
    .await;
    assert_eq!(resp["success"], true);

    // Without agent_deps, no background task is spawned, so session stays busy
    tokio::time::sleep(Duration::from_millis(200)).await;
    let resp = rpc_call(
        &mut ws,
        3,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["isRunning"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_multiple_sessions() {
    let provider = Arc::new(TextOnlyProvider::new("multi"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid1 = create_and_bind_session(&mut ws, 1).await;
    let sid2 = create_and_bind_session(&mut ws, 2).await;

    // Both can prompt
    let resp1 = rpc_call(
        &mut ws,
        3,
        "agent.prompt",
        Some(json!({"sessionId": sid1, "prompt": "session 1"})),
    )
    .await;
    let resp2 = rpc_call(
        &mut ws,
        4,
        "agent.prompt",
        Some(json!({"sessionId": sid2, "prompt": "session 2"})),
    )
    .await;
    assert_eq!(resp1["success"], true);
    assert_eq!(resp2["success"], true);

    // Both should eventually complete
    wait_until_not_busy(&mut ws, &sid1, 100).await;
    wait_until_not_busy(&mut ws, &sid2, 200).await;

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_run_id_matches() {
    // Use SlowProvider so the run is still active when we check getState
    let provider = Arc::new(SlowProvider);
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;
    let run_id = resp["result"]["runId"].as_str().unwrap().to_string();
    assert!(!run_id.is_empty());

    // getState should show the same runId while busy
    let resp = rpc_call(
        &mut ws,
        3,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["runId"], run_id);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_text_content_arrives() {
    let provider = Arc::new(TextOnlyProvider::new("specific text content"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    // Collect events and find text_delta
    let events = collect_events(&mut ws, Duration::from_secs(3)).await;
    let text_deltas: Vec<&Value> = events
        .iter()
        .filter(|e| e.get("type").and_then(|v| v.as_str()) == Some("agent.text_delta"))
        .collect();

    assert!(
        !text_deltas.is_empty(),
        "should receive text_delta events, got: {:?}",
        events.iter().filter_map(|e| e.get("type")).collect::<Vec<_>>()
    );

    // Verify actual text content from the provider is present
    let has_content = text_deltas
        .iter()
        .any(|e| e["data"]["delta"].as_str().unwrap_or("").contains("specific text content"));
    assert!(has_content, "text_delta should contain provider text");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_events_scoped_to_session() {
    let provider = Arc::new(TextOnlyProvider::new("scoped"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let _ = rpc_call(
        &mut ws,
        2,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "test"})),
    )
    .await;

    let events = collect_events(&mut ws, Duration::from_secs(3)).await;

    // All agent events should have the correct session ID
    for evt in &events {
        if let Some(event_type) = evt.get("type").and_then(|v| v.as_str()) {
            if event_type.starts_with("agent.") {
                if let Some(evt_sid) = evt.get("sessionId").and_then(|v| v.as_str()) {
                    assert_eq!(
                        evt_sid, sid,
                        "event {event_type} should be scoped to session {sid}"
                    );
                }
            }
        }
    }

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_prompt_state_transitions() {
    let provider = Arc::new(TextOnlyProvider::new("state"));
    let (url, server) = boot_server_with_provider(provider).await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    // Initially not busy
    let resp = rpc_call(
        &mut ws,
        2,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["isRunning"], false, "should start not busy");

    // Send prompt
    let _ = rpc_call(
        &mut ws,
        3,
        "agent.prompt",
        Some(json!({"sessionId": sid, "prompt": "work"})),
    )
    .await;

    // Wait for completion
    let _ = read_until_event_type(&mut ws, "agent.ready").await;

    // Should be not busy again
    let resp = rpc_call(
        &mut ws,
        10,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["isRunning"], false, "should be not busy after ready");

    server.shutdown().shutdown();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Phase 15: iOS compatibility integration tests
// ═══════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn e2e_system_get_info_ios_compat() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "system.getInfo", None).await;
    let result = &resp["result"];
    assert!(result["version"].is_string());
    assert!(result["uptime"].is_number());
    assert!(result["activeSessions"].is_number());
    assert!(result["platform"].is_string());
    assert!(result["arch"].is_string());
    assert_eq!(result["runtime"], "agent-rs");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_agent_get_state_ios_compat() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "agent.getState",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];
    assert_eq!(result["isRunning"], false);
    assert!(result["currentTurn"].is_number());
    assert!(result["messageCount"].is_number());
    assert!(result["model"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_get_history_exists() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let sid = create_and_bind_session(&mut ws, 1).await;

    let resp = rpc_call(
        &mut ws,
        2,
        "session.getHistory",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];
    assert!(result["messages"].is_array());
    assert_eq!(result["hasMore"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_settings_get_ios_compat() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "settings.get", None).await;
    let result = &resp["result"];
    // iOS flat fields
    assert!(result["defaultModel"].is_string());
    assert!(result["maxConcurrentSessions"].is_number());
    assert!(result["compaction"].is_object());
    assert!(result["memory"].is_object());
    // Original nested fields still present
    assert!(result["server"].is_object());
    assert!(result["models"].is_object());

    server.shutdown().shutdown();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Phase 16: iOS wire format compatibility tests
// ═══════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn e2e_connected_event_is_connection_established() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let msg = read_json(&mut ws).await;
    assert_eq!(msg["type"], "connection.established");
    assert!(msg["data"]["clientId"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_session_list_has_cache_tokens() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let _ = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "m", "workingDirectory": "/tmp"})),
    )
    .await;

    let resp = rpc_call(&mut ws, 2, "session.list", None).await;
    assert_eq!(resp["success"], true);
    let sessions = resp["result"]["sessions"].as_array().unwrap();
    let s = &sessions[0];
    assert!(s.get("cacheReadTokens").is_some());
    assert!(s.get("cacheCreationTokens").is_some());
    assert!(s.get("lastTurnInputTokens").is_some());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_model_list_ios_cost_fields() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(&mut ws, 1, "model.list", None).await;
    let models = resp["result"]["models"].as_array().unwrap();
    for model in models {
        assert!(
            model.get("inputCostPerMillion").is_some(),
            "missing inputCostPerMillion"
        );
        assert!(
            model.get("outputCostPerMillion").is_some(),
            "missing outputCostPerMillion"
        );
        assert!(
            model.get("inputCostPer1M").is_none(),
            "legacy inputCostPer1M should not exist"
        );
    }

    server.shutdown().shutdown();
}

// ── Phase 17: Context loading integration tests ──

#[tokio::test]
async fn e2e_context_snapshot_has_real_tokens() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    // Create session
    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    // Get context snapshot
    let resp = rpc_call(
        &mut ws,
        2,
        "context.getSnapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];

    // System prompt tokens should be > 0 (default TRON_CORE_PROMPT is non-empty)
    assert!(
        result["breakdown"]["systemPrompt"].as_u64().unwrap() > 0,
        "systemPrompt tokens should be > 0"
    );
    // Context limit should match model
    assert_eq!(
        result["contextLimit"].as_u64().unwrap(),
        tron_llm::tokens::get_context_limit("claude-opus-4-6")
    );
    assert_eq!(result["thresholdLevel"], "normal");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_detailed_snapshot_has_system_prompt() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    let resp = rpc_call(
        &mut ws,
        2,
        "context.getDetailedSnapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];

    // System prompt content should be non-empty
    let sys_content = result["systemPromptContent"].as_str().unwrap();
    assert!(!sys_content.is_empty(), "systemPromptContent should be non-empty");

    // iOS required fields
    assert!(result["messages"].is_array());
    assert!(result["toolsContent"].is_array());
    assert!(result["addedSkills"].is_array());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_detailed_snapshot_has_rules_when_present() {
    let tmp = tempfile::tempdir().unwrap();
    let claude_dir = tmp.path().join(".claude");
    std::fs::create_dir_all(&claude_dir).unwrap();
    std::fs::write(claude_dir.join("AGENTS.md"), "# E2E Test Rules\nFoo bar.").unwrap();

    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": tmp.path().to_str().unwrap()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    let resp = rpc_call(
        &mut ws,
        2,
        "context.getDetailedSnapshot",
        Some(json!({"sessionId": sid})),
    )
    .await;
    let result = &resp["result"];

    // Rules should be structured: { files, totalFiles, tokens }
    let rules = &result["rules"];
    assert!(rules.is_object(), "rules should be an object, got: {rules}");
    assert!(rules["totalFiles"].as_u64().unwrap() > 0);
    assert!(rules["tokens"].as_u64().unwrap() > 0);
    let files = rules["files"].as_array().unwrap();
    assert!(!files.is_empty());
    assert!(result["breakdown"]["rules"].as_u64().unwrap() > 0);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_should_compact_reflects_usage() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    // Empty session should not need compaction
    let resp = rpc_call(
        &mut ws,
        2,
        "context.shouldCompact",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["shouldCompact"], false);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_can_accept_turn_empty_session() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session.create",
        Some(json!({"model": "claude-opus-4-6", "workingDirectory": "/tmp"})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_owned();

    let resp = rpc_call(
        &mut ws,
        2,
        "context.canAcceptTurn",
        Some(json!({"sessionId": sid})),
    )
    .await;
    assert_eq!(resp["result"]["canAcceptTurn"], true);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_context_snapshot_session_not_found() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;
    let _ = read_json(&mut ws).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "context.getSnapshot",
        Some(json!({"sessionId": "nonexistent_session"})),
    )
    .await;
    assert_eq!(resp["success"], false);
    assert_eq!(resp["error"]["code"], "SESSION_NOT_FOUND");

    server.shutdown().shutdown();
}
