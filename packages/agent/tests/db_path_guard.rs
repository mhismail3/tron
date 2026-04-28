#![allow(missing_docs, unused_results)]

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use tron::settings::db_path_policy::{
    PRODUCTION_DB_FILENAME, production_db_dir_from_home, resolve_production_db_path_for_home,
    validate_production_db_path_for_home,
};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("packages/agent has a repo root")
        .to_path_buf()
}

fn setup_home() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    (dir, home)
}

fn file_signature(path: &Path) -> (u64, SystemTime) {
    let meta = std::fs::metadata(path).unwrap();
    (meta.len(), meta.modified().unwrap())
}

#[test]
fn accepts_default_log_db() {
    let (_tmp, home) = setup_home();
    let expected_dir = production_db_dir_from_home(&home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let resolved = resolve_production_db_path_for_home(None, &home).unwrap();
    assert_eq!(
        resolved.file_name().and_then(std::ffi::OsStr::to_str),
        Some(PRODUCTION_DB_FILENAME)
    );
    assert_eq!(
        resolved.parent().unwrap().canonicalize().unwrap(),
        expected_dir.canonicalize().unwrap()
    );
}

#[test]
fn rejects_alternate_filename() {
    let (_tmp, home) = setup_home();
    let expected_dir = production_db_dir_from_home(&home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let bad = expected_dir.join("wrong.db");
    let err = validate_production_db_path_for_home(&bad, &home).unwrap_err();
    assert!(err.to_string().contains(PRODUCTION_DB_FILENAME));
    assert!(!bad.exists());
}

#[cfg(unix)]
#[test]
fn rejects_symlink_escape_path() {
    use std::os::unix::fs::symlink;

    let (_tmp, home) = setup_home();
    let expected_dir = production_db_dir_from_home(&home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let outside = home.join("outside.db");
    std::fs::write(&outside, "do-not-touch").unwrap();
    let outside_before = file_signature(&outside);

    let symlink_path = expected_dir.join(PRODUCTION_DB_FILENAME);
    symlink(&outside, &symlink_path).unwrap();

    let err = validate_production_db_path_for_home(&symlink_path, &home).unwrap_err();
    assert!(err.to_string().contains("symlink"));
    assert_eq!(outside_before, file_signature(&outside));
}

#[test]
fn rejected_path_does_not_create_or_modify_db_files() {
    let (_tmp, home) = setup_home();
    let expected_dir = production_db_dir_from_home(&home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let sentinel = expected_dir.join(PRODUCTION_DB_FILENAME);
    std::fs::write(&sentinel, "sentinel").unwrap();
    let sentinel_before = file_signature(&sentinel);

    let bad_parent = home.join("other-dir");
    std::fs::create_dir_all(&bad_parent).unwrap();
    let rejected_path = bad_parent.join(PRODUCTION_DB_FILENAME);
    let err = resolve_production_db_path_for_home(Some(rejected_path.clone()), &home).unwrap_err();
    assert!(err.to_string().contains("only allows DBs under"));
    assert!(!rejected_path.exists());
    assert_eq!(sentinel_before, file_signature(&sentinel));
}

#[test]
fn startup_migrations_only_touch_log_db() {
    let (_tmp, home) = setup_home();
    let expected_dir = production_db_dir_from_home(&home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let untouched = expected_dir.join("other.db");
    std::fs::write(&untouched, "keep").unwrap();
    let untouched_before = file_signature(&untouched);

    let db_path = resolve_production_db_path_for_home(None, &home).unwrap();
    let conn = rusqlite::Connection::open(&db_path).unwrap();
    tron::events::run_migrations(&conn).unwrap();
    drop(conn);

    let db_meta = std::fs::metadata(&db_path).unwrap();
    assert!(
        db_meta.len() > 0,
        "log.db should contain schema after migration"
    );
    assert_eq!(untouched_before, file_signature(&untouched));
}

#[test]
fn contributor_scripts_keep_runtime_artifacts_under_system_run() {
    let root = repo_root();
    let scripts = [
        root.join("scripts/tron-lib.sh"),
        root.join("scripts/tron"),
        root.join("scripts/tron-cli"),
        root.join("scripts/auto-deploy"),
    ];

    for script in scripts {
        let body = std::fs::read_to_string(&script)
            .unwrap_or_else(|e| panic!("read {}: {e}", script.display()));
        assert!(
            !body.contains("system/deployment"),
            "{} must not recreate the old deployment directory",
            script.display()
        );
    }

    let tron_lib = std::fs::read_to_string(root.join("scripts/tron-lib.sh")).unwrap();
    assert!(tron_lib.contains("RUN_DIR=\"$TRON_HOME/system/run\""));
    assert!(tron_lib.contains("CONTRIBUTOR_DIR=\"$RUN_DIR\""));
    assert!(tron_lib.contains("DEV_BUNDLE=\"$RUN_DIR/Tron-Dev.app\""));
}

#[test]
fn mac_bundle_script_loads_gitignored_local_relay_env() {
    let root = repo_root();
    let script_path = root.join("packages/mac-app/scripts/bundle-agent.sh");
    let script = std::fs::read_to_string(&script_path).unwrap();

    assert!(
        script.contains("LOCAL_ENV_FILE=\"$SCRIPT_DIR/../.env.local\""),
        "{} should use the mac app's ignored local env file",
        script_path.display()
    );
    assert!(script.contains("load_local_relay_env"));
    assert!(script.contains("TRON_RELAY_URL"));
    assert!(script.contains("TRON_RELAY_SECRET"));
    assert!(script.contains("TRON_RELAY_ENVIRONMENT"));

    let gitignore = std::fs::read_to_string(root.join(".gitignore")).unwrap();
    assert!(
        gitignore.lines().any(|line| line.trim() == ".env.local"),
        "packages/mac-app/.env.local must stay gitignored because it can contain relay secrets"
    );
}
