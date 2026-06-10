//! Static gates for the State Ownership And Lifecycle campaign.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str = "packages/agent/docs/state-ownership-lifecycle-scorecard.md";
const EVIDENCE_PATH: &str = "packages/agent/docs/state-ownership-lifecycle-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/state-ownership-lifecycle-inventory.md";
const INVENTORY_TSV_PATH: &str = "packages/agent/docs/state-ownership-lifecycle-inventory.tsv";
const INVARIANT_TEST_PATH: &str = "packages/agent/tests/state_ownership_lifecycle_invariants.rs";

const INVENTORY_HEADER: &str = "path\tlanguage\tstate_surface\towner\tstate_class\tscope\tcreation_path\tmutation_boundary\thydration_or_reconstruction\tretirement_or_retention\tconcurrency_or_task_guard\tsol_rows";

const STATEFUL_MARKERS: &[&str] = &[
    "Mutex",
    "RwLock",
    "DashMap",
    "OnceLock",
    "ArcSwap",
    "Atomic",
    "tokio::spawn",
    "JoinHandle",
    "Task",
    "UserDefaults",
    "Keychain",
    "SQLite",
    "Store",
    "Repository",
    "cached",
    "pending",
    "cursor",
    "active",
    "status",
];

const ALLOWED_STATE_CLASSES: &[&str] = &[
    "canonical_truth",
    "durable_substrate",
    "projection_cache",
    "ephemeral_runtime",
    "local_device_preference",
    "secret",
    "diagnostic_buffer",
    "test_fixture",
];

#[derive(Debug)]
struct InventoryRow {
    path: String,
    language: String,
    state_surface: String,
    owner: String,
    state_class: String,
    scope: String,
    creation_path: String,
    mutation_boundary: String,
    hydration_or_reconstruction: String,
    retirement_or_retention: String,
    concurrency_or_task_guard: String,
    sol_rows: String,
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn assert_contains_in_order(name: &str, text: &str, needles: &[&str]) {
    let mut offset = 0;
    for needle in needles {
        let Some(index) = text[offset..].find(needle) else {
            panic!("{name} missing `{needle}` after byte offset {offset}");
        };
        offset += index + needle.len();
    }
}

fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn is_production_rust_or_swift(path: &str) -> bool {
    let is_rust = path.starts_with("packages/agent/src/") && path.ends_with(".rs");
    let is_swift = path.starts_with("packages/ios-app/Sources/") && path.ends_with(".swift");
    (is_rust || is_swift)
        && !path.contains("/tests/")
        && !path.ends_with("/tests.rs")
        && !path.ends_with("/test_utils.rs")
}

fn marker_paths() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| is_production_rust_or_swift(path))
        .filter(|path| repo_path(path).is_file())
        .filter(|path| {
            let text = read_repo_file(path);
            STATEFUL_MARKERS.iter().any(|marker| text.contains(marker))
        })
        .collect()
}

fn parse_inventory() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header = lines.next().expect("inventory TSV must have a header");
    assert_eq!(header, INVENTORY_HEADER, "SOL inventory TSV header changed");

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                12,
                "inventory row {} must have 12 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                path: columns[0].to_owned(),
                language: columns[1].to_owned(),
                state_surface: columns[2].to_owned(),
                owner: columns[3].to_owned(),
                state_class: columns[4].to_owned(),
                scope: columns[5].to_owned(),
                creation_path: columns[6].to_owned(),
                mutation_boundary: columns[7].to_owned(),
                hydration_or_reconstruction: columns[8].to_owned(),
                retirement_or_retention: columns[9].to_owned(),
                concurrency_or_task_guard: columns[10].to_owned(),
                sol_rows: columns[11].to_owned(),
            }
        })
        .collect()
}

fn inventory_by_path() -> BTreeMap<String, Vec<InventoryRow>> {
    let mut rows_by_path: BTreeMap<String, Vec<InventoryRow>> = BTreeMap::new();
    for row in parse_inventory() {
        rows_by_path.entry(row.path.clone()).or_default().push(row);
    }
    rows_by_path
}

