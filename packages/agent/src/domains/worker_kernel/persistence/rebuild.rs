//! Reconstruction of disposable worker indexes from canonical bundles.
//!
//! Filesystem bundles and active pointers are authoritative. This module only
//! rebuilds routes, versions, triggers, and health projections; invocation,
//! attempt, generic run-stage, and inbox ledgers remain durable operational
//! evidence.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};

use super::super::types::{WorkerBundle, WorkerState, WorkerTrigger};
use super::filesystem::{read_json, tree_version};
use super::store::validate_bundle;

pub(super) fn rebuild_indexes(root: &Path, database: &Path) -> Result<(), String> {
    let mut connection = Connection::open(database)
        .map_err(|error| format!("open worker index for reconstruction: {error}"))?;
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
                tracing::warn!(
                    worker_id,
                    "worker index rebuild ignored mismatched worker identity"
                );
                disable_existing_index(&connection, &worker_id, "corrupt")?;
                continue;
            }
            Err(error) => {
                tracing::warn!(worker_id, %error, "worker index rebuild ignored invalid worker state");
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
                        tracing::warn!(worker_id, version, %error, "worker index rebuild ignored invalid bundle");
                        continue;
                    }
                };
                let expected = tree_version(&version_dir)?;
                if expected != version {
                    tracing::warn!(
                        worker_id,
                        version,
                        expected,
                        "worker index rebuild ignored bundle with mismatched content hash"
                    );
                    continue;
                }
                versions.push((version, bundle));
            }
        }
        let Some((_, active_bundle)) = versions
            .iter()
            .find(|(version, _)| version == &state.active_version)
        else {
            tracing::warn!(
                worker_id,
                version = state.active_version,
                "worker index rebuild disabled worker with absent or invalid active version"
            );
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
                "INSERT INTO workers(worker_id,name,description,tool_name,runner_kind,active_version,enabled,retired,health,presentation_json,created_at,updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11)
                 ON CONFLICT(worker_id) DO UPDATE SET name=excluded.name,
                    description=excluded.description,tool_name=excluded.tool_name,
                    runner_kind=excluded.runner_kind,active_version=excluded.active_version,
                    enabled=excluded.enabled,retired=excluded.retired,health=excluded.health,
                    presentation_json=excluded.presentation_json,
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
                    active_bundle
                        .presentation
                        .as_ref()
                        .map(serde_json::to_string)
                        .transpose()
                        .map_err(|error| error.to_string())?,
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
        prune_stale_version_indexes(&transaction, &worker_id, &versions)?;
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
        }
        rebuild_triggers(&transaction, &worker_id, &active_bundle.triggers)?;
        transaction
            .commit()
            .map_err(|error| format!("commit worker reconstruction: {error}"))?;
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
        }
    }
    Ok(())
}

fn prune_stale_version_indexes(
    transaction: &rusqlite::Transaction<'_>,
    worker_id: &str,
    versions: &[(String, WorkerBundle)],
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
    transaction
        .execute(
            &format!(
                "DELETE FROM worker_versions WHERE worker_id=? AND version NOT IN ({placeholders})"
            ),
            rusqlite::params_from_iter(values),
        )
        .map_err(|error| format!("remove stale worker version indexes: {error}"))?;
    Ok(())
}
fn rebuild_triggers(
    transaction: &rusqlite::Transaction<'_>,
    worker_id: &str,
    triggers: &[WorkerTrigger],
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
