//! `TronServer` — Axum HTTP + WebSocket server.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::rpc::context::RpcContext;
use crate::rpc::registry::MethodRegistry;
use axum::Router;
use axum::extract::State;
use axum::extract::ws::WebSocketUpgrade;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use axum::routing::get;
use tokio::net::TcpListener;
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::compression::CompressionLayer;
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::request_id::{
    MakeRequestId, PropagateRequestIdLayer, RequestId, SetRequestIdLayer,
};
use tower_http::timeout::TimeoutLayer;

use tracing::{info, instrument};

use metrics_exporter_prometheus::PrometheusHandle;

use crate::config::ServerConfig;
use crate::health::{self, HealthResponse};
use crate::shutdown::ShutdownCoordinator;
use crate::websocket::broadcast::BroadcastManager;
use crate::websocket::session::run_ws_session;

/// Generates UUIDv7 request IDs.
#[derive(Clone)]
struct UuidV7RequestId;

impl MakeRequestId for UuidV7RequestId {
    fn make_request_id<B>(&mut self, _request: &axum::http::Request<B>) -> Option<RequestId> {
        let id = uuid::Uuid::now_v7().to_string();
        axum::http::HeaderValue::from_str(&id)
            .ok()
            .map(RequestId::new)
    }
}

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
    /// RPC context shared across handlers.
    pub rpc_context: Arc<RpcContext>,
    /// Server configuration.
    pub config: ServerConfig,
    /// Prometheus metrics handle for rendering.
    pub metrics_handle: Arc<PrometheusHandle>,
}

/// The main Tron server.
pub struct TronServer {
    config: ServerConfig,
    registry: Arc<MethodRegistry>,
    broadcast: Arc<BroadcastManager>,
    shutdown: Arc<ShutdownCoordinator>,
    rpc_context: Arc<RpcContext>,
    metrics_handle: Arc<PrometheusHandle>,
    start_time: Instant,
}

impl TronServer {
    /// Create a new server.
    pub fn new(
        config: ServerConfig,
        registry: MethodRegistry,
        rpc_context: RpcContext,
        metrics_handle: PrometheusHandle,
    ) -> Self {
        Self {
            config,
            registry: Arc::new(registry),
            broadcast: Arc::new(BroadcastManager::new()),
            shutdown: Arc::new(ShutdownCoordinator::new()),
            rpc_context: Arc::new(rpc_context),
            metrics_handle: Arc::new(metrics_handle),
            start_time: Instant::now(),
        }
    }

    /// Build the Axum router with all routes and middleware.
    pub fn router(&self) -> Router {
        let state = AppState {
            broadcast: self.broadcast.clone(),
            shutdown: self.shutdown.clone(),
            start_time: self.start_time,
            registry: self.registry.clone(),
            rpc_context: self.rpc_context.clone(),
            config: self.config.clone(),
            metrics_handle: self.metrics_handle.clone(),
        };

        Router::new()
            .route("/health", get(health_handler))
            .route("/metrics", get(metrics_handler))
            .route("/ws", get(ws_upgrade_handler))
            .with_state(state)
            // Outermost layers execute first on request, last on response.
            .layer(CatchPanicLayer::new())
            .layer(CompressionLayer::new())
            .layer(RequestBodyLimitLayer::new(1024 * 1024)) // 1 MB
            .layer(TimeoutLayer::with_status_code(
                StatusCode::REQUEST_TIMEOUT,
                Duration::from_secs(30),
            ))
            .layer(SetRequestIdLayer::x_request_id(UuidV7RequestId))
            .layer(PropagateRequestIdLayer::x_request_id())
    }

    /// Bind to a TCP port and start serving. Returns the bound address and a
    /// join handle for the server task.
    #[instrument(skip_all, fields(host = %self.config.host, port = self.config.port))]
    pub async fn listen(
        &self,
    ) -> Result<(SocketAddr, tokio::task::JoinHandle<()>), std::io::Error> {
        let addr = format!("{}:{}", self.config.host, self.config.port);
        let listener = TcpListener::bind(&addr).await?;
        let bound_addr = listener.local_addr()?;

        let methods = self.registry.methods().len();
        info!(addr = %bound_addr, methods, "server started");

        let router = self.router();
        let shutdown_token = self.shutdown.token();

        let handle = tokio::spawn(async move {
            let _ = axum::serve(listener, router)
                .with_graceful_shutdown(async move {
                    shutdown_token.cancelled().await;
                    info!("server shutdown initiated");
                })
                .await;
            info!("server shutdown complete");
        });

        Ok((bound_addr, handle))
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

    /// Get the RPC context.
    pub fn rpc_context(&self) -> &Arc<RpcContext> {
        &self.rpc_context
    }
}

/// GET /health
async fn health_handler(State(state): State<AppState>) -> Json<HealthResponse> {
    let connections = state.broadcast.connection_count().await;
    let resp = health::health_check(state.start_time, connections, 0);
    Json(resp)
}

/// GET /metrics — Prometheus text format.
async fn metrics_handler(State(state): State<AppState>) -> String {
    state.metrics_handle.render()
}

/// GET /ws — WebSocket upgrade handler.
async fn ws_upgrade_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    // Enforce max_connections
    let current = state.broadcast.connection_count().await;
    if current >= state.config.max_connections {
        tracing::warn!(
            current,
            max = state.config.max_connections,
            "connection limit reached, rejecting WebSocket upgrade"
        );
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }

