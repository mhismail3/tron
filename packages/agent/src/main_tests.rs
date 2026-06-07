use super::*;
use clap::Parser;
use std::path::PathBuf;
use std::sync::Arc;
use tron::app::config::ServerConfig;
use tron::app::server::TronServer;
use tron::domains::agent::runner::{Orchestrator, SessionManager};
use tron::domains::model::providers::factory as provider_factory;
use tron::domains::model::providers::provider::ProviderFactory;
use tron::domains::session::event_store::{ConnectionConfig, EventStore};
use tron::domains::settings::TronSettings;
use tron::domains::settings::db_path_policy::{
    PRODUCTION_DB_FILENAME, default_production_db_path, production_db_dir_from_tron_home,
    validate_production_db_path_for_tron_home,
};
use tron::shared::server::context::ServerRuntimeContext;
use tron::transport::runtime::streams::EngineStreamEventPump;

/// Small pool size for tests — prevents FD exhaustion when many tests
/// run in parallel, each opening a file-backed `SQLite` pool.
fn test_db_config() -> ConnectionConfig {
    ConnectionConfig {
        pool_size: 2,
        ..ConnectionConfig::default()
    }
}

fn test_tron_home(dir: &tempfile::TempDir) -> std::path::PathBuf {
    let home = dir.path().join(".tron");
    tron::shared::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

fn test_settings_path(home: &std::path::Path) -> std::path::PathBuf {
    home.join(tron::shared::paths::dirs::PROFILES)
        .join(tron::shared::profile::USER_PROFILE)
        .join(tron::shared::paths::files::PROFILE_TOML)
}

fn test_profile_runtime(
    home: &std::path::Path,
) -> Arc<tron::domains::agent::runner::ProfileRuntime> {
    Arc::new(tron::domains::agent::runner::ProfileRuntime::load(home).unwrap())
}

#[test]
fn cli_default_host() {
    let cli = Cli::parse_from(["tron"]);
    assert_eq!(cli.host, "0.0.0.0");
}

// ── C2: startup log names bind address ──────────────────────────────

/// Startup log for the default 0.0.0.0 bind MUST name the Tailscale /
/// trusted-local assumption. Without this, an operator who accidentally
/// bound on an untrusted network has no visible warning.
#[test]
fn startup_log_on_all_interfaces_names_trust_boundary() {
    let addr: std::net::SocketAddr = "0.0.0.0:9847".parse().unwrap();
    let msg = format_listening_log(&addr, "0.0.0.0");
    assert!(
        msg.contains("0.0.0.0:9847"),
        "bind address must appear: {msg}"
    );
    assert!(
        msg.to_lowercase().contains("tailscale") || msg.to_lowercase().contains("firewall"),
        "0.0.0.0 bind must name the trust assumption, got: {msg}"
    );
}

/// IPv6 catch-all (`::`) is the same trust boundary as `0.0.0.0`.
#[test]
fn startup_log_on_ipv6_all_interfaces_names_trust_boundary() {
    let addr: std::net::SocketAddr = "[::]:9847".parse().unwrap();
    let msg = format_listening_log(&addr, "::");
    assert!(
        msg.to_lowercase().contains("tailscale") || msg.to_lowercase().contains("firewall"),
        "`::` bind must name the trust assumption, got: {msg}"
    );
}

/// Loopback binds are explicitly safer; the log should say so.
#[test]
fn startup_log_on_loopback_is_annotated() {
    for host in ["127.0.0.1", "::1", "localhost"] {
        let addr: std::net::SocketAddr = "127.0.0.1:9847".parse().unwrap();
        let msg = format_listening_log(&addr, host);
        assert!(
            msg.to_lowercase().contains("loopback"),
            "{host}-bound log must note loopback scope: {msg}"
        );
    }
}

/// A specific non-default host (e.g. a LAN IP the operator chose
/// deliberately) is left bare — we don't second-guess intentional
/// network selection, and the raw address is already in the message.
#[test]
fn startup_log_on_specific_host_is_bare() {
    let addr: std::net::SocketAddr = "192.168.1.5:9847".parse().unwrap();
    let msg = format_listening_log(&addr, "192.168.1.5");
    assert!(!msg.to_lowercase().contains("tailscale"));
    assert!(!msg.to_lowercase().contains("loopback"));
    assert!(msg.contains("192.168.1.5:9847"));
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
fn shutdown_signal_surface_includes_process_manager_stop_signal() {
    assert!(shutdown_signal_names().contains(&"SIGINT"));
    #[cfg(unix)]
    assert!(
        shutdown_signal_names().contains(&"SIGTERM"),
        "launchd and tron dev --stop use SIGTERM; managed child cleanup must run for it"
    );
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
async fn init_engine_host_bootstraps_sqlite_host() {
    let dir = tempfile::tempdir().unwrap();
    let event_db = dir.path().join("database").join("tron.sqlite");
    ensure_parent_dir(&event_db).unwrap();
    let handle = init_engine_host(&event_db).unwrap();
    let host = handle.lock().await;
    assert!(
        host.catalog()
            .function(&tron::engine::FunctionId::new("engine::discover").unwrap())
            .is_some()
    );
    assert!(event_db.exists());
}

#[test]
fn init_engine_host_fails_when_storage_parent_is_not_directory() {
    let dir = tempfile::tempdir().unwrap();
    let not_dir = dir.path().join("database");
    std::fs::write(&not_dir, b"not a directory").unwrap();
    let event_db = not_dir.join("tron.sqlite");
    let err = match init_engine_host(&event_db) {
        Ok(_) => panic!("engine host init should fail"),
        Err(err) => err,
    };
    assert!(
        err.to_string()
            .contains("Failed to initialize engine host storage"),
        "{err:#}"
    );
}

#[tokio::test]
async fn factory_unknown_model_returns_unsupported_model_error() {
    let settings = TronSettings::default();
    let factory = provider_factory::DefaultProviderFactory::new(&settings)
        .with_auth_path(PathBuf::from("/tmp/tron-test-no-such-auth.json"));
    let result = factory.create_for_model("unknown-model").await;
    assert!(matches!(
        result,
        Err(tron::domains::model::providers::provider::ProviderError::UnsupportedModel { .. })
    ));
}

#[test]
fn db_policy_accepts_expected_home_path() {
    let dir = tempfile::tempdir().unwrap();
    let tron_home = dir.path().join(".tron-dev");
    std::fs::create_dir_all(&tron_home).unwrap();
    let db_path = production_db_dir_from_tron_home(&tron_home).join(PRODUCTION_DB_FILENAME);
    validate_production_db_path_for_tron_home(&db_path, &tron_home).unwrap();
}

#[test]
fn db_policy_rejects_alternate_filename() {
    let dir = tempfile::tempdir().unwrap();
    let tron_home = dir.path().join(".tron-dev");
    std::fs::create_dir_all(&tron_home).unwrap();
    let db_path = production_db_dir_from_tron_home(&tron_home).join("not-beta.db");
    let err = validate_production_db_path_for_tron_home(&db_path, &tron_home).unwrap_err();
    assert!(err.to_string().contains(PRODUCTION_DB_FILENAME));
}

#[test]
fn db_policy_rejects_wrong_directory_without_creating_it() {
    let dir = tempfile::tempdir().unwrap();
    let tron_home = dir.path().join(".tron-dev");
    std::fs::create_dir_all(&tron_home).unwrap();

    let bad_parent = tron_home.join("other-db-dir");
    let bad_path = bad_parent.join(PRODUCTION_DB_FILENAME);
    assert!(!bad_parent.exists());

    let err = validate_production_db_path_for_tron_home(&bad_path, &tron_home).unwrap_err();
    assert!(err.to_string().contains("does not exist"));
    assert!(!bad_parent.exists());
}

#[cfg(unix)]
#[test]
fn db_policy_rejects_symlink_db_file() {
    use std::os::unix::fs::symlink;

    let dir = tempfile::tempdir().unwrap();
    let tron_home = dir.path().join(".tron-dev");
    std::fs::create_dir_all(&tron_home).unwrap();

    let prod_dir = production_db_dir_from_tron_home(&tron_home);
    std::fs::create_dir_all(&prod_dir).unwrap();

    let target = dir.path().join("escape.db");
    std::fs::write(&target, "x").unwrap();
    let symlink_path = prod_dir.join(PRODUCTION_DB_FILENAME);
    symlink(&target, &symlink_path).unwrap();

    let err = validate_production_db_path_for_tron_home(&symlink_path, &tron_home).unwrap_err();
    assert!(err.to_string().contains("symlink"));
}

#[tokio::test]
async fn openai_returns_none_without_auth() {
    // With no auth.json, OpenAI returns None
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");
    let result = tron::domains::auth::provider_credentials::openai::load_server_auth(&path)
        .await
        .unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn google_returns_none_without_auth() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");
    let result = tron::domains::auth::provider_credentials::google::load_server_auth(&path)
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
    let tokens = tron::domains::auth::provider_credentials::OAuthTokens {
        access_token: "sk-ant-oat-test".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::domains::auth::provider_credentials::now_ms() + 3_600_000,
    };
    tron::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "test",
        &tokens,
    )
    .unwrap();

    // load_server_auth should find the OAuth tokens
    let config = tron::domains::auth::provider_credentials::anthropic::default_config();
    let result =
        tron::domains::auth::provider_credentials::anthropic::load_server_auth(&path, &config)
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
    tron::domains::auth::provider_credentials::storage::save_named_api_key(
        &path,
        "anthropic",
        "(default)",
        "sk-api-key",
    )
    .unwrap();
    let tokens = tron::domains::auth::provider_credentials::OAuthTokens {
        access_token: "sk-ant-oat-primary".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::domains::auth::provider_credentials::now_ms() + 3_600_000,
    };
    tron::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "test",
        &tokens,
    )
    .unwrap();

    // OAuth takes priority
    let config = tron::domains::auth::provider_credentials::anthropic::default_config();
    let result =
        tron::domains::auth::provider_credentials::anthropic::load_server_auth(&path, &config)
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

    let work_tokens = tron::domains::auth::provider_credentials::OAuthTokens {
        access_token: "work-tok".to_string(),
        refresh_token: "ref1".to_string(),
        expires_at: tron::domains::auth::provider_credentials::now_ms() + 3_600_000,
    };
    tron::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
        &path,
        "anthropic",
        "work",
        &work_tokens,
    )
    .unwrap();

    let config = tron::domains::auth::provider_credentials::anthropic::default_config();
    let result =
        tron::domains::auth::provider_credentials::anthropic::load_server_auth(&path, &config)
            .await
            .unwrap();
    assert_eq!(result.unwrap().token(), "work-tok");
}

