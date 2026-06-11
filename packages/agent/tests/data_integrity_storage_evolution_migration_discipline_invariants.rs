//! Static gates for the Data Integrity Storage Evolution Migration Discipline slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

const SCORECARD_PATH: &str =
    "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-scorecard.md";
const EVIDENCE_PATH: &str = "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv";
const INVARIANT_PATH: &str =
    "packages/agent/tests/data_integrity_storage_evolution_migration_discipline_invariants.rs";
const TARGET_NAME: &str = "data_integrity_storage_evolution_migration_discipline_invariants";

#[derive(Debug)]
struct ScorecardRow {
    id: String,
    weight: u32,
    status: String,
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

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| DISEMD-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "DISEMD scorecard row must have at least five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid scorecard weight in {line}: {error}")),
                status: columns[3].to_owned(),
            }
        })
        .collect()
}

#[test]
fn disemd_scorecard_is_formalized_and_closed() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "DISEMD scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|row| row.weight).sum::<u32>(),
        100,
        "DISEMD row weights must sum to 100"
    );
    for expected in 0..=11 {
        assert!(
            rows.iter()
                .any(|row| row.id == format!("DISEMD-{expected}")),
            "missing DISEMD-{expected}"
        );
    }
    for row in &rows {
        assert_eq!(
            row.status, "passed_after_fix",
            "{} must be closed for final DISEMD closeout",
            row.id
        );
    }
    assert!(scorecard.contains("Status: **complete**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    for required in [
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_PATH,
        "SQLite storage",
        "archive-manifest.json",
        "SAVEPOINT tron_storage_schema",
        "WAL/foreign-key/busy-timeout pragmas",
    ] {
        assert!(
            scorecard.contains(required),
            "scorecard missing required closeout text: {required}"
        );
    }
}

#[test]
fn disemd_evidence_manifest_records_passed_matrix_without_forward_claims() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("Status: **complete**"));
    assert!(evidence.contains("Current score: **100/100**"));
    assert!(
        !evidence.contains("| not_run |"),
        "final evidence manifest must not retain not_run command rows"
    );
    for row in 0..=11 {
        let marker = format!("| DISEMD-{row} | passed_after_fix |");
        assert!(
            evidence.contains(&marker),
            "evidence manifest missing closed row marker {marker}"
        );
    }
    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml event_store::sqlite --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml event_store::store --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(&format!("| `{command}` | pass |")),
            "evidence manifest must record command as pass: {command}"
        );
    }
    assert!(
        evidence.contains("git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj"),
        "evidence must include the XcodeGen project drift check"
    );
}

#[test]
fn disemd_inventory_is_structured_and_covers_all_rows() {
    let inventory = read_repo_file(INVENTORY_PATH);
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    assert!(inventory.contains("Status: Complete"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some("id\tpath\tlanguage\tsurface\towner\taction\trationale\tevidence\tdisemd_rows"),
        "DISEMD TSV header changed unexpectedly"
    );

    let mut ids = BTreeSet::new();
    let mut by_path = BTreeMap::new();
    let mut covered_rows = BTreeSet::new();
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

    for line in lines {
        let columns: Vec<_> = line.split('\t').collect();
        assert_eq!(
            columns.len(),
            9,
            "inventory row must have 9 columns: {line}"
        );
        assert!(
            ids.insert(columns[0].to_owned()),
            "duplicate DISEMD inventory id {}",
            columns[0]
        );
        assert!(
            columns[0].starts_with("DISEMD-INV-"),
            "inventory id must use DISEMD prefix: {}",
            columns[0]
        );
        assert!(
            allowed_surfaces.contains(columns[3]),
            "{} has unknown surface {}",
            columns[0],
            columns[3]
        );
        for (field, value) in [
            ("path", columns[1]),
            ("language", columns[2]),
            ("owner", columns[4]),
            ("action", columns[5]),
            ("rationale", columns[6]),
            ("evidence", columns[7]),
            ("disemd_rows", columns[8]),
        ] {
            assert!(
                !value.trim().is_empty()
                    && !value.contains("TBD")
                    && !value.contains("TODO")
                    && !value.contains("unclassified"),
                "{} has invalid {field} field: {value}",
                columns[0]
            );
        }
        assert!(
            by_path.insert(columns[1].to_owned(), columns[0]).is_none(),
            "inventory has duplicate path {}",
            columns[1]
        );
        for row in columns[8].split(',') {
            covered_rows.insert(row.to_owned());
        }
    }

    assert!(
        ids.len() >= 95,
        "DISEMD inventory should cover the audited storage surface set"
    );
    for row in 0..=11 {
        assert!(
            covered_rows.contains(&format!("DISEMD-{row}")),
            "inventory does not cover DISEMD-{row}"
        );
    }
    for required_path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_PATH,
        "packages/agent/src/shared/storage/archive.rs",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/shared/storage/maintenance.rs",
        "packages/agent/src/domains/session/event_store/sqlite/connection.rs",
        "packages/agent/src/domains/session/event_store/sqlite/process_lock.rs",
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift",
        "scripts/tron.d/quality.sh",
        ".github/workflows/ci.yml",
    ] {
        assert!(
            by_path.contains_key(required_path),
            "DISEMD inventory missing required path {required_path}"
        );
    }
}

