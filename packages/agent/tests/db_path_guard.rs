#![allow(missing_docs, unused_results)]

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use tron::domains::settings::db_path_policy::{
    PRODUCTION_DB_FILENAME, production_db_dir_from_home, resolve_production_db_path_for_home,
    validate_production_db_path_for_home,
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
fn startup_migrations_only_touch_tron_sqlite() {
    let (_tmp, home) = setup_home();
    let expected_dir = production_db_dir_from_home(&home);
    std::fs::create_dir_all(&expected_dir).unwrap();

    let untouched = expected_dir.join("other.db");
    std::fs::write(&untouched, "keep").unwrap();
    let untouched_before = file_signature(&untouched);

    let db_path = resolve_production_db_path_for_home(None, &home).unwrap();
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
fn contributor_scripts_keep_runtime_artifacts_under_internal_run() {
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
    assert!(tron_lib.contains("RUN_DIR=\"$TRON_HOME/internal/run\""));
    assert!(tron_lib.contains("CONTRIBUTOR_DIR=\"$RUN_DIR\""));
    assert!(tron_lib.contains("DEV_BUNDLE=\"$RUN_DIR/Tron-Dev.app\""));
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
        root.join("packages/agent/skills"),
        root.join("packages/agent/src"),
        root.join("packages/ios-app/Sources"),
        root.join("packages/mac-app/Sources"),
        root.join("packages/mac-app/docs"),
        root.join("scripts"),
    ];
    let old_patterns = [
        "~/.tron/system/",
        ".tron/system/",
        "system/database",
        "system/settings.json",
        "system/auth.json",
        "system/run",
        "system/transcription",
        "workspace/memory",
        "workspace/artifacts",
        "artifacts/renders",
        "artifacts/screenshots",
        "artifacts/exports",
        "exports_dir",
        "dirs::ARTIFACTS",
        "dirs::EXPORTS",
        "~/.tron/settings",
        "~/.tron/knowledge/",
        "~/.tron/vault/",
        "~/.tron/instructions",
        "~/.tron/user",
        "master-default",
        "~/.tron/auto-update.pause",
        "~/.tron/auto-deploy.pause",
        "~/.tron/deploy.lock",
        "~/.tron/auto-deploy.lock",
        "~/.tron/tools/json-render",
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
        for pattern in old_patterns {
            if body.contains(pattern) {
                violations.push(format!("{relative}: contains {pattern}"));
            }
        }
    }

    assert!(
        violations.is_empty(),
        "old Tron Home paths must not appear in runtime, defaults, docs, skills, or scripts:\n{}",
        violations.join("\n")
    );
}

#[test]
fn runtime_does_not_use_global_active_profile_helpers() {
    let root = repo_root();
    let scan_roots = [
        root.join("packages/agent/src/domains/cron"),
        root.join("packages/agent/src/domains/model/providers"),
        root.join("packages/agent/src/domains/agent/runner"),
        root.join("packages/agent/src/app"),
        root.join("packages/agent/src/domains/capability_support"),
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
        collect_text_files(&scan_root, &mut files);
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

#[test]
fn tron_dev_loads_same_gitignored_local_relay_env() {
    let root = repo_root();
    let script_path = root.join("scripts/tron");
    let script = std::fs::read_to_string(&script_path).unwrap();

    assert!(
        script.contains("MAC_APP_LOCAL_ENV_FILE=\"$PROJECT_DIR/packages/mac-app/.env.local\""),
        "{} should use the same ignored relay env file as the Mac bundle build",
        script_path.display()
    );
    assert!(script.contains("load_dev_relay_env"));
    assert!(script.contains("prepare_dev_relay_env"));
    assert!(script.contains("TRON_RELAY_URL"));
    assert!(script.contains("TRON_RELAY_SECRET"));
    assert!(script.contains("TRON_RELAY_ENVIRONMENT"));
    assert!(
        script.matches("prepare_dev_relay_env").count() >= 3,
        "dev build, foreground takeover, and background takeover must all load relay env"
    );
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

    assert!(
        body.contains("attempting public-link auto-discovery"),
        "stale public TestFlight group config should fall back to ASC public-link discovery"
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
