//! Static gates for the Data Integrity Storage Evolution Migration Discipline slice.

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
const INVARIANT_PATH: &str =
    "packages/agent/tests/data_integrity_storage_evolution_migration_discipline_invariants.rs";
const TARGET_NAME: &str = "data_integrity_storage_evolution_migration_discipline_invariants";

#[derive(Debug)]
struct ScorecardRow {
    id: String,
    name: String,
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

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| DSEMD-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "scorecard row must have 5 columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid scorecard weight in {line}: {error}")),
                status: columns[3].to_owned(),
            }
        })
        .collect()
}

fn parse_inventory_rows() -> Vec<Vec<String>> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tlanguage\tsurface\towner\tschema_or_path_mechanism\tlock_or_transaction_behavior\tgeneration_or_version_behavior\tcrash_restart_or_archive_behavior\tverification\tdsemd_rows"
        ),
        "DSEMD inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

#[test]
fn dsemd_scorecard_rows_are_weighted_and_named_exactly() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        ("DSEMD-0", ("Harness, Baseline, and Scope Inventory", 6_u32)),
        (
            "DSEMD-1",
            ("Storage Ownership and Canonical Path Discipline", 10),
        ),
        (
            "DSEMD-2",
            (
                "SQLite Schema Ownership, Migrations, and Drift Rejection",
                14,
            ),
        ),
        (
            "DSEMD-3",
            (
                "Transaction, Lock, WAL, Checkpoint, and Crash/Restart Safety",
                14,
            ),
        ),
        (
            "DSEMD-4",
            (
                "Archive, Generation Marker, Reset, and Clean-Break Semantics",
                12,
            ),
        ),
        (
            "DSEMD-5",
            (
                "Engine Durability Stores: Ledger, Queue, Streams, Resources",
                12,
            ),
        ),
        (
            "DSEMD-6",
            (
                "Session Event Store, Logs, Replay, and Provider Audit Integrity",
                10,
            ),
        ),
        (
            "DSEMD-7",
            ("Script/CLI Data Handling and Runtime State Hygiene", 8),
        ),
        (
            "DSEMD-8",
            (
                "Negative Guards Against Silent Corruption and Compatibility Drift",
                8,
            ),
        ),
        (
            "DSEMD-9",
            ("Evidence, Broad Verification, and Clean Commit", 6),
        ),
    ]);
    assert_eq!(rows.len(), expected.len(), "DSEMD must contain rows 0..9");
    let mut total = 0;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected DSEMD row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        total += row.weight;
    }
    assert_eq!(total, 100, "DSEMD scorecard weights must sum to 100");

    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.weight)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "DSEMD current score must equal closed row weights"
    );
}

#[test]
fn dsemd_inventory_is_structured_and_covers_required_surfaces() {
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    let rows = parse_inventory_rows();
    assert!(rows.len() >= 55, "DSEMD inventory row count regressed");
    let allowed_surfaces = BTreeSet::from([
        "campaign_harness",
        "path_policy",
        "shared_storage",
        "event_store",
        "engine_durability",
        "profile_auth",
        "script_cli",
        "ios_projection",
        "predecessor_inventory",
    ]);
    let mut ids = BTreeSet::new();
    let mut by_path = BTreeMap::new();
    let mut covered_rows = BTreeSet::new();
    for row in rows {
        assert_eq!(
            row.len(),
            11,
            "DSEMD inventory row must have 11 fields: {row:?}"
        );
        assert!(
            ids.insert(row[0].clone()),
            "duplicate DSEMD inventory id {}",
            row[0]
        );
        assert!(row[0].starts_with("DSEMD-INV-"));
        assert!(
            allowed_surfaces.contains(row[3].as_str()),
            "{} has unknown surface {}",
            row[0],
            row[3]
        );
        assert!(
            tracked.contains(&row[1]) || repo_path(&row[1]).exists(),
            "inventory path must be tracked or staged for tracking: {}",
            row[1]
        );
        for value in &row {
            assert!(
                !value.trim().is_empty()
                    && !value.contains("TODO")
                    && !value.contains("TBD")
                    && !value.contains("unclassified"),
                "invalid DSEMD inventory field in row {:?}",
                row
            );
        }
        for row_id in row[10].split(',') {
            covered_rows.insert(row_id.to_owned());
        }
        by_path.insert(row[1].clone(), row[0].clone());
    }
    for row_id in 0..=9 {
        assert!(
            covered_rows.contains(&format!("DSEMD-{row_id}")),
            "DSEMD inventory does not cover DSEMD-{row_id}"
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
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "scripts/reset-db",
        "packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift",
    ] {
        assert!(
            by_path.contains_key(required_path),
            "DSEMD inventory missing required path {required_path}"
        );
    }
}

#[test]
fn dsemd_readme_and_ci_wiring_are_present() {
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
    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(TARGET_NAME),
            "{path} must list DSEMD invariant target"
        );
    }
}

