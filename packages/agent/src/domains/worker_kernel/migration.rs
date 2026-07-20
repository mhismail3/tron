use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::store::validate_bundle;
use super::types::{WorkerBundle, WorkerState, WorkerTrigger};

const REBUILD_FORMAT: &str = "tron.worker_index_rebuild.v1";
const IMPORT_FORMAT: &str = "tron.worker_legacy_import.v1";

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

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ImportReport {
    format: &'static str,
    imported_at: String,
    source_database: String,
    source_sha256: Option<String>,
    imported_candidates: Vec<Value>,
    unconvertible_records: Vec<Value>,
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

/// Convert only records that contain a complete executable worker bundle.
/// Metadata-only historical records are explicitly reported instead of being
/// promoted into behavior they never described.
pub(super) fn import_legacy_candidates(home: &Path, root: &Path) -> Result<(), String> {
    let report_path = root.join("legacy-import-report.v1.json");
    if report_path.exists() {
        return Ok(());
    }
    let source = home.join("internal").join("database").join("tron.sqlite");
    let mut report = ImportReport {
        format: IMPORT_FORMAT,
        imported_at: chrono::Utc::now().to_rfc3339(),
        source_database: source.display().to_string(),
        source_sha256: source.is_file().then(|| file_sha256(&source)).transpose()?,
        imported_candidates: Vec::new(),
        unconvertible_records: Vec::new(),
    };
    if !source.is_file() {
        return write_json_atomic(&report_path, &report);
    }
    let connection = Connection::open_with_flags(
        &source,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| format!("open legacy state for worker import: {error}"))?;
    let resources_exist = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='engine_resources'",
            [],
            |_| Ok(()),
        )
        .optional()
        .map_err(|error| error.to_string())?
        .is_some();
    if !resources_exist {
        return write_json_atomic(&report_path, &report);
    }
    let mut statement = connection
        .prepare(
            "SELECT r.resource_id,r.kind,r.lifecycle,v.payload_json
             FROM engine_resources r
             JOIN engine_resource_versions v ON v.version_id=r.current_version_id
             WHERE r.kind='module_proposal' OR r.kind='procedural_candidate'
                OR r.kind='procedural_record' OR r.kind LIKE '%worker%'
                OR r.kind LIKE '%package%'
             ORDER BY r.updated_at",
        )
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })
        .map_err(|error| error.to_string())?;
    for row in rows {
        let (resource_id, kind, lifecycle, payload_json) =
            row.map_err(|error| error.to_string())?;
        let payload: Value = match serde_json::from_str(&payload_json) {
            Ok(payload) => payload,
            Err(error) => {
                report.unconvertible_records.push(json!({
                    "resourceId":resource_id,"kind":kind,"lifecycle":lifecycle,
                    "reason":format!("invalid JSON payload: {error}"),
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
                fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
                write_json_atomic(&directory.join("manifest.json"), &bundle)?;
                write_json_atomic(
                    &directory.join("candidate.json"),
                    &json!({
                        "status":"inactive_candidate",
                        "sourceResourceId":resource_id,
                        "sourceKind":kind,
                        "sourceLifecycle":lifecycle,
                        "importedAt":chrono::Utc::now().to_rfc3339(),
                    }),
                )?;
                report.imported_candidates.push(json!({
                    "resourceId":resource_id,"kind":kind,"candidateId":candidate_id,
                    "version":version,"path":directory,
                }));
            }
            Err(error) => report.unconvertible_records.push(json!({
                "resourceId":resource_id,"kind":kind,"lifecycle":lifecycle,
                "reason":format!("record does not contain a complete executable worker bundle: {error}"),
            })),
        }
    }
    write_json_atomic(&report_path, &report)
}

fn disable_existing_index(
    connection: &Connection,
    worker_id: &str,
    health: &str,
) -> Result<(), String> {
    connection
        .execute(
            "UPDATE workers SET enabled=0,health=?2,updated_at=?3 WHERE worker_id=?1",
            params![worker_id, health, chrono::Utc::now().to_rfc3339()],
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
        entry.file_type().is_file() && entry.file_name().to_string_lossy() != "content.sha256"
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
        digest.update(fs::read(entry.path()).map_err(|error| error.to_string())?);
        digest.update([0xff]);
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
mod tests {
    use super::*;
    use crate::domains::worker_kernel::types::{BUNDLE_SCHEMA, SourceProvenance, WorkerRunner};

    fn complete_bundle() -> WorkerBundle {
        WorkerBundle {
            schema_version: BUNDLE_SCHEMA.to_owned(),
            worker_id: Some("importable-worker".to_owned()),
            name: "Importable Worker".to_owned(),
            description: "A complete executable legacy worker bundle".to_owned(),
            tool_name: Some("worker_importable".to_owned()),
            input_schema: json!({"type":"object"}),
            output_schema: json!({"type":"object"}),
            runner: WorkerRunner::Command {
                command: vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()],
            },
            files: Default::default(),
            dependencies: Vec::new(),
            triggers: vec![WorkerTrigger::Manual {
                id: "manual".to_owned(),
            }],
            secret_bindings: Vec::new(),
            smoke_tests: Vec::new(),
            provenance: vec![SourceProvenance {
                source: "legacy:test".to_owned(),
                revision: Some("1".to_owned()),
                checksum: None,
            }],
            routing: Default::default(),
        }
    }

    #[test]
    fn importer_converts_complete_bundles_and_reports_last30days_metadata_only_record() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join("workspace/workers");
        fs::create_dir_all(&root).unwrap();
        let database = home.path().join("internal/database/tron.sqlite");
        fs::create_dir_all(database.parent().unwrap()).unwrap();
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE engine_resource_versions(
                    version_id TEXT PRIMARY KEY,
                    payload_json TEXT NOT NULL
                 );
                 CREATE TABLE engine_resources(
                    resource_id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    lifecycle TEXT NOT NULL,
                    current_version_id TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                 );",
            )
            .unwrap();
        let bundle_payload = json!({"workerBundle": complete_bundle()}).to_string();
        connection
            .execute(
                "INSERT INTO engine_resource_versions VALUES('v-worker',?1)",
                [&bundle_payload],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO engine_resources VALUES(
                    'worker_package:complete','worker_package','candidate','v-worker','2026-01-01T00:00:00Z'
                 )",
                [],
            )
            .unwrap();
        let inert = json!({
            "proposalId":"last30days",
            "sourceUrl":"https://github.com/mvanhorn/last30days-skill",
            "summary":"metadata without an executable runner or schemas"
        })
        .to_string();
        connection
            .execute(
                "INSERT INTO engine_resource_versions VALUES('v-last30days',?1)",
                [&inert],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO engine_resources VALUES(
                    'module_proposal:0ad5c4402aef2a3421a002ff68b704d8e85e9c73bc08e3f089aca8b85ee72444',
                    'module_proposal','draft','v-last30days','2026-01-02T00:00:00Z'
                 )",
                [],
            )
            .unwrap();
        drop(connection);

        import_legacy_candidates(home.path(), &root).unwrap();

        let report: Value =
            serde_json::from_slice(&fs::read(root.join("legacy-import-report.v1.json")).unwrap())
                .unwrap();
        assert_eq!(report["format"], IMPORT_FORMAT);
        assert_eq!(report["importedCandidates"].as_array().unwrap().len(), 1);
        assert_eq!(report["unconvertibleRecords"].as_array().unwrap().len(), 1);
        assert_eq!(
            report["unconvertibleRecords"][0]["resourceId"],
            "module_proposal:0ad5c4402aef2a3421a002ff68b704d8e85e9c73bc08e3f089aca8b85ee72444"
        );
        assert!(
            report["unconvertibleRecords"][0]["reason"]
                .as_str()
                .unwrap()
                .contains("complete executable worker bundle")
        );
        let imported_path =
            PathBuf::from(report["importedCandidates"][0]["path"].as_str().unwrap());
        assert!(imported_path.join("manifest.json").is_file());
        let candidate: Value =
            serde_json::from_slice(&fs::read(imported_path.join("candidate.json")).unwrap())
                .unwrap();
        assert_eq!(candidate["status"], "inactive_candidate");
        assert!(!root.join("importable-worker/worker.json").exists());
    }
}
