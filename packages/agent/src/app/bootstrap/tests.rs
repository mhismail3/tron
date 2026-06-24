use super::*;
use crate::domains::session::event_store::ConnectionConfig;

mod cli;
mod database;
mod provider_auth;
mod server_runtime;
mod source_guards;

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
    crate::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

fn test_settings_path(home: &std::path::Path) -> std::path::PathBuf {
    home.join(crate::shared::foundation::paths::dirs::PROFILES)
        .join(crate::shared::foundation::profile::USER_PROFILE)
        .join(crate::shared::foundation::paths::files::PROFILE_TOML)
}

fn test_profile_runtime(
    home: &std::path::Path,
) -> std::sync::Arc<crate::domains::agent::r#loop::ProfileRuntime> {
    std::sync::Arc::new(crate::domains::agent::r#loop::ProfileRuntime::load(home).unwrap())
}
