use std::sync::Arc;

use axum::extract::ws::{WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use tokio::sync::{broadcast, mpsc};
use tower_http::cors::CorsLayer;
use tron_core::events::AgentEvent;
use tron_core::ids::WorkspaceId;
use tron_store::Database;

use crate::client::{self, ClientId, ClientRegistry};
use crate::event_bridge;
use crate::handlers::HandlerState;
use crate::rpc::{RpcRequest, RpcResponse};

/// Server configuration.
pub struct ServerConfig {
    pub port: u16,
    pub max_send_queue: usize,
    pub request_timeout_secs: u64,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            port: 9091,
            max_send_queue: 256,
            request_timeout_secs: 300,
        }
    }
}

/// Shared application state passed to Axum handlers.
#[derive(Clone)]
pub struct AppState {
    pub handler_state: Arc<HandlerState>,
    pub client_registry: Arc<ClientRegistry>,
    pub message_tx: mpsc::Sender<(ClientId, String)>,
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
    let client_registry = Arc::new(ClientRegistry::new(config.max_send_queue));

    // Start event bridge
    let bridge_rx = event_tx.subscribe();
    let bridge_handle = event_bridge::create_bridge(Arc::clone(&client_registry), bridge_rx);

    // Start dead-client cleanup task (every 60s)
    let _cleanup = client::start_cleanup_task(
        Arc::clone(&client_registry),
        std::time::Duration::from_secs(60),
    );

    // Message processing channel
    let (msg_tx, msg_rx) = mpsc::channel::<(ClientId, String)>(1024);

    let handler_state = Arc::new(HandlerState::new(db, default_workspace_id));

    let app_state = AppState {
        handler_state: Arc::clone(&handler_state),
        client_registry: Arc::clone(&client_registry),
        message_tx: msg_tx,
    };

    // Start RPC message processor
    let rpc_state = Arc::clone(&handler_state);
    let rpc_registry = Arc::clone(&client_registry);
    let rpc_handle = tokio::spawn(process_rpc_messages(msg_rx, rpc_state, rpc_registry));

    let router = build_router(app_state);
    let addr = format!("0.0.0.0:{}", config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    let local_addr = listener.local_addr()?;

    tracing::info!(port = local_addr.port(), "Tron server started");

    let server_handle = tokio::spawn(async move {
        axum::serve(listener, router).await.ok();
    });

    Ok(ServerHandle {
        port: local_addr.port(),
        _server: server_handle,
        _bridge: bridge_handle,
        _rpc: rpc_handle,
        _cleanup,
    })
}

/// Handle returned by `start()` — keeps background tasks alive.
pub struct ServerHandle {
    pub port: u16,
    _server: tokio::task::JoinHandle<()>,
    _bridge: tokio::task::JoinHandle<()>,
    _rpc: tokio::task::JoinHandle<()>,
    _cleanup: tokio::task::JoinHandle<()>,
}

/// WebSocket upgrade handler.
async fn ws_handler(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Handle a new WebSocket connection.
async fn handle_socket(socket: WebSocket, state: AppState) {
    let (client_id, rx) = state.client_registry.register();
    tracing::info!(client_id = %client_id, "WebSocket client connected");

    client::handle_ws_connection(
        socket,
        client_id,
        rx,
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

/// Process incoming RPC messages from WebSocket clients.
async fn process_rpc_messages(
    mut rx: mpsc::Receiver<(ClientId, String)>,
    state: Arc<HandlerState>,
    registry: Arc<ClientRegistry>,
) {
    while let Some((client_id, raw_message)) = rx.recv().await {
        let request: RpcRequest = match serde_json::from_str(&raw_message) {
            Ok(req) => req,
            Err(_) => {
                let resp = RpcResponse::parse_error();
                if let Ok(json) = serde_json::to_string(&resp) {
                    registry.send_to(&client_id, json).await;
                }
                continue;
            }
        };

        let params = request.params.unwrap_or(serde_json::json!({}));
        let response = crate::handlers::dispatch(&state, &request.method, &params, request.id).await;

        if let Ok(json) = serde_json::to_string(&response) {
            registry.send_to(&client_id, json).await;
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

        let state = AppState {
            handler_state,
            client_registry,
            message_tx: msg_tx,
        };

        let _router = build_router(state);
        // If this doesn't panic, the router was built successfully
    }
}
