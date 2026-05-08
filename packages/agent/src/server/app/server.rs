//! `TronServer` — Axum HTTP + WebSocket server.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::server::services::context::ServerCapabilityContext;
use axum::Router;
use axum::extract::ConnectInfo;
use axum::extract::Request as AxumRequest;
use axum::extract::State;
use axum::extract::ws::WebSocketUpgrade;
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Json, Response};
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

use crate::server::config::ServerConfig;
use crate::server::external_workers::{SharedExternalWorkerRuntime, run_external_worker_socket};
use crate::server::health::{self, HealthResponse};
use crate::server::shutdown::ShutdownCoordinator;
use crate::server::transport::auth::{BearerTokenStore, verify_bearer_header};
use crate::server::transport::engine_ws::{EngineClientRegistry, run_engine_ws_session};

/// Generates `UUIDv7` request IDs.
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
    /// Shutdown coordinator.
    pub shutdown: Arc<ShutdownCoordinator>,
    /// When the server started.
    pub start_time: Instant,
    /// Capability context shared across domain functions.
    pub capability_context: Arc<ServerCapabilityContext>,
    /// Server configuration.
    pub config: ServerConfig,
    /// Prometheus metrics handle for rendering.
    pub metrics_handle: Arc<PrometheusHandle>,
    /// Bearer-token verifier for engine WebSocket upgrades.
    pub auth_store: Arc<BearerTokenStore>,
    /// Shared local external-worker runtime.
    pub external_workers: SharedExternalWorkerRuntime,
    /// Connected `/engine` clients.
    pub engine_clients: Arc<EngineClientRegistry>,
}

/// The main Tron server.
pub struct TronServer {
    config: ServerConfig,
    shutdown: Arc<ShutdownCoordinator>,
    capability_context: Arc<ServerCapabilityContext>,
    metrics_handle: Arc<PrometheusHandle>,
    auth_store: Arc<BearerTokenStore>,
    external_workers: SharedExternalWorkerRuntime,
    engine_clients: Arc<EngineClientRegistry>,
    start_time: Instant,
}

impl TronServer {
    /// Create a new server.
    pub fn new(
        config: ServerConfig,
        mut capability_context: ServerCapabilityContext,
        metrics_handle: PrometheusHandle,
    ) -> Self {
        let shutdown = Arc::new(ShutdownCoordinator::new());
        // Inject shutdown coordinator into context so handlers can register tasks
        capability_context.shutdown_coordinator = Some(Arc::clone(&shutdown));
        // Inject device request broker (publishes device.request events to engine streams)
        capability_context.device_request_broker =
            Some(Arc::new(crate::server::device::DeviceRequestBroker::new(
                capability_context.engine_host.clone(),
                shutdown.token(),
            )));
        capability_context.set_ws_port(config.port);
        let auth_store = Arc::new(BearerTokenStore::new(capability_context.auth_path.clone()));
        let external_workers = Arc::new(tokio::sync::Mutex::new(
            crate::engine::EngineExternalWorkerRuntime::new(capability_context.engine_host.clone()),
        ));
        let engine_clients = Arc::new(EngineClientRegistry::new());
        Self {
            config,
            shutdown,
            capability_context: Arc::new(capability_context),
            metrics_handle: Arc::new(metrics_handle),
            auth_store,
            external_workers,
            engine_clients,
            start_time: Instant::now(),
        }
    }

    /// Build the Axum router with all routes and middleware.
    pub fn router(&self) -> Router {
        let state = AppState {
            shutdown: self.shutdown.clone(),
            start_time: self.start_time,
            capability_context: self.capability_context.clone(),
            config: self.config.clone(),
            metrics_handle: self.metrics_handle.clone(),
            auth_store: self.auth_store.clone(),
            external_workers: self.external_workers.clone(),
            engine_clients: self.engine_clients.clone(),
        };

        Router::new()
            .route("/health", get(health_handler))
            .route("/metrics", get(metrics_handler))
            .route(
                "/engine",
                get(engine_upgrade_handler)
                    .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth_gate)),
            )
            .route(
                "/engine/workers",
                get(engine_worker_upgrade_handler)
                    .route_layer(middleware::from_fn_with_state(state.clone(), ws_auth_gate)),
            )
            .route("/health/deep", get(deep_health_handler))
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
        self.capability_context.set_ws_port(bound_addr.port());

        info!(addr = %bound_addr, "engine server started");

        let router = self.router();
        let shutdown_token = self.shutdown.token();

        let handle = tokio::spawn(async move {
            let _ = axum::serve(
                listener,
                router.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .with_graceful_shutdown(async move {
                shutdown_token.cancelled().await;
                info!("server shutdown initiated");
            })
            .await;
            info!("server shutdown complete");
        });

        Ok((bound_addr, handle))
    }

    /// Get the shutdown coordinator.
    pub fn shutdown(&self) -> &Arc<ShutdownCoordinator> {
        &self.shutdown
    }

    /// Get the server configuration.
    pub fn config(&self) -> &ServerConfig {
        &self.config
    }

    /// Get the capability context.
    pub fn capability_context(&self) -> &Arc<ServerCapabilityContext> {
        &self.capability_context
    }

    /// Get the local external-worker runtime.
    pub fn external_workers(&self) -> &SharedExternalWorkerRuntime {
        &self.external_workers
    }

    /// Get the connected engine client registry.
    pub fn engine_clients(&self) -> &Arc<EngineClientRegistry> {
        &self.engine_clients
    }
}

