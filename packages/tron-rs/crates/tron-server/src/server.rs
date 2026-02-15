use std::sync::Arc;

use axum::extract::ws::{WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use tokio::sync::{broadcast, mpsc};
use tokio_util::sync::CancellationToken;
use tower_http::cors::CorsLayer;
use tron_core::events::AgentEvent;
use tron_core::ids::WorkspaceId;
use tron_store::Database;

use tron_telemetry::TelemetryGuard;

use crate::client::{self, ClientId, ClientRegistry, MessagePriority, RateLimiter};
use crate::event_bridge;
use crate::handlers::HandlerState;
use crate::orchestrator::AgentOrchestrator;
use crate::rpc::{RpcRequest, RpcResponse};

/// Server configuration.
pub struct ServerConfig {
    pub port: u16,
    pub max_send_queue: usize,
    pub request_timeout_secs: u64,
    /// Maximum RPC requests per second per client (burst capacity).
    pub rate_limit_burst: u32,
    /// RPC request refill rate (tokens per second).
    pub rate_limit_per_sec: f64,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            port: 9091,
            max_send_queue: 256,
            request_timeout_secs: 300,
            rate_limit_burst: 100,
            rate_limit_per_sec: 100.0,
        }
    }
}

/// Shared application state passed to Axum handlers.
#[derive(Clone)]
pub struct AppState {
    pub handler_state: Arc<HandlerState>,
    pub client_registry: Arc<ClientRegistry>,
    pub message_tx: mpsc::Sender<(ClientId, String)>,
    pub rate_limiter: Arc<RateLimiter>,
}

/// Build the Axum router with all routes.
pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/ws", get(ws_handler))
        .route("/health", get(health_handler))
        .with_state(state)
        .layer(CorsLayer::permissive())
}

/// Create and start the server. Returns a handle to shut it down.
pub async fn start(
    config: ServerConfig,
    db: Database,
    default_workspace_id: WorkspaceId,
    event_tx: broadcast::Sender<AgentEvent>,
) -> Result<ServerHandle, std::io::Error> {
    start_with_telemetry(config, db, default_workspace_id, event_tx, None, None).await
}

/// Create and start the server with optional telemetry and orchestrator.
/// Returns a handle to shut it down.
pub async fn start_with_telemetry(
    config: ServerConfig,
    db: Database,
    default_workspace_id: WorkspaceId,
    event_tx: broadcast::Sender<AgentEvent>,
    telemetry: Option<Arc<TelemetryGuard>>,
    orchestrator: Option<Arc<dyn AgentOrchestrator>>,
) -> Result<ServerHandle, std::io::Error> {
    let client_registry = Arc::new(ClientRegistry::new(config.max_send_queue));

    // Start event bridge
    let bridge_rx = event_tx.subscribe();
    let bridge_handle = event_bridge::create_bridge(Arc::clone(&client_registry), bridge_rx);

    // Start dead-client cleanup task (every 60s)
    let cleanup_handle = client::start_cleanup_task(
        Arc::clone(&client_registry),
        std::time::Duration::from_secs(60),
    );

    // Message processing channel
    let (msg_tx, msg_rx) = mpsc::channel::<(ClientId, String)>(1024);

    let mut handler_state = match telemetry {
        Some(t) => HandlerState::with_telemetry(db, default_workspace_id, t),
        None => HandlerState::new(db, default_workspace_id),
    };
    if let Some(orch) = orchestrator {
        handler_state = handler_state.with_orchestrator(orch);
    }
    let handler_state = Arc::new(handler_state);

    let rate_limiter = Arc::new(RateLimiter::new(
        config.rate_limit_burst,
        config.rate_limit_per_sec,
    ));

    let app_state = AppState {
        handler_state: Arc::clone(&handler_state),
        client_registry: Arc::clone(&client_registry),
        message_tx: msg_tx,
        rate_limiter: Arc::clone(&rate_limiter),
    };

    // Start RPC message processor
    let rpc_state = Arc::clone(&handler_state);
    let rpc_registry = Arc::clone(&client_registry);
    let rpc_limiter = Arc::clone(&rate_limiter);
    let rpc_handle = tokio::spawn(process_rpc_messages(
        msg_rx,
        rpc_state,
        rpc_registry,
        rpc_limiter,
    ));

    let router = build_router(app_state);
    let addr = format!("0.0.0.0:{}", config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    let local_addr = listener.local_addr()?;

    tracing::info!(port = local_addr.port(), "Tron server started");

    let shutdown = CancellationToken::new();
    let shutdown_for_axum = shutdown.clone();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, router)
            .with_graceful_shutdown(async move {
                shutdown_for_axum.cancelled().await;
            })
            .await
            .ok();
    });

    Ok(ServerHandle {
        port: local_addr.port(),
        shutdown,
        server: server_task,
        bridge: bridge_handle,
        rpc: rpc_handle,
        cleanup: cleanup_handle,
    })
}

