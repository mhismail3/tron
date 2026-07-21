//! One-time import and transactional retirement of superseded engine state.
//!
//! The clean-cut worker engine keeps no steady-state compatibility adapters.
//! Before an existing profile first opens, this importer snapshots the source,
//! preserves complete executable bundles as inactive candidates, reports
//! incomplete records, and removes the retired governance schema atomically.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::types::WorkerBundle;
use super::filesystem::write_json_atomic;
use super::store::validate_bundle;

const IMPORT_FORMAT: &str = "tron.worker_legacy_import.v6";
const IMPORT_MARKER_KEY: &str = "worker_first_retirement_v6";
const IMPORT_REPORT_FILE: &str = "legacy-import-report.v6.json";
const RETIRED_TABLES: &[&str] = &[
    "engine_resource_events",
    "engine_resource_links",
    "engine_resource_versions",
    "engine_resources",
    "engine_resource_type_definitions",
    "engine_grant_events",
    "engine_grants",
    "engine_resource_leases",
    "engine_compensation_records",
    "engine_catalog_functions",
    "engine_catalog_workers",
    "engine_stream_subscriptions",
    "engine_queue_items",
    "trace_records",
];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportReport {
    format: String,
    schema_version: u32,
    imported_at: String,
    source_database: String,
    source_sha256: String,
    source_schema_sha256: String,
    source_inventory_sha256: String,
    source_counts: LegacyCounts,
    imported_candidates: Vec<Value>,
    unconvertible_records: Vec<Value>,
    invocation_ledger_rebuilt: bool,
    catalog_changes_retired: usize,
    payload_refs_removed: usize,
    payload_blobs_removed: usize,
    payload_blobs_reconciled: usize,
    retired_tables: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyCounts {
    resource_types: usize,
    resources: usize,
    resource_versions: usize,
    resource_links: usize,
    resource_events: usize,
    grants: usize,
    grant_events: usize,
    resource_leases: usize,
    compensation_records: usize,
    invocations: usize,
}

pub(super) fn prepare_worker_first_retirement(
    home: &Path,
    source_label: &str,
    source: &Path,
) -> Result<(), String> {
    prepare_worker_first_retirement_with_fault(home, source_label, source, false)
}

fn prepare_worker_first_retirement_with_fault(
    home: &Path,
    source_label: &str,
    source: &Path,
    fail_before_commit: bool,
) -> Result<(), String> {
    if !source.is_file() {
        return Ok(());
    }
    let connection = Connection::open(source)
        .map_err(|error| format!("open legacy state for worker-first retirement: {error}"))?;
    connection
        .busy_timeout(std::time::Duration::from_secs(5))
        .map_err(|error| format!("configure retirement database timeout: {error}"))?;
    connection
        .execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA wal_checkpoint(TRUNCATE);",
        )
        .map_err(|error| format!("checkpoint state before worker-first snapshot: {error}"))?;
    let root = home
        .join(crate::shared::foundation::paths::dirs::WORKSPACE)
        .join(crate::shared::foundation::paths::dirs::WORKERS);
    fs::create_dir_all(&root).map_err(|error| format!("create worker root: {error}"))?;
    let report_path = root.join(IMPORT_REPORT_FILE);

    if let Some(stored) = read_retirement_marker(&connection)? {
        verify_retired_schema(&connection)?;
        write_json_atomic(&report_path, &stored)?;
        return Ok(());
    }
    let counts = legacy_counts(&connection)?;
    let source_schema_sha256 = legacy_schema_hash(&connection)?;
    let source_inventory_sha256 = legacy_inventory_hash(&connection)?;
    let source_sha256 = file_sha256(source)?;
    let snapshot_inventory_sha256 =
        retirement_source_fingerprint(&source_schema_sha256, &source_inventory_sha256, &counts)?;
    super::snapshot::ensure_pre_worker_snapshot(home, source_label, &snapshot_inventory_sha256)
        .map_err(|error| format!("create verified worker-first retirement snapshot: {error}"))?;
    let imported_at = chrono::Utc::now().to_rfc3339();
    let (imported_candidates, unconvertible_records) =
        collect_legacy_candidates(&connection, &root, &imported_at)?;
    let mut report = ImportReport {
        format: IMPORT_FORMAT.to_owned(),
        schema_version: 6,
        imported_at,
        source_database: source.display().to_string(),
        source_sha256,
        source_schema_sha256,
        source_inventory_sha256,
        source_counts: counts,
        imported_candidates,
        unconvertible_records,
        invocation_ledger_rebuilt: false,
        catalog_changes_retired: 0,
        payload_refs_removed: 0,
        payload_blobs_removed: 0,
        payload_blobs_reconciled: 0,
        retired_tables: RETIRED_TABLES.iter().map(ToString::to_string).collect(),
    };

    let mut connection = connection;
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|error| format!("begin worker-first retirement transaction: {error}"))?;
    crate::engine::retire_legacy_idempotency_replay_column(&transaction)?;
    crate::engine::migrate_profile_idempotency_scope(&transaction)?;
    report.invocation_ledger_rebuilt =
        crate::engine::retire_legacy_invocation_columns(&transaction)?;
    report.catalog_changes_retired = retire_legacy_catalog_changes(&transaction)?;
    let cleanup = crate::shared::storage::retire_payload_refs_by_owner_kind(
        &transaction,
        &[
            "engine_resource_version",
            "engine_compensation",
            "engine_queue_item",
        ],
    )
    .map_err(|error| format!("retire legacy payload ownership: {error}"))?;
    report.payload_refs_removed = cleanup.refs_removed;
    report.payload_blobs_removed = cleanup.blobs_removed;
    report.payload_blobs_reconciled = cleanup.blobs_reconciled;
    transaction
        .execute_batch(
            "DROP TABLE IF EXISTS engine_resource_events;
             DROP TABLE IF EXISTS engine_resource_links;
             DROP TABLE IF EXISTS engine_resource_versions;
             DROP TABLE IF EXISTS engine_resources;
             DROP TABLE IF EXISTS engine_resource_type_definitions;
             DROP TABLE IF EXISTS engine_grant_events;
             DROP TABLE IF EXISTS engine_resource_leases;
             DROP TABLE IF EXISTS engine_compensation_records;
             DROP TABLE IF EXISTS engine_grants;
             DROP TABLE IF EXISTS engine_queue_items;
             DROP TABLE IF EXISTS engine_catalog_functions;
             DROP TABLE IF EXISTS engine_catalog_workers;
             DROP TABLE IF EXISTS engine_stream_subscriptions;
             DROP TABLE IF EXISTS trace_records;",
        )
        .map_err(|error| format!("drop retired worker-first tables: {error}"))?;
    let report_json = serde_json::to_string(&report).map_err(|error| error.to_string())?;
    transaction
        .execute(
            "INSERT INTO storage_metadata(key,value,updated_at) VALUES (?1,?2,?3)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at",
            params![
                IMPORT_MARKER_KEY,
                report_json,
                chrono::Utc::now().to_rfc3339()
            ],
        )
        .map_err(|error| format!("record worker-first retirement marker: {error}"))?;
    verify_retired_schema(&transaction)?;
    verify_payload_ownership(&transaction)?;
    let integrity: String = transaction
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|error| format!("run post-retirement integrity check: {error}"))?;
    if integrity != "ok" {
        return Err(format!(
            "post-retirement integrity check failed: {integrity}"
        ));
    }
    let foreign_key_violation = transaction
        .query_row("SELECT 1 FROM pragma_foreign_key_check LIMIT 1", [], |_| {
            Ok(())
        })
        .optional()
        .map_err(|error| format!("run post-retirement foreign-key check: {error}"))?
        .is_some();
    if foreign_key_violation {
        return Err("post-retirement foreign-key check failed".to_owned());
    }
    if fail_before_commit {
        return Err("injected worker-first retirement failure before commit".to_owned());
    }
    transaction
        .commit()
        .map_err(|error| format!("commit worker-first retirement: {error}"))?;
    write_json_atomic(&report_path, &report)
}

