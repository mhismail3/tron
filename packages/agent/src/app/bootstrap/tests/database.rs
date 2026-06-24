use super::*;
use crate::domains::settings::db_path_policy::{
    PRODUCTION_DB_FILENAME, default_production_db_path, production_db_dir_from_tron_home,
    validate_production_db_path_for_tron_home,
};

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
            .function(&crate::engine::FunctionId::new("engine::discover").unwrap())
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
#[test]
fn auth_path_under_tron_dir() {
    let path = auth_path();
    assert!(path.to_string_lossy().contains(".tron"));
    assert!(path.to_string_lossy().ends_with("auth.json"));
}
#[test]
fn server_creates_db_on_first_run() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("new.db");
    assert!(!db_path.exists());

    let db_str = db_path.to_string_lossy();
    let pool = crate::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    let conn = pool.get().unwrap();
    let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();

    assert!(db_path.exists());
}

#[test]
fn server_runs_migrations() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let db_str = db_path.to_string_lossy();
    let pool = crate::domains::session::event_store::new_file(&db_str, &test_db_config()).unwrap();
    let conn = pool.get().unwrap();
    let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();

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