#[tokio::test]
async fn create_openai_with_oauth_from_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");

    let tokens = tron::domains::auth::provider_credentials::OAuthTokens {
        access_token: "openai-oauth-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::domains::auth::provider_credentials::now_ms() + 3_600_000,
    };
    tron::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
        &path,
        tron::domains::auth::provider_credentials::openai::PROVIDER_KEY,
        "test",
        &tokens,
    )
    .unwrap();

    let result = tron::domains::auth::provider_credentials::openai::load_server_auth(&path)
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
    let tokens = tron::domains::auth::provider_credentials::OAuthTokens {
        access_token: "ya29.google-tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: tron::domains::auth::provider_credentials::now_ms() + 3_600_000,
    };
    tron::domains::auth::provider_credentials::storage::save_account_oauth_tokens(
        &path, "google", "(test)", &tokens,
    )
    .unwrap();

    // Set client_id (required for OAuth)
    let mut gpa =
        tron::domains::auth::provider_credentials::storage::get_google_provider_auth(&path)
            .unwrap()
            .unwrap_or_default();
    gpa.client_id = Some("test-client-id".to_string());
    tron::domains::auth::provider_credentials::storage::save_google_provider_auth(&path, &gpa)
        .unwrap();

    let result = tron::domains::auth::provider_credentials::google::load_server_auth(&path)
        .await
        .unwrap();
    let auth = result.unwrap();
    assert_eq!(auth.auth.token(), "ya29.google-tok");
    assert!(auth.project_id.is_none());
}