fn read_retirement_marker(connection: &Connection) -> Result<Option<ImportReport>, String> {
    if !table_exists(connection, "storage_metadata")? {
        return Ok(None);
    }
    let stored = connection
        .query_row(
            "SELECT value FROM storage_metadata WHERE key=?1",
            [IMPORT_MARKER_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| format!("read worker-first retirement marker: {error}"))?;
    stored
        .map(|value| {
            serde_json::from_str::<ImportReport>(&value)
                .map_err(|error| format!("decode worker-first retirement marker: {error}"))
        })
        .transpose()
}

fn retire_legacy_catalog_changes(transaction: &rusqlite::Transaction<'_>) -> Result<usize, String> {
    if !table_exists(transaction, "engine_catalog_changes")? {
        return Ok(0);
    }
    transaction
        .execute(
            "DELETE FROM engine_catalog_changes
             WHERE kind_json IN (
                    '\"TriggerRegistered\"','\"TriggerTypeRegistered\"',
                    '\"WorkerRegistered\"','\"WorkerUpdated\"','\"WorkerUnregistered\"'
                  )
                OR subject_kind_json IN ('\"Trigger\"','\"TriggerType\"','\"Worker\"')",
            [],
        )
        .map_err(|error| format!("retire legacy trigger catalog history: {error}"))
}

fn collect_legacy_candidates(
    connection: &Connection,
    root: &Path,
    imported_at: &str,
) -> Result<(Vec<Value>, Vec<Value>), String> {
    if !table_exists(connection, "engine_resources")?
        || !table_exists(connection, "engine_resource_versions")?
    {
        return Ok((Vec::new(), Vec::new()));
    }
    let mut imported = Vec::new();
    let mut unconvertible = Vec::new();
    let mut statement = connection
        .prepare(
            "SELECT r.resource_id,r.kind,r.lifecycle,v.version_id,v.content_hash,v.payload_json
             FROM engine_resources r
             JOIN engine_resource_versions v ON v.version_id=r.current_version_id
             WHERE r.kind='module_proposal' OR r.kind='procedural_candidate'
                OR r.kind='procedural_record' OR r.kind LIKE '%worker%'
                OR r.kind LIKE '%package%'
             ORDER BY r.resource_id",
        )
        .map_err(|error| format!("prepare legacy candidate inventory: {error}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
            ))
        })
        .map_err(|error| format!("query legacy candidate inventory: {error}"))?;
    for row in rows {
        let (resource_id, kind, lifecycle, source_version, content_hash, stored_payload) =
            row.map_err(|error| format!("decode legacy candidate inventory: {error}"))?;
        let payload =
            match crate::shared::storage::resolve_stored_json_value(connection, &stored_payload) {
                Ok(payload) => payload,
                Err(error) => {
                    unconvertible.push(json!({
                        "resourceId":resource_id,"kind":kind,"lifecycle":lifecycle,
                        "sourceVersion":source_version,"contentHash":content_hash,
                        "reason":format!("payload could not be resolved: {error}"),
                    }));
                    continue;
                }
            };
        let candidate = payload
            .get("workerBundle")
            .or_else(|| payload.get("bundle"))
            .unwrap_or(&payload);
        let bundle = serde_json::from_value::<WorkerBundle>(candidate.clone())
            .map_err(|error| error.to_string())
            .and_then(|bundle| validate_bundle(&bundle).map(|()| bundle));
        match bundle {
            Ok(bundle) => {
                let version = bundle_version(&bundle)?;
                let candidate_id = bundle
                    .worker_id
                    .clone()
                    .unwrap_or_else(|| safe_slug(&bundle.name));
                let directory = root
                    .join(".candidates")
                    .join(&candidate_id)
                    .join(&version);
                publish_inactive_candidate(
                    &directory,
                    &bundle,
                    &json!({
                        "status":"inactive_candidate",
                        "sourceResourceId":resource_id,
                        "sourceKind":kind,
                        "sourceLifecycle":lifecycle,
                        "sourceVersion":source_version,
                        "sourceContentHash":content_hash,
                        "importedAt":imported_at,
                    }),
                )?;
                imported.push(json!({
                    "resourceId":resource_id,"kind":kind,"candidateId":candidate_id,
                    "sourceVersion":source_version,"contentHash":content_hash,
                    "version":version,"path":directory,
                }));
            }
            Err(error) => unconvertible.push(json!({
                "resourceId":resource_id,"kind":kind,"lifecycle":lifecycle,
                "sourceVersion":source_version,"contentHash":content_hash,
                "reason":format!("record does not contain a complete executable worker bundle: {error}"),
            })),
        }
    }
    Ok((imported, unconvertible))
}

