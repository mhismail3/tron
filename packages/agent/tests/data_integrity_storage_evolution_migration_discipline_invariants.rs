//! Static and source-semantic gates for the Data Integrity / Storage Evolution
//! / Migration Discipline campaign.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-scorecard.md";
const EVIDENCE_PATH: &str = "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/data_integrity_storage_evolution_migration_discipline_invariants.rs";
const INVARIANT_TARGET: &str = "data_integrity_storage_evolution_migration_discipline_invariants";
const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\towner\taction\trationale\tevidence\tdisemd_rows";

#[derive(Debug)]
struct ScorecardRow {
    row: String,
    weight: u32,
    status: String,
}

#[derive(Debug, Clone)]
struct InventoryRow {
    id: String,
    path: String,
    language: String,
    surface: String,
    owner: String,
    action: String,
    rationale: String,
    evidence: String,
    disemd_rows: String,
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

fn git_output(args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root())
        .output()
        .unwrap_or_else(|error| panic!("git command failed to start: {args:?}: {error}"));
    assert!(
        output.status.success(),
        "git command failed: {:?}\nstdout:\n{}\nstderr:\n{}",
        args,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("git output should be UTF-8")
}

fn git_ls_files() -> BTreeSet<String> {
    git_output(&["ls-files"])
        .lines()
        .map(str::to_owned)
        .collect()
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| DISEMD-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "scorecard row must have at least 5 columns: {line}"
            );
            ScorecardRow {
                row: columns[1].to_owned(),
                weight: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

fn parse_inventory() -> Vec<InventoryRow> {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = inventory.lines();
    assert_eq!(
        lines.next().expect("inventory TSV must have a header"),
        INVENTORY_HEADER
    );
    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                9,
                "inventory row {} must have 9 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                id: columns[0].to_owned(),
                path: columns[1].to_owned(),
                language: columns[2].to_owned(),
                surface: columns[3].to_owned(),
                owner: columns[4].to_owned(),
                action: columns[5].to_owned(),
                rationale: columns[6].to_owned(),
                evidence: columns[7].to_owned(),
                disemd_rows: columns[8].to_owned(),
            }
        })
        .collect()
}

fn position(source: &str, needle: &str) -> usize {
    source
        .find(needle)
        .unwrap_or_else(|| panic!("source missing required marker: {needle}"))
}

fn is_disemd_complete(scorecard: &str) -> bool {
    scorecard.contains("Status: **complete**")
}

#[test]
fn disemd_harness_docs_readme_and_ci_are_wired() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Data Integrity Storage Evolution Migration Discipline Scorecard",
        "Passing threshold: **100/100**",
        "codex/data-integrity-storage-migration-discipline",
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    assert!(
        scorecard.contains("Status: **complete**") || scorecard.contains("Status: **in progress**"),
        "scorecard must have an explicit DISEMD status"
    );
    for required in [
        "# Data Integrity Storage Evolution Migration Discipline Evidence Manifest",
        "codex/data-integrity-storage-migration-discipline",
        "| DISEMD-0 |",
        "| DISEMD-11 |",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Data Integrity Storage Evolution Migration Discipline Inventory",
        "Status: Complete",
        "`server_storage`",
        "`event_store`",
        "`engine_durability`",
        "`ios_projection`",
        "`cli_dev_boundary`",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        INVARIANT_TARGET,
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }
    for (path, source) in [
        ("scripts/tron.d/quality.sh", local_ci),
        (".github/workflows/ci.yml", github_ci),
    ] {
        assert!(
            source.contains(INVARIANT_TARGET),
            "{path} must include the DISEMD invariant target"
        );
    }
}

