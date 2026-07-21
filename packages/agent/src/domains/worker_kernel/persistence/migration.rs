use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::types::{WorkerBundle, WorkerState, WorkerTrigger};
use super::store::validate_bundle;

const REBUILD_FORMAT: &str = "tron.worker_index_rebuild.v1";
const IMPORT_FORMAT: &str = "tron.worker_legacy_import.v3";
const IMPORT_MARKER_KEY: &str = "worker_first_retirement_v3";
const IMPORT_REPORT_FILE: &str = "legacy-import-report.v3.json";
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
    "engine_queue_items",
    "trace_records",
];

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RebuildReport {
    format: &'static str,
    rebuilt_at: String,
    workers_indexed: usize,
    versions_indexed: usize,
    disabled_webhooks_requiring_rotation: Vec<String>,
    invalid_bundles: Vec<Value>,
    removed_stale_indexes: Vec<String>,
}

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
    idempotency_rows_rewritten: usize,
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

/// Rebuild the disposable worker catalog and trigger index from canonical
/// filesystem state. Invocation and inbox tables are intentionally retained.
pub(super) fn rebuild_indexes(root: &Path, database: &Path) -> Result<(), String> {
    let mut connection = Connection::open(database)
        .map_err(|error| format!("open worker index for reconstruction: {error}"))?;
    let mut report = RebuildReport {
        format: REBUILD_FORMAT,
        rebuilt_at: chrono::Utc::now().to_rfc3339(),
        workers_indexed: 0,
        versions_indexed: 0,
        disabled_webhooks_requiring_rotation: Vec::new(),
        invalid_bundles: Vec::new(),
        removed_stale_indexes: Vec::new(),
    };
    let mut filesystem_ids = BTreeSet::new();

    for entry in fs::read_dir(root).map_err(|error| format!("scan worker root: {error}"))? {
        let entry = entry.map_err(|error| format!("scan worker entry: {error}"))?;
        let worker_dir = entry.path();
        let worker_id = entry.file_name().to_string_lossy().into_owned();
        if !worker_dir.is_dir() || worker_id.starts_with('.') {
            continue;
        }
        let _ = filesystem_ids.insert(worker_id.clone());
        let state = match read_json::<WorkerState>(&worker_dir.join("worker.json")) {
            Ok(state) if state.worker_id == worker_id => state,
            Ok(_) => {
                report.invalid_bundles.push(json!({
                    "workerId": worker_id,
                    "reason": "worker.json identity does not match its directory",
                }));
                disable_existing_index(&connection, &worker_id, "corrupt")?;
                continue;
            }
            Err(error) => {
                report
                    .invalid_bundles
                    .push(json!({"workerId":worker_id,"reason":error}));
                disable_existing_index(&connection, &worker_id, "corrupt")?;
                continue;
            }
        };

        let versions_dir = worker_dir.join("versions");
        let mut versions = Vec::new();
        if let Ok(entries) = fs::read_dir(&versions_dir) {
            for version_entry in entries.flatten() {
                let version_dir = version_entry.path();
                if !version_dir.is_dir() {
                    continue;
                }
                let version = version_entry.file_name().to_string_lossy().into_owned();
                let manifest_path = version_dir.join("manifest.json");
                let bundle = match read_json::<WorkerBundle>(&manifest_path)
                    .and_then(|bundle| validate_bundle(&bundle).map(|()| bundle))
                {
                    Ok(bundle) => bundle,
                    Err(error) => {
                        report.invalid_bundles.push(json!({
                            "workerId": worker_id,
                            "version": version,
                            "reason": error,
                        }));
                        continue;
                    }
                };
                let expected = tree_version(&version_dir)?;
                if expected != version {
                    report.invalid_bundles.push(json!({
                        "workerId": worker_id,
                        "version": version,
                        "reason": format!("content hash resolves to {expected}"),
                    }));
                    continue;
                }
                versions.push((version, bundle));
            }
        }
        let Some((_, active_bundle)) = versions
            .iter()
            .find(|(version, _)| version == &state.active_version)
        else {
            report.invalid_bundles.push(json!({
                "workerId": worker_id,
                "version": state.active_version,
                "reason": "canonical active version is absent or invalid",
            }));
            disable_existing_index(&connection, &worker_id, "corrupt")?;
            continue;
        };
        let tool_name = active_bundle
            .tool_name
            .as_deref()
            .ok_or_else(|| format!("worker '{worker_id}' active bundle has no toolName"))?;
        let now = state.updated_at.clone();
        let health = if state.retired {
            "retired"
        } else if !state.enabled && state.health == "healthy" {
            "disabled"
        } else {
            state.health.as_str()
        };
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker reconstruction: {error}"))?;
        transaction
            .execute(
                "INSERT INTO workers(worker_id,name,description,tool_name,runner_kind,active_version,enabled,retired,health,created_at,updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)
                 ON CONFLICT(worker_id) DO UPDATE SET name=excluded.name,
                    description=excluded.description,tool_name=excluded.tool_name,
                    runner_kind=excluded.runner_kind,active_version=excluded.active_version,
                    enabled=excluded.enabled,retired=excluded.retired,health=excluded.health,
                    updated_at=excluded.updated_at",
                params![
                    worker_id,
                    active_bundle.name,
                    active_bundle.description,
                    tool_name,
                    active_bundle.runner.kind(),
                    state.active_version,
                    i64::from(state.enabled),
                    i64::from(state.retired),
                    health,
                    now,
                ],
            )
            .map_err(|error| format!("rebuild worker '{worker_id}': {error}"))?;
        transaction
            .execute(
                "INSERT INTO worker_routes(worker_id,worker_version,tool_name,description,routing_json,enabled,updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7)
                 ON CONFLICT(worker_id) DO UPDATE SET worker_version=excluded.worker_version,
                    tool_name=excluded.tool_name,description=excluded.description,
                    routing_json=excluded.routing_json,enabled=excluded.enabled,
                    updated_at=excluded.updated_at",
                params![
                    worker_id,
                    state.active_version,
                    tool_name,
                    active_bundle.description,
                    serde_json::to_string(&active_bundle.routing)
                        .map_err(|error| error.to_string())?,
                    i64::from(state.enabled && !state.retired),
                    now,
                ],
            )
            .map_err(|error| format!("rebuild worker route '{worker_id}': {error}"))?;
        let has_health = transaction
            .query_row(
                "SELECT 1 FROM worker_health WHERE worker_id=?1 LIMIT 1",
                [&worker_id],
                |_| Ok(()),
            )
            .optional()
            .map_err(|error| format!("inspect worker health history: {error}"))?
            .is_some();
        if !has_health {
            transaction
                .execute(
                    "INSERT INTO worker_health(health_id,worker_id,worker_version,status,source,details_json,recorded_at)
                     VALUES (?1,?2,?3,?4,'reconstruction','{}',?5)",
                    params![
                        format!("worker_health_{}", uuid::Uuid::now_v7()),
                        worker_id,
                        state.active_version,
                        health,
                        now,
                    ],
                )
                .map_err(|error| format!("rebuild worker health '{worker_id}': {error}"))?;
        }
        prune_stale_version_indexes(&transaction, &worker_id, &versions, &mut report)?;
        for (version, bundle) in &versions {
            transaction
                .execute(
                    "INSERT INTO worker_versions(worker_id,version,manifest_json,content_hash,created_at)
                     VALUES (?1,?2,?3,?2,?4)
                     ON CONFLICT(worker_id,version) DO UPDATE SET manifest_json=excluded.manifest_json,
                        content_hash=excluded.content_hash",
                    params![
                        worker_id,
                        version,
                        serde_json::to_string(bundle).map_err(|error| error.to_string())?,
                        now,
                    ],
                )
                .map_err(|error| format!("rebuild worker version '{worker_id}@{version}': {error}"))?;
            report.versions_indexed += 1;
        }
        rebuild_triggers(
            &transaction,
            &worker_id,
            &active_bundle.triggers,
            &mut report,
        )?;
        transaction
            .commit()
            .map_err(|error| format!("commit worker reconstruction: {error}"))?;
        report.workers_indexed += 1;
    }

    let indexed_ids = {
        let mut statement = connection
            .prepare("SELECT worker_id FROM workers")
            .map_err(|error| error.to_string())?;
        statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| error.to_string())?
    };
    for worker_id in indexed_ids {
        if !filesystem_ids.contains(&worker_id) {
            connection
                .execute("DELETE FROM workers WHERE worker_id=?1", [&worker_id])
                .map_err(|error| format!("remove stale worker index: {error}"))?;
            report.removed_stale_indexes.push(worker_id);
        }
    }
    write_json_atomic(&root.join("index-rebuild-report.json"), &report)
}