/// Handle returned by `start()` — keeps background tasks alive.
///
/// Call `shutdown()` to signal the server to stop accepting new connections,
/// then `drain()` to wait for in-flight work to complete.
pub struct ServerHandle {
    pub port: u16,
    shutdown: CancellationToken,
    server: tokio::task::JoinHandle<()>,
    bridge: tokio::task::JoinHandle<()>,
    rpc: tokio::task::JoinHandle<()>,
    cleanup: tokio::task::JoinHandle<()>,
}

impl ServerHandle {
    /// Signal the server to stop accepting new connections.
    /// In-flight requests and WebSocket connections continue until they complete.
    pub fn shutdown(&self) {
        tracing::info!("Server shutdown initiated");
        self.shutdown.cancel();
    }

    /// Wait for all server tasks to complete after shutdown.
    /// Call `shutdown()` first, then `drain()`.
    pub async fn drain(self) {
        // Server exits after graceful shutdown completes
        let _ = self.server.await;
        tracing::debug!("Server task drained");

        // RPC processor exits when mpsc channel closes (server dropped the sender)
        let _ = self.rpc.await;
        tracing::debug!("RPC processor drained");

        // Abort background tasks that loop forever
        self.bridge.abort();
        self.cleanup.abort();
        let _ = self.bridge.await;
        let _ = self.cleanup.await;
        tracing::debug!("Background tasks stopped");
    }
}