#[test]
fn disemd_scorecard_weights_statuses_and_evidence_are_consistent() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "DISEMD scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|row| row.weight).sum::<u32>(),
        100,
        "DISEMD row weights must sum to 100"
    );
    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.weight)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "current score must equal closed DISEMD row weights"
    );
    let complete = is_disemd_complete(&scorecard);
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row in rows {
        assert!(
            matches!(row.status.as_str(), "passed_after_fix" | "in_progress"),
            "{} has invalid status {}",
            row.row,
            row.status
        );
        if complete {
            assert_eq!(
                row.status, "passed_after_fix",
                "{} must be closed at DISEMD closeout",
                row.row
            );
        }
        let required = format!("| {} | {} |", row.row, row.status);
        assert!(
            evidence.contains(&required),
            "evidence missing row status: {required}"
        );
    }
    if complete {
        assert!(
            scorecard.contains("Current score: **100/100**"),
            "complete DISEMD scorecard must be 100/100"
        );
        for required in [
            "Status: **complete**",
            "Current score: **100/100**",
            "| DISEMD-0 | passed_after_fix |",
            "| DISEMD-11 | passed_after_fix |",
        ] {
            assert!(
                evidence.contains(required),
                "complete evidence missing {required}"
            );
        }
        assert!(
            !evidence.contains("| not_run |"),
            "complete evidence must not keep unrun verification rows"
        );
    }
}

#[test]
fn disemd_inventory_is_structured_and_covers_storage_surfaces() {
    let rows = parse_inventory();
    assert!(rows.len() >= 65, "DISEMD inventory row count regressed");
    let tracked = git_ls_files();
    let allowed_surfaces = BTreeSet::from([
        "campaign_harness",
        "server_storage",
        "startup_boundary",
        "event_store",
        "engine_durability",
        "authority_storage",
        "ios_projection",
        "cli_dev_boundary",
        "docs_static_gate",
    ]);
    let mut ids = BTreeSet::new();
    let mut by_path = BTreeMap::new();
    for row in rows {
        assert!(ids.insert(row.id.clone()), "duplicate row id {}", row.id);
        assert!(
            row.id.starts_with("DISEMD-INV-"),
            "inventory id must use DISEMD prefix: {}",
            row.id
        );
        assert!(
            tracked.contains(&row.path) || repo_path(&row.path).exists(),
            "{} must reference a tracked or staged path",
            row.path
        );
        assert!(
            allowed_surfaces.contains(row.surface.as_str()),
            "{} has unexpected surface {}",
            row.id,
            row.surface
        );
        for (field, value) in [
            ("language", row.language.as_str()),
            ("owner", row.owner.as_str()),
            ("action", row.action.as_str()),
            ("rationale", row.rationale.as_str()),
            ("evidence", row.evidence.as_str()),
            ("disemd_rows", row.disemd_rows.as_str()),
        ] {
            assert!(
                !value.trim().is_empty()
                    && !value.contains("TBD")
                    && !value.contains("TODO")
                    && !value.contains("unclassified"),
                "{} has invalid {field}: {value}",
                row.id
            );
        }
        assert!(
            row.disemd_rows.contains("DISEMD-"),
            "{} must reference DISEMD rows",
            row.id
        );
        assert!(
            by_path.insert(row.path.clone(), row.id.clone()).is_none(),
            "duplicate inventory path {}",
            row.path
        );
    }

    for required in required_inventory_paths() {
        assert!(
            by_path.contains_key(*required),
            "DISEMD inventory missing required storage surface: {required}"
        );
    }
}