#[test]
fn sol_campaign_harness_exists() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# State Ownership And Lifecycle Scorecard",
        "Current score:",
        "Status: **active**",
        "Total weight: **100**",
        "| SOL-0 | Campaign harness, red static gate, README links, scorecard/evidence/inventory scaffolding | 5 | passed_after_fix |",
        "| SOL-1 | Whole-repo state inventory for Rust server, iOS app, scripts/CI state, docs-owned state claims | 10 |",
        "| SOL-8 | iOS projection and local state lifecycle | 14 |",
        "| SOL-10 | Final closeout | 3 |",
        "SessionManager::plan_mode",
        "Engine compensation records",
        "iOS local-only state surfaces",
        "cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture",
    ] {
        assert!(
            scorecard.contains(required),
            "SOL scorecard missing required text: {required}"
        );
    }

    for required in [
        "# State Ownership And Lifecycle Evidence Manifest",
        "Current score:",
        "| SOL-0 | passed_after_fix |",
        "| SOL-10 | pending |",
        "## SOL-0 Evidence",
        "## Verification Log",
        "## Residual Risk Log",
    ] {
        assert!(
            evidence.contains(required),
            "SOL evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# State Ownership And Lifecycle Inventory",
        "Allowed State Classes",
        "`canonical_truth`",
        "`durable_substrate`",
        "`projection_cache`",
        "`ephemeral_runtime`",
        "`local_device_preference`",
        "`secret`",
        "`diagnostic_buffer`",
        "`test_fixture`",
    ] {
        assert!(
            inventory.contains(required),
            "SOL inventory missing required text: {required}"
        );
    }

    assert!(
        tsv.starts_with(INVENTORY_HEADER),
        "SOL inventory TSV must start with the required header"
    );

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            readme.contains(required),
            "README living-doc map must link {required}"
        );
    }
}

#[test]
fn sol_scorecard_weights_sum_to_100() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let total: u32 = scorecard
        .lines()
        .filter_map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            if columns.get(1).is_some_and(|cell| cell.starts_with("SOL-")) {
                columns.get(3).and_then(|cell| cell.parse::<u32>().ok())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(total, 100, "SOL row weights must sum to 100");
}

#[test]
fn sol_inventory_rows_are_structured_and_classified() {
    let rows = parse_inventory();
    assert!(!rows.is_empty(), "SOL inventory must have rows");

    let mut seen = BTreeSet::new();
    for row in rows {
        assert!(
            seen.insert((row.path.clone(), row.state_surface.clone())),
            "duplicate SOL inventory row for path/surface: {} {}",
            row.path,
            row.state_surface
        );
        assert!(
            repo_path(&row.path).exists(),
            "SOL inventory path must exist: {}",
            row.path
        );
        assert!(
            ALLOWED_STATE_CLASSES.contains(&row.state_class.as_str()),
            "invalid state_class `{}` for {}",
            row.state_class,
            row.path
        );
        for (name, value) in [
            ("language", &row.language),
            ("owner", &row.owner),
            ("scope", &row.scope),
            ("creation_path", &row.creation_path),
            ("mutation_boundary", &row.mutation_boundary),
            (
                "hydration_or_reconstruction",
                &row.hydration_or_reconstruction,
            ),
            ("retirement_or_retention", &row.retirement_or_retention),
            ("concurrency_or_task_guard", &row.concurrency_or_task_guard),
            ("sol_rows", &row.sol_rows),
        ] {
            assert!(
                !value.trim().is_empty(),
                "SOL inventory field {name} must be populated for {}",
                row.path
            );
        }
    }
}