#[test]
fn dsemd_source_contracts_are_guarded() {
    let archive = read_repo_file("packages/agent/src/shared/storage/archive.rs");
    for required in [
        "archive-manifest.json",
        "orphaned WAL/SHM sidecars without active tron.sqlite",
        "failed to inspect active database generation",
        "unique_archive_dir",
        "refusing to overwrite existing archive file",
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
        "storage generation marker mismatch",
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
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/authority/compensation.rs",
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains("apply_runtime_pragmas(&"),
            "{path} must apply shared storage runtime pragmas"
        );
        assert!(
            source.contains("ensure_storage_schema(&"),
            "{path} must validate shared storage schema"
        );
    }

    let tests = read_repo_file("packages/agent/src/shared/storage/tests.rs");
    for required in [
        "malformed_generation_marker_fails_closed_without_archiving_active_db",
        "orphaned_wal_and_shm_sidecars_are_archived_before_fresh_startup",
        "storage_schema_drift_fails_closed_before_marker_rewrite",
        "wrong_storage_generation_marker_is_not_silently_rewritten",
        "dangling_payload_blob_refs_fail_storage_integrity_checks",
        "retention_prunes_expired_payload_refs_and_their_now_unowned_blobs",
    ] {
        assert!(tests.contains(required), "storage tests missing {required}");
    }
}

#[test]
fn dsemd_negative_guards_reject_silent_corruption_patterns() {
    let archive = read_repo_file("packages/agent/src/shared/storage/archive.rs");
    assert!(
        !archive.contains("unwrap_or(None)"),
        "archive generation inspection must not silently swallow errors"
    );

    let schema = read_repo_file("packages/agent/src/shared/storage/schema.rs");
    assert!(
        !schema.contains("ON CONFLICT(key) DO UPDATE SET value = excluded.value"),
        "storage generation marker must not be silently rewritten"
    );

    for path in ["packages/agent/src/shared/storage/mod.rs", INVENTORY_PATH] {
        let source = read_repo_file(path);
        for forbidden in [
            "compatibility reader",
            "legacy fallback",
            "best effort migration",
            "silently repair",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} contains silent compatibility wording: {forbidden}"
            );
        }
    }

    for path in git_ls_files() {
        if !(path.starts_with("packages/agent/tests/")
            || path.starts_with("scripts/")
            || path == "README.md")
        {
            continue;
        }
        if path == INVARIANT_PATH {
            continue;
        }
        let is_text_path = path.ends_with(".rs")
            || path.ends_with(".sh")
            || path.ends_with(".py")
            || path.ends_with(".md")
            || path == "scripts/tron";
        if !is_text_path {
            continue;
        }
        let source = read_repo_file(&path);
        let unsafe_remove_dir_all = ["remove_dir_all(", "paths::tron_home"].join("");
        if source.contains("rm -rf \"$TRON_HOME\"")
            || source.contains("rm -rf ~/.tron")
            || source.contains(&unsafe_remove_dir_all)
        {
            panic!("{path} contains unsafe ad hoc Tron home deletion");
        }
    }
}

