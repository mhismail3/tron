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
    crate::shared::foundation::paths::settings_path_for_home(home)
}

fn test_settings_runtime(
    home: &std::path::Path,
) -> std::sync::Arc<crate::domains::settings::SettingsRuntime> {
    std::sync::Arc::new(crate::domains::settings::SettingsRuntime::load(home).unwrap())
}

#[test]
fn bootstrap_snapshots_legacy_settings_before_retirement() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join(".tron");
    let profiles = home.join(crate::shared::foundation::paths::dirs::PROFILES);
    std::fs::create_dir_all(profiles.join("user")).unwrap();
    std::fs::write(profiles.join("active.toml"), "active = \"user\"\n").unwrap();
    let legacy = "[settings]\nautonomousWorkers = true\n";
    std::fs::write(profiles.join("user/profile.toml"), legacy).unwrap();
    std::fs::write(
        profiles.join("auth.json"),
        "{\"bearerToken\":\"test-token\"}\n",
    )
    .unwrap();

    init_directories_at(&home).unwrap();

    let settings =
        crate::domains::settings::load_settings_from_path(&test_settings_path(&home)).unwrap();
    assert!(settings.autonomous_workers);
    assert!(!profiles.join("active.toml").exists());
    assert!(!profiles.join("user").exists());
    assert_eq!(
        std::fs::read_to_string(profiles.join("auth.json")).unwrap(),
        "{\"bearerToken\":\"test-token\"}\n"
    );

    let snapshots = home
        .join(crate::shared::foundation::paths::dirs::INTERNAL)
        .join(crate::shared::foundation::paths::dirs::SNAPSHOTS);
    let snapshot = std::fs::read_dir(snapshots)
        .unwrap()
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .find(|path| path.is_dir() && path.join("manifest.json").is_file())
        .expect("bootstrap must publish a verified snapshot before retirement");
    assert_eq!(
        std::fs::read_to_string(snapshot.join("profiles/user/profile.toml")).unwrap(),
        legacy
    );
}