#[test]
fn startup_archive_schema_and_retention_fail_closed_by_source_contract() {
    let archive = read_repo_file("packages/agent/src/shared/storage/archive.rs");
    assert!(
        !archive.contains("active_database_generation(active_db_path).unwrap_or(None)"),
        "generation marker inspection errors must not be swallowed"
    );
    for required in [
        "orphaned-sidecars",
        "write_archive_manifest",
        "unique_archive_dir",
        "refusing to overwrite existing archive file",
        "failed to inspect active storage generation",
    ] {
        assert!(
            archive.contains(required),
            "archive guard missing {required}"
        );
    }

    let schema = read_repo_file("packages/agent/src/shared/storage/schema.rs");
    for required in [
        "SAVEPOINT tron_storage_schema",
        "ROLLBACK TO SAVEPOINT tron_storage_schema",
        "verify_storage_schema",
        "verify_payload_blob_integrity",
        "storage schema drift",
        "storage payload integrity failed",
    ] {
        assert!(schema.contains(required), "schema guard missing {required}");
    }

    let maintenance = read_repo_file("packages/agent/src/shared/storage/maintenance.rs");
    for required in [
        ".transaction()",
        "failed to begin storage retention transaction",
        "failed to record storage retention run",
        "failed to commit storage retention transaction",
        "PRAGMA wal_checkpoint(PASSIVE)",
    ] {
        assert!(
            maintenance.contains(required),
            "retention guard missing {required}"
        );
    }

    let bootstrap = read_repo_file("packages/agent/src/app/bootstrap/mod.rs");
    let prepare = position(&bootstrap, "prepare_active_database(&db_path)");
    let lock = position(&bootstrap, "acquire_database_lock(&db_path)");
    let open = position(&bootstrap, "new_file(&db_str");
    let integrity = position(&bootstrap, "check_integrity(&conn)");
    let migrations = position(&bootstrap, "run_migrations(&conn)");
    let storage_schema = position(&bootstrap, "ensure_storage_schema(&conn)");
    assert!(
        prepare < lock,
        "startup must prepare/archive before DB lock"
    );
    assert!(
        lock < open,
        "startup must take process lock before opening pool"
    );
    assert!(open < integrity, "startup must open before integrity check");
    assert!(
        integrity < migrations,
        "startup must run integrity check before migrations"
    );
    assert!(
        migrations < storage_schema,
        "startup must run migrations before final storage schema ensure"
    );
}

#[test]
fn engine_authority_sqlite_stores_use_shared_storage_pragmas() {
    for path in [
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/authority/compensation.rs",
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains("apply_runtime_pragmas(&conn)"),
            "{path} must apply shared runtime pragmas to its SQLite connection"
        );
        assert!(
            source.contains("ensure_storage_schema(&conn)"),
            "{path} must validate shared storage schema before using the connection"
        );
    }
}

#[test]
fn event_store_locking_migration_and_payload_contracts_remain_owned() {
    let sqlite_mod = read_repo_file("packages/agent/src/domains/session/event_store/sqlite/mod.rs");
    for required in [
        "r2d2",
        "WAL mode",
        "foreign keys",
        "run transactionally",
        "PRAGMA foreign_key_check",
        "process_lock",
    ] {
        assert!(
            sqlite_mod.contains(required),
            "sqlite docs missing {required}"
        );
    }

    let migrations =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/migrations/mod.rs");
    for required in [
        "const MIGRATIONS: &[Migration] = &[Migration",
        "include_str!(\"v001_schema.sql\")",
        "unchecked_transaction()",
        "PRAGMA foreign_key_check",
        "ensure_storage_schema(conn)",
    ] {
        assert!(
            migrations.contains(required),
            "migration contract missing {required}"
        );
    }

    let event_insert = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/crud.rs",
    );
    for required in ["store_json_value(", "\"session_event\"", "\"audit\""] {
        assert!(
            event_insert.contains(required),
            "event store payload/order contract missing {required}"
        );
    }
    let v001_schema = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    for required in [
        "idx_events_session_sequence_unique",
        "ON events(session_id, sequence)",
    ] {
        assert!(
            v001_schema.contains(required),
            "event store order constraint missing {required}"
        );
    }

    let lock =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/process_lock.rs");
    for required in [
        "LOCK_EX",
        "LOCK_NB",
        "stale_lockfile_is_acquirable_when_holder_dead",
        "holder_pid",
    ] {
        assert!(
            lock.contains(required),
            "process lock contract missing {required}"
        );
    }
}