/// WebSocket upgrade handler.
async fn ws_handler(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Handle a new WebSocket connection.
async fn handle_socket(socket: WebSocket, state: AppState) {
    let (client_id, queue) = state.client_registry.register();
    tracing::info!(client_id = %client_id, "WebSocket client connected");

    // Send connection.established event as the first message
    let established = serde_json::json!({
        "type": "connection.established",
        "timestamp": chrono::Utc::now().to_rfc3339(),
        "data": { "clientId": client_id.to_string() }
    });
    if let Ok(json) = serde_json::to_string(&established) {
        queue.send(MessagePriority::Critical, json);
    }

    client::handle_ws_connection(
        socket,
        client_id,
        queue,
        state.client_registry,
        state.message_tx,
    )
    .await;
}

/// Health check HTTP endpoint.
async fn health_handler(State(state): State<AppState>) -> impl IntoResponse {
    let resp = crate::handlers::dispatch(
        &state.handler_state,
        "health",
        &serde_json::json!({}),
        None,
    )
    .await;

    let status = resp
        .result
        .as_ref()
        .and_then(|r| r.get("status"))
        .and_then(|s| s.as_str())
        .unwrap_or("unknown");

    let http_status = if status == "healthy" {
        axum::http::StatusCode::OK
    } else {
        axum::http::StatusCode::SERVICE_UNAVAILABLE
    };

    (http_status, axum::Json(resp.result.unwrap_or_default()))
}

/// Custom JSON-RPC error code for rate limiting.
const RATE_LIMITED: i32 = -32000;

/// Process incoming RPC messages from WebSocket clients.
async fn process_rpc_messages(
    mut rx: mpsc::Receiver<(ClientId, String)>,
    state: Arc<HandlerState>,
    registry: Arc<ClientRegistry>,
    rate_limiter: Arc<RateLimiter>,
) {
    while let Some((client_id, raw_message)) = rx.recv().await {
        // Rate limit check
        if !rate_limiter.check(&client_id) {
            let resp = RpcResponse::error(None, RATE_LIMITED, "Rate limit exceeded");
            if let Ok(json) = serde_json::to_string(&resp) {
                registry.send_to(&client_id, json);
            }
            tracing::warn!(client_id = %client_id, "Rate limit exceeded");
            continue;
        }

        let request: RpcRequest = match serde_json::from_str(&raw_message) {
            Ok(req) => req,
            Err(_) => {
                let resp = RpcResponse::parse_error();
                if let Ok(json) = serde_json::to_string(&resp) {
                    registry.send_to(&client_id, json);
                }
                continue;
            }
        };

        let params = request.params.unwrap_or(serde_json::json!({}));
        let response =
            crate::handlers::dispatch(&state, &request.method, &params, request.id).await;

        // Auto-subscribe client to session for event routing.
        // Check params first (most methods), then response (session.create, session.fork).
        if response.success {
            let session_id_str = params
                .get("session_id")
                .or_else(|| params.get("sessionId"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .or_else(|| {
                    response.result.as_ref().and_then(|r| {
                        r.get("sessionId")
                            .or_else(|| r.get("newSessionId"))
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string())
                    })
                });

            if let Some(sid) = session_id_str {
                let session_id = tron_core::ids::SessionId::from_raw(sid);
                registry.set_session(&client_id, session_id).await;
            }
        }

        if let Ok(json) = serde_json::to_string(&response) {
            registry.send_to(&client_id, json);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_store::workspaces::WorkspaceRepo;

    fn setup() -> (Database, WorkspaceId) {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        (db, ws.id)
    }

    #[tokio::test]
    async fn server_starts_and_serves_health() {
        let (db, ws_id) = setup();
        let (event_tx, _) = broadcast::channel(100);

        let config = ServerConfig {
            port: 0, // Random port
            ..Default::default()
        };

        let handle = start(config, db, ws_id, event_tx).await.unwrap();
        assert!(handle.port > 0);

        // Test health endpoint
        let url = format!("http://127.0.0.1:{}/health", handle.port);
        let resp = reqwest::get(&url).await.unwrap();
        assert_eq!(resp.status(), 200);

        let body: serde_json::Value = resp.json().await.unwrap();
        assert_eq!(body["status"], "healthy");
    }

    #[test]
    fn build_router_creates_routes() {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        let handler_state = Arc::new(HandlerState::new(db, ws.id));
        let client_registry = Arc::new(ClientRegistry::new(32));
        let (msg_tx, _) = mpsc::channel(32);
        let rate_limiter = Arc::new(RateLimiter::new(100, 100.0));

        let state = AppState {
            handler_state,
            client_registry,
            message_tx: msg_tx,
            rate_limiter,
        };

        let _router = build_router(state);
        // If this doesn't panic, the router was built successfully
    }

    #[test]
    fn connection_established_message_format() {
        // Verify the connection.established message has the expected structure
        let registry = ClientRegistry::new(32);
        let (client_id, queue) = registry.register();

        let established = serde_json::json!({
            "type": "connection.established",
            "timestamp": chrono::Utc::now().to_rfc3339(),
            "data": { "clientId": client_id.to_string() }
        });
        let json = serde_json::to_string(&established).unwrap();
        queue.send(MessagePriority::Critical, json);

        assert_eq!(queue.len(), 1);

        // Parse it back to verify structure
        let parsed: serde_json::Value =
            serde_json::from_str(&tokio::runtime::Runtime::new().unwrap().block_on(async {
                queue.recv().await.unwrap()
            }))
            .unwrap();

        assert_eq!(parsed["type"], "connection.established");
        assert!(parsed["timestamp"].is_string());
        assert_eq!(parsed["data"]["clientId"], client_id.to_string());
    }

    #[tokio::test]
    async fn rate_limited_response_sent_to_client() {
        let registry = Arc::new(ClientRegistry::new(32));
        let (client_id, queue) = registry.register();
        let rate_limiter = Arc::new(RateLimiter::new(1, 0.0)); // 1 token, no refill

        let (tx, rx) = mpsc::channel(32);
        let state = {
            let db = Database::in_memory().unwrap();
            let ws_repo = WorkspaceRepo::new(db.clone());
            let ws = ws_repo.get_or_create("/test", "test").unwrap();
            Arc::new(HandlerState::new(db, ws.id))
        };

        // Spawn the processor
        let reg_clone = Arc::clone(&registry);
        let lim_clone = Arc::clone(&rate_limiter);
        let handle = tokio::spawn(process_rpc_messages(rx, state, reg_clone, lim_clone));

        // Send 2 messages — first should pass, second should be rate limited
        let msg = r#"{"method":"health","id":1}"#;
        tx.send((client_id.clone(), msg.into())).await.unwrap();
        tx.send((client_id.clone(), msg.into())).await.unwrap();

        // Give processor time to handle both
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        drop(tx); // Close channel so processor exits
        let _ = handle.await;

        // Should have received 2 responses: one health result, one rate limit error
        let mut messages = Vec::new();
        while !queue.is_empty() {
            messages.push(queue.recv().await.unwrap());
        }
        assert_eq!(messages.len(), 2);

        // One should be a rate limit error
        let has_rate_limit = messages
            .iter()
            .any(|m| m.contains("Rate limit exceeded") && m.contains("RATE_LIMITED"));
        assert!(has_rate_limit, "Expected rate limit error in {messages:?}");
    }

    #[tokio::test]
    async fn server_shutdown_stops_health_endpoint() {
        let (db, ws_id) = setup();
        let (event_tx, _rx) = broadcast::channel(100);

        let config = ServerConfig {
            port: 0,
            ..Default::default()
        };

        let handle = start(config, db, ws_id, event_tx).await.unwrap();
        let port = handle.port;

        // Verify health works before shutdown
        let url = format!("http://127.0.0.1:{}/health", port);
        let resp = reqwest::get(&url).await.unwrap();
        assert_eq!(resp.status(), 200);

        // Trigger shutdown and drain
        handle.shutdown();
        handle.drain().await;

        // After drain, connection should be refused
        let result = reqwest::get(&url).await;
        assert!(result.is_err(), "Expected connection error after shutdown");
    }

    #[tokio::test]
    async fn server_drain_completes_within_timeout() {
        let (db, ws_id) = setup();
        let (event_tx, _rx) = broadcast::channel(100);

        let config = ServerConfig {
            port: 0,
            ..Default::default()
        };

        let handle = start(config, db, ws_id, event_tx).await.unwrap();
        handle.shutdown();

        // drain should complete quickly (no in-flight requests)
        let result = tokio::time::timeout(std::time::Duration::from_secs(5), handle.drain()).await;
        assert!(result.is_ok(), "drain should complete within 5s");
    }

    #[tokio::test]
    async fn server_shutdown_idempotent() {
        let (db, ws_id) = setup();
        let (event_tx, _rx) = broadcast::channel(100);

        let config = ServerConfig {
            port: 0,
            ..Default::default()
        };

        let handle = start(config, db, ws_id, event_tx).await.unwrap();

        // Calling shutdown multiple times should not panic
        handle.shutdown();
        handle.shutdown();
        handle.drain().await;
    }
}
