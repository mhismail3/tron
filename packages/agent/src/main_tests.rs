use super::*;
use super::tool_factory::create_tool_registry;
use clap::Parser;
use tron::settings::db_path_policy::{
    PRODUCTION_DB_FILENAME, default_production_db_path, production_db_dir_from_home,
    validate_production_db_path_for_home,
};
use tron::settings::TronSettings;

/// Small pool size for tests — prevents FD exhaustion when many tests
/// run in parallel, each opening a file-backed `SQLite` pool.
fn test_db_config() -> ConnectionConfig {
    ConnectionConfig {
        pool_size: 2,
        ..ConnectionConfig::default()
    }
}

#[test]
fn cli_default_host() {
    let cli = Cli::parse_from(["tron"]);
    assert_eq!(cli.host, "0.0.0.0");
}

#[test]
fn cli_default_port() {
    let cli = Cli::parse_from(["tron"]);
    assert_eq!(cli.port, 9847);
}

#[test]
fn cli_parses_log_level_flag() {
    let cli = Cli::parse_from(["tron", "--log-level", "debug"]);
    assert_eq!(cli.log_level.as_deref(), Some("debug"));
}

#[test]
fn cli_log_level_is_optional() {
    let cli = Cli::parse_from(["tron"]);
    assert!(cli.log_level.is_none());
}

#[test]
fn default_db_path_under_tron_dir() {
    let path = default_production_db_path();
    assert!(path.to_string_lossy().contains(".tron"));
    assert!(path.to_string_lossy().ends_with(PRODUCTION_DB_FILENAME));
}

#[test]
fn ensure_parent_dir_creates_nested() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a").join("b").join("test.db");
    ensure_parent_dir(&path).unwrap();
    assert!(path.parent().unwrap().exists());
}

#[tokio::test]
async fn factory_unknown_model_returns_unsupported_model_error() {
    let settings = TronSettings::default();
    let factory = provider_factory::DefaultProviderFactory::new(&settings)
        .with_auth_path(PathBuf::from("/tmp/tron-test-no-such-auth.json"));
    let result = factory.create_for_model("unknown-model").await;
    assert!(matches!(
        result,
        Err(tron::llm::provider::ProviderError::UnsupportedModel { .. })
    ));
}

#[test]
fn db_policy_accepts_expected_home_path() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db_path = production_db_dir_from_home(&home).join(PRODUCTION_DB_FILENAME);
    validate_production_db_path_for_home(&db_path, &home).unwrap();
}

#[test]
fn db_policy_rejects_alternate_filename() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db_path = production_db_dir_from_home(&home).join("not-beta.db");
    let err = validate_production_db_path_for_home(&db_path, &home).unwrap_err();
    assert!(err.to_string().contains(PRODUCTION_DB_FILENAME));
}

#[test]
fn db_policy_rejects_wrong_directory_without_creating_it() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();

    let bad_parent = home.join("other-db-dir");
    let bad_path = bad_parent.join(PRODUCTION_DB_FILENAME);
    assert!(!bad_parent.exists());

    let err = validate_production_db_path_for_home(&bad_path, &home).unwrap_err();
    assert!(err.to_string().contains("does not exist"));
    assert!(!bad_parent.exists());
}

#[cfg(unix)]
#[test]
fn db_policy_rejects_symlink_db_file() {
    use std::os::unix::fs::symlink;

    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();

    let prod_dir = production_db_dir_from_home(&home);
    std::fs::create_dir_all(&prod_dir).unwrap();

    let target = dir.path().join("escape.db");
    std::fs::write(&target, "x").unwrap();
    let symlink_path = prod_dir.join(PRODUCTION_DB_FILENAME);
    symlink(&target, &symlink_path).unwrap();

    let err = validate_production_db_path_for_home(&symlink_path, &home).unwrap_err();
    assert!(err.to_string().contains("symlink"));
}

#[tokio::test]
async fn openai_returns_none_without_auth() {
    // With no auth.json, OpenAI returns None
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");
    let result = tron::llm::auth::openai::load_server_auth(&path)
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn google_returns_none_without_auth() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");
    let result = tron::llm::auth::google::load_server_auth(&path)
        .await
        .unwrap();
    assert!(result.is_none());
}

#[test]
fn auth_path_under_tron_dir() {
    let path = auth_path();
    assert!(path.to_string_lossy().contains(".tron"));
    assert!(path.to_string_lossy().ends_with("auth.json"));
}

