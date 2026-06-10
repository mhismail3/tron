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
fn sol_runtime_task_memory_lifecycle_is_source_backed() {
    let session_manager =
        read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs");
    for forbidden in ["plan_mode", "set_plan_mode", "is_plan_mode"] {
        assert!(
            !session_manager.contains(forbidden),
            "SessionManager still contains unowned dead state marker `{forbidden}`"
        );
    }
    for required in [
        "active_sessions: DashMap<String, CachedSession>",
        "last_accessed: Mutex<Instant>",
        "is_processing: AtomicBool",
        "insert(session_id.clone()",
        "insert(session_id.to_owned()",
        "active_sessions.remove",
        "active_sessions.retain",
        "cached.is_processing.load",
        "cached.is_processing.store(true",
        "cached.is_processing.store(false",
    ] {
        assert!(
            session_manager.contains(required),
            "SessionManager runtime cache lifecycle missing `{required}`"
        );
    }

    let core = read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/core/mod.rs");
    assert_contains_in_order(
        "StartedRun cleanup",
        &core,
        &[
            "pub struct StartedRun",
            "impl Drop for StartedRun",
            "self.registry.remove",
            "self.permit.take",
        ],
    );
    assert_contains_in_order(
        "RetainGuard cleanup",
        &core,
        &[
            "pub struct RetainGuard",
            "impl Drop for RetainGuard",
            "self.set.remove",
        ],
    );
    for required in [
        "run_semaphore: Arc<Semaphore>",
        "active_runs: Mutex<HashMap<String, ActiveRun>>",
        "sequence_counters: Arc<DashMap<String, Arc<AtomicI64>>>",
        "remove_sequence_counter",
        "compaction_handlers.remove",
        "capability_invocation_tracker.lock().cancel_all()",
        "sequence_counters.clear()",
        "compaction_handlers.clear()",
        "invocation_abort_registry: Arc<InvocationAbortRegistry>",
    ] {
        assert!(
            core.contains(required),
            "Orchestrator runtime lifecycle missing `{required}`"
        );
    }

    let abort_registry = read_repo_file(
        "packages/agent/src/domains/agent/loop/orchestrator/invocation_abort_registry.rs",
    );
    assert_contains_in_order(
        "InvocationAbortGuard cleanup",
        &abort_registry,
        &[
            "pub struct InvocationAbortGuard",
            "impl Drop for InvocationAbortGuard",
            "self.registry",
            ".unregister",
        ],
    );
    for required in [
        "entries: DashMap<Key, CancellationToken>",
        "token.cancel()",
        "remove(&(",
    ] {
        assert!(
            abort_registry.contains(required),
            "Invocation abort registry lifecycle missing `{required}`"
        );
    }

    let tracker = read_repo_file(
        "packages/agent/src/domains/agent/loop/orchestrator/capability_invocation_tracker.rs",
    );
    for required in [
        "pending: HashMap<String, oneshot::Sender<Value>>",
        "pending.insert",
        "pending.remove",
        "pending.clear",
    ] {
        assert!(
            tracker.contains(required),
            "Capability invocation tracker lifecycle missing `{required}`"
        );
    }

    let shutdown = read_repo_file("packages/agent/src/app/lifecycle/shutdown.rs");
    for required in [
        "abort_handles: Mutex<HashMap<u64, AbortHandle>>",
        "register_task",
        "handle.abort()",
        "registry.finish(task_id)",
        "wait_for_empty",
        "register_phase_callback",
        "run_phase_callbacks",
        "tokio::time::timeout",
    ] {
        assert!(
            shutdown.contains(required),
            "Shutdown coordinator lifecycle missing `{required}`"
        );
    }

    let server_context = read_repo_file("packages/agent/src/shared/server/context.rs");
    assert_contains_in_order(
        "blocking supervisor lifecycle",
        &server_context,
        &[
            "pub struct BlockingTaskSupervisor",
            "semaphore: Arc<tokio::sync::Semaphore>",
            "struct BlockingTaskGuard",
            "impl Drop for BlockingTaskGuard",
            "self.active.fetch_sub",
            "register_blocking_supervisor_shutdown",
            "shutdown.register_phase_callback",
        ],
    );
    assert!(
        server_context.contains("shutdown.register_task(handle)"),
        "detached blocking tasks must register with the shutdown coordinator"
    );

    let runtime = read_repo_file("packages/agent/src/transport/runtime/mod.rs");
    for required in [
        "EngineRuntimeServices",
        "shutdown.register_task(tokio::spawn(service.run()))",
        "shutdown.register_task(tokio::spawn(heartbeat.run()))",
    ] {
        assert!(
            runtime.contains(required),
            "Engine runtime service ownership missing `{required}`"
        );
    }
    for (path, owner) in [
        (
            "packages/agent/src/transport/runtime/queue_drainer.rs",
            "queue drainer",
        ),
        (
            "packages/agent/src/transport/runtime/worker_heartbeat.rs",
            "worker heartbeat",
        ),
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains("CancellationToken") && source.contains("cancel.cancelled()"),
            "{owner} must select on its shutdown cancellation token"
        );
    }

    let bootstrap = read_repo_file("packages/agent/src/app/bootstrap/mod.rs");
    for required in [
        "spawn_background_tasks",
        "server.shutdown().register_task(eviction_task)",
        "register_blocking_supervisor_shutdown(server.shutdown())",
        "EngineRuntimeServices::start(&server)",
        "register_task(profile_runtime_for_watcher.spawn_watcher",
    ] {
        assert!(
            bootstrap.contains(required),
            "app bootstrap background task ownership missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/agent/src/app/lifecycle/shutdown.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/capability_invocation_tracker.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/core/mod.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/invocation_abort_registry.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs",
        "packages/agent/src/shared/server/context.rs",
        "packages/agent/src/transport/runtime/mod.rs",
        "packages/agent/src/transport/runtime/queue_drainer.rs",
        "packages/agent/src/transport/runtime/worker_heartbeat.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-4"))),
            "SOL inventory must tag {required} as part of SOL-4"
        );
    }
}