fn prune_stale_version_indexes(
    transaction: &rusqlite::Transaction<'_>,
    worker_id: &str,
    versions: &[(String, WorkerBundle)],
    report: &mut RebuildReport,
) -> Result<(), String> {
    let placeholders = (0..versions.len())
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(",");
    let mut values = vec![rusqlite::types::Value::Text(worker_id.to_owned())];
    values.extend(
        versions
            .iter()
            .map(|(version, _)| rusqlite::types::Value::Text(version.clone())),
    );
    let removed = transaction
        .execute(
            &format!(
                "DELETE FROM worker_versions WHERE worker_id=? AND version NOT IN ({placeholders})"
            ),
            rusqlite::params_from_iter(values),
        )
        .map_err(|error| format!("remove stale worker version indexes: {error}"))?;
    if removed > 0 {
        report
            .removed_stale_indexes
            .push(format!("{worker_id}:worker_versions:{removed}"));
    }
    Ok(())
}

fn rebuild_triggers(
    transaction: &rusqlite::Transaction<'_>,
    worker_id: &str,
    triggers: &[WorkerTrigger],
    report: &mut RebuildReport,
) -> Result<(), String> {
    let prior = {
        let mut statement = transaction
            .prepare(
                "SELECT trigger_id,token_hash,next_run_at,stream_cursor,enabled
                 FROM worker_triggers WHERE worker_id=?1",
            )
            .map_err(|error| error.to_string())?;
        let rows = statement
            .query_map([worker_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    (
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                    ),
                ))
            })
            .map_err(|error| error.to_string())?;
        rows.collect::<rusqlite::Result<HashMap<_, _>>>()
            .map_err(|error| error.to_string())?
    };
    let ids = triggers.iter().map(WorkerTrigger::id).collect::<Vec<_>>();
    if ids.is_empty() {
        transaction
            .execute(
                "DELETE FROM worker_triggers WHERE worker_id=?1",
                [worker_id],
            )
            .map_err(|error| error.to_string())?;
    } else {
        let placeholders = (0..ids.len()).map(|_| "?").collect::<Vec<_>>().join(",");
        let mut values = vec![rusqlite::types::Value::Text(worker_id.to_owned())];
        values.extend(
            ids.iter()
                .map(|id| rusqlite::types::Value::Text((*id).to_owned())),
        );
        transaction
            .execute(
                &format!(
                    "DELETE FROM worker_triggers WHERE worker_id=? AND trigger_id NOT IN ({placeholders})"
                ),
                rusqlite::params_from_iter(values),
            )
            .map_err(|error| error.to_string())?;
    }
    for trigger in triggers {
        let old = prior.get(trigger.id());
        let token_hash = old.and_then(|(token, _, _, _)| token.clone());
        let next_run_at = old
            .and_then(|(_, next, _, _)| next.clone())
            .or_else(|| match trigger {
                WorkerTrigger::Schedule { every_seconds, .. } => Some(
                    (chrono::Utc::now()
                        + chrono::Duration::seconds(
                            i64::try_from(*every_seconds).unwrap_or(i64::MAX),
                        ))
                    .to_rfc3339(),
                ),
                _ => None,
            });
        let stream_cursor = old.map_or(0, |(_, _, cursor, _)| *cursor);
        let enabled = if matches!(trigger, WorkerTrigger::Webhook { .. }) && token_hash.is_none() {
            report
                .disabled_webhooks_requiring_rotation
                .push(format!("{worker_id}:{}", trigger.id()));
            0
        } else {
            old.map_or(1, |(_, _, _, enabled)| *enabled)
        };
        transaction
            .execute(
                "INSERT INTO worker_triggers(worker_id,trigger_id,kind,config_json,token_hash,next_run_at,stream_cursor,enabled)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
                 ON CONFLICT(worker_id,trigger_id) DO UPDATE SET kind=excluded.kind,
                    config_json=excluded.config_json,token_hash=excluded.token_hash,
                    next_run_at=excluded.next_run_at,stream_cursor=excluded.stream_cursor,
                    enabled=excluded.enabled",
                params![
                    worker_id,
                    trigger.id(),
                    trigger.kind(),
                    serde_json::to_string(trigger).map_err(|error| error.to_string())?,
                    token_hash,
                    next_run_at,
                    stream_cursor,
                    enabled,
                ],
            )
            .map_err(|error| format!("rebuild trigger '{}': {error}", trigger.id()))?;
    }
    Ok(())
}