/// GET /engine — public engine client WebSocket protocol.
async fn engine_upgrade_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    let client_id = uuid::Uuid::now_v7().to_string();
    let ctx = state.capability_context;
    let clients = state.engine_clients;
    let max_message_size = state.config.max_message_size;
    Ok(ws
        .max_message_size(max_message_size)
        .on_upgrade(move |socket| async move {
            run_engine_ws_session(socket, client_id, ctx, clients).await;
        }))
}

/// GET /engine/workers — local engine worker WebSocket upgrade handler.
async fn engine_worker_upgrade_handler(
    ws: WebSocketUpgrade,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    if !addr.ip().is_loopback() {
        tracing::warn!(%addr, "rejected non-loopback engine worker connection");
        return Err(StatusCode::FORBIDDEN);
    }
    let runtime = state.external_workers;
    Ok(ws.on_upgrade(move |socket| async move {
        run_external_worker_socket(socket, runtime).await;
    }))
}

/// GET /health
async fn health_handler(State(state): State<AppState>) -> Json<HealthResponse> {
    let connections = state.engine_clients.connection_count();
    let sessions = state.capability_context.orchestrator.active_session_count();
    let resp = health::health_check(state.start_time, connections, sessions);
    Json(resp)
}

/// GET /health/deep — Deep health check with per-subsystem results.
async fn deep_health_handler(State(state): State<AppState>) -> Json<health::DeepHealthResponse> {
    let connections = state.engine_clients.connection_count();
    let sessions = state.capability_context.orchestrator.active_session_count();
    let pool = state.capability_context.event_store.pool().clone();
    let tron_home = crate::settings::tron_home_dir();
    let response = state
        .capability_context
        .run_blocking("http.health.deep", move || {
            Ok(health::deep_health_check(
                state.start_time,
                connections,
                sessions,
                &pool,
                &tron_home,
            ))
        })
        .await;

    match response {
        Ok(resp) => Json(resp),
        Err(error) => Json(health::DeepHealthResponse {
            status: "unhealthy".into(),
            uptime_secs: state.start_time.elapsed().as_secs(),
            connections,
            active_sessions: sessions,
            checks: vec![health::DeepHealthCheck {
                name: "deepHealth".into(),
                status: "fail".into(),
                detail: Some(serde_json::json!({ "error": error.to_string() })),
            }],
        }),
    }
}

/// GET /metrics — Prometheus text format.
async fn metrics_handler(State(state): State<AppState>) -> String {
    state.metrics_handle.render()
}