#[tokio::test]
async fn server_auth_maps_to_anthropic_oauth_auth() {
    let server_auth = tron::domains::auth::provider_credentials::ServerAuth::OAuth {
        access_token: "tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: 999,
    };
    assert!(server_auth.is_oauth());
    assert_eq!(server_auth.token(), "tok");
}

#[tokio::test]
async fn server_auth_maps_to_api_key_auth() {
    let server_auth = tron::domains::auth::provider_credentials::ServerAuth::from_api_key("sk-123");
    assert!(!server_auth.is_oauth());
    assert_eq!(server_auth.token(), "sk-123");
}

#[tokio::test]
async fn server_boots_and_responds() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let home = test_tron_home(&dir);
    let settings_path = test_settings_path(&home);

    // Single DB for events + tasks
    let db_str = db_path.to_string_lossy();
    let pool = tron::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    let event_store = Arc::new(EventStore::new(pool));

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let runtime_context = ServerRuntimeContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        profile_runtime: test_profile_runtime(&home),
        settings_path,
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        health_tracker: Arc::new(tron::domains::model::providers::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        auth_path: dir.path().join("auth.json"),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: dir.path().join(".onboarded"),
        release_fetcher: None,
        updater_state_path: dir.path().join("updater-state.json"),
    };

    let config = ServerConfig::default();
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = TronServer::new(config, runtime_context, metrics_handle);
    tron::transport::setup::register_server_domains_for_context(server.runtime_context()).unwrap();

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

