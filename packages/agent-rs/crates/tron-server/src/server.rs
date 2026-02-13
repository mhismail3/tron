//! `TronServer` — Axum HTTP + WebSocket server.

use std::sync::Arc;
use std::time::Instant;

use axum::extract::State;
use axum::response::Json;
use axum::routing::get;
use axum::Router;
use tron_rpc::registry::MethodRegistry;

use crate::config::ServerConfig;
use crate::health::{self, HealthResponse};
use crate::shutdown::ShutdownCoordinator;
use crate::websocket::broadcast::BroadcastManager;

/// Shared state accessible from Axum handlers.
#[derive(Clone)]
pub struct AppState {
    /// Broadcast manager for event fan-out.
    pub broadcast: Arc<BroadcastManager>,
    /// Shutdown coordinator.
    pub shutdown: Arc<ShutdownCoordinator>,
    /// When the server started.
    pub start_time: Instant,
    /// RPC method registry.
    pub registry: Arc<MethodRegistry>,
}

/// The main Tron server.
pub struct TronServer {
    config: ServerConfig,
    registry: Arc<MethodRegistry>,
    broadcast: Arc<BroadcastManager>,
    shutdown: Arc<ShutdownCoordinator>,
    start_time: Instant,
}

impl TronServer {
    /// Create a new server.
    pub fn new(config: ServerConfig, registry: MethodRegistry) -> Self {
        Self {
            config,
            registry: Arc::new(registry),
            broadcast: Arc::new(BroadcastManager::new()),
            shutdown: Arc::new(ShutdownCoordinator::new()),
            start_time: Instant::now(),
        }
    }

    /// Build the Axum router with all routes.
    pub fn router(&self) -> Router {
        let state = AppState {
            broadcast: self.broadcast.clone(),
            shutdown: self.shutdown.clone(),
            start_time: self.start_time,
            registry: self.registry.clone(),
        };

        Router::new()
            .route("/health", get(health_handler))
            .route("/ws", get(ws_placeholder))
            .with_state(state)
    }

    /// Get the broadcast manager.
    pub fn broadcast(&self) -> &Arc<BroadcastManager> {
        &self.broadcast
    }

    /// Get the shutdown coordinator.
    pub fn shutdown(&self) -> &Arc<ShutdownCoordinator> {
        &self.shutdown
    }

    /// Get the server configuration.
    pub fn config(&self) -> &ServerConfig {
        &self.config
    }

    /// Get the method registry.
    pub fn registry(&self) -> &Arc<MethodRegistry> {
        &self.registry
    }
}

/// GET /health
async fn health_handler(State(state): State<AppState>) -> Json<HealthResponse> {
    let connections = state.broadcast.connection_count().await;
    let resp = health::health_check(state.start_time, connections, 0);
    Json(resp)
}

/// GET /ws — placeholder for WebSocket upgrade.
///
/// Full WebSocket upgrade handling requires integration tests with a real
/// HTTP client and is out of scope for this initial implementation.
async fn ws_placeholder() -> &'static str {
    "WebSocket endpoint"
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    fn make_server() -> TronServer {
        TronServer::new(ServerConfig::default(), MethodRegistry::new())
    }

    #[tokio::test]
    async fn server_with_default_config() {
        let server = make_server();
        assert_eq!(server.config().host, "127.0.0.1");
        assert_eq!(server.config().port, 0);
    }

    #[tokio::test]
    async fn broadcast_manager_accessible() {
        let server = make_server();
        let bm = server.broadcast();
        assert_eq!(bm.connection_count().await, 0);
    }

    #[test]
    fn shutdown_coordinator_accessible() {
        let server = make_server();
        assert!(!server.shutdown().is_shutting_down());
    }

    #[test]
    fn registry_accessible() {
        let server = make_server();
        assert!(server.registry().methods().is_empty());
    }

    #[tokio::test]
    async fn health_endpoint_returns_ok() {
        let server = make_server();
        let app = server.router();

        let req = Request::builder()
            .uri("/health")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let body = axum::body::to_bytes(resp.into_body(), 10_000)
            .await
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(parsed["status"], "ok");
        assert!(parsed["connections"].is_number());
    }

    #[tokio::test]
    async fn ws_endpoint_exists() {
        let server = make_server();
        let app = server.router();

        let req = Request::builder()
            .uri("/ws")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn unknown_route_returns_404() {
        let server = make_server();
        let app = server.router();

        let req = Request::builder()
            .uri("/nonexistent")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn server_with_custom_config() {
        let config = ServerConfig {
            host: "0.0.0.0".into(),
            port: 9090,
            max_connections: 10,
            ..ServerConfig::default()
        };
        let server = TronServer::new(config, MethodRegistry::new());
        assert_eq!(server.config().host, "0.0.0.0");
        assert_eq!(server.config().port, 9090);
        assert_eq!(server.config().max_connections, 10);
    }

    #[tokio::test]
    async fn health_response_has_expected_fields() {
        let server = make_server();
        let app = server.router();

        let req = Request::builder()
            .uri("/health")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        let body = axum::body::to_bytes(resp.into_body(), 10_000)
            .await
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();

        assert!(parsed.get("status").is_some());
        assert!(parsed.get("uptime_secs").is_some());
        assert!(parsed.get("connections").is_some());
        assert!(parsed.get("active_sessions").is_some());
    }

    #[tokio::test]
    async fn shutdown_propagates_to_coordinator() {
        let server = make_server();
        let shutdown = server.shutdown().clone();
        assert!(!shutdown.is_shutting_down());
        shutdown.shutdown();
        assert!(server.shutdown().is_shutting_down());
    }
}