fn publish_inactive_candidate(
    directory: &Path,
    bundle: &WorkerBundle,
    candidate: &Value,
) -> Result<(), String> {
    if directory.join("manifest.json").is_file() && directory.join("candidate.json").is_file() {
        return Ok(());
    }
    let parent = directory
        .parent()
        .ok_or_else(|| "inactive candidate has no parent directory".to_owned())?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let staging = parent.join(format!(".{}.staging", uuid::Uuid::now_v7()));
    fs::create_dir(&staging).map_err(|error| error.to_string())?;
    write_json_atomic(&staging.join("manifest.json"), bundle)?;
    write_json_atomic(&staging.join("candidate.json"), candidate)?;
    if directory.exists() {
        fs::remove_dir_all(&staging).map_err(|error| error.to_string())?;
    } else {
        fs::rename(&staging, directory).map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn legacy_counts(connection: &Connection) -> Result<LegacyCounts, String> {
    Ok(LegacyCounts {
        resource_types: table_count(connection, "engine_resource_type_definitions")?,
        resources: table_count(connection, "engine_resources")?,
        resource_versions: table_count(connection, "engine_resource_versions")?,
        resource_links: table_count(connection, "engine_resource_links")?,
        resource_events: table_count(connection, "engine_resource_events")?,
        grants: table_count(connection, "engine_grants")?,
        grant_events: table_count(connection, "engine_grant_events")?,
        resource_leases: table_count(connection, "engine_resource_leases")?,
        compensation_records: table_count(connection, "engine_compensation_records")?,
        invocations: table_count(connection, "engine_invocations")?,
    })
}

fn table_count(connection: &Connection, table: &str) -> Result<usize, String> {
    if !table_exists(connection, table)? {
        return Ok(0);
    }
    let count = connection
        .query_row(&format!("SELECT COUNT(*) FROM \"{table}\""), [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|error| format!("count legacy table {table}: {error}"))?;
    usize::try_from(count).map_err(|_| format!("legacy table {table} count was negative"))
}

fn table_exists(connection: &Connection, table: &str) -> Result<bool, String> {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
            [table],
            |_| Ok(()),
        )
        .optional()
        .map(|value| value.is_some())
        .map_err(|error| format!("inspect table {table}: {error}"))
}

fn legacy_schema_hash(connection: &Connection) -> Result<String, String> {
    let mut statement = connection
        .prepare(
            "SELECT name,COALESCE(sql,'') FROM sqlite_master
             WHERE type IN ('table','index') ORDER BY type,name",
        )
        .map_err(|error| format!("prepare source schema inventory: {error}"))?;
    let mut digest = Sha256::new();
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|error| format!("query source schema inventory: {error}"))?;
    for row in rows {
        let (name, sql) = row.map_err(|error| error.to_string())?;
        digest.update(name.as_bytes());
        digest.update([0]);
        digest.update(sql.as_bytes());
        digest.update([0xff]);
    }
    Ok(hex::encode(digest.finalize()))
}

fn legacy_inventory_hash(connection: &Connection) -> Result<String, String> {
    let mut digest = Sha256::new();
    if table_exists(connection, "engine_resources")?
        && table_exists(connection, "engine_resource_versions")?
    {
        let mut statement = connection
            .prepare(
                "SELECT r.resource_id,r.kind,r.lifecycle,COALESCE(r.current_version_id,''),
                        COALESCE(v.content_hash,'')
                 FROM engine_resources r
                 LEFT JOIN engine_resource_versions v ON v.version_id=r.current_version_id
                 ORDER BY r.resource_id",
            )
            .map_err(|error| format!("prepare source resource inventory: {error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })
            .map_err(|error| format!("query source resource inventory: {error}"))?;
        for row in rows {
            let row = row.map_err(|error| error.to_string())?;
            for field in [&row.0, &row.1, &row.2, &row.3, &row.4] {
                digest.update(field.as_bytes());
                digest.update([0]);
            }
            digest.update([0xff]);
        }
    }
    Ok(hex::encode(digest.finalize()))
}

fn retirement_source_fingerprint(
    schema_sha256: &str,
    inventory_sha256: &str,
    counts: &LegacyCounts,
) -> Result<String, String> {
    let mut digest = Sha256::new();
    digest.update(schema_sha256.as_bytes());
    digest.update([0]);
    digest.update(inventory_sha256.as_bytes());
    digest.update([0]);
    digest.update(serde_json::to_vec(counts).map_err(|error| error.to_string())?);
    Ok(hex::encode(digest.finalize()))
}

fn verify_retired_schema(connection: &Connection) -> Result<(), String> {
    for table in RETIRED_TABLES {
        if table_exists(connection, table)? {
            return Err(format!(
                "worker-first retirement marker exists but table {table} remains"
            ));
        }
    }
    if table_exists(connection, "engine_invocations")? {
        let mut statement = connection
            .prepare("PRAGMA table_info(engine_invocations)")
            .map_err(|error| error.to_string())?;
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<BTreeSet<_>>>()
            .map_err(|error| error.to_string())?;
        for retired in [
            "authority_grant_id",
            "authority_scopes_json",
            "resource_lease_ids_json",
            "compensation_status",
            "produced_resource_refs_json",
            "trigger_id",
        ] {
            if columns.contains(retired) {
                return Err(format!("retired invocation column {retired} remains"));
            }
        }
    }
    if table_exists(connection, "engine_idempotency_entries")? {
        let mut statement = connection
            .prepare("PRAGMA table_info(engine_idempotency_entries)")
            .map_err(|error| error.to_string())?;
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<BTreeSet<_>>>()
            .map_err(|error| error.to_string())?;
        if columns.contains("replay_behavior_json") {
            return Err("retired idempotency replay column remains".to_owned());
        }
    }
    if table_exists(connection, "engine_catalog_changes")? {
        let retired_changes: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM engine_catalog_changes
                 WHERE kind_json IN (
                        '\"TriggerRegistered\"','\"TriggerTypeRegistered\"',
                        '\"WorkerRegistered\"','\"WorkerUpdated\"','\"WorkerUnregistered\"'
                      )
                    OR subject_kind_json IN ('\"Trigger\"','\"TriggerType\"','\"Worker\"')",
                [],
                |row| row.get(0),
            )
            .map_err(|error| format!("verify retired catalog history: {error}"))?;
        if retired_changes != 0 {
            return Err(format!("{retired_changes} retired catalog changes remain"));
        }
    }
    Ok(())
}

fn verify_payload_ownership(connection: &Connection) -> Result<(), String> {
    if !table_exists(connection, "storage_payload_refs")? {
        return Ok(());
    }
    let retired_refs: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM storage_payload_refs WHERE owner_kind IN
             ('engine_resource_version','engine_compensation','engine_queue_item')",
            [],
            |row| row.get(0),
        )
        .map_err(|error| format!("verify retired payload refs: {error}"))?;
    if retired_refs != 0 {
        return Err(format!("{retired_refs} retired payload refs remain"));
    }
    let mismatched: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM blobs b
             WHERE EXISTS (SELECT 1 FROM storage_payload_refs r WHERE r.payload_blob_id=b.id)
               AND b.ref_count != (SELECT COUNT(*) FROM storage_payload_refs r WHERE r.payload_blob_id=b.id)",
            [],
            |row| row.get(0),
        )
        .map_err(|error| format!("verify payload blob owner counts: {error}"))?;
    if mismatched != 0 {
        return Err(format!(
            "{mismatched} payload blob owner counts are inconsistent"
        ));
    }
    Ok(())
}

fn bundle_version(bundle: &WorkerBundle) -> Result<String, String> {
    let canonical = serde_json::to_vec(bundle).map_err(|error| error.to_string())?;
    Ok(hex::encode(Sha256::digest(canonical))[..16].to_owned())
}

fn file_sha256(path: &Path) -> Result<String, String> {
    Ok(hex::encode(Sha256::digest(
        fs::read(path).map_err(|error| error.to_string())?,
    )))
}

fn safe_slug(value: &str) -> String {
    let slug = value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>();
    let slug = slug.trim_matches('-').to_owned();
    if slug.is_empty() {
        "imported-worker".to_owned()
    } else {
        slug
    }
}

#[cfg(test)]
#[path = "migration_tests.rs"]
mod tests;