#[test]
fn sol_engine_durable_substrate_lifecycle_is_source_backed() {
    let compensation = read_repo_file("packages/agent/src/engine/authority/compensation.rs");
    assert_contains_in_order(
        "compensation audit-only lifecycle",
        &compensation,
        &[
            "Compensation is intentionally recorded before Tron attempts any automated",
            "pub enum EngineCompensationStatus",
            "Recorded",
            "Self::Recorded => \"recorded\"",
            "status: EngineCompensationStatus::Recorded",
            "\"engine_compensation\"",
            "\"audit\"",
        ],
    );
    assert!(
        !compensation.contains("Succeeded") && !compensation.contains("RolledBack"),
        "compensation must remain explicit audit-only state until a rollback owner is implemented"
    );

    let invocation_support =
        read_repo_file("packages/agent/src/engine/invocation/host/invocation_support.rs");
    for required in [
        "acquire_resource_lease_for_invocation",
        "release_resource_lease_sync",
        "record_compensation_for_result_sync",
        "\"resource_lease.acquired\"",
        "\"resource_lease.released\"",
        "\"compensation.recorded\"",
    ] {
        assert!(
            invocation_support.contains(required),
            "engine host contract bookkeeping missing `{required}`"
        );
    }

    let meta_invocation =
        read_repo_file("packages/agent/src/engine/invocation/host/meta_invocation.rs");
    assert_contains_in_order(
        "host-dispatched primitive contract finalization",
        &meta_invocation,
        &[
            "let compensation_contract = function.compensation.clone();",
            "let lease_result = self.acquire_resource_lease_for_invocation",
            "release_after_primary(self.release_resource_lease_sync",
            "finish_meta_invocation_with_contracts",
            "complete_invocation_idempotency",
            "record_compensation_for_result_sync",
            "record_invocation_result_with_contracts",
        ],
    );

    let ledger = read_repo_file("packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs");
    for required in [
        "append_catalog_change",
        "upsert_durable_worker_definition",
        "remove_durable_worker_definition",
        "upsert_durable_function_definition",
        "remove_durable_function_definition",
        "append_invocation",
        "resource_lease_ids_json",
        "compensation_status",
        "produced_resource_refs_json",
        "reserve_idempotency",
        "IdempotencyStatus::InProgress",
        "complete_idempotency",
        "IdempotencyStatus::Completed",
        "\"engine_invocation\"",
        "\"engine_idempotency\"",
        "list_invocations_by_session",
        "list_idempotency_by_session",
    ] {
        assert!(
            ledger.contains(required),
            "engine ledger lifecycle missing `{required}`"
        );
    }

    let queue = read_repo_file("packages/agent/src/engine/durability/queue/mod.rs");
    for required in [
        "pub enum QueueItemStatus",
        "Ready",
        "Leased",
        "Completed",
        "Cancelled",
        "DeadLettered",
        "pub struct EngineQueueAttemptRecord",
        "resource_lease_ids",
        "compensation_status",
        "compensation_id",
    ] {
        assert!(
            queue.contains(required),
            "engine queue model lifecycle missing `{required}`"
        );
    }
    for path in [
        "packages/agent/src/engine/durability/queue/memory.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
    ] {
        let source = read_repo_file(path);
        for required in [
            "QueueItemStatus::Ready",
            "QueueItemStatus::Leased",
            "QueueItemStatus::Completed",
            "QueueItemStatus::Cancelled",
            "QueueItemStatus::DeadLettered",
            "lease_owner = None",
            "lease_expires_at = None",
            "attempt_records.push",
            "list_by_session",
        ] {
            assert!(source.contains(required), "{path} missing `{required}`");
        }
    }
    let sqlite_queue = read_repo_file("packages/agent/src/engine/durability/queue/sqlite_store.rs");
    assert!(
        sqlite_queue.contains("attempt_records_json"),
        "SQLite queue store must persist attempt records"
    );

    let resources = read_repo_file("packages/agent/src/engine/durability/resources/store/mod.rs");
    for required in [
        "register_type",
        "resource.created",
        "append_version_inner",
        "EngineResourceVersionState::Available",
        "store_json_value",
        "\"engine_resource_version\"",
        "update_resource_pointer",
        "resource.version.created",
        "resource.linked",
        "expected_current_version_id",
        "version conflict",
        "inspect",
        "list",
    ] {
        assert!(
            resources.contains(required),
            "engine resource store lifecycle missing `{required}`"
        );
    }

    let state = read_repo_file("packages/agent/src/engine/durability/state.rs");
    for required in [
        "revision.saturating_add(1)",
        "compare_and_set",
        "state revision conflict",
        "DELETE FROM engine_state_entries",
        "\"engine_state_entry\"",
        "list(",
    ] {
        assert!(
            state.contains(required),
            "engine state store lifecycle missing `{required}`"
        );
    }

    for path in [
        "packages/agent/src/engine/durability/streams/memory.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
    ] {
        let source = read_repo_file(path);
        for required in [
            "publish",
            "subscribe",
            "latest_cursor",
            "unsubscribe",
            "acknowledge",
            "poll",
            "list_by_session",
            "stream_scope_visible",
        ] {
            assert!(source.contains(required), "{path} missing `{required}`");
        }
    }
    let sqlite_stream =
        read_repo_file("packages/agent/src/engine/durability/streams/sqlite_store.rs");
    for required in [
        "engine_stream_events",
        "engine_stream_subscriptions",
        "active = 0",
        "SET cursor = CASE",
        "\"engine_stream_event\"",
    ] {
        assert!(
            sqlite_stream.contains(required),
            "SQLite stream lifecycle missing `{required}`"
        );
    }

    let stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    assert_contains_in_order(
        "primitive store sqlite bundle",
        &stores,
        &[
            "fn sqlite(path: &std::path::Path) -> Result<Self>",
            "SqliteEngineStreamStore::open(path)?",
            "SqliteEngineStateStore::open(path)?",
            "SqliteEngineQueueStore::open(path)?",
            "SqliteEngineResourceLeaseStore::open(path)?",
            "SqliteEngineResourceStore::open(path)?",
            "SqliteEngineGrantStore::open(path)?",
            "SqliteEngineCompensationStore::open(path)?",
            "stores.install_builtin_resource_types()?",
        ],
    );

    let storage_schema = read_repo_file("packages/agent/src/shared/storage/schema.rs");
    for required in [
        "CREATE TABLE IF NOT EXISTS storage_checkpoints",
        "CREATE TABLE IF NOT EXISTS storage_exports",
        "CREATE TABLE IF NOT EXISTS storage_retention_runs",
        "CREATE TABLE IF NOT EXISTS storage_payload_refs",
        "retention_class",
        "expires_at",
    ] {
        assert!(
            storage_schema.contains(required),
            "shared storage schema missing `{required}`"
        );
    }
    let payloads = read_repo_file("packages/agent/src/shared/storage/payloads.rs");
    for required in [
        "store_owned_payload_ref",
        "storage_payload_refs",
        "owner_kind",
        "owner_id",
        "field_name",
        "retention_class",
        "resolve_payload_ref_envelope",
    ] {
        assert!(
            payloads.contains(required),
            "shared payload-ref lifecycle missing `{required}`"
        );
    }
    let maintenance = read_repo_file("packages/agent/src/shared/storage/maintenance.rs");
    for required in [
        "checkpoint_database",
        "export_snapshot",
        "retention_run",
        "DELETE FROM storage_payload_refs",
        "storage_checkpoints",
        "storage_exports",
        "storage_retention_runs",
    ] {
        assert!(
            maintenance.contains(required),
            "shared storage maintenance lifecycle missing `{required}`"
        );
    }
    let stats = read_repo_file("packages/agent/src/shared/storage/stats.rs");
    for required in [
        "payload_owner_stats",
        "expired_pending_payload_refs",
        "storage_payload_refs",
        "unowned_blob_count",
        "PayloadOwnerStorageStats",
    ] {
        assert!(
            stats.contains(required),
            "storage stats missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/engine/authority/compensation.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/catalog/registry/idempotency.rs",
        "packages/agent/src/engine/catalog/registry/invocation.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/invocation/host/meta_invocation.rs",
        "packages/agent/src/engine/primitives/stores.rs",
        "packages/agent/src/shared/storage/maintenance.rs",
        "packages/agent/src/shared/storage/mod.rs",
        "packages/agent/src/shared/storage/payloads.rs",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/shared/storage/stats.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-5"))),
            "SOL inventory must tag {required} as part of SOL-5"
        );
    }
}