async fn ws_auth_gate(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: AxumRequest,
    next: Next,
) -> Result<Response, StatusCode> {
    verify_bearer_header(&headers, &state.auth_store)?;
    Ok(next.run(request).await)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::services::test_support::make_test_context;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    fn make_metrics_handle() -> PrometheusHandle {
        metrics_exporter_prometheus::PrometheusBuilder::new()
            .build_recorder()
            .handle()
    }

    fn make_server() -> TronServer {
        let ctx = make_test_context();
        TronServer::new(ServerConfig::default(), ctx, make_metrics_handle())
    }

    fn make_server_with_auth() -> (TronServer, tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let auth_path = dir.path().join("auth.json");
        let token = crate::server::onboarding::load_or_create_bearer_token(&auth_path).unwrap();
        let mut ctx = make_test_context();
        ctx.auth_path = auth_path;
        let server = TronServer::new(ServerConfig::default(), ctx, make_metrics_handle());
        (server, dir, token)
    }

    fn ws_upgrade_request_to(path: &str, auth: Option<String>) -> Request<Body> {
        let mut builder = Request::builder()
            .method("GET")
            .uri(path)
            .header("connection", "upgrade")
            .header("upgrade", "websocket")
            .header("sec-websocket-version", "13")
            .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==");
        if let Some(auth) = auth {
            builder = builder.header("authorization", auth);
        }
        builder.body(Body::empty()).unwrap()
    }

    fn ws_upgrade_request(auth: Option<String>) -> Request<Body> {
        ws_upgrade_request_to("/engine", auth)
    }

    #[tokio::test]
    async fn server_with_default_config() {
        let server = make_server();
        assert_eq!(server.config().host, "0.0.0.0");
        assert_eq!(server.config().port, 0);
    }

    #[tokio::test]
    async fn engine_client_registry_accessible() {
        let server = make_server();
        assert_eq!(server.engine_clients().connection_count(), 0);
    }

    #[test]
    fn shutdown_coordinator_accessible() {
        let server = make_server();
        assert!(!server.shutdown().is_shutting_down());
    }

    #[test]
    fn capability_context_accessible() {
        let server = make_server();
        let ctx = server.capability_context();
        assert!(ctx.orchestrator.can_accept_session());
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
    async fn engine_endpoint_requires_upgrade() {
        let (server, _dir, token) = make_server_with_auth();
        let marker = server.capability_context().onboarded_marker_path.clone();
        let app = server.router();

        // GET /engine without WebSocket upgrade headers → should return an error
        let req = Request::builder()
            .uri("/engine")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        // Without upgrade headers, axum returns a non-success status
        assert_ne!(resp.status(), StatusCode::OK);
        assert_ne!(resp.status(), StatusCode::UNAUTHORIZED);
        assert!(!marker.exists(), "invalid upgrades must not mark paired");
    }

    #[tokio::test]
    async fn engine_endpoint_rejects_missing_bearer() {
        let (server, _dir, _token) = make_server_with_auth();
        let app = server.router();

        let req = ws_upgrade_request(None);

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn engine_ws_endpoint_uses_same_bearer_auth_gate() {
        let (server, _dir, token) = make_server_with_auth();
        let app = server.router();

        let missing = ws_upgrade_request_to("/engine", None);
        let missing_resp = app.clone().oneshot(missing).await.unwrap();
        assert_eq!(missing_resp.status(), StatusCode::UNAUTHORIZED);

        let authorized = ws_upgrade_request_to("/engine", Some(format!("Bearer {token}")));
        let authorized_resp = app.oneshot(authorized).await.unwrap();
        assert_ne!(authorized_resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn engine_endpoint_rejects_wrong_bearer() {
        let (server, _dir, _token) = make_server_with_auth();
        let app = server.router();

        let req = ws_upgrade_request(Some("Bearer wrong".into()));

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn engine_endpoint_rejects_wrong_auth_scheme() {
        let (server, _dir, token) = make_server_with_auth();
        let app = server.router();

        let req = ws_upgrade_request(Some(format!("Basic {token}")));

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn engine_endpoint_reloads_rotated_bearer() {
        let (server, dir, token) = make_server_with_auth();
        let app = server.router();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let rotated =
            crate::server::onboarding::rotate_bearer_token(&dir.path().join("auth.json")).unwrap();

        let old_req = ws_upgrade_request(Some(format!("Bearer {token}")));
        let old_resp = app.clone().oneshot(old_req).await.unwrap();
        assert_eq!(old_resp.status(), StatusCode::UNAUTHORIZED);

        let new_req = ws_upgrade_request(Some(format!("Bearer {rotated}")));
        let new_resp = app.oneshot(new_req).await.unwrap();
        assert_ne!(new_resp.status(), StatusCode::UNAUTHORIZED);
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
    async fn deploy_routes_are_not_registered_in_production_router() {
        let server = make_server();
        let app = server.router();

        let req = Request::builder()
            .uri("/deploy/status")
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
        let ctx = make_test_context();
        let server = TronServer::new(config, ctx, make_metrics_handle());
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
        assert_eq!(parsed["active_sessions"], 0);
    }

    #[tokio::test]
    async fn health_reports_active_sessions_from_orchestrator() {
        let ctx = make_test_context();
        // Create a session so orchestrator reports 1
        assert!(
            ctx.session_manager
                .create_session("claude-opus-4-6", "/tmp", None, None)
                .is_ok()
        );
        let server = TronServer::new(ServerConfig::default(), ctx, make_metrics_handle());
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
        assert_eq!(parsed["active_sessions"], 1);
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
        assert_eq!(server.capability_context().ws_port(), addr.port());
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

    #[tokio::test]
    async fn deep_health_endpoint_returns_200() {
        let server = make_server();
        let app = server.router();

        let req = Request::builder()
            .uri("/health/deep")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let body = axum::body::to_bytes(resp.into_body(), 10_000)
            .await
            .unwrap();
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(["healthy", "degraded", "unhealthy"].contains(&parsed["status"].as_str().unwrap()));
        assert!(parsed["checks"].is_array());
        assert!(parsed["uptimeSecs"].is_number());
    }
}
