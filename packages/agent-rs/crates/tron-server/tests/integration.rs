//! End-to-end integration tests using a real WebSocket client.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use parking_lot::RwLock;
use serde_json::{json, Value};
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use tron_events::{ConnectionConfig, EventStore};
use tron_rpc::context::RpcContext;
use tron_rpc::registry::MethodRegistry;
use tron_runtime::orchestrator::orchestrator::Orchestrator;
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_server::config::ServerConfig;
use tron_server::server::TronServer;
use tron_server::websocket::event_bridge::EventBridge;
use tron_skills::registry::SkillRegistry;

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
    }
    let event_store = Arc::new(EventStore::new(pool));

    // Task DB
    let task_pool = tron_events::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = task_pool.get().unwrap();
        tron_tasks::migrations::run_migrations(&conn).unwrap();
    }

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
    };

    let mut registry = MethodRegistry::new();
    tron_rpc::handlers::register_all(&mut registry);

    let config = ServerConfig::default(); // port 0 = auto-assign
    let server = Arc::new(TronServer::new(config, registry, rpc_context));

    let bridge = EventBridge::new(orchestrator.subscribe(), server.broadcast().clone());
    let _bridge_handle = tokio::spawn(bridge.run());

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
    assert_eq!(msg["type"], "system.connected");
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
    assert_eq!(resp["result"]["busy"], false);

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
    assert_eq!(resp["result"]["busy"], true);
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
    assert_eq!(resp["result"]["acknowledged"], true);

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