#[test]
fn sol_truth_taxonomy_is_owner_scoped() {
    let inventory_doc = read_repo_file(INVENTORY_PATH);
    for class in ALLOWED_STATE_CLASSES {
        assert!(
            inventory_doc.contains(&format!("`{class}`")),
            "SOL inventory docs must define allowed state class `{class}`"
        );
    }

    let rows = parse_inventory();
    let mut bad_rows = Vec::new();

    for row in rows {
        if row.owner.contains("unclassified") {
            bad_rows.push(format!("{} has unclassified owner {}", row.path, row.owner));
        }

        if row.path.starts_with("packages/ios-app/") && row.state_class == "canonical_truth" {
            bad_rows.push(format!(
                "{} is iOS-local but claims canonical server truth",
                row.path
            ));
        }

        if (row.path.starts_with("scripts/")
            || row.path.starts_with(".github/")
            || row.path.starts_with("packages/agent/docs/")
            || row.path == "README.md")
            && matches!(
                row.state_class.as_str(),
                "canonical_truth" | "durable_substrate" | "secret"
            )
        {
            bad_rows.push(format!(
                "{} is docs/script/CI state but claims {}",
                row.path, row.state_class
            ));
        }

        if row.state_class == "canonical_truth"
            && !matches!(
                row.owner.as_str(),
                "session_event_store" | "settings_profile" | "shared_foundation"
            )
        {
            bad_rows.push(format!(
                "{} canonical truth has unexpected owner {}",
                row.path, row.owner
            ));
        }

        if row.state_class == "secret"
            && !(row.owner == "auth_credentials"
                || row.owner == "ios_local_storage"
                || row.path.contains("Keychain")
                || row.path.contains("TokenStore"))
        {
            bad_rows.push(format!(
                "{} secret has unexpected owner {}",
                row.path, row.owner
            ));
        }

        if row.state_class == "local_device_preference"
            && !row.path.starts_with("packages/ios-app/")
        {
            bad_rows.push(format!(
                "{} local_device_preference is not owned by iOS local state",
                row.path
            ));
        }
    }

    assert!(
        bad_rows.is_empty(),
        "SOL truth taxonomy violations:\n{}",
        bad_rows.join("\n")
    );
}

#[test]
fn sol_inventory_covers_stateful_marker_sources() {
    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| !inventory.contains_key(path))
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "SOL inventory missing stateful marker source rows:\n{}",
        missing.join("\n")
    );
}

#[test]
fn sol_inventory_covers_scripts_ci_and_docs_state_claims() {
    let inventory = inventory_by_path();
    for required in [
        "README.md",
        "scripts/tron",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/quality.sh",
        "scripts/tron-lib.d/service.sh",
        ".github/workflows/ci.yml",
    ] {
        assert!(
            inventory.contains_key(required),
            "SOL inventory must cover script/CI/docs state surface: {required}"
        );
    }
}

#[test]
fn sol_server_bootstrap_lifecycle_is_source_backed() {
    let bootstrap = read_repo_file("packages/agent/src/app/bootstrap/mod.rs");
    let run_server = bootstrap
        .split("pub(crate) async fn run_server")
        .nth(1)
        .expect("run_server must remain the server bootstrap entry point");
    assert_contains_in_order(
        "server bootstrap sequence",
        run_server,
        &[
            "init_directories()",
            "initialize_bearer_token_at",
            "init_database(args.db_path)",
            "ProfileRuntime::load",
            "init_logging",
            "retention_run(false",
            "enforce_size_budget",
            "EventStore::new",
            "init_engine_host",
            "init_services",
            "build_server_runtime_context",
            "TronServer::new",
            "register_server_domains_for_context",
            "EngineStreamEventPump::new",
            "EngineRuntimeServices::start",
            "spawn_background_tasks",
            "spawn_watcher",
            "server.listen()",
            "wait_for_shutdown_signal",
            "graceful_shutdown",
            "flush_task.abort",
            "log_handle.flush",
            "checkpoint()",
        ],
    );
    assert_contains_in_order(
        "database bootstrap sequence",
        &bootstrap,
        &[
            "resolve_production_db_path",
            "ensure_parent_dir",
            "prepare_active_database",
            "acquire_database_lock",
            "new_file",
            "check_integrity",
            "run_migrations",
            "ensure_storage_schema",
        ],
    );
    assert!(
        bootstrap.contains("recover_incomplete_turns(&event_store)"),
        "bootstrap must recover crash journals before accepting traffic"
    );

    let onboarding = read_repo_file("packages/agent/src/app/lifecycle/onboarding/mod.rs");
    assert_contains_in_order(
        "bearer-token materialization sequence",
        &onboarding,
        &[
            "load_or_create_bearer_token",
            "read_token(path)",
            "rotate_lock().lock()",
            "load_or_init_for_write(path)",
            "generate_bearer_token()",
            "save_auth_storage(path",
        ],
    );

    let storage = read_repo_file("packages/agent/src/shared/storage/mod.rs");
    assert_contains_in_order(
        "storage runtime startup sequence",
        &storage,
        &[
            "pub const CURRENT_STORAGE_GENERATION",
            "pub fn open_connection",
            "apply_runtime_pragmas(&conn)",
            "ensure_storage_schema(&conn)",
            "pub fn prepare_for_startup",
            "prepare_active_database(&self.path)",
        ],
    );

    let archive = read_repo_file("packages/agent/src/shared/storage/archive.rs");
    assert_contains_in_order(
        "storage generation archive sequence",
        &archive,
        &[
            "archive_non_current_active_database",
            "active_database_generation",
            "CURRENT_STORAGE_GENERATION",
            "archive_named_files",
            "fs::rename",
        ],
    );

    let schema = read_repo_file("packages/agent/src/shared/storage/schema.rs");
    for required in [
        "PRAGMA journal_mode = WAL",
        "PRAGMA busy_timeout = 5000",
        "CREATE TABLE IF NOT EXISTS storage_metadata",
        "STORAGE_GENERATION_KEY",
    ] {
        assert!(
            schema.contains(required),
            "storage schema bootstrap missing `{required}`"
        );
    }

    let engine_host = read_repo_file("packages/agent/src/engine/invocation/host/bootstrap.rs");
    assert_contains_in_order(
        "engine host sqlite bootstrap sequence",
        &engine_host,
        &[
            "pub fn open_sqlite",
            "prepare_for_startup",
            "open_connection",
            "checkpoint",
            "SqliteEngineLedgerStore::open",
            "hydrate_durable_catalog_from_ledger",
            "PrimitiveStores::sqlite",
            "bootstrap_meta_capabilities",
        ],
    );

    let process_lock =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/process_lock.rs");
    for required in [
        "flock(2)",
        "Every production startup path acquires this lock before",
        "DatabaseLock",
        "AlreadyLocked",
        "try_flock_exclusive",
    ] {
        assert!(
            process_lock.contains(required),
            "database process-lock owner missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/agent/src/app/lifecycle/onboarding/mod.rs",
        "packages/agent/src/shared/storage/archive.rs",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/shared/foundation/paths/mod.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-3"))),
            "SOL inventory must tag {required} as part of SOL-3"
        );
    }
}