/// Snapshot, import, and transactionally retire the superseded governance
/// planes before any current engine or session schema is opened.
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
        schema_version: 3,
        imported_at,
        source_database: source.display().to_string(),
        source_sha256,
        source_schema_sha256,
        source_inventory_sha256,
        source_counts: counts,
        imported_candidates,
        unconvertible_records,
        invocation_ledger_rebuilt: false,
        idempotency_rows_rewritten: 0,
        payload_refs_removed: 0,
        payload_blobs_removed: 0,
        payload_blobs_reconciled: 0,
        retired_tables: RETIRED_TABLES.iter().map(ToString::to_string).collect(),
    };

    let mut connection = connection;
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|error| format!("begin worker-first retirement transaction: {error}"))?;
    report.idempotency_rows_rewritten = transaction
        .execute(
            "UPDATE engine_idempotency_entries SET replay_behavior_json='\"Reject\"' \
             WHERE replay_behavior_json IN ('\"Compensate\"','\"compensate\"')",
            [],
        )
        .unwrap_or(0);
    report.invocation_ledger_rebuilt =
        crate::engine::retire_legacy_invocation_columns(&transaction)?;
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
        ] {
            if columns.contains(retired) {
                return Err(format!("retired invocation column {retired} remains"));
            }
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

fn disable_existing_index(
    connection: &Connection,
    worker_id: &str,
    health: &str,
) -> Result<(), String> {
    let now = chrono::Utc::now().to_rfc3339();
    connection
        .execute(
            "UPDATE workers SET enabled=0,health=?2,updated_at=?3 WHERE worker_id=?1",
            params![worker_id, health, now],
        )
        .map_err(|error| error.to_string())?;
    connection
        .execute(
            "UPDATE worker_routes SET enabled=0,updated_at=?2 WHERE worker_id=?1",
            params![worker_id, now],
        )
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, String> {
    serde_json::from_slice(
        &fs::read(path).map_err(|error| format!("read {}: {error}", path.display()))?,
    )
    .map_err(|error| format!("decode {}: {error}", path.display()))
}

fn bundle_version(bundle: &WorkerBundle) -> Result<String, String> {
    let canonical = serde_json::to_vec(bundle).map_err(|error| error.to_string())?;
    Ok(hex::encode(Sha256::digest(canonical))[..16].to_owned())
}

fn tree_version(root: &Path) -> Result<String, String> {
    let mut entries = walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;
    entries.retain(|entry| {
        let is_root_hash = entry
            .path()
            .strip_prefix(root)
            .is_ok_and(|relative| relative == Path::new("content.sha256"));
        (entry.file_type().is_file() || entry.file_type().is_symlink()) && !is_root_hash
    });
    entries.sort_by(|left, right| left.path().cmp(right.path()));
    let mut digest = Sha256::new();
    for entry in entries {
        let relative = entry
            .path()
            .strip_prefix(root)
            .map_err(|error| error.to_string())?;
        digest.update(relative.to_string_lossy().as_bytes());
        digest.update([0]);
        if entry.file_type().is_symlink() {
            digest.update(
                fs::read_link(entry.path())
                    .map_err(|error| error.to_string())?
                    .to_string_lossy()
                    .as_bytes(),
            );
            digest.update([0xfe]);
        } else {
            digest.update(fs::read(entry.path()).map_err(|error| error.to_string())?);
            digest.update([0xff]);
        }
    }
    Ok(hex::encode(digest.finalize()))
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

fn write_json_atomic(path: &Path, value: &impl Serialize) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temporary = PathBuf::from(format!("{}.tmp", path.display()));
    fs::write(
        &temporary,
        serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    fs::rename(&temporary, path).map_err(|error| error.to_string())
}

#[cfg(test)]
#[path = "migration_tests.rs"]
mod tests;