#[test]
fn sol_session_event_store_lifecycle_is_source_backed() {
    let lifecycle_mod = read_repo_file("packages/agent/src/domains/session/lifecycle/mod.rs");
    for required in [
        "## Submodules",
        "`archive`",
        "`create`",
        "`delete`",
        "`fork`",
        "Archive/unarchive is reversible session-row state (`ended_at`)",
        "Deleting a session is the only physical event-row cleanup path",
        "Fork-inherited ancestor history stays",
        "`message.deleted` event",
        "Runtime sequence counters and compaction handlers are projections",
    ] {
        assert!(
            lifecycle_mod.contains(required),
            "session lifecycle module docs missing `{required}`"
        );
    }

    let session_manager =
        read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs");
    assert_contains_in_order(
        "session manager create/resume/end lifecycle",
        &session_manager,
        &[
            "pub fn create_session",
            ".create_session(model, workspace_path, title, None)",
            "active_sessions",
            "pub fn resume_session",
            "session_reconstructor::reconstruct",
            "pub async fn end_session",
            "persister.flush().await",
            ".append(&AppendOptions",
            "EventType::SessionEnd",
            ".end_session(session_id)",
        ],
    );
    for required in [
        "pub fn fork_session",
        "head_event_id",
        ".fork(",
        "pub fn archive_session",
        "active_sessions.remove(session_id)",
        ".end_session(session_id)",
        "pub fn unarchive_session",
        ".clear_session_ended(session_id)",
        "pub fn delete_session",
        ".delete_session(session_id)",
        "pub fn evict_idle_sessions",
        "retain(|session_id, cached|",
        "pub fn mark_processing",
        "pub fn clear_processing",
    ] {
        assert!(
            session_manager.contains(required),
            "session manager lifecycle missing `{required}`"
        );
    }

    let lifecycle = read_repo_file(
        "packages/agent/src/domains/session/event_store/store/event_store/session_lifecycle.rs",
    );
    assert_contains_in_order(
        "event store create session transaction",
        &lifecycle,
        &[
            "create_session_in_tx_with_identity",
            "WorkspaceRepo::get_or_create_with_identity",
            "SessionRepo::create_with_identity",
            "EventType::SessionStart",
            "sequence: 0",
            "EventRepo::insert(tx, &event)",
            "SessionRepo::update_root",
            "SessionRepo::update_head_at",
            "SessionRepo::increment_counters_at",
            "tx.commit()",
        ],
    );
    assert_contains_in_order(
        "event store fork transaction",
        &lifecycle,
        &[
            "pub fn fork_with_identity",
            "EventRepo::get_by_id(&tx, from_event_id)",
            "SessionRepo::get_by_id(&tx, &source_event.session_id)",
            "parent_session_id: Some(&source_session.id)",
            "fork_from_event_id: Some(from_event_id)",
            "parent_id: Some(from_event_id.to_string())",
            "EventType::SessionFork",
            "EventRepo::insert(&tx, &fork_event)",
            "SessionRepo::update_root",
            "SessionRepo::update_head_at",
            "tx.commit()",
        ],
    );
    assert_contains_in_order(
        "event store archive/delete lifecycle",
        &lifecycle,
        &[
            "pub fn end_session",
            "with_session_write_lock(session_id",
            "SessionRepo::mark_ended",
            "pub fn clear_session_ended",
            "SessionRepo::clear_ended",
            "pub fn delete_session",
            "EventRepo::delete_by_session",
            "SessionRepo::delete",
            "tx.commit()",
            "self.remove_session_write_lock(session_id)",
        ],
    );

    let event_log = read_repo_file(
        "packages/agent/src/domains/session/event_store/store/event_store/event_log.rs",
    );
    for required in [
        "with_session_write_lock(opts.session_id",
        "SELECT MAX(sequence) FROM events WHERE session_id = ?1",
        "UNIQUE(session_id, sequence)",
        "EventRepo::insert(tx, &event)",
        "SessionRepo::update_head",
        "SessionRepo::increment_counters",
        "EventType::MessageDeleted",
    ] {
        assert!(
            event_log.contains(required),
            "event append lifecycle missing `{required}`"
        );
    }

    let event_repo = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/crud.rs",
    );
    for required in ["store_json_value", "\"session_event\"", "\"audit\""] {
        assert!(
            event_repo.contains(required),
            "event repository payload lifecycle missing `{required}`"
        );
    }
    assert!(
        !event_repo.contains("pub fn delete(conn: &Connection, event_id: &str)"),
        "single-event physical delete must not exist; use message.deleted or session-scoped delete"
    );
    assert!(
        event_repo.contains("pub fn delete_by_session"),
        "session-scoped delete path must remain explicit"
    );

    let event_repo_docs = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/mod.rs",
    );
    assert!(
        event_repo_docs.contains("session-scoped delete"),
        "event repository docs must distinguish session-scoped delete from append-only event lifecycle"
    );

    let schema = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    for required in [
        "CREATE TABLE IF NOT EXISTS sessions",
        "head_event_id",
        "root_event_id",
        "parent_session_id",
        "fork_from_event_id",
        "ended_at",
        "CREATE TABLE IF NOT EXISTS events",
        "session_id            TEXT    NOT NULL REFERENCES sessions(id)",
        "parent_id             TEXT    REFERENCES events(id)",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_sequence_unique",
        "ON events(session_id, sequence)",
    ] {
        assert!(
            schema.contains(required),
            "session/event schema missing `{required}`"
        );
    }

    let lifecycle_archive =
        read_repo_file("packages/agent/src/domains/session/lifecycle/archive.rs");
    for required in [
        "SessionLifecycleService::archive",
        "archive_session(&session_id_for_archive)",
        "remove_sequence_counter(&session_id)",
        "remove_compaction_handler(&session_id)",
        "TronEvent::SessionArchived",
        "unarchive_session(&session_id_for_unarchive)",
        "TronEvent::SessionUnarchived",
        "archive_older_than",
        "include_archived: false",
        "Self::archive(deps, session_id.clone()).await",
    ] {
        assert!(
            lifecycle_archive.contains(required),
            "session archive lifecycle missing `{required}`"
        );
    }
    let lifecycle_delete = read_repo_file("packages/agent/src/domains/session/lifecycle/delete.rs");
    for required in [
        "delete_session(&session_id_for_delete)",
        "remove_sequence_counter(&session_id)",
        "remove_compaction_handler(&session_id)",
        "TronEvent::SessionDeleted",
    ] {
        assert!(
            lifecycle_delete.contains(required),
            "session delete lifecycle missing `{required}`"
        );
    }
    let lifecycle_create = read_repo_file("packages/agent/src/domains/session/lifecycle/create.rs");
    for required in [
        "normalize_working_directory",
        "create_session(&model, &stored_working_directory",
        "TronEvent::SessionCreated",
        "init_sequence_counter(&session_id, 0)",
    ] {
        assert!(
            lifecycle_create.contains(required),
            "session create lifecycle missing `{required}`"
        );
    }
    let lifecycle_fork = read_repo_file("packages/agent/src/domains/session/lifecycle/fork.rs");
    for required in [
        "fork_session(",
        "from_event_id.as_deref()",
        "init_sequence_counter(&new_session_id, 0)",
        "TronEvent::SessionForked",
    ] {
        assert!(
            lifecycle_fork.contains(required),
            "session fork lifecycle missing `{required}`"
        );
    }

    let reconstruction = read_repo_file("packages/agent/src/domains/session/reconstruction/mod.rs");
    for required in [
        "MAX_RECONSTRUCT_EVENTS",
        ".clamp(0, MAX_RECONSTRUCT_EVENTS)",
        "session.parent_session_id.is_some()",
        "event_store.get_ancestors(head_id)",
        "paginate_ordered_chain",
        "get_events_before",
        "has_events_before",
        "get_latest_events",
        "resolve_event_payloads",
        "current_sequence(&session_id)",
        "build_in_flight_state",
    ] {
        assert!(
            reconstruction.contains(required),
            "session reconstruction lifecycle missing `{required}`"
        );
    }

    let event_state =
        read_repo_file("packages/agent/src/domains/session/event_store/store/event_store/state.rs");
    for required in [
        "get_messages_at_head",
        "get_ancestors(&conn, head_id)",
        "event_rows_to_session_events_with_conn",
        "resolve_stored_json_value",
        "reconstruct_from_events(&events)",
        "build_session_state",
    ] {
        assert!(
            event_state.contains(required),
            "event-store reconstruction state missing `{required}`"
        );
    }

    let query = read_repo_file("packages/agent/src/domains/session/query/mod.rs");
    for required in [
        "pub(crate) async fn resume",
        "resume_session(&session_id_for_resume)",
        "pub(crate) async fn list",
        "get_session_message_previews",
        "get_session_activity_summaries_batch",
        "pub(crate) async fn export",
        "\"format\": \"tron.session.v1\"",
        "get_events_by_session",
        "resolve_event_payloads",
    ] {
        assert!(
            query.contains(required),
            "session query lifecycle missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/domains/agent/loop/orchestrator/core/mod.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/event_persister.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/session_manager/mod.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/session_reconstructor.rs",
        "packages/agent/src/domains/session/lifecycle/archive.rs",
        "packages/agent/src/domains/session/lifecycle/mod.rs",
        "packages/agent/src/domains/session/mod.rs",
        "packages/agent/src/domains/session/query/mod.rs",
        "packages/agent/src/domains/session/reconstruction/mod.rs",
        "packages/agent/src/domains/session/event_store/mod.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/event_log.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/locking.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/session_lifecycle.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/crud.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/session_queries.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/tree_queries.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/session/mod.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-6"))),
            "SOL inventory must tag {required} as part of SOL-6"
        );
    }
}