#[test]
fn dead_plan_mode_state_is_removed() {
    let source =
        read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs");
    for forbidden in ["plan_mode", "set_plan_mode", "is_plan_mode"] {
        assert!(
            !source.contains(forbidden),
            "SessionManager still contains unowned dead state marker `{forbidden}`"
        );
    }
}

#[test]
fn production_tokio_spawns_have_shutdown_or_scoped_lifecycle() {
    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| path.ends_with(".rs"))
        .filter(|path| read_repo_file(path).contains("tokio::spawn"))
        .filter(|path| {
            inventory
                .get(path)
                .is_none_or(|rows| !rows.iter().any(row_has_runtime_guard))
        })
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "production tokio::spawn sites need shutdown/scoped inventory guards:\n{}",
        missing.join("\n")
    );
}

#[test]
fn ios_tasks_have_cancellation_or_view_lifecycle_ownership() {
    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| path.ends_with(".swift"))
        .filter(|path| read_repo_file(path).contains("Task"))
        .filter(|path| {
            inventory
                .get(path)
                .is_none_or(|rows| !rows.iter().any(row_has_runtime_guard))
        })
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "Swift Task sites need cancellation/scoped inventory guards:\n{}",
        missing.join("\n")
    );
}

#[test]
fn server_auth_and_settings_writes_stay_owner_private() {
    let allowed = [
        "packages/agent/src/app/lifecycle/onboarding/mod.rs",
        "packages/agent/src/app/health/mod.rs",
        "packages/agent/src/domains/auth/credentials/",
        "packages/agent/src/domains/settings/profile/",
        "packages/agent/src/shared/foundation/profile/",
    ];
    let offenders = git_ls_files()
        .into_iter()
        .filter(|path| is_production_rust_or_swift(path) && path.ends_with(".rs"))
        .filter(|path| repo_path(path).is_file())
        .filter(|path| !allowed.iter().any(|prefix| path.starts_with(prefix)))
        .filter(|path| {
            let text = read_repo_file(path);
            (text.contains("auth.json") || text.contains("profile.toml"))
                && (text.contains("std::fs::write")
                    || text.contains("write_all")
                    || text.contains(".write(true)")
                    || text.contains("tokio::fs::write"))
        })
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "settings/auth/profile writes must stay behind owner stores:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn ios_local_state_is_documented_as_projection_or_local_state() {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    for (path, class) in [
        (
            "packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift",
            "projection_cache",
        ),
        (
            "packages/ios-app/Sources/Engine/Persistence/Sync/EngineStreamCursorStore.swift",
            "projection_cache",
        ),
        (
            "packages/ios-app/Sources/Support/Pairing/PairedServerStore.swift",
            "local_device_preference",
        ),
        (
            "packages/ios-app/Sources/Support/Storage/PairedServerTokenStore.swift",
            "secret",
        ),
        (
            "packages/ios-app/Sources/Support/Storage/DraftStore.swift",
            "local_device_preference",
        ),
        (
            "packages/ios-app/Sources/Support/Storage/InputHistoryStore.swift",
            "local_device_preference",
        ),
        (
            "packages/ios-app/Sources/Support/Share/SharedContent.swift",
            "local_device_preference",
        ),
        (
            "packages/ios-app/Sources/Support/Diagnostics/MetricKitDiagnosticsStore.swift",
            "diagnostic_buffer",
        ),
    ] {
        let needle = format!("{path}\t");
        assert!(
            inventory
                .lines()
                .any(|line| line.starts_with(&needle) && line.contains(&format!("\t{class}\t"))),
            "SOL inventory must classify {path} as {class}"
        );
    }
    assert!(
        !inventory
            .lines()
            .filter(|line| line.starts_with("packages/ios-app/"))
            .any(|line| line.contains("\tcanonical_truth\t")),
        "iOS local state rows must not be classified as canonical server truth"
    );
}