#[tokio::test]
async fn create_anthropic_with_oauth_from_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    // Save fresh OAuth tokens
    let tokens = tron::llm::auth::OAuthTokens {
        access_token: "sk-ant-oat-test".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::llm::auth::now_ms() + 3_600_000,
    };
    tron::llm::auth::storage::save_account_oauth_tokens(&path, "anthropic", "test", &tokens).unwrap();

    // load_server_auth should find the OAuth tokens
    let config = tron::llm::auth::anthropic::default_config();
    let result = tron::llm::auth::anthropic::load_server_auth(&path, &config)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "sk-ant-oat-test");
}

#[tokio::test]
async fn create_anthropic_oauth_over_api_key() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    // Save both OAuth account and API key
    tron::llm::auth::storage::save_named_api_key(&path, "anthropic", "(default)", "sk-api-key").unwrap();
    let tokens = tron::llm::auth::OAuthTokens {
        access_token: "sk-ant-oat-primary".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::llm::auth::now_ms() + 3_600_000,
    };
    tron::llm::auth::storage::save_account_oauth_tokens(&path, "anthropic", "test", &tokens).unwrap();

    // OAuth takes priority
    let config = tron::llm::auth::anthropic::default_config();
    let result = tron::llm::auth::anthropic::load_server_auth(&path, &config)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "sk-ant-oat-primary");
}

#[tokio::test]
async fn create_anthropic_uses_first_account() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    let work_tokens = tron::llm::auth::OAuthTokens {
        access_token: "work-tok".to_string(),
        refresh_token: "ref1".to_string(),
        expires_at: tron::llm::auth::now_ms() + 3_600_000,
    };
    tron::llm::auth::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "work",
        &work_tokens,
    )
    .unwrap();

    let config = tron::llm::auth::anthropic::default_config();
    let result = tron::llm::auth::anthropic::load_server_auth(&path, &config)
        .await
        .unwrap();
    assert_eq!(result.unwrap().token(), "work-tok");
}

#[tokio::test]
async fn create_openai_with_oauth_from_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = tron::llm::auth::OAuthTokens {
        access_token: "openai-oauth-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::llm::auth::now_ms() + 3_600_000,
    };
    tron::llm::auth::storage::save_account_oauth_tokens(
        &path,
        tron::llm::auth::openai::PROVIDER_KEY,
        "test",
        &tokens,
    )
    .unwrap();

    let result = tron::llm::auth::openai::load_server_auth(&path)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert!(auth.is_oauth());
    assert_eq!(auth.token(), "openai-oauth-tok");
}

#[tokio::test]
async fn create_google_with_oauth_from_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    // Save OAuth tokens via account path
    let tokens = tron::llm::auth::OAuthTokens {
        access_token: "ya29.google-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::llm::auth::now_ms() + 3_600_000,
    };
    tron::llm::auth::storage::save_account_oauth_tokens(&path, "google", "(test)", &tokens).unwrap();

    // Set client_id (required for OAuth)
    let mut gpa = tron::llm::auth::storage::get_google_provider_auth(&path)
        .unwrap_or_default();
    gpa.client_id = Some("test-client-id".to_string());
    tron::llm::auth::storage::save_google_provider_auth(&path, &gpa).unwrap();

    let result = tron::llm::auth::google::load_server_auth(&path)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.auth.token(), "ya29.google-tok");
    assert!(auth.project_id.is_none());
}

#[tokio::test]
async fn server_auth_maps_to_anthropic_oauth_auth() {
    let server_auth = tron::llm::auth::ServerAuth::OAuth {
        access_token: "tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: 999,
    };
    assert!(server_auth.is_oauth());
    assert_eq!(server_auth.token(), "tok");
}

#[tokio::test]
async fn server_auth_maps_to_api_key_auth() {
    let server_auth = tron::llm::auth::ServerAuth::from_api_key("sk-123");
    assert!(!server_auth.is_oauth());
    assert_eq!(server_auth.token(), "sk-123");
}

#[tokio::test]
async fn server_boots_and_responds() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("log.db");
    let settings_path = dir.path().join("settings.json");

    // Single DB for events + tasks
    let db_str = db_path.to_string_lossy();
    let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();
    }
    let event_store = Arc::new(EventStore::new(pool));

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        memory_registry: Arc::new(parking_lot::Mutex::new(
            tron::runtime::memory::MemoryRegistry::new(),
        )),
        settings_path,
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::server::rpc::session_context::ContextArtifactsService::new(),
        ),
        auth_path: dir.path().join("auth.json"),
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(tron::runtime::hooks::abort_tracker::HookAbortTracker::new()),
    };

    let mut registry = MethodRegistry::new();
    tron::server::rpc::handlers::register_all(&mut registry);

    let config = ServerConfig::default();
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = TronServer::new(config, registry, rpc_context, metrics_handle);

    let bridge = EventBridge::new(
        orchestrator.subscribe(),
        server.broadcast().clone(),
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    );
    let _bridge = tokio::spawn(bridge.run());

    let (addr, handle) = server.listen().await.unwrap();

    // Health check
    let resp = reqwest::get(format!("http://{addr}/health")).await.unwrap();
    assert!(resp.status().is_success());
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "ok");

    server.shutdown().shutdown();
    let _ = handle.await;
}