    let client_id = uuid::Uuid::now_v7().to_string();
    let registry = state.registry;
    let ctx = state.rpc_context;
    let broadcast = state.broadcast;
    let max_message_size = state.config.max_message_size;

    Ok(ws
        .max_message_size(max_message_size)
        .on_upgrade(move |socket| run_ws_session(socket, client_id, registry, ctx, broadcast)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use std::path::PathBuf;
    use tower::ServiceExt;

    fn make_test_rpc_context() -> RpcContext {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(tron_events::EventStore::new(pool));
        let mgr = Arc::new(
            tron_runtime::orchestrator::session_manager::SessionManager::new(store.clone()),
        );
        let orch = Arc::new(tron_runtime::orchestrator::orchestrator::Orchestrator::new(
            mgr.clone(),
            10,
        ));
        RpcContext {
            orchestrator: orch,
            session_manager: mgr,
            event_store: store,
            skill_registry: Arc::new(parking_lot::RwLock::new(
                tron_skills::registry::SkillRegistry::new(),
            )),
            task_pool: None,
            settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            browser_service: None,
            transcription_engine: None,
            subagent_manager: None,
            embedding_controller: None,
            health_tracker: Arc::new(tron_llm::ProviderHealthTracker::new()),
        }
    }

    fn make_metrics_handle() -> PrometheusHandle {
        metrics_exporter_prometheus::PrometheusBuilder::new()
            .build_recorder()
            .handle()
    }

    fn make_server() -> TronServer {
        let ctx = make_test_rpc_context();
        TronServer::new(
            ServerConfig::default(),
            MethodRegistry::new(),
            ctx,
            make_metrics_handle(),
        )
    }

    #[tokio::test]
    async fn server_with_default_config() {
        let server = make_server();
        assert_eq!(server.config().host, "0.0.0.0");
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

    #[test]
    fn rpc_context_accessible() {
        let server = make_server();
        let ctx = server.rpc_context();
        assert_eq!(ctx.orchestrator.max_concurrent_sessions(), 10);
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
    async fn ws_endpoint_requires_upgrade() {
        let server = make_server();
        let app = server.router();

        // GET /ws without WebSocket upgrade headers → should return an error
        let req = Request::builder().uri("/ws").body(Body::empty()).unwrap();

        let resp = app.oneshot(req).await.unwrap();
        // Without upgrade headers, axum returns a non-success status
        assert_ne!(resp.status(), StatusCode::OK);
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
        let ctx = make_test_rpc_context();
        let server = TronServer::new(config, MethodRegistry::new(), ctx, make_metrics_handle());
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

    #[tokio::test]
    async fn server_listen_binds_port() {
        let server = make_server();
        let (addr, handle) = server.listen().await.unwrap();

        assert_ne!(addr.port(), 0); // auto-assigned
        assert_eq!(addr.ip().to_string(), "0.0.0.0");

        // Shutdown
        server.shutdown().shutdown();
        let _ = handle.await;
    }

    #[tokio::test]
    async fn server_listen_returns_address() {
        let server = make_server();
        let (addr, handle) = server.listen().await.unwrap();

        assert!(addr.port() > 0);

        server.shutdown().shutdown();
        let _ = handle.await;
    }

    #[tokio::test]
    async fn server_graceful_shutdown() {
        let server = make_server();
        let (_, handle) = server.listen().await.unwrap();

        server.shutdown().shutdown();
        // Should complete without hanging
        tokio::time::timeout(std::time::Duration::from_secs(5), handle)
            .await
            .expect("shutdown timed out")
            .expect("join error");
    }

    #[tokio::test]
    async fn server_health_while_running() {
        let server = make_server();
        let (addr, handle) = server.listen().await.unwrap();

        let resp = reqwest::get(format!("http://{addr}/health")).await.unwrap();
        assert!(resp.status().is_success());

        let body: serde_json::Value = resp.json().await.unwrap();
        assert_eq!(body["status"], "ok");

        server.shutdown().shutdown();
        let _ = handle.await;
    }
}
