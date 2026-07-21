use super::*;
use crate::domains::session::event_store::ConnectionConfig;

mod cli;
mod database;
mod provider_auth;
mod server_runtime;

/// Small pool size for tests - prevents FD exhaustion when many tests
/// run in parallel, each opening a file-backed `SQLite` pool.
fn test_db_config() -> ConnectionConfig {
    ConnectionConfig {
        pool_size: 2,
        ..ConnectionConfig::default()
    }
}

fn test_tron_home(dir: &tempfile::TempDir) -> std::path::PathBuf {
    let home = dir.path().join(".tron");
    crate::shared::foundation::home::ensure_tron_home_at(&home).unwrap();
    home
}

fn test_settings_path(home: &std::path::Path) -> std::path::PathBuf {
    crate::shared::foundation::paths::settings_path_for_home(home)
}

fn test_settings_runtime(
    home: &std::path::Path,
) -> std::sync::Arc<crate::domains::settings::SettingsRuntime> {
    std::sync::Arc::new(crate::domains::settings::SettingsRuntime::load(home).unwrap())
}

#[tokio::test]
async fn process_shutdown_runs_agent_cleanup_before_drain() {
    let context = crate::shared::server::test_support::make_test_context();
    let orchestrator = Arc::clone(&context.orchestrator);
    let run = orchestrator
        .begin_run("shutdown-session", "shutdown-run")
        .expect("active run");
    let cancelled = run.cancel_token();
    let shutdown = Arc::new(ShutdownCoordinator::new());

    register_agent_shutdown(&shutdown, Arc::clone(&orchestrator));
    shutdown
        .graceful_shutdown(vec![], Some(std::time::Duration::from_secs(2)))
        .await;

    assert!(cancelled.is_cancelled());
    assert_eq!(orchestrator.active_run_count(), 0);
}