fn extract_sqlite_table_names(source: &str) -> BTreeSet<String> {
    const MARKER: &str = "CREATE TABLE IF NOT EXISTS ";
    source
        .lines()
        .filter_map(|line| {
            let marker_start = line.find(MARKER)?;
            let rest = &line[marker_start + MARKER.len()..];
            let table_name: String = rest
                .chars()
                .take_while(|ch| ch.is_ascii_alphanumeric() || *ch == '_')
                .collect();
            (!table_name.is_empty()).then_some(table_name)
        })
        .collect()
}

fn readme_database_table_names() -> BTreeSet<String> {
    let readme = read_repo_file("README.md");
    let mut in_table_section = false;
    let mut saw_table_row = false;
    let mut names = BTreeSet::new();
    for line in readme.lines() {
        if line.trim() == "### Tables" {
            in_table_section = true;
            continue;
        }
        if !in_table_section {
            continue;
        }
        if line.trim().is_empty() {
            if saw_table_row {
                break;
            }
            continue;
        }
        let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
        if columns.len() < 2 || columns[0] == "Table" || columns[0].starts_with("---") {
            continue;
        }
        saw_table_row = true;
        let mut rest = columns[0];
        while let Some(start) = rest.find('`') {
            rest = &rest[start + 1..];
            let end = rest
                .find('`')
                .unwrap_or_else(|| panic!("unclosed README table name literal in {line}"));
            let table_name = &rest[..end];
            assert!(
                table_name
                    .chars()
                    .all(|ch| ch.is_ascii_alphanumeric() || ch == '_'),
                "README database table literal is not a SQLite table name: {table_name}"
            );
            names.insert(table_name.to_owned());
            rest = &rest[end + 1..];
        }
    }
    names
}

#[test]
fn readme_database_schema_table_catalog_matches_sqlite_sources() {
    let schema_sources = [
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_codec.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/resources/store/sqlite_codec.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/authority/compensation.rs",
    ];
    let mut source_tables = BTreeSet::new();
    for path in schema_sources {
        let tables = extract_sqlite_table_names(&read_repo_file(path));
        assert!(
            !tables.is_empty(),
            "schema source declares no tables: {path}"
        );
        source_tables.extend(tables);
    }

    let readme_tables = readme_database_table_names();
    assert!(
        !readme_tables.is_empty(),
        "README Database Schema table catalog was not found"
    );
    assert_eq!(
        readme_tables, source_tables,
        "README Database Schema table catalog must match active SQLite schema sources"
    );
}

#[test]
fn dsemd_closeout_claims_require_concrete_command_results() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    let scorecard = read_repo_file(SCORECARD_PATH);

    if scorecard.contains("Status: **complete**") {
        assert!(scorecard.contains("Current score: **100/100**"));
        for row in 0..=9 {
            assert!(
                evidence.contains(&format!("| DSEMD-{row} | passed_after_fix |")),
                "complete DSEMD evidence missing closed row DSEMD-{row}"
            );
        }
        for command in [
            "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
            "cargo check --manifest-path packages/agent/Cargo.toml",
            "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
            "cargo test --manifest-path packages/agent/Cargo.toml session_event_store --lib -- --nocapture",
            "cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture",
            "scripts/tron ci fmt check clippy test",
            "scripts/personal-info-guard.sh",
            "git diff --check",
            "git ls-files -ci --exclude-standard",
            "git status --short",
        ] {
            assert!(
                evidence.contains(&format!("| `{command}` | pass |")),
                "complete DSEMD evidence missing command pass row: {command}"
            );
        }
        for forbidden in [
            "Status: **active**",
            "in_progress",
            "not yet",
            "not_run",
            "pending",
            "TODO",
            "TBD",
            "open loop",
            "open-loop",
        ] {
            assert!(
                !scorecard.contains(forbidden) && !evidence.contains(forbidden),
                "complete DSEMD artifacts contain stale marker: {forbidden}"
            );
        }
    }
}
