//! Primitive end-to-end tests using a real `/engine` WebSocket client.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
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
use tron::domains::agent::{Orchestrator, ProfileRuntime, SessionManager};
use tron::domains::session::event_store::{ConnectionConfig, EventStore, new_file, run_migrations};
use tron::shared::server::context::ServerRuntimeContext;

const TIMEOUT: Duration = Duration::from_secs(5);

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct TestServer {
    _temp: TempDir,
    url: String,
    auth_path: PathBuf,
    server: Arc<TronServer>,
}

fn unique_home(root: &Path) -> PathBuf {
    let home = root.join(".tron");
    tron::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
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
        run_migrations(&conn).unwrap();
    }

    let event_store = Arc::new(EventStore::new(pool));
    let session_manager = Arc::new(SessionManager::new(Arc::clone(&event_store)));
    let orchestrator = Arc::new(Orchestrator::new(Arc::clone(&session_manager)));
    let settings_path = home
        .join(tron::shared::foundation::paths::dirs::PROFILES)
        .join(tron::shared::foundation::profile::USER_PROFILE)
        .join(tron::shared::foundation::paths::files::PROFILE_TOML);
    let auth_path = home
        .join(tron::shared::foundation::paths::dirs::PROFILES)
        .join(tron::shared::foundation::paths::files::AUTH_JSON);
    let runtime_context = ServerRuntimeContext {
        orchestrator: Arc::clone(&orchestrator),
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        transcription_runtime: tron::domains::transcription::SharedTranscriptionEngine::new(),
        apns_runtime: tron::platform::apns::ApnsRuntime::disabled(),
        settings_path,
        profile_runtime: Arc::new(ProfileRuntime::load(&home).unwrap()),
        responder_factory: None,
        server_start_time: Instant::now(),
        shutdown_coordinator: None,
        origin: "127.0.0.1:0".to_owned(),
        auth_path: auth_path.clone(),
        oauth_flows: Arc::new(Mutex::new(HashMap::new())),
        ws_port: Arc::new(AtomicU16::new(0)),
        onboarded_marker_path: temp.path().join(".onboarded"),
    };
    tron::transport::runtime::setup::register_server_domains_for_context(&runtime_context)
        .expect("primitive domains register");

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(config, runtime_context, metrics_handle));
    tron::transport::runtime::EngineRuntimeServices::start(&server);
    let (addr, _handle) = server.listen().await.unwrap();

    TestServer {
        _temp: temp,
        url: format!("ws://{addr}/engine"),
        auth_path,
        server,
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
    if let Some(child) = response.pointer("/result/child") {
        assert!(
            child.get("error").is_none_or(Value::is_null),
            "child invocation failed: {child}"
        );
        child.get("value").cloned().unwrap_or(Value::Null)
    } else {
        response.get("result").cloned().unwrap_or(Value::Null)
    }
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
async fn session_create_reconstruct_and_public_execute_fails_closed() {
    let runtime = boot_server().await;
    let mut ws = connect(&runtime.url, &runtime.auth_path).await;
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

    let rejected = invoke_with_context(
        &mut ws,
        "execute-observe",
        "capability::execute",
        json!({
            "operation": "observe",
            "input": "primitive integration observation"
        }),
        Some(json!({
            "sessionId": session_id,
        })),
    )
    .await;
    assert_eq!(
        rejected["ok"], true,
        "engine invoke wrapper failed: {rejected}"
    );
    let child = rejected.pointer("/result/child").unwrap_or(&Value::Null);
    let child_error = child
        .pointer("/error/details/message")
        .and_then(Value::as_str)
        .unwrap_or_default();
    assert!(
        child["value"].is_null()
            && child["error"]["kind"] == "policy_violation"
            && (child_error.contains("wildcard authority scopes")
                || child_error.contains("trusted agent or system runtime context")),
        "public capability::execute must fail closed, got: {rejected}"
    );

    runtime.server.shutdown().shutdown();
}