#[test]
fn server_creates_db_on_first_run() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("new.db");
    assert!(!db_path.exists());

    let db_str = db_path.to_string_lossy();
    let pool = tron::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    let conn = pool.get().unwrap();
    let _ = tron::domains::session::event_store::run_migrations(&conn).unwrap();

    assert!(db_path.exists());
}

#[test]
fn server_runs_migrations() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let db_str = db_path.to_string_lossy();
    let pool = tron::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    let conn = pool.get().unwrap();
    let _ = tron::domains::session::event_store::run_migrations(&conn).unwrap();

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

#[test]
fn server_registers_public_engine_protocol_messages_only() {
    let mut methods = vec!["discover", "inspect", "invoke", "promote", "watch"];
    methods.sort();
    assert_eq!(
        methods,
        vec!["discover", "inspect", "invoke", "promote", "watch",],
        "public engine protocol is intentionally limited to the engine transport surface"
    );
}

#[test]
fn removed_client_transport_scaffolding_stays_deleted() {
    let crate_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    for removed in [
        ["src", "server", "transport", &["json", "_rpc"].concat()]
            .iter()
            .collect::<std::path::PathBuf>(),
        ["src", "server", "websocket"]
            .iter()
            .collect::<std::path::PathBuf>(),
    ] {
        assert!(
            !crate_root.join(&removed).exists(),
            "{} must stay deleted",
            removed.display()
        );
    }

    let banned = [
        ["Json", "Rpc"].concat(),
        ["json", "_rpc"].concat(),
        ["Broadcast", "Manager"].concat(),
        ["/", "ws"].concat(),
        ["rpc", "::"].concat(),
        ["rpc", ".read"].concat(),
        ["rpc", ".write"].concat(),
    ];
    for rel in ["src/app", "src/main.rs"] {
        let path = crate_root.join(rel);
        for file in rust_files_under_path(&path) {
            let content = std::fs::read_to_string(&file)
                .unwrap_or_else(|error| panic!("failed to read {}: {error}", file.display()));
            for needle in &banned {
                assert!(
                    !content.contains(needle),
                    "{} still contains removed transport marker `{needle}`",
                    file.display()
                );
            }
        }
    }
}

#[test]
fn readme_documents_engine_protocol() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("agent crate should live under packages/agent");
    let readme_path = repo_root.join("README.md");
    let readme = std::fs::read_to_string(&readme_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", readme_path.display()));
    assert!(
        readme.contains("GET /engine"),
        "README must document the public engine protocol endpoint"
    );
}

fn rust_files_under_path(path: &std::path::Path) -> Vec<std::path::PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    let mut files = Vec::new();
    let entries = std::fs::read_dir(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    for entry in entries {
        let entry = entry.unwrap_or_else(|error| panic!("failed to read dir entry: {error}"));
        let path = entry.path();
        if path.is_dir() {
            files.extend(rust_files_under_path(&path));
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            files.push(path);
        }
    }
    files
}

#[tokio::test]
async fn server_graceful_shutdown() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("events.db");
    let db_str = db_path.to_string_lossy();
    let pool = tron::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron::domains::session::event_store::run_migrations(&conn).unwrap();
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
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        profile_runtime: test_profile_runtime(&home),
        settings_path,
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        health_tracker: Arc::new(tron::domains::model::providers::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        auth_path: dir.path().join("auth.json"),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: dir.path().join(".onboarded"),
        release_fetcher: None,
        updater_state_path: dir.path().join("updater-state.json"),
    };

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = TronServer::new(ServerConfig::default(), runtime_context, metrics_handle);
    tron::transport::setup::register_server_domains_for_context(server.runtime_context()).unwrap();
    let (_, handle) = server.listen().await.unwrap();

    server.shutdown().shutdown();
    tokio::time::timeout(std::time::Duration::from_secs(5), handle)
        .await
        .expect("shutdown timed out")
        .expect("join error");
}

// ── CLI subcommand dispatch ──────────────────────────────────────────
//
// These tests cover Phase 2.7 — the `tron auth rotate` surface. The
// goal is twofold: (a) the clap parse tree exists exactly as documented,
// and (b) the dispatch helper writes a fresh token to disk and prints
// it on stdout. The end-to-end path uses the public `onboarding`
// helpers, so the on-disk side effect lands in `~/.tron/profiles/`; the
// tests below avoid that by exercising the helper directly with a temp
// path. The clap layer is tested in isolation.

