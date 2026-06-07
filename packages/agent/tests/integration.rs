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

use tron::app::config::ServerConfig;
use tron::app::server::TronServer;
use tron::domains::agent::runner::{Orchestrator, ProfileRuntime, SessionManager};
use tron::domains::model::providers::ProviderHealthTracker;
use tron::domains::session::event_store::{ConnectionConfig, EventStore, new_file, run_migrations};
use tron::shared::model_capabilities::CapabilityResult;
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
    tron::shared::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

async fn boot_server() -> TestServer {
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
        .join(tron::shared::paths::dirs::PROFILES)
        .join(tron::shared::profile::USER_PROFILE)
        .join(tron::shared::paths::files::PROFILE_TOML);
    let auth_path = home
        .join(tron::shared::paths::dirs::PROFILES)
        .join(tron::shared::paths::files::AUTH_JSON);
    let settings =
        tron::domains::settings::load_settings_from_path(&settings_path).expect("settings load");
    tron::domains::settings::init_settings(settings);

    let runtime_context = ServerRuntimeContext {
        orchestrator: Arc::clone(&orchestrator),
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        settings_path,
        profile_runtime: Arc::new(ProfileRuntime::load(&home).unwrap()),
        agent_deps: None,
        server_start_time: Instant::now(),
        health_tracker: Arc::new(ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "127.0.0.1:0".to_owned(),
        auth_path: auth_path.clone(),
        oauth_flows: Arc::new(Mutex::new(HashMap::new())),
        ws_port: Arc::new(AtomicU16::new(0)),
        onboarded_marker_path: temp.path().join(".onboarded"),
        release_fetcher: None,
        updater_state_path: temp.path().join("updater-state.json"),
    };
    tron::transport::setup::register_server_domains_for_context(&runtime_context)
        .expect("primitive domains register");

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(
        ServerConfig {
            host: "127.0.0.1".to_owned(),
            ..ServerConfig::default()
        },
        runtime_context,
        metrics_handle,
    ));
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
    let token = tron::app::onboarding::load_or_create_bearer_token(auth_path).unwrap();
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
async fn session_create_reconstruct_and_execute_observe_stay_on_primitive_surface() {
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

    let observed = unwrap_invoke_value(
        invoke_with_context(
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
        .await,
    );
    let result: CapabilityResult = serde_json::from_value(observed).unwrap();
    assert_eq!(
        result.details.as_ref().unwrap()["primitiveOperation"],
        "observe"
    );
    assert!(
        serde_json::to_string(&result.content)
            .unwrap()
            .contains("primitive integration observation")
    );

    runtime.server.shutdown().shutdown();
}