#[test]
fn sol_settings_auth_secrets_lifecycle_is_source_backed() {
    let settings_store = read_repo_file("packages/agent/src/domains/settings/profile/store.rs");
    for required in [
        "static SETTINGS_WRITE_LOCK",
        "static SETTINGS_OPERATION_LOCK",
        "pub async fn operation_lock",
        "pub fn read_sparse_value",
        "pub fn reset",
        "pub fn update",
        "pub fn replace_sparse_value",
        "pub fn restore_sparse_value_for_rollback",
        "validate_sparse_settings",
        "load_settings_defaults_for(path)",
        "validate_strict()",
        "tempfile_in(parent)",
        "persist(&self.path)",
        "sync_parent_dir(parent)",
    ] {
        assert!(
            settings_store.contains(required),
            "settings store lifecycle missing `{required}`"
        );
    }

    let settings_operations =
        read_repo_file("packages/agent/src/domains/settings/profile/operations.rs");
    assert_contains_in_order(
        "settings update rollback lifecycle",
        &settings_operations,
        &[
            "settings_update_value",
            "SettingsStore::operation_lock().await",
            "read_sparse_settings_snapshot",
            "SettingsStore::new(settings_path)",
            ".update(updates)",
            "reload_profile_runtime_or_rollback",
        ],
    );
    for required in [
        "settings_reset_to_defaults_value",
        "restore_sparse_value_for_rollback",
        "rollback_sparse_settings",
        "init_settings(deps.profile_runtime.current().settings.clone())",
        "deps.profile_runtime.reload_now(reason)",
        "sparse settings were rolled back",
    ] {
        assert!(
            settings_operations.contains(required),
            "settings operation lifecycle missing `{required}`"
        );
    }

    let settings_loader =
        read_repo_file("packages/agent/src/domains/settings/profile/storage/loader.rs");
    for required in [
        "load_settings_from_path",
        "read_sparse_settings_overlay",
        "apply_env_overrides",
        "deep_merge",
        "validate_strict()",
    ] {
        assert!(
            settings_loader.contains(required),
            "settings loader lifecycle missing `{required}`"
        );
    }

    let profile_runtime =
        read_repo_file("packages/agent/src/domains/agent/loop/profile_runtime.rs");
    for required in [
        "current: ArcSwap<ResolvedHarnessSpec>",
        "pub fn reload_now",
        "self.current.store(next.clone())",
        "crate::domains::settings::init_settings(next.settings.clone())",
        "profile runtime reload rejected; keeping previous valid spec",
        "pub fn spawn_watcher",
        "CancellationToken",
        "cancel.cancelled()",
        "fn profile_tree_hash",
        "AUTH_JSON",
        "continue;",
        "invalid_reload_keeps_previous_spec",
        "reload_updates_global_settings_snapshot",
    ] {
        assert!(
            profile_runtime.contains(required),
            "profile runtime lifecycle missing `{required}`"
        );
    }

    let auth_storage = read_repo_file("packages/agent/src/domains/auth/credentials/storage/mod.rs");
    for required in [
        "load_auth_storage",
        "serde_json::Map::is_empty",
        "AuthStorage::new()",
        "MalformedAuthFile",
        "load_or_init_for_write",
        "save_auth_storage",
        "storage.last_updated",
        "atomic_write_0600",
        "tempfile_in(parent)",
        "persist(final_path)",
        "set_permissions(&lock_path",
        "from_mode(0o600)",
        "pub fn acquire_auth_file_lock",
        "libc::flock",
        "AuthFileLock",
    ] {
        assert!(
            auth_storage.contains(required),
            "auth storage lifecycle missing `{required}`"
        );
    }

    let auth_accounts = read_repo_file("packages/agent/src/domains/auth/credentials/accounts.rs");
    for required in [
        "auth_update",
        "acquire_auth_file_lock(&auth_path)",
        "update_google_provider",
        "update_standard_provider",
        "update_service",
        "build_masked_state(&auth_path)",
        "publish_auth_updated",
        "auth_clear",
        "clear_provider_auth",
        "clear_service_auth",
    ] {
        assert!(
            auth_accounts.contains(required),
            "auth account operation lifecycle missing `{required}`"
        );
    }

    let provider_state =
        read_repo_file("packages/agent/src/domains/auth/credentials/provider_state.rs");
    for required in [
        "write_auth_and_broadcast",
        "acquire_auth_file_lock(&auth_path)",
        "mutate(&auth_path)",
        "build_masked_state(&auth_path)",
        "publish_auth_updated",
        "update_google_provider",
        "save_auth_storage(auth_path",
        "build_provider_info",
        "mask_key",
    ] {
        assert!(
            provider_state.contains(required),
            "auth provider-state lifecycle missing `{required}`"
        );
    }

    let oauth_operations = read_repo_file("packages/agent/src/domains/auth/oauth/operations.rs");
    assert_contains_in_order(
        "OAuth pending-flow lifecycle",
        &oauth_operations,
        &[
            "auth_oauth_begin",
            "flows.retain",
            "OAUTH_FLOW_TTL_SECS",
            "flows.insert",
            "PendingOAuthFlow",
            "auth_oauth_complete",
            "flows.remove(&flow_id)",
            "flow.created_at.elapsed() >",
            "OAUTH_FLOW_TTL_SECS",
            "auth::oauth_complete",
            "acquire_auth_file_lock(&auth_path)",
            "save_account_oauth_tokens",
            "publish_auth_updated",
        ],
    );
    let oauth_mod = read_repo_file("packages/agent/src/domains/auth/oauth/mod.rs");
    assert!(
        oauth_mod.contains("pub(crate) const OAUTH_FLOW_TTL_SECS: u64 = 600"),
        "OAuth pending-flow TTL must remain explicit"
    );

    let onboarding = read_repo_file("packages/agent/src/app/lifecycle/onboarding/mod.rs");
    assert_contains_in_order(
        "bearer-token auth storage lifecycle",
        &onboarding,
        &[
            "load_or_create_bearer_token",
            "read_token(path)",
            "rotate_lock().lock()",
            "load_or_init_for_write(path)",
            "generate_bearer_token()",
            "save_auth_storage(path",
            "rotate_bearer_token",
            "load_or_init_for_write(path)",
            "save_auth_storage(path",
        ],
    );
    for required in [
        "TOKEN_BYTE_LEN: usize = 32",
        "ENCODED_TOKEN_LEN: usize = 43",
        "non_empty_token",
        "rotate_lock()",
        "OnceLock<Mutex<()>>",
    ] {
        assert!(
            onboarding.contains(required),
            "bearer-token onboarding lifecycle missing `{required}`"
        );
    }

    let http_auth = read_repo_file("packages/agent/src/transport/http/auth.rs");
    for required in [
        "cached: Mutex<Option<CachedToken>>",
        "std::fs::metadata(&self.path)",
        "cached.mtime == disk",
        "load_or_create_bearer_token(&self.path)",
        "tokens_eq(presented.as_bytes(), canonical.as_bytes())",
        "verify_bearer_header",
        "strip_prefix(\"Bearer \")",
        "trim_end()",
        "StatusCode::UNAUTHORIZED",
        "concurrent_verification_under_rotation_never_panics",
    ] {
        assert!(
            http_auth.contains(required),
            "HTTP bearer-token cache lifecycle missing `{required}`"
        );
    }

    for (path, provider_key) in [
        (
            "packages/agent/src/domains/auth/credentials/anthropic.rs",
            "Anthropic",
        ),
        (
            "packages/agent/src/domains/auth/credentials/openai/mod.rs",
            "OpenAI",
        ),
        (
            "packages/agent/src/domains/auth/credentials/google.rs",
            "Google",
        ),
    ] {
        let source = read_repo_file(path);
        for required in [
            "static REFRESH_LOCK",
            "TokioMutex",
            "acquire_auth_file_lock(auth_path)",
            "read_tokens_from_disk",
            "persist_tokens",
            "-> Result<(), AuthError>",
            "persist_tokens(&auth_path, &account_label_owned, &new_tokens)?",
            "is_stale_token_error",
            "invalid_grant",
            "super::refresh::maybe_refresh",
        ] {
            assert!(
                source.contains(required),
                "{provider_key} token refresh lifecycle missing `{required}`"
            );
        }
    }
    let google_auth = read_repo_file("packages/agent/src/domains/auth/credentials/google.rs");
    assert_contains_in_order(
        "Google refresh lock and disk re-read lifecycle",
        &google_auth,
        &[
            "maybe_refresh_tokens(auth_path",
            "static REFRESH_LOCK",
            "lock.lock().await",
            "acquire_auth_file_lock(auth_path)",
            "read_tokens_from_disk(auth_path, account_label)",
            "persist_tokens(&auth_path",
            "Google refresh token consumed by another process",
        ],
    );
    assert!(
        google_auth.contains("persisting refreshed Google tokens"),
        "Google refresh lifecycle must log token persistence"
    );

    let provider_factory =
        read_repo_file("packages/agent/src/domains/model/providers/factory/mod.rs");
    for required in [
        "Auth is re-loaded from disk on each call",
        "auth_path: PathBuf",
        "load_server_auth_with_client",
        "create_google_with_credential",
        "get_google_provider_auth(&self.auth_path)",
        "provider_settings",
        "client_secret",
    ] {
        assert!(
            provider_factory.contains(required),
            "provider factory auth-copy lifecycle missing `{required}`"
        );
    }

    let readme = read_repo_file("README.md");
    for required in [
        "OAuth refresh is owned by `domains/auth/credentials/`",
        "process-local refresh mutex",
        "auth-file `flock`",
        "re-read `auth.json` after the lock",
        "fail the refresh if persistence fails",
        "Model providers receive ephemeral token copies",
    ] {
        assert!(
            readme.contains(required),
            "README auth lifecycle docs missing `{required}`"
        );
    }

    let google_provider =
        read_repo_file("packages/agent/src/domains/model/providers/google/provider/mod.rs");
    for required in [
        "tokens: Option<tokio::sync::Mutex<OAuthTokens>>",
        "Some(tokio::sync::Mutex::new(tokens.clone()))",
        "ensure_valid_tokens",
        "refresh_tokens(&tokens",
        "*tokens = new_tokens",
        "build_headers",
        "Bearer {}",
    ] {
        assert!(
            google_provider.contains(required),
            "Google provider ephemeral token lifecycle missing `{required}`"
        );
    }
    assert!(
        !google_provider.contains("save_account_oauth_tokens")
            && !google_provider.contains("auth_path"),
        "Google model provider must not persist durable auth truth directly"
    );

    let bootstrap = read_repo_file("packages/agent/src/app/bootstrap/mod.rs");
    let context = read_repo_file("packages/agent/src/shared/server/context.rs");
    let registration = read_repo_file("packages/agent/src/domains/registration/worker.rs");
    for (name, source) in [
        ("bootstrap", bootstrap.as_str()),
        ("server runtime context", context.as_str()),
        ("domain registration context", registration.as_str()),
    ] {
        for required in [
            "settings_path",
            "profile_runtime",
            "auth_path",
            "oauth_flows",
        ] {
            assert!(
                source.contains(required),
                "{name} must carry settings/auth lifecycle handle `{required}`"
            );
        }
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/lifecycle/onboarding/mod.rs",
        "packages/agent/src/domains/agent/loop/profile_runtime.rs",
        "packages/agent/src/domains/auth/credentials/anthropic.rs",
        "packages/agent/src/domains/auth/credentials/google.rs",
        "packages/agent/src/domains/auth/credentials/openai/mod.rs",
        "packages/agent/src/domains/auth/credentials/provider_state.rs",
        "packages/agent/src/domains/auth/credentials/storage/mod.rs",
        "packages/agent/src/domains/auth/oauth/operations.rs",
        "packages/agent/src/domains/model/providers/factory/mod.rs",
        "packages/agent/src/domains/model/providers/google/provider/mod.rs",
        "packages/agent/src/domains/model/providers/google/types/mod.rs",
        "packages/agent/src/domains/registration/worker.rs",
        "packages/agent/src/domains/settings/profile/operations.rs",
        "packages/agent/src/domains/settings/profile/storage/loader.rs",
        "packages/agent/src/domains/settings/profile/store.rs",
        "packages/agent/src/shared/foundation/paths/mod.rs",
        "packages/agent/src/shared/foundation/profile/mod.rs",
        "packages/agent/src/shared/foundation/profile/validation.rs",
        "packages/agent/src/shared/server/context.rs",
        "packages/agent/src/transport/http/auth.rs",
        "README.md",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-7"))),
            "SOL inventory must tag {required} as part of SOL-7"
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
fn sol_ios_projection_local_state_lifecycle_is_source_backed() {
    let architecture = read_repo_file("packages/ios-app/docs/architecture.md");
    for required in [
        "## State Ownership",
        "The iOS app owns no canonical server truth.",
        "`EventDatabase` is a Documents-backed SQLite projection cache",
        "startup fails at the composition",
        "boundary instead of silently changing the projection substrate",
        "diagnostics harnesses may create explicit isolated database paths",
        "`EventStoreManager` and `SessionSynchronizer` rebuild local session/event",
        "projections from server session lists and event-sync APIs",
        "Engine stream cursors are stored per server",
        "origin/topic/filter for ACK coalescing and diagnostics only",
        "Server settings shown in the iOS settings UI are snapshots from",
        "Pairing is device-local `UserDefaults` state",
        "bearer tokens are per-server",
        "Keychain secrets",
        "MetricKit payloads are bounded Application Support diagnostics buffers",
    ] {
        assert!(
            architecture.contains(required),
            "iOS architecture state ownership docs missing `{required}`"
        );
    }

    let event_database =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift");
    for required in [
        "urls(for: .documentDirectory",
        ".appendingPathComponent(\".tron\", isDirectory: true)",
        ".appendingPathComponent(\"database\", isDirectory: true)",
        ".appendingPathComponent(\"prod.db\")",
        "init(databasePath: String)",
        "func clearAll() async throws",
        "DELETE FROM events",
        "DELETE FROM sessions",
        "DELETE FROM sync_state",
        "DELETE FROM session_drafts",
    ] {
        assert!(
            event_database.contains(required),
            "EventDatabase projection lifecycle missing `{required}`"
        );
    }
    for forbidden in [
        "EventDatabaseStorageMode",
        "temporaryCache",
        "temporaryCachePath",
        "NSTemporaryDirectory() + \".tron/database/events.db\"",
    ] {
        assert!(
            !event_database.contains(forbidden),
            "EventDatabase must not retain alternate production substrate marker `{forbidden}`"
        );
    }

    let dependency_container =
        read_repo_file("packages/ios-app/Sources/Support/Composition/DependencyContainer.swift");
    for required in [
        "preconditionFailure(\"Documents directory unavailable; cannot initialize iOS local projection stores\")",
        "preconditionFailure(\"Documents directory unavailable; cannot initialize EventDatabase\")",
        "let db = EventDatabase()",
        "eventStoreManager.draftStore = draftStore",
        "selectPairedServer",
        "eventStoreManager.updateEngineClient(newClient)",
        "eventStoreManager.attachConnectionManager(manager)",
    ] {
        assert!(
            dependency_container.contains(required),
            "DependencyContainer iOS state lifecycle missing `{required}`"
        );
    }
    for forbidden in [
        "EventDatabase(temporaryCachePath:",
        "eventDatabaseStorageMode",
        "NSTemporaryDirectory()",
    ] {
        assert!(
            !dependency_container.contains(forbidden),
            "DependencyContainer must not retain alternate production state path `{forbidden}`"
        );
    }

    let event_store_manager =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift");
    for required in [
        "globalEventTask?.cancel()",
        "globalEventTask = Task",
        "sessionSynchronizer.updateEngineClient(client)",
        "setupGlobalEventHandlers()",
        "handleSessionDeleted",
        "handleSessionArchived",
        "handleSessionUnarchived",
    ] {
        assert!(
            event_store_manager.contains(required),
            "EventStoreManager task/projection lifecycle missing `{required}`"
        );
    }

    let event_store_sync = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager+Sync.swift",
    );
    assert_contains_in_order(
        "iOS session list projection refresh",
        &event_store_sync,
        &[
            "fetchServerSessions",
            "serverSessionIds",
            "mergeSessionData",
            "serverSessionToCached",
            "getByOrigin(serverOrigin)",
            "deleteBySession(local.id)",
            "sessions.delete(local.id)",
            "loadSessions()",
            "seedProcessingStateFromSessions()",
        ],
    );
    for required in [
        "max(existing.eventCount, serverInfo.eventCount ?? existing.eventCount)",
        "session.rootEventId = existing.rootEventId",
        "session.headEventId = existing.headEventId",
        "session.serverOrigin = serverOrigin",
    ] {
        assert!(
            event_store_sync.contains(required),
            "EventStoreManager projection merge missing `{required}`"
        );
    }

    let synchronizer = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/SessionSynchronizer.swift",
    );
    assert_contains_in_order(
        "iOS event sync cursor projection",
        &synchronizer,
        &[
            "eventDB.sync.getState(sessionId)",
            "lastSyncedEventId",
            "engineClient.eventSync.getSince",
            "eventDB.events.insertBatch(events)",
            "eventDB.sync.update(newSyncState)",
        ],
    );
    for required in [
        "fullSync(sessionId: String)",
        "eventDB.events.deleteBySession(sessionId)",
        "lastSyncedEventId: nil",
        "engineClient.eventSync.getAll(sessionId: sessionId)",
        "fetchMissingAncestors",
        "engineClient.eventSync.getAncestors(parentId)",
        "insertIgnoringDuplicates",
        "sessionHasDifferentOrigin",
    ] {
        assert!(
            synchronizer.contains(required),
            "SessionSynchronizer lifecycle missing `{required}`"
        );
    }

    let cursor_store = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/EngineStreamCursorStore.swift",
    );
    for required in [
        "serverOrigin: String",
        "filterHash: String",
        "Session history is never restored from this store",
        "save(_ cursor: EngineStreamCursor",
        "guard existing.map({ cursor > $0 }) ?? true else { return }",
        "removeAll()",
    ] {
        assert!(
            cursor_store.contains(required),
            "Engine stream cursor lifecycle missing `{required}`"
        );
    }

    let engine_client =
        read_repo_file("packages/ios-app/Sources/Engine/Transport/WebSocket/EngineClient.swift");
    for required in [
        "Session history is reconstructed through `session::reconstruct`.",
        "sessionEventSubscriptionCursor(stored: EngineStreamCursor?) -> EngineStreamCursor?",
        "nil",
        "clearActiveStreamSubscriptions(reason: \"explicit disconnect\")",
        "streamCursorStore.save(cursor, for: key)",
        "scheduleStreamAck(subscriptionId: subscriptionId, cursor: cursor)",
        "streamAckCoalescer.removeAll()",
        "streamSubscriptions.removeAll()",
        "streamSubscriptionKeysById.removeAll()",
    ] {
        assert!(
            engine_client.contains(required),
            "EngineClient stream projection lifecycle missing `{required}`"
        );
    }

    let engine_connection = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection.swift",
    );
    for required in [
        "reconnectTask?.cancel()",
        "openTimeoutTask?.cancel()",
        "pingTask?.cancel()",
        "receiveTask?.cancel()",
        "failPendingRequests(error:",
        "setBackgroundState",
        "Cancelling in-flight reconnect for background transition",
        "cleanupDeadConnection",
    ] {
        assert!(
            engine_connection.contains(required),
            "EngineConnection lifecycle missing `{required}`"
        );
    }
    let engine_receiving = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection+Receiving.swift",
    );
    for required in [
        "timeoutTasks.values.forEach { $0.cancel() }",
        "pendingRequests.removeAll()",
        "timeoutTasks.removeAll()",
    ] {
        assert!(
            engine_receiving.contains(required),
            "EngineConnection request cleanup missing `{required}`"
        );
    }
    let connection_manager =
        read_repo_file("packages/ios-app/Sources/Engine/Transport/Retry/ConnectionManager.swift");
    for required in [
        "deinit",
        "observationTask?.cancel()",
        "hooks.removeAll()",
        "runOnReconnect",
        "cancelHook(label: String)",
    ] {
        assert!(
            connection_manager.contains(required),
            "ConnectionManager hook lifecycle missing `{required}`"
        );
    }

    let settings_state =
        read_repo_file("packages/ios-app/Sources/Session/Chat/State/SettingsState.swift");
    for required in [
        "Observable state for server-authoritative settings",
        "settingsRepository.get()",
        "settingsRepository.resetToDefaults",
        "clearServerSnapshot()",
        "rollbackToLastLoadedSettings",
        "applyServerSettings",
        "lastLoadedSettings = settings",
        "Every field is overwritten from the active server's effective settings.",
    ] {
        assert!(
            settings_state.contains(required),
            "SettingsState server snapshot lifecycle missing `{required}`"
        );
    }

    let paired_store =
        read_repo_file("packages/ios-app/Sources/Support/Pairing/PairedServerStore.swift");
    for required in [
        "iOS-local source of truth for paired servers and active selection.",
        "There is intentionally no migration from the removed server-side pairing",
        "fresh store starts empty",
        "serversKey",
        "activeIdKey",
        "normalizeActiveSelection()",
        "func replace(",
        "func select(",
        "func remove(",
        "shouldReturnToOnboarding: servers.isEmpty",
    ] {
        assert!(
            paired_store.contains(required),
            "PairedServerStore local lifecycle missing `{required}`"
        );
    }

    let token_store =
        read_repo_file("packages/ios-app/Sources/Support/Storage/PairedServerTokenStore.swift");
    for required in [
        "Per-paired-server bearer-token registry",
        "Keychain",
        "keychainServicePrefix",
        "func setToken",
        "func token(forServerId",
        "func remove(serverId",
        "account: id",
    ] {
        assert!(
            token_store.contains(required),
            "PairedServerTokenStore secret lifecycle missing `{required}`"
        );
    }

    let draft_store = read_repo_file("packages/ios-app/Sources/Support/Storage/DraftStore.swift");
    for required in [
        "debounceTask?.cancel()",
        "pendingSessionId",
        "pendingInputBarState",
        "flushPending()",
        "clearDraft(sessionId:",
        "deleteSessionDraft(sessionId:",
        "removeAttachmentFiles(sessionId:",
        "removeAllDraftFiles()",
    ] {
        assert!(
            draft_store.contains(required),
            "DraftStore local workflow lifecycle missing `{required}`"
        );
    }
    let history_store =
        read_repo_file("packages/ios-app/Sources/Support/Storage/InputHistoryStore.swift");
    for required in [
        "storageKey = \"tron.inputHistory\"",
        "maxHistorySize = 100",
        "history = Array(history.prefix(maxHistorySize))",
        "resetNavigation()",
        "clearHistory()",
        "UserDefaults.standard.removeObject",
    ] {
        assert!(
            history_store.contains(required),
            "InputHistoryStore local lifecycle missing `{required}`"
        );
    }

    let shared_content =
        read_repo_file("packages/ios-app/Sources/Support/Share/SharedContent.swift");
    for required in [
        "App Group UserDefaults",
        "static let suiteName",
        "static func save",
        "static func load",
        "static func clear",
        "suite.removeObject(forKey: key)",
    ] {
        assert!(
            shared_content.contains(required),
            "PendingShareService handoff lifecycle missing `{required}`"
        );
    }

    let metric_store = read_repo_file(
        "packages/ios-app/Sources/Support/Diagnostics/MetricKitDiagnosticsStore.swift",
    );
    for required in [
        "applicationSupportDirectory",
        "MetricKitDiagnostics",
        "preconditionFailure(\"Application Support directory unavailable",
        "private let lock = NSLock()",
        "maxAgeDays",
        "maxFiles",
        "maxTotalBytes",
        "try encoded.write(to: url, options: [.atomic])",
        "pruneStoredPayloadsLocked",
        "fileManager.removeItem",
        "loadPayloads(maxFiles: Int = 50, maxBytes: Int = 1_000_000)",
    ] {
        assert!(
            metric_store.contains(required),
            "MetricKitDiagnosticsStore buffer lifecycle missing `{required}`"
        );
    }
    assert!(
        !metric_store.contains("NSTemporaryDirectory()"),
        "MetricKit diagnostics must not silently move to temporary storage"
    );

    let diagnostics_builder = read_repo_file(
        "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
    );
    assert!(
        !diagnostics_builder.contains("eventDatabaseStorageMode")
            && !diagnostics_builder.contains("storageMode"),
        "Diagnostics bundle must not report deleted event database storage modes"
    );

    let inventory = inventory_by_path();
    for required in [
        "packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/EngineStreamCursorStore.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager+Sync.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/SessionSynchronizer.swift",
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineClient.swift",
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection.swift",
        "packages/ios-app/Sources/Engine/Transport/Retry/ConnectionManager.swift",
        "packages/ios-app/Sources/Session/Chat/State/SettingsState.swift",
        "packages/ios-app/Sources/Support/Composition/DependencyContainer.swift",
        "packages/ios-app/Sources/Support/Diagnostics/MetricKitDiagnosticsStore.swift",
        "packages/ios-app/Sources/Support/Pairing/PairedServerStore.swift",
        "packages/ios-app/Sources/Support/Share/SharedContent.swift",
        "packages/ios-app/Sources/Support/Storage/DraftStore.swift",
        "packages/ios-app/Sources/Support/Storage/InputHistoryStore.swift",
        "packages/ios-app/Sources/Support/Storage/PairedServerTokenStore.swift",
        "packages/ios-app/docs/architecture.md",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-8"))),
            "SOL inventory must tag {required} as part of SOL-8"
        );
    }
    assert!(
        inventory
            .iter()
            .filter(|(path, _)| path.starts_with("packages/ios-app/Sources/"))
            .all(|(_, rows)| rows.iter().all(|row| row.state_class != "canonical_truth")),
        "iOS source inventory rows must not claim canonical server truth"
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