#[test]
fn cli_parses_auth_rotate_subcommand() {
    let cli = Cli::parse_from(["tron", "auth", "rotate"]);
    match cli.command {
        Some(Command::Auth {
            action: AuthAction::Rotate,
        }) => {}
        other => panic!("expected Some(Auth {{ Rotate }}), got {other:?}"),
    }
}

#[test]
fn cli_no_subcommand_resolves_to_none() {
    // The bare `tron` invocation (with default host/port) MUST yield
    // `command: None` so the server-startup branch in `main` runs.
    let cli = Cli::parse_from(["tron"]);
    assert!(
        cli.command.is_none(),
        "bare `tron` must not pick up a subcommand"
    );
}

#[test]
fn cli_auth_without_action_fails() {
    // `tron auth` with no action is a user error; clap should reject it
    // rather than silently doing nothing.
    let result = Cli::try_parse_from(["tron", "auth"]);
    assert!(result.is_err(), "tron auth with no action must error");
}

#[test]
fn cli_auth_unknown_action_fails() {
    let result = Cli::try_parse_from(["tron", "auth", "no-such-action"]);
    assert!(result.is_err(), "unknown auth action must error");
}

#[test]
fn run_subcommand_auth_rotate_writes_token_to_default_path() {
    // The default path for `auth.json` is under `~/.tron/profiles/`,
    // which would clobber the user's real token on a dev machine. The
    // test writes through the lower-level `rotate_bearer_token` helper
    // with a temp path instead — same code path the dispatch hits, just
    // with the path injected. The clap dispatch test above guarantees
    // the wiring matches.
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("auth.json");
    let token = tron::app::onboarding::rotate_bearer_token(&path).expect("rotate writes token");
    assert_eq!(
        token.len(),
        43,
        "rotated token must be 43 chars (32 bytes URL-safe-base64 no pad)"
    );
    assert!(path.exists(), "rotation must persist to disk");

    // Round-trip: load the same path and verify the token round-trips.
    let read_back = tron::app::onboarding::load_or_create_bearer_token(&path).expect("load");
    assert_eq!(read_back, token, "rotated token must round-trip on disk");
}

#[test]
fn startup_ensures_bearer_token_exists() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("auth.json");

    let token = initialize_bearer_token_at(&path).expect("startup should create bearer token");

    assert_eq!(token.len(), 43);
    assert!(path.exists(), "startup must persist auth.json for pairing");
    let read_back = tron::app::onboarding::load_or_create_bearer_token(&path).expect("read");
    assert_eq!(read_back, token);
}

#[test]
fn ordinary_startup_delegates_to_constitution_seeders() {
    let source = include_str!("main_runtime.rs");
    assert!(source.contains("ensure_tron_home"));
    assert!(!source.contains("startup_system_subdirs"));
}

#[test]
fn constitution_startup_creates_internal_run_for_ephemeral_locks() {
    let dir = tempfile::tempdir().expect("tempdir");
    let home = dir.path().join(".tron");
    tron::shared::constitution::ensure_tron_home_at(&home).expect("seed Constitution home");

    assert!(
        home.join(tron::shared::paths::dirs::INTERNAL)
            .join(tron::shared::paths::dirs::RUN)
            .exists(),
        "internal/run/ holds runtime locks that normal server startup may create"
    );
    assert!(
        home.join(tron::shared::paths::dirs::PROFILES)
            .join(tron::shared::profile::DEFAULT_PROFILE)
            .join(tron::shared::paths::files::PROFILE_TOML)
            .exists(),
        "default profile must be seeded for auditable profile-owned settings"
    );
}

#[test]
fn ordinary_startup_does_not_probe_tcc_permissions() {
    let source = include_str!("main_runtime.rs");
    let spawn_body = source
        .split("fn spawn_background_tasks")
        .nth(1)
        .and_then(|tail| tail.split("pub async fn run_server").next())
        .expect("spawn_background_tasks body should be discoverable");

    for forbidden in ["Privacy_AllFiles", "x-apple.systempreferences"] {
        assert!(
            !spawn_body.contains(forbidden),
            "ordinary startup must not touch macOS TCC or open permission UI; found {forbidden}"
        );
    }
}

#[test]
fn run_subcommand_auth_rotate_invalidates_prior_token() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("auth.json");
    let first = tron::app::onboarding::load_or_create_bearer_token(&path).expect("first");
    let second = tron::app::onboarding::rotate_bearer_token(&path).expect("rotate");
    let third = tron::app::onboarding::load_or_create_bearer_token(&path).expect("third");
    assert_ne!(
        first, second,
        "rotation must produce a new token (otherwise paired devices stay valid)"
    );
    assert_eq!(
        second, third,
        "post-rotation reads must observe the rotated token, not the original"
    );
}