#[test]
fn final_closeout_is_complete() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "Current score: **100/100**",
        "Status: **complete**",
        "| SOL-0 | Campaign harness, red static gate, README links, scorecard/evidence/inventory scaffolding | 5 | passed_after_fix |",
        "| SOL-1 | Whole-repo state inventory for Rust server, iOS app, scripts/CI state, docs-owned state claims | 10 | passed_after_fix |",
        "| SOL-2 | Truth taxonomy for every state surface | 8 | passed_after_fix |",
        "| SOL-3 | Server bootstrap lifecycle | 10 | passed_after_fix |",
        "| SOL-4 | Runtime task and memory lifecycle | 12 | passed_after_fix |",
        "| SOL-5 | Engine durable substrate lifecycle | 14 | passed_after_fix |",
        "| SOL-6 | Session/event-store lifecycle | 10 | passed_after_fix |",
        "| SOL-7 | Settings/auth/secrets lifecycle | 10 | passed_after_fix |",
        "| SOL-8 | iOS projection and local state lifecycle | 14 | passed_after_fix |",
        "| SOL-9 | Observability/recovery evidence | 4 | passed_after_fix |",
        "| SOL-10 | Final closeout | 3 | passed_after_fix |",
        "No open loops remain.",
    ] {
        assert!(
            scorecard.contains(required),
            "SOL final scorecard missing required closeout text: {required}"
        );
    }

    for required in [
        "Current score: **100/100**",
        "Status: **complete**",
        "| SOL-10 | passed_after_fix |",
        "Full closeout verification",
        "clean worktree proof",
    ] {
        assert!(
            evidence.contains(required),
            "SOL final evidence missing required closeout text: {required}"
        );
    }

    for (name, content) in [
        ("scorecard", scorecard.as_str()),
        ("evidence", evidence.as_str()),
        ("inventory", inventory.as_str()),
        ("inventory_tsv", tsv.as_str()),
        ("readme", readme.as_str()),
    ] {
        for forbidden in [
            "Status: **active**",
            "Not started.",
            "pending |",
            "| pending |",
            "Open loops",
            "open loops remain",
            "must still",
            "may close only",
            "remaining proof",
            "deletion pending",
        ] {
            assert!(
                !content.contains(forbidden),
                "{name} contains stale SOL closeout wording: {forbidden}"
            );
        }
    }
}

fn row_has_runtime_guard(row: &InventoryRow) -> bool {
    let guard = row.concurrency_or_task_guard.to_ascii_lowercase();
    [
        "shutdown",
        "abort",
        "join",
        "drop",
        "cancel",
        "scoped",
        "raii",
        "deinit",
        "stop",
        "clear",
        "server-switch reset",
        "view lifecycle",
        "fire-and-forget one-shot",
        "mainactor one-shot",
        "awaited",
    ]
    .iter()
    .any(|needle| guard.contains(needle))
}
