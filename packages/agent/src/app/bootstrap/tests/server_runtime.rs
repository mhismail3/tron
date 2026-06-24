use super::*;
use crate::app::bootstrap::config::ServerConfig;
use crate::app::bootstrap::server::TronServer;
use crate::domains::agent::r#loop::{Orchestrator, SessionManager};
use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::ServerRuntimeContext;
use crate::transport::runtime::streams::EngineStreamEventPump;
use std::sync::Arc;

#[tokio::test]
async fn server_boots_and_responds() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let home = test_tron_home(&dir);
    let settings_path = test_settings_path(&home);

    // Single DB for events + tasks
    let db_str = db_path.to_string_lossy();
    let pool = crate::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    let event_store = Arc::new(EventStore::new(pool));

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let runtime_context = ServerRuntimeContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        transcription_runtime: crate::domains::transcription::SharedTranscriptionEngine::new(),
        profile_runtime: test_profile_runtime(&home),
        settings_path,
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        auth_path: dir.path().join("auth.json"),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: dir.path().join(".onboarded"),
    };

    let config = ServerConfig::default();
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = TronServer::new(config, runtime_context, metrics_handle);
    crate::transport::runtime::setup::register_server_domains_for_context(server.runtime_context())
        .unwrap();

    let pump = EngineStreamEventPump::new(
        orchestrator.subscribe(),
        server.runtime_context().engine_host.clone(),
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    );
    let _stream_event_pump = tokio::spawn(pump.run());

    let (addr, handle) = server.listen().await.unwrap();

    // Health check
    let resp = reqwest::get(format!("http://{addr}/health")).await.unwrap();
    assert!(resp.status().is_success());
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "ok");

    server.shutdown().shutdown();
    let _ = handle.await;
}
#[tokio::test]
async fn server_graceful_shutdown() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("events.db");
    let db_str = db_path.to_string_lossy();
    let pool = crate::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    let event_store = Arc::new(EventStore::new(pool));
    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let home = test_tron_home(&dir);
    let settings_path = test_settings_path(&home);

    let runtime_context = ServerRuntimeContext {
        orchestrator,
        session_manager,
        event_store,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        transcription_runtime: crate::domains::transcription::SharedTranscriptionEngine::new(),
        profile_runtime: test_profile_runtime(&home),
        settings_path,
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        auth_path: dir.path().join("auth.json"),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: dir.path().join(".onboarded"),
    };

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = TronServer::new(ServerConfig::default(), runtime_context, metrics_handle);
    crate::transport::runtime::setup::register_server_domains_for_context(server.runtime_context())
        .unwrap();
    let (_, handle) = server.listen().await.unwrap();

    server.shutdown().shutdown();
    tokio::time::timeout(std::time::Duration::from_secs(5), handle)
        .await
        .expect("shutdown timed out")
        .expect("join error");
}
#[test]
fn startup_ensures_bearer_token_exists() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("auth.json");

    let token = initialize_bearer_token_at(&path).expect("startup should create bearer token");

    assert_eq!(token.len(), 43);
    assert!(path.exists(), "startup must persist auth.json for pairing");
    let read_back =
        crate::app::lifecycle::onboarding::load_or_create_bearer_token(&path).expect("read");
    assert_eq!(read_back, token);
}
#[test]
fn constitution_startup_creates_internal_run_for_ephemeral_locks() {
    let dir = tempfile::tempdir().expect("tempdir");
    let home = dir.path().join(".tron");
    crate::shared::foundation::constitution::ensure_tron_home_at(&home)
        .expect("seed Constitution home");

    assert!(
        home.join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::RUN)
            .exists(),
        "internal/run/ holds runtime locks that normal server startup may create"
    );
    assert!(
        home.join(crate::shared::foundation::paths::dirs::PROFILES)
            .join(crate::shared::foundation::profile::DEFAULT_PROFILE)
            .join(crate::shared::foundation::paths::files::PROFILE_TOML)
            .exists(),
        "default profile must be seeded for auditable profile-owned settings"
    );
}
