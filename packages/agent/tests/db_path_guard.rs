#![allow(missing_docs, unused_results)]

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use tron::domains::settings::db_path_policy::{
    PRODUCTION_DB_FILENAME, production_db_dir_from_tron_home,
    resolve_production_db_path_for_tron_home, validate_production_db_path_for_tron_home,
};

fn repo_relative(path: &Path) -> String {
    path.strip_prefix(repo_root())
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("packages/agent has a repo root")
        .to_path_buf()
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_root().join(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn sqlite_table_names(source: &str) -> BTreeSet<String> {
    const MARKER: &str = "CREATE TABLE IF NOT EXISTS ";
    source
        .lines()
        .filter_map(|line| {
            let rest = line.split_once(MARKER)?.1;
            let table_name: String = rest
                .chars()
                .take_while(|ch| ch.is_ascii_alphanumeric() || *ch == '_')
                .collect();
            (!table_name.is_empty()).then_some(table_name)
        })
        .collect()
}

fn project_reference_database_table_names() -> BTreeSet<String> {
    let reference = read_repo_file("packages/agent/docs/project-reference.md");
    let table_section = reference
        .split_once("### Tables\n")
        .expect("project reference must document the database tables")
        .1;
    let mut names = BTreeSet::new();
    let mut rows_started = false;
    for line in table_section.lines() {
        if line.trim().is_empty() && rows_started {
            break;
        }
        if !line.starts_with('|') || line.starts_with("| Table") || line.starts_with("|---") {
            continue;
        }
        rows_started = true;
        let table_cell = line
            .split('|')
            .nth(1)
            .expect("database table row must have a name cell");
        names.extend(table_cell.split('`').skip(1).step_by(2).map(str::to_owned));
    }
    names
}

fn setup_tron_home() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let tron_home = dir.path().join(".tron-dev");
    std::fs::create_dir_all(&tron_home).unwrap();
    (dir, tron_home)
}

fn file_signature(path: &Path) -> (u64, SystemTime) {
    let meta = std::fs::metadata(path).unwrap();
    (meta.len(), meta.modified().unwrap())
}

fn collect_text_files(path: &Path, files: &mut Vec<PathBuf>) {
    if path.is_file() {
        files.push(path.to_path_buf());
        return;
    }

    for entry in std::fs::read_dir(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
    {
        let entry = entry.unwrap();
        let child = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if child.is_dir()
            && matches!(
                name.as_ref(),
                "target" | ".build" | "DerivedData" | "node_modules"
            )
        {
            continue;
        }
        if child.is_dir() || child.is_file() {
            collect_text_files(&child, files);
        }
    }
}

#[test]
fn accepts_default_tron_sqlite() {
    let (_tmp, tron_home) = setup_tron_home();
    let expected_dir = production_db_dir_from_tron_home(&tron_home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let resolved = resolve_production_db_path_for_tron_home(None, &tron_home).unwrap();
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
fn resolved_tron_home_is_not_nested_under_dot_tron_again() {
    let (_tmp, tron_home) = setup_tron_home();
    let expected = tron_home
        .join("internal")
        .join("database")
        .join(PRODUCTION_DB_FILENAME);

    let resolved = resolve_production_db_path_for_tron_home(None, &tron_home).unwrap();

    assert_eq!(resolved.file_name(), expected.file_name());
    assert_eq!(
        resolved.parent().unwrap(),
        expected.parent().unwrap().canonicalize().unwrap()
    );
    assert!(
        !resolved.to_string_lossy().contains(".tron-dev/.tron/"),
        "isolated homes must not be forced back under production .tron: {}",
        resolved.display()
    );
}

#[test]
fn rejects_alternate_filename() {
    let (_tmp, tron_home) = setup_tron_home();
    let expected_dir = production_db_dir_from_tron_home(&tron_home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let bad = expected_dir.join("wrong.db");
    let err = validate_production_db_path_for_tron_home(&bad, &tron_home).unwrap_err();
    assert!(err.to_string().contains(PRODUCTION_DB_FILENAME));
    assert!(!bad.exists());
}

#[cfg(unix)]
#[test]
fn rejects_symlink_escape_path() {
    use std::os::unix::fs::symlink;

    let (_tmp, tron_home) = setup_tron_home();
    let expected_dir = production_db_dir_from_tron_home(&tron_home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let outside = tron_home.join("outside.db");
    std::fs::write(&outside, "do-not-touch").unwrap();
    let outside_before = file_signature(&outside);

    let symlink_path = expected_dir.join(PRODUCTION_DB_FILENAME);
    symlink(&outside, &symlink_path).unwrap();

    let err = validate_production_db_path_for_tron_home(&symlink_path, &tron_home).unwrap_err();
    assert!(err.to_string().contains("symlink"));
    assert_eq!(outside_before, file_signature(&outside));
}

#[test]
fn rejected_path_does_not_create_or_modify_db_files() {
    let (_tmp, tron_home) = setup_tron_home();
    let expected_dir = production_db_dir_from_tron_home(&tron_home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let sentinel = expected_dir.join(PRODUCTION_DB_FILENAME);
    std::fs::write(&sentinel, "sentinel").unwrap();
    let sentinel_before = file_signature(&sentinel);

    let bad_parent = tron_home.join("other-dir");
    std::fs::create_dir_all(&bad_parent).unwrap();
    let rejected_path = bad_parent.join(PRODUCTION_DB_FILENAME);
    let err = resolve_production_db_path_for_tron_home(Some(rejected_path.clone()), &tron_home)
        .unwrap_err();
    assert!(err.to_string().contains("only allows DBs under"));
    assert!(!rejected_path.exists());
    assert_eq!(sentinel_before, file_signature(&sentinel));
}

#[test]
fn startup_migrations_only_touch_tron_sqlite() {
    let (_tmp, tron_home) = setup_tron_home();
    let expected_dir = production_db_dir_from_tron_home(&tron_home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let untouched = expected_dir.join("other.db");
    std::fs::write(&untouched, "keep").unwrap();
    let untouched_before = file_signature(&untouched);

    let db_path = resolve_production_db_path_for_tron_home(None, &tron_home).unwrap();
    let conn = rusqlite::Connection::open(&db_path).unwrap();
    tron::domains::session::event_store::run_migrations(&conn).unwrap();
    drop(conn);

    let db_meta = std::fs::metadata(&db_path).unwrap();
    assert!(
        db_meta.len() > 0,
        "tron.sqlite should contain schema after migration"
    );
    assert_eq!(untouched_before, file_signature(&untouched));
}

#[test]
fn project_reference_database_table_catalog_matches_active_sqlite_sources() {
    let schema_sources = [
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_codec.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/resources/store/sqlite_codec.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/authority/compensation.rs",
    ];
    let source_tables = schema_sources
        .into_iter()
        .flat_map(|path| {
            let tables = sqlite_table_names(&read_repo_file(path));
            assert!(
                !tables.is_empty(),
                "schema source declares no tables: {path}"
            );
            tables
        })
        .collect();

    assert_eq!(
        project_reference_database_table_names(),
        source_tables,
        "project-reference database catalog must match active SQLite schema owners"
    );
}

#[test]
fn contributor_scripts_keep_runtime_artifacts_under_internal_run() {
    let root = repo_root();
    let scripts = [
        root.join("scripts/tron-lib.sh"),
        root.join("scripts/tron"),
        root.join("scripts/tron-cli"),
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
    assert!(tron_lib.contains("RUN_DIR=\"$TRON_HOME/internal/run\""));
    assert!(tron_lib.contains("CONTRIBUTOR_DIR=\"$RUN_DIR\""));
    assert!(tron_lib.contains("DEV_BUNDLE=\"$RUN_DIR/Tron-Dev.app\""));
}

#[test]
fn runtime_owners_do_not_delete_unified_storage_ad_hoc() {
    let root = repo_root();
    assert!(
        !root.join("scripts/reset-db").exists(),
        "database-only reset scripts cannot preserve unified storage integrity"
    );

    let mut files = Vec::new();
    collect_text_files(&root.join("scripts"), &mut files);
    for file in files {
        let Ok(body) = std::fs::read_to_string(&file) else {
            continue;
        };
        let relative = repo_relative(&file);
        for forbidden in [
            "rm -rf \"$TRON_HOME\"",
            "rm -rf \"${TRON_HOME}\"",
            "rm -rf ~/.tron",
            "rm -rf \"$HOME/.tron\"",
        ] {
            assert!(
                !body.contains(forbidden),
                "{} must not mutate unified runtime storage through {forbidden}",
                relative
            );
        }
        let owns_runtime_storage = matches!(
            relative.as_str(),
            "scripts/tron" | "scripts/tron-cli" | "scripts/tron-lib.sh"
        ) || relative.starts_with("scripts/tron.d/")
            || relative.starts_with("scripts/tron-lib.d/");
        if owns_runtime_storage {
            for forbidden in ["PRAGMA foreign_keys = OFF", "DELETE FROM "] {
                assert!(
                    !body.contains(forbidden),
                    "{relative} must not mutate the runtime database through {forbidden}"
                );
            }
        }
    }

    let mut rust_files = Vec::new();
    collect_text_files(&root.join("packages/agent/src"), &mut rust_files);
    for file in rust_files {
        let Ok(body) = std::fs::read_to_string(&file) else {
            continue;
        };
        let compact: String = body.chars().filter(|ch| !ch.is_whitespace()).collect();
        assert!(
            !(compact.contains("remove_dir_all(") && compact.contains("paths::tron_home")),
            "{} must not recursively delete the resolved Tron home",
            repo_relative(&file)
        );
    }
}

#[test]
fn retired_tron_home_paths_are_absent() {
    let root = repo_root();
    let scan_roots = [
        root.join("AGENTS.md"),
        root.join(".claude"),
        root.join("README.md"),
        root.join("CONTRIBUTING.md"),
        root.join("packages/agent/defaults"),
        root.join("packages/agent/docs"),
        root.join("packages/agent/src"),
        root.join("packages/ios-app/Sources"),
        root.join("packages/mac-app/Sources"),
        root.join("packages/mac-app/docs"),
        root.join("scripts"),
    ];
    let old_patterns = vec![
        "~/.tron/system/".to_owned(),
        ".tron/system/".to_owned(),
        "system/database".to_owned(),
        "system/settings.json".to_owned(),
        "system/auth.json".to_owned(),
        "system/run".to_owned(),
        ["system/", "trans", "cription"].concat(),
        "workspace/memory".to_owned(),
        "workspace/artifacts".to_owned(),
        "artifacts/renders".to_owned(),
        "artifacts/screenshots".to_owned(),
        "artifacts/exports".to_owned(),
        "exports_dir".to_owned(),
        "dirs::ARTIFACTS".to_owned(),
        "dirs::EXPORTS".to_owned(),
        "~/.tron/settings".to_owned(),
        "~/.tron/knowledge/".to_owned(),
        "~/.tron/vault/".to_owned(),
        "~/.tron/instructions".to_owned(),
        "~/.tron/user".to_owned(),
        "master-default".to_owned(),
        "~/.tron/deploy.lock".to_owned(),
        concat!("~/.tron/", "to", "ols", "/json-render").to_owned(),
    ];
    let mut files = Vec::new();
    for scan_root in scan_roots {
        if scan_root.exists() {
            collect_text_files(&scan_root, &mut files);
        }
    }

    let mut violations = Vec::new();
    for file in files {
        let relative = repo_relative(&file);
        let Ok(body) = std::fs::read_to_string(&file) else {
            continue;
        };
        for pattern in &old_patterns {
            if body.contains(pattern) {
                violations.push(format!("{relative}: contains {pattern}"));
            }
        }
    }

    assert!(
        violations.is_empty(),
        "old Tron Home paths must not appear in runtime, defaults, docs, or scripts:\n{}",
        violations.join("\n")
    );
}

#[test]
fn runtime_does_not_use_global_active_profile_helpers() {
    let root = repo_root();
    let scan_roots = [
        root.join("packages/agent/src/domains/model/providers"),
        root.join("packages/agent/src/domains/agent/loop"),
        root.join("packages/agent/src/domains/agent/context"),
        root.join("packages/agent/src/app"),
    ];
    let forbidden = [
        "active_execution_spec(",
        "active_process_spec(",
        "resolve_active_profile(",
        "instruction_prompts::entrypoint_prompt",
        "instruction_prompts::process_prompt",
        "instruction_prompts::provider_prompt",
        "ContextPolicy::from_provider(",
        "local_model_tools(",
    ];

    let mut files = Vec::new();
    for scan_root in scan_roots {
        if scan_root.exists() {
            collect_text_files(&scan_root, &mut files);
        }
    }

    let mut violations = Vec::new();
    for file in files {
        let relative = repo_relative(&file);
        let Ok(body) = std::fs::read_to_string(&file) else {
            continue;
        };
        for pattern in forbidden {
            if body.contains(pattern) {
                violations.push(format!("{relative}: contains {pattern}"));
            }
        }
    }

    assert!(
        violations.is_empty(),
        "runtime must consume ProfileRuntime/session/process plans, not global active-profile helpers:\n{}",
        violations.join("\n")
    );
}

#[test]
fn mac_bundle_script_has_no_push_relay_build_plane() {
    let root = repo_root();
    let script_path = root.join("packages/mac-app/scripts/bundle-agent.sh");
    let script = std::fs::read_to_string(&script_path).unwrap();

    assert!(!script.contains("TRON_RELAY"));
    assert!(!script.contains("relay"));
    assert!(!script.contains(".env.local"));
}

#[test]
fn tron_dev_loads_only_private_push_relay_runtime_configuration() {
    let root = repo_root();
    let script_path = root.join("scripts/tron");
    let workspace_script_path = root.join("scripts/tron.d/workspace.sh");
    let dev_script_path = root.join("scripts/tron.d/dev.sh");
    let script = std::fs::read_to_string(&script_path).unwrap();
    let workspace_script = std::fs::read_to_string(&workspace_script_path).unwrap();
    let dev_script = std::fs::read_to_string(&dev_script_path).unwrap();

    assert!(!script.contains("MAC_APP_LOCAL_ENV_FILE"));
    assert!(!workspace_script.contains("TRON_RELAY"));
    assert!(!workspace_script.contains("relay"));
    assert!(dev_script.contains("packages/mac-app/.env.local"));
    assert!(dev_script.contains("TRON_RELAY_URL|TRON_RELAY_SECRET"));
    assert!(
        dev_script.contains("TRON_RELAY_URL and TRON_RELAY_SECRET must be configured together")
    );
    assert!(dev_script.contains("chmod 600 \"$DEV_PLIST_PATH\""));
    assert!(!dev_script.contains("TRON_APNS_KEY"));
    assert!(!dev_script.contains("TRON_APNS_KEY_ID"));
    assert!(!dev_script.contains("TRON_APNS_TEAM_ID"));
}

#[test]
fn mac_release_workflow_notarizes_dmg_before_stapling() {
    let root = repo_root();
    let workflow_path = root.join(".github/workflows/release-mac.yml");
    let workflow = std::fs::read_to_string(&workflow_path).unwrap();

    let sign_dmg = workflow
        .find("- name: Sign DMG")
        .unwrap_or_else(|| panic!("{} should sign the DMG", workflow_path.display()));
    let notarize_dmg = workflow.find("- name: Notarize DMG").unwrap_or_else(|| {
        panic!(
            "{} should notarize the signed DMG before stapling it",
            workflow_path.display()
        )
    });
    let staple_dmg = workflow
        .find("- name: Staple DMG")
        .unwrap_or_else(|| panic!("{} should staple the DMG", workflow_path.display()));

    assert!(
        sign_dmg < notarize_dmg && notarize_dmg < staple_dmg,
        "{} should run Sign DMG -> Notarize DMG -> Staple DMG",
        workflow_path.display()
    );
    assert!(
        workflow[notarize_dmg..staple_dmg].contains("xcrun notarytool submit"),
        "Notarize DMG step should submit the signed DMG to Apple"
    );
    assert!(
        workflow[notarize_dmg..staple_dmg].contains("${{ steps.dmg.outputs.dmg_path }}"),
        "Notarize DMG step should submit the generated DMG artifact"
    );
}

#[test]
fn ios_release_workflow_does_not_block_on_internal_testflight_group() {
    let root = repo_root();
    let workflow_path = root.join(".github/workflows/release-ios.yml");
    let workflow = std::fs::read_to_string(&workflow_path).unwrap();

    let validate = workflow
        .find("- name: Validate TestFlight groups")
        .unwrap_or_else(|| {
            panic!(
                "{} should validate TestFlight groups",
                workflow_path.display()
            )
        });
    let distribute = workflow
        .find("- name: Distribute to TestFlight groups")
        .unwrap_or_else(|| {
            panic!(
                "{} should distribute processed builds to TestFlight groups",
                workflow_path.display()
            )
        });
    let body = &workflow[validate..distribute];

    assert_eq!(
        body.matches("asc testflight groups list").count(),
        1,
        "current Homebrew asc must be the single TestFlight group-list owner"
    );
    assert!(
        !body.contains("asc testflight beta-groups list"),
        "release workflow must not retain a legacy asc command-shape fallback"
    );
    assert!(
        body.contains("attempting public-link auto-discovery"),
        "stale public TestFlight group config should use ASC public-link discovery"
    );
    assert!(
        body.contains("no public TestFlight group id resolved; skipping API group assignment"),
        "unresolvable TestFlight group config should not fail an uploaded/processed release"
    );
    assert!(
        body.contains("::warning::ASC_TESTFLIGHT_INTERNAL_GROUP_ID"),
        "stale internal TestFlight group config should warn instead of failing release"
    );
    assert!(
        !body.contains("::error::ASC_TESTFLIGHT_INTERNAL_GROUP_ID"),
        "internal TestFlight group validation must not block an otherwise successful public release"
    );
    assert!(
        body.contains("echo \"external_group_ids=$public_group_id\""),
        "workflow should publish only the resolved public TestFlight group through the ASC API"
    );
}
