//! Primitive end-to-end tests using a real `/engine` WebSocket client.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::Mutex;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use tron::app::bootstrap::config::ServerConfig;
use tron::app::bootstrap::server::TronServer;
use tron::domains::agent::{Orchestrator, SessionManager};
use tron::domains::session::event_store::{ConnectionConfig, EventStore, ensure_schema, new_file};
use tron::domains::settings::SettingsRuntime;
use tron::engine::{ActorContext, ActorId, ActorKind};
use tron::shared::server::context::ServerRuntimeContext;

const TIMEOUT: Duration = Duration::from_secs(5);

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct TestServer {
    _temp: TempDir,
    url: String,
    auth_path: PathBuf,
    server: Arc<TronServer>,
    server_handle: Option<tokio::task::JoinHandle<()>>,
}

fn unique_home(root: &Path) -> PathBuf {
    let home = root.join(".tron");
    tron::shared::foundation::home::ensure_tron_home_at(&home).unwrap();
    home
}

async fn boot_server() -> TestServer {
    boot_server_with_config(ServerConfig {
        host: "127.0.0.1".to_owned(),
        ..ServerConfig::default()
    })
    .await
}

async fn boot_server_with_config(config: ServerConfig) -> TestServer {
    let temp = tempfile::tempdir().unwrap();
    let home = unique_home(temp.path());
    let db_path = temp.path().join("tron.sqlite");
    let pool = new_file(db_path.to_str().unwrap(), &ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        ensure_schema(&conn).unwrap();
    }

    let event_store = Arc::new(EventStore::new(pool));
    let session_manager = Arc::new(SessionManager::new(Arc::clone(&event_store)));
    let orchestrator = Arc::new(Orchestrator::new(Arc::clone(&session_manager)));
    let settings_path = tron::shared::foundation::paths::settings_path_for_home(&home);
    let auth_path = tron::shared::foundation::paths::auth_path_for_home(&home);
    let runtime_context = ServerRuntimeContext {
        orchestrator: Arc::clone(&orchestrator),
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        settings_path,
        settings_runtime: Arc::new(SettingsRuntime::load(&home).unwrap()),
        responder_factory: None,
        server_start_time: Instant::now(),
        shutdown_coordinator: None,
        origin: "127.0.0.1:0".to_owned(),
        auth_path: auth_path.clone(),
        oauth_flows: Arc::new(Mutex::new(HashMap::new())),
    };
    tron::transport::runtime::setup::register_server_domains_for_context(&runtime_context)
        .expect("primitive domains register");

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(config, runtime_context, metrics_handle));
    let (addr, server_handle) = server.listen().await.unwrap();

    TestServer {
        _temp: temp,
        url: format!("ws://{addr}/engine"),
        auth_path,
        server,
        server_handle: Some(server_handle),
    }
}

async fn connect(url: &str, auth_path: &Path) -> WsStream {
    let token = tron::app::lifecycle::onboarding::load_or_create_bearer_token(auth_path).unwrap();
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {token}").parse().unwrap());
    let (ws, _) = connect_async(request).await.unwrap();
    ws
}

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

async fn invoke(ws: &mut WsStream, id: &str, function_id: &str, payload: Value) -> Value {
    invoke_with_context(ws, id, function_id, payload, None).await
}

async fn invoke_with_context(
    ws: &mut WsStream,
    id: &str,
    function_id: &str,
    payload: Value,
    context: Option<Value>,
) -> Value {
    let request = json!({
        "type": "invoke",
        "id": id,
        "functionId": function_id,
        "payload": payload,
        "idempotencyKey": format!("{id}-{function_id}", function_id = function_id.replace("::", "-")),
        "context": context,
    });
    ws.send(Message::text(request.to_string())).await.unwrap();
    loop {
        let response = read_json(ws).await;
        if response.get("id").and_then(Value::as_str) == Some(id) {
            return response;
        }
    }
}

fn unwrap_invoke_value(response: Value) -> Value {
    assert_eq!(response["ok"], true, "invoke failed: {response}");
    assert!(response.pointer("/result/child").is_none());
    response.get("result").cloned().unwrap_or(Value::Null)
}