#[test]
fn disemd_readme_ci_and_predecessor_wiring_are_present() {
    let readme = read_repo_file("README.md");
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_PATH,
        TARGET_NAME,
        "Data Integrity Storage Evolution Migration Discipline",
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }

    let local_quality = read_repo_file("scripts/tron.d/quality.sh");
    assert!(
        local_quality.contains(TARGET_NAME),
        "local closeout target list must include DISEMD invariant"
    );
    let github_ci = read_repo_file(".github/workflows/ci.yml");
    assert!(
        github_ci.contains(&format!("cargo test --test {TARGET_NAME} -- --quiet")),
        "GitHub static gates must include DISEMD invariant"
    );

    let saastc_inventory =
        read_repo_file("packages/agent/docs/off-plan-successor-teardown-cleanup-inventory.tsv");
    for required_path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_PATH,
    ] {
        assert!(
            saastc_inventory.contains(required_path),
            "OPSTC inventory must account for DISEMD artifact {required_path}"
        );
    }
}

#[test]
fn disemd_source_contracts_are_guarded() {
    let archive = read_repo_file("packages/agent/src/shared/storage/archive.rs");
    for required in [
        "archive-manifest.json",
        "orphaned WAL/SHM sidecars without active tron.sqlite",
        "failed to inspect active database generation",
        "unique_archive_dir",
    ] {
        assert!(archive.contains(required), "archive.rs missing {required}");
    }

    let schema = read_repo_file("packages/agent/src/shared/storage/schema.rs");
    for required in [
        "SAVEPOINT tron_storage_schema",
        "ROLLBACK TO SAVEPOINT tron_storage_schema",
        "verify_storage_schema",
        "verify_table_columns",
        "verify_payload_blob_integrity",
        "storage_payload_refs",
        "payload_blob_id",
    ] {
        assert!(schema.contains(required), "schema.rs missing {required}");
    }

    let maintenance = read_repo_file("packages/agent/src/shared/storage/maintenance.rs");
    for required in [
        "failed to begin storage retention transaction",
        "DELETE FROM storage_payload_refs",
        "DELETE FROM blobs",
        "failed to commit storage retention transaction",
        "PRAGMA wal_checkpoint(PASSIVE)",
    ] {
        assert!(
            maintenance.contains(required),
            "maintenance.rs missing {required}"
        );
    }

    for path in [
        "packages/agent/src/engine/authority/compensation.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains("apply_runtime_pragmas(&conn)"),
            "{path} must apply shared storage runtime pragmas"
        );
        assert!(
            source.contains("ensure_storage_schema(&conn)"),
            "{path} must validate shared storage schema"
        );
    }

    let tests = read_repo_file("packages/agent/src/shared/storage/tests.rs");
    for required in [
        "malformed_generation_marker_fails_closed_without_archiving_active_db",
        "orphaned_wal_and_shm_sidecars_are_archived_before_fresh_startup",
        "storage_schema_drift_fails_closed_before_retention_deletes_rows",
        "dangling_payload_blob_refs_fail_storage_integrity_checks",
        "retention_prunes_expired_payload_refs_and_their_now_unowned_blobs",
    ] {
        assert!(tests.contains(required), "storage tests missing {required}");
    }
}