#[test]
fn server_creates_db_on_first_run() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("new.db");
    assert!(!db_path.exists());

    let db_str = db_path.to_string_lossy();
    let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
    let conn = pool.get().unwrap();
    let _ = tron::events::run_migrations(&conn).unwrap();

    assert!(db_path.exists());
}

#[test]
fn server_runs_migrations() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("log.db");
    let db_str = db_path.to_string_lossy();
    let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
    let conn = pool.get().unwrap();
    let _ = tron::events::run_migrations(&conn).unwrap();

    // Verify tables exist
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='events'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
}

fn make_tool_config() -> ToolRegistryConfig {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tools-test.db");
    let db_str = db_path.to_string_lossy();
    let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();
    }
    let event_store = Arc::new(EventStore::new(pool));
    ToolRegistryConfig {
        event_store,
        brave_api_key: None,
        push_service: None,
        http_client: reqwest::Client::new(),
        sandbox_settings: tron::settings::BashSandboxSettings::default(),
        computer_use_settings: tron::settings::ComputerUseSettings::default(),
        display_event_tx: None,
        mcp_search: None,
        mcp_call: None,
    }
}

#[test]
fn tool_registry_order() {
    let config = make_tool_config();
    let registry = create_tool_registry(&config);
    let names = registry.names();
    assert_eq!(names[0], "Read");
    assert_eq!(names[1], "Write");
    assert_eq!(names[2], "Edit");
    assert_eq!(names[3], "Bash");
    assert_eq!(names[4], "Search");
    assert_eq!(names[5], "Find");
    assert_eq!(names[6], "AskUserQuestion");
    assert_eq!(names[7], "GetConfirmation");
    assert_eq!(names[8], "NotifyApp");
    assert_eq!(names[9], "WebFetch");
    assert_eq!(names[10], "Display");
    assert_eq!(names[11], "ComputerUse");
}

#[test]
fn tool_registry_has_notify_app() {
    let config = make_tool_config();
    let registry = create_tool_registry(&config);
    assert!(registry.names().contains(&"NotifyApp".to_string()));
}

#[test]
fn tool_registry_count() {
    let config = make_tool_config();
    let registry = create_tool_registry(&config);
    // 12 tools without Brave API key (no WebSearch), without subagent tools
    assert_eq!(
        registry.len(),
        12,
        "expected 12 tools (no WebSearch without Brave key), got: {:?}",
        registry.names()
    );
}

#[test]
fn tool_registry_count_with_web_search() {
    let config = ToolRegistryConfig {
        brave_api_key: Some("test-key".into()),
        ..make_tool_config()
    };
    let registry = create_tool_registry(&config);
    assert_eq!(
        registry.len(),
        13,
        "expected 13 tools with WebSearch, got: {:?}",
        registry.names()
    );
}

#[test]
fn server_registers_all_rpc_methods() {
    let mut registry = MethodRegistry::new();
    tron::server::rpc::handlers::register_all(&mut registry);
    // Should have a substantial number of methods registered
    assert!(registry.methods().len() >= 50);
}

#[tokio::test]
async fn server_graceful_shutdown() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("events.db");
    let db_str = db_path.to_string_lossy();
    let pool = tron::events::new_file(&db_str, &test_db_config()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();
    }
    let event_store = Arc::new(EventStore::new(pool));
    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));

    let rpc_context = RpcContext {
        orchestrator,
        session_manager,
        event_store,
        skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
        memory_registry: Arc::new(parking_lot::Mutex::new(
            tron::runtime::memory::MemoryRegistry::new(),
        )),
        settings_path: dir.path().join("settings.json"),
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::server::rpc::session_context::ContextArtifactsService::new(),
        ),
        auth_path: dir.path().join("auth.json"),
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(tron::runtime::hooks::abort_tracker::HookAbortTracker::new()),
    };

    let mut registry = MethodRegistry::new();
    tron::server::rpc::handlers::register_all(&mut registry);

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = TronServer::new(
        ServerConfig::default(),
        registry,
        rpc_context,
        metrics_handle,
    );
    let (_, handle) = server.listen().await.unwrap();

    server.shutdown().shutdown();
    tokio::time::timeout(std::time::Duration::from_secs(5), handle)
        .await
        .expect("shutdown timed out")
        .expect("join error");
}