async fn wait_for_connection_count(server: &TronServer, expected: usize) {
    timeout(TIMEOUT, async {
        while server.engine_clients().connection_count() != expected {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("engine connection count did not reach {expected}"));
}

async fn wait_for_tracked_task_count(server: &TronServer, expected: usize) {
    timeout(TIMEOUT, async {
        while server.shutdown().tracked_task_count() != expected {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("shutdown task count did not reach {expected}"));
}

fn heartbeat_test_config() -> ServerConfig {
    ServerConfig {
        host: "127.0.0.1".to_owned(),
        heartbeat_interval_ms: 50,
        heartbeat_timeout_ms: 250,
        ..ServerConfig::default()
    }
}

#[tokio::test]
async fn engine_reaps_an_unresponsive_websocket_client() {
    let runtime = boot_server_with_config(heartbeat_test_config()).await;
    let mut ws = connect(&runtime.url, &runtime.auth_path).await;
    wait_for_connection_count(&runtime.server, 1).await;

    // Do not poll the client: tungstenite cannot process the server's Ping or
    // write a Pong while its stream is idle.
    wait_for_connection_count(&runtime.server, 0).await;

    timeout(TIMEOUT, async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            }
        }
    })
    .await
    .expect("reaped websocket did not close");

    runtime.server.shutdown().shutdown();
}

#[tokio::test]
async fn engine_keeps_a_responsive_websocket_client_alive() {
    let runtime = boot_server_with_config(heartbeat_test_config()).await;
    let mut ws = connect(&runtime.url, &runtime.auth_path).await;
    wait_for_connection_count(&runtime.server, 1).await;

    ws.send(Message::text(
        json!({"type": "hello", "id": "heartbeat-hello", "protocolVersion": 1}).to_string(),
    ))
    .await
    .unwrap();

    let started = Instant::now();
    let mut hello_seen = false;
    let mut ping_count = 0;
    while started.elapsed() < Duration::from_millis(800) {
        let Ok(next) = timeout(Duration::from_millis(150), ws.next()).await else {
            continue;
        };
        let Some(message) = next else {
            panic!("responsive websocket closed unexpectedly");
        };
        match message.expect("responsive websocket read failed") {
            Message::Ping(payload) => {
                ping_count += 1;
                ws.send(Message::Pong(payload)).await.unwrap();
            }
            Message::Text(text) => {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value.get("id").and_then(Value::as_str) == Some("heartbeat-hello") {
                    assert_eq!(value.get("type").and_then(Value::as_str), Some("hello.ok"));
                    hello_seen = true;
                }
            }
            Message::Close(frame) => panic!("responsive websocket closed: {frame:?}"),
            Message::Binary(_) | Message::Pong(_) | Message::Frame(_) => {}
        }
    }

    assert!(hello_seen, "responsive client did not complete hello");
    assert!(
        ping_count >= 3,
        "responsive client saw only {ping_count} pings"
    );
    assert_eq!(runtime.server.engine_clients().connection_count(), 1);

    ws.close(None).await.unwrap();
    wait_for_connection_count(&runtime.server, 0).await;
    runtime.server.shutdown().shutdown();
}

#[tokio::test]
async fn engine_shutdown_drains_an_upgraded_subscribed_client() {
    let mut runtime = boot_server().await;
    let baseline_tasks = runtime.server.shutdown().tracked_task_count();
    let mut ws = connect(&runtime.url, &runtime.auth_path).await;
    wait_for_connection_count(&runtime.server, 1).await;
    wait_for_tracked_task_count(&runtime.server, baseline_tasks + 1).await;

    ws.send(Message::text(
        json!({
            "type": "subscribe",
            "id": "shutdown-subscribe",
            "topic": "events.session",
            "cursor": 0
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let response = read_json(&mut ws).await;
    assert_eq!(response["id"], "shutdown-subscribe");
    assert_eq!(response["ok"], true);

    let server_handle = runtime.server_handle.take().unwrap();
    runtime
        .server
        .shutdown()
        .graceful_shutdown(vec![server_handle], Some(Duration::from_secs(2)))
        .await;
    assert_eq!(runtime.server.engine_clients().connection_count(), 0);
    assert_eq!(runtime.server.shutdown().tracked_task_count(), 0);

    timeout(TIMEOUT, async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            }
        }
    })
    .await
    .expect("shutdown-owned websocket did not close");
}

#[tokio::test]
async fn engine_hello_and_ping_use_current_minimal_transport() {
    let runtime = boot_server().await;
    let mut ws = connect(&runtime.url, &runtime.auth_path).await;

    ws.send(Message::text(
        json!({"type": "hello", "id": "hello", "protocolVersion": 1}).to_string(),
    ))
    .await
    .unwrap();
    let hello = read_json(&mut ws).await;
    assert_eq!(hello["type"], "hello.ok");
    assert_eq!(hello["serverId"], "tron-engine");

    let ping = unwrap_invoke_value(
        invoke(
            &mut ws,
            "ping",
            "system::ping",
            json!({"protocolVersion": 1, "clientVersion": "primitive-test"}),
        )
        .await,
    );
    assert_eq!(ping["pong"], true);
    assert_eq!(ping["serverProtocolVersion"], 1);

    runtime.server.shutdown().shutdown();
}

#[tokio::test]
async fn worker_first_baseline_characterizes_startup_tools_events_settings_and_connectivity() {
    let runtime = boot_server().await;
    let mut ws = connect(&runtime.url, &runtime.auth_path).await;
    wait_for_connection_count(&runtime.server, 1).await;
    let working_directory = runtime._temp.path().join("workspace");
    std::fs::create_dir_all(&working_directory).unwrap();

    let created = unwrap_invoke_value(
        invoke(
            &mut ws,
            "session-create",
            "session::create",
            json!({
                "workingDirectory": working_directory.to_string_lossy(),
                "model": "openai/gpt-4o",
                "title": "primitive integration"
            }),
        )
        .await,
    );
    let session_id = created["sessionId"].as_str().unwrap().to_owned();

    let reconstructed = unwrap_invoke_value(
        invoke(
            &mut ws,
            "session-reconstruct",
            "session::reconstruct",
            json!({"sessionId": session_id, "limit": 10}),
        )
        .await,
    );
    let events = reconstructed["events"].as_array().unwrap();
    assert!(events.iter().any(|event| event["type"] == "session.start"));

    let workers = unwrap_invoke_value(
        invoke_with_context(
            &mut ws,
            "worker-list",
            "worker_kernel::list",
            json!({"includeRetired": false}),
            Some(json!({
                "sessionId": session_id,
            })),
        )
        .await,
    );
    assert!(
        workers["workers"].is_array(),
        "worker list missing: {workers}"
    );
    assert_eq!(workers["stopAll"], false);

    let settings =
        unwrap_invoke_value(invoke(&mut ws, "settings-get", "settings::get", json!({})).await);
    assert!(settings["server"]["defaultModel"].is_string());
    let upserted = unwrap_invoke_value(
        invoke_with_context(
            &mut ws,
            "worker-upsert",
            "worker_kernel::upsert",
            json!({
                "bundle": {
                    "schemaVersion": "tron.worker_bundle.v1",
                    "workerId": "baseline-echo",
                    "name": "Baseline Echo",
                    "description": "Echo typed input for the startup characterization fixture",
                    "toolName": "worker_baseline_echo",
                    "inputSchema": {"type":"object"},
                    "toolInputSchema": {
                        "type": "object",
                        "additionalProperties": false
                    },
                    "outputSchema": {"type":"object"},
                    "runner": {"kind":"command", "command":["sh", "-c", "cat"]},
                    "triggers": [{"kind":"manual", "id":"manual"}],
                    "provenance": [{"source":"test:worker-first-baseline"}]
                }
            }),
            Some(json!({"sessionId": session_id})),
        )
        .await,
    );
    assert_eq!(
        upserted.pointer("/worker/workerId"),
        Some(&json!("baseline-echo"))
    );

    ws.send(Message::text(
        json!({
            "type": "poll",
            "id": "worker-lifecycle-poll",
            "topic": "worker.lifecycle",
            "cursor": 0
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let lifecycle = loop {
        let response = read_json(&mut ws).await;
        if response.get("id").and_then(Value::as_str) == Some("worker-lifecycle-poll") {
            break response;
        }
    };
    assert_eq!(lifecycle["ok"], true, "lifecycle poll failed: {lifecycle}");
    assert!(
        lifecycle
            .pointer("/result/events")
            .and_then(Value::as_array)
            .is_some_and(|events| events.iter().any(|event| {
                event
                    .pointer("/event/data/worker/workerId")
                    .and_then(Value::as_str)
                    == Some("baseline-echo")
            })),
        "worker activation event missing: {lifecycle}"
    );

    let system = ActorContext::new(
        ActorId::new("baseline-characterization").unwrap(),
        ActorKind::System,
    );
    let functions = runtime
        .server
        .runtime_context()
        .engine_host
        .visible_functions(&system)
        .await;
    let model_tools = functions
        .iter()
        .filter_map(|function| function.model_tool.as_ref())
        .filter(|tool| tool.callable)
        .map(|tool| tool.name.as_str())
        .collect::<Vec<_>>();
    assert!(model_tools.contains(&"worker_upsert"), "{model_tools:?}");
    assert!(model_tools.contains(&"worker_list"), "{model_tools:?}");
    assert!(model_tools.contains(&"worker_stop"), "{model_tools:?}");
    assert!(
        model_tools.contains(&"worker_baseline_echo"),
        "{model_tools:?}"
    );
    runtime.server.shutdown().shutdown();
}