#[test]
fn ios_persistence_is_projection_not_server_truth() {
    let architecture = read_repo_file("packages/ios-app/docs/architecture.md");
    for required in [
        "owns no canonical server truth",
        "EventDatabase",
        "SQLite projection cache",
    ] {
        assert!(
            architecture.contains(required),
            "iOS architecture docs missing storage boundary: {required}"
        );
    }
    let event_db =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift");
    for required in ["EventDatabase", "DatabaseActor", "DatabaseTransport"] {
        assert!(
            event_db.contains(required),
            "iOS EventDatabase missing expected owner marker: {required}"
        );
    }
    let database_schema = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/SQLite/Schema/DatabaseSchema.swift",
    );
    for required in [
        "PRAGMA user_version",
        "migrate",
        "CREATE TABLE IF NOT EXISTS",
    ] {
        assert!(
            database_schema.contains(required),
            "iOS schema boundary missing {required}"
        );
    }
}

#[test]
fn disemd_closeout_artifacts_reject_stale_open_loop_language() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    if !is_disemd_complete(&scorecard) {
        return;
    }
    for (label, source) in [
        ("scorecard", scorecard),
        ("evidence", read_repo_file(EVIDENCE_PATH)),
        ("inventory", read_repo_file(INVENTORY_PATH)),
    ] {
        let lowered = source.to_lowercase();
        for forbidden in [
            "status: **in progress**",
            "status: in progress",
            "pending closeout",
            "pending row",
            "tbd",
            "todo",
            "simplify",
            "not yet",
        ] {
            assert!(
                !lowered.contains(forbidden),
                "{label} contains stale closeout wording: {forbidden}"
            );
        }
    }
}

fn required_inventory_paths() -> &'static [&'static str] {
    &[
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        "README.md",
        "scripts/tron.d/quality.sh",
        ".github/workflows/ci.yml",
        "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.md",
        "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.tsv",
        "packages/agent/docs/state-ownership-lifecycle-inventory.md",
        "packages/agent/docs/state-ownership-lifecycle-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.md",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/tests/security_authority_capability_boundaries/scorecard_inventory.rs",
        "packages/agent/src/shared/storage/mod.rs",
        "packages/agent/src/shared/storage/archive.rs",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/shared/storage/maintenance.rs",
        "packages/agent/src/shared/storage/payloads.rs",
        "packages/agent/src/shared/storage/stats.rs",
        "packages/agent/src/shared/storage/tests.rs",
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/domains/settings/profile/db_path_policy.rs",
        "packages/agent/src/domains/session/event_store/sqlite/connection.rs",
        "packages/agent/src/domains/session/event_store/sqlite/process_lock.rs",
        "packages/agent/src/domains/session/event_store/sqlite/contention.rs",
        "packages/agent/src/domains/session/event_store/sqlite/migrations/mod.rs",
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
        "packages/agent/src/domains/session/event_store/store/event_store/event_log.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/locking.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/session_lifecycle.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/logs.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/crud.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/blob.rs",
        "packages/agent/src/domains/session/event_store/trace.rs",
        "packages/agent/src/domains/session/reconstruction/mod.rs",
        "packages/agent/src/engine/durability/mod.rs",
        "packages/agent/src/engine/durability/ledger/mod.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_codec.rs",
        "packages/agent/src/engine/durability/queue/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/grants/sqlite_codec.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/authority/compensation.rs",
        "packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift",
        "packages/ios-app/Sources/Engine/Persistence/SQLite/Schema/DatabaseSchema.swift",
        "packages/ios-app/Sources/Engine/Persistence/Repositories/EventRepository.swift",
        "packages/ios-app/Sources/Support/Storage/DraftStore.swift",
        "packages/ios-app/Sources/Support/Diagnostics/MetricKitDiagnosticsStore.swift",
        "scripts/tron-lib.sh",
        "scripts/tron-lib.d/service.sh",
        "scripts/tron-lib.d/logs.sh",
        "scripts/reset-db",
    ]
}
