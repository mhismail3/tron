//! Durable content-addressed artifact custody and authenticated inbox reads.

use std::path::Path;

use base64::Engine;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::*;
use crate::domains::worker_kernel::artifacts::ArtifactIntent;
use crate::shared::storage::{DATABASE_STORAGE_BUDGET_MB, StorePayloadOptions};

const ARTIFACT_OWNER_KIND: &str = "worker_artifact";
const ARTIFACT_FIELD_NAME: &str = "content";
const ARTIFACT_RETENTION_CLASS: &str = "user_artifact";
const MAX_ARTIFACT_PAGE: usize = 200;

impl WorkerStore {
    pub(super) fn insert_artifacts(
        transaction: &rusqlite::Transaction<'_>,
        invocation_id: &str,
        worker_id: &str,
        worker_version: &str,
        trace_id: &str,
        artifacts: &[ArtifactIntent],
        created_at: &str,
    ) -> Result<(), String> {
        for artifact in artifacts {
            let owner_id = artifact_owner_id(worker_id, &artifact.artifact_id);
            let content_sha256 =
                format!("sha256:{}", hex::encode(Sha256::digest(&artifact.content)));
            let existing = transaction
                .query_row(
                    "SELECT display_name,media_type,size_bytes,content_sha256
                     FROM worker_artifacts
                     WHERE worker_id=?1 AND artifact_id=?2",
                    params![worker_id, artifact.artifact_id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, i64>(2)?,
                            row.get::<_, String>(3)?,
                        ))
                    },
                )
                .optional()
                .map_err(|error| format!("inspect stable worker artifact: {error}"))?;
            if let Some((display_name, media_type, size_bytes, stored_hash)) = existing {
                if display_name != artifact.display_name
                    || media_type != artifact.media_type
                    || usize::try_from(size_bytes).unwrap_or(usize::MAX) != artifact.size_bytes
                    || stored_hash != content_sha256
                {
                    return Err(format!(
                        "artifact '{}' for worker '{}' is immutable and already names different content",
                        artifact.artifact_id, worker_id
                    ));
                }
                continue;
            }

            let mut options = StorePayloadOptions::new(
                ARTIFACT_OWNER_KIND,
                owner_id,
                ARTIFACT_FIELD_NAME,
                ARTIFACT_RETENTION_CLASS,
            )
            .with_scope(Some(trace_id.to_owned()), None, None)
            .with_redaction_level("binary");
            options.payload_kind = artifact.media_type.clone();
            // Artifact content must always have exact blob custody. Unlike JSON
            // columns, there is intentionally no parallel inline body.
            options.inline_threshold = 0;
            let stored = crate::shared::storage::store_owned_payload_ref(
                transaction,
                &artifact.content,
                &options,
            )
            .map_err(|error| format!("store durable worker artifact: {error:#}"))?;
            if format!("sha256:{}", stored.payload_hash) != content_sha256
                || stored.payload_size_bytes != artifact.size_bytes
            {
                return Err("stored worker artifact identity diverged from admission".to_owned());
            }
            let content_reference = json!({
                "kind":"artifact_content_reference",
                "workerId":worker_id,
                "artifactId":artifact.artifact_id,
                "contentSha256":content_sha256,
                "sizeBytes":artifact.size_bytes,
            });
            transaction
                .execute(
                    "INSERT INTO worker_artifacts(
                        worker_id,artifact_id,display_name,media_type,size_bytes,
                        content_sha256,content_reference_json,content_pointer,
                        source_invocation_id,source_worker_version,trace_id,created_at
                     ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                    params![
                        worker_id,
                        artifact.artifact_id,
                        artifact.display_name,
                        artifact.media_type,
                        i64::try_from(artifact.size_bytes).unwrap_or(i64::MAX),
                        content_sha256,
                        serde_json::to_string(&content_reference)
                            .map_err(|error| error.to_string())?,
                        artifact.content_pointer,
                        invocation_id,
                        worker_version,
                        trace_id,
                        created_at,
                    ],
                )
                .map_err(|error| format!("record durable worker artifact: {error}"))?;
        }
        reconcile_artifact_storage_attention(transaction, invocation_id, worker_id, created_at)?;
        Ok(())
    }

    pub fn artifact_deliveries(&self, limit: usize, offset: usize) -> Result<Value, String> {
        let limit = limit.clamp(1, MAX_ARTIFACT_PAGE);
        let connection = self.connection()?;
        let rows = {
            let mut statement = connection
                .prepare(
                    "SELECT worker_id,artifact_id,display_name,media_type,size_bytes,
                            content_sha256,content_reference_json,source_invocation_id,
                            source_worker_version,trace_id,created_at
                     FROM worker_artifacts
                     ORDER BY created_at DESC,worker_id,artifact_id
                     LIMIT ?1 OFFSET ?2",
                )
                .map_err(|error| format!("prepare artifact inbox: {error}"))?;
            statement
                .query_map(
                    params![
                        i64::try_from(limit).unwrap_or(i64::MAX),
                        i64::try_from(offset).unwrap_or(i64::MAX)
                    ],
                    artifact_row,
                )
                .map_err(|error| format!("query artifact inbox: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode artifact inbox: {error}"))?
        };
        let total: i64 = connection
            .query_row("SELECT COUNT(*) FROM worker_artifacts", [], |row| {
                row.get(0)
            })
            .map_err(|error| format!("count artifacts: {error}"))?;
        let next_offset =
            if offset.saturating_add(rows.len()) < usize::try_from(total).unwrap_or(usize::MAX) {
                Some(offset.saturating_add(rows.len()))
            } else {
                None
            };
        Ok(json!({
            "artifacts":rows,
            "returned":rows.len(),
            "total":total,
            "nextOffset":next_offset,
            "storageAttention":artifact_storage_attention(&connection, &self.database)?,
        }))
    }

    pub fn artifact_content(&self, worker_id: &str, artifact_id: &str) -> Result<Value, String> {
        validate_runtime_identifier(worker_id, "worker id", 128)?;
        validate_runtime_identifier(artifact_id, "artifact id", 128)?;
        let connection = self.connection()?;
        let artifact = connection
            .query_row(
                "SELECT worker_id,artifact_id,display_name,media_type,size_bytes,
                        content_sha256,content_reference_json,source_invocation_id,
                        source_worker_version,trace_id,created_at
                 FROM worker_artifacts
                 WHERE worker_id=?1 AND artifact_id=?2",
                params![worker_id, artifact_id],
                artifact_row,
            )
            .optional()
            .map_err(|error| format!("load artifact metadata: {error}"))?
            .ok_or_else(|| format!("artifact '{worker_id}/{artifact_id}' was not found"))?;
        let content = crate::shared::storage::resolve_owned_payload_bytes(
            &connection,
            ARTIFACT_OWNER_KIND,
            &artifact_owner_id(worker_id, artifact_id),
            ARTIFACT_FIELD_NAME,
        )
        .map_err(|error| format!("resolve durable worker artifact: {error:#}"))?;
        Ok(json!({
            "artifact":artifact,
            "data":base64::engine::general_purpose::STANDARD.encode(content),
        }))
    }

    pub fn delete_artifact(&self, worker_id: &str, artifact_id: &str) -> Result<Value, String> {
        validate_runtime_identifier(worker_id, "worker id", 128)?;
        validate_runtime_identifier(artifact_id, "artifact id", 128)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("start artifact deletion: {error}"))?;
        let source_invocation_id = transaction
            .query_row(
                "SELECT source_invocation_id FROM worker_artifacts
                 WHERE worker_id=?1 AND artifact_id=?2",
                params![worker_id, artifact_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| format!("load artifact deletion source: {error}"))?;
        let deleted = transaction
            .execute(
                "DELETE FROM worker_artifacts WHERE worker_id=?1 AND artifact_id=?2",
                params![worker_id, artifact_id],
            )
            .map_err(|error| format!("delete artifact metadata: {error}"))?
            != 0;
        if deleted {
            crate::shared::storage::delete_owned_payload_refs(
                &transaction,
                ARTIFACT_OWNER_KIND,
                &artifact_owner_id(worker_id, artifact_id),
            )
            .map_err(|error| format!("delete artifact payload owner: {error:#}"))?;
            crate::shared::storage::delete_unowned_blobs(&transaction)
                .map_err(|error| format!("delete unowned artifact blob: {error:#}"))?;
            reconcile_artifact_storage_attention(
                &transaction,
                source_invocation_id
                    .as_deref()
                    .ok_or_else(|| "deleted artifact had no source invocation".to_owned())?,
                worker_id,
                &chrono::Utc::now().to_rfc3339(),
            )?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit artifact deletion: {error}"))?;
        Ok(json!({
            "workerId":worker_id,
            "artifactId":artifact_id,
            "deleted":deleted,
        }))
    }
}

fn reconcile_artifact_storage_attention(
    transaction: &rusqlite::Transaction<'_>,
    invocation_id: &str,
    worker_id: &str,
    created_at: &str,
) -> Result<(), String> {
    reconcile_artifact_storage_attention_with_budget(
        transaction,
        invocation_id,
        worker_id,
        created_at,
        DATABASE_STORAGE_BUDGET_MB.saturating_mul(1_048_576).max(1),
    )
}

pub(super) fn reconcile_artifact_storage_attention_with_budget(
    transaction: &rusqlite::Transaction<'_>,
    invocation_id: &str,
    worker_id: &str,
    created_at: &str,
    budget_bytes: u64,
) -> Result<(), String> {
    let page_count: u64 = transaction
        .query_row("PRAGMA page_count", [], |row| row.get(0))
        .map_err(|error| format!("measure worker database pages: {error}"))?;
    let freelist_count: u64 = transaction
        .query_row("PRAGMA freelist_count", [], |row| row.get(0))
        .map_err(|error| format!("measure worker database free pages: {error}"))?;
    let page_size: u64 = transaction
        .query_row("PRAGMA page_size", [], |row| row.get(0))
        .map_err(|error| format!("measure worker database page size: {error}"))?;
    let active_database_bytes = page_count
        .saturating_sub(freelist_count)
        .saturating_mul(page_size);
    let next_state = if active_database_bytes >= budget_bytes.saturating_mul(4) / 5 {
        "attention"
    } else {
        "normal"
    };
    let (current_state, current_inbox_id): (String, Option<String>) = transaction
        .query_row(
            "SELECT state,attention_inbox_id
             FROM worker_artifact_storage_state WHERE singleton=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|error| format!("load artifact storage attention state: {error}"))?;
    if current_state == next_state {
        return Ok(());
    }
    if next_state == "normal" {
        transaction
            .execute(
                "UPDATE worker_artifact_storage_state
                 SET state='normal',attention_inbox_id=NULL,updated_at=?1
                 WHERE singleton=1",
                [created_at],
            )
            .map_err(|error| format!("resolve artifact storage attention: {error}"))?;
        return Ok(());
    }

    let inbox_id = format!("worker_inbox_{}", uuid::Uuid::now_v7());
    let result = json!({
        "status":"artifact_storage_pressure",
        "activeDatabaseBytes":active_database_bytes,
        "databaseBudgetBytes":budget_bytes,
        "message":"Worker database storage needs attention. Artifact custody persists until explicit deletion; inspect the Artifact Inbox and delete artifacts you no longer need.",
    });
    transaction
        .execute(
            "INSERT INTO worker_inbox(
                inbox_id,invocation_id,worker_id,severity,result_json,created_at
             ) VALUES (?1,?2,?3,'error',?4,?5)",
            params![
                inbox_id,
                invocation_id,
                worker_id,
                serde_json::to_string(&result).map_err(|error| error.to_string())?,
                created_at,
            ],
        )
        .map_err(|error| format!("record artifact storage attention: {error}"))?;
    transaction
        .execute(
            "UPDATE worker_artifact_storage_state
             SET state='attention',attention_inbox_id=?1,updated_at=?2
             WHERE singleton=1",
            params![inbox_id, created_at],
        )
        .map_err(|error| format!("publish artifact storage attention state: {error}"))?;
    debug_assert!(current_inbox_id.is_none());
    Ok(())
}

fn artifact_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let content_reference: String = row.get(6)?;
    Ok(json!({
        "workerId":row.get::<_, String>(0)?,
        "artifactId":row.get::<_, String>(1)?,
        "displayName":row.get::<_, String>(2)?,
        "mediaType":row.get::<_, String>(3)?,
        "sizeBytes":row.get::<_, i64>(4)?,
        "contentSha256":row.get::<_, String>(5)?,
        "contentReference":serde_json::from_str::<Value>(&content_reference)
            .unwrap_or(Value::Null),
        "sourceInvocationId":row.get::<_, String>(7)?,
        "sourceWorkerVersion":row.get::<_, String>(8)?,
        "traceId":row.get::<_, String>(9)?,
        "createdAt":row.get::<_, String>(10)?,
    }))
}

fn artifact_owner_id(worker_id: &str, artifact_id: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(worker_id.as_bytes());
    digest.update([0]);
    digest.update(artifact_id.as_bytes());
    format!("artifact_{}", hex::encode(digest.finalize()))
}

fn artifact_storage_attention(connection: &Connection, database: &Path) -> Result<Value, String> {
    let artifact_bytes: i64 = connection
        .query_row(
            "SELECT COALESCE(SUM(size_bytes),0) FROM worker_artifacts",
            [],
            |row| row.get(0),
        )
        .map_err(|error| format!("measure artifact storage: {error}"))?;
    let budget_bytes = DATABASE_STORAGE_BUDGET_MB.saturating_mul(1_048_576).max(1);
    let artifact_bytes_u64 = u64::try_from(artifact_bytes).unwrap_or(u64::MAX);
    let database_bytes = crate::shared::storage::storage_stats(database)
        .map_err(|error| format!("measure worker database storage pressure: {error:#}"))?
        .total_file_bytes();
    Ok(artifact_storage_attention_value(
        artifact_bytes_u64,
        database_bytes,
        budget_bytes,
    ))
}

fn artifact_storage_attention_value(
    artifact_bytes: u64,
    database_bytes: u64,
    budget_bytes: u64,
) -> Value {
    let attention = database_bytes >= budget_bytes.saturating_mul(4) / 5;
    json!({
        "state":if attention {"attention"} else {"normal"},
        "artifactBytes":artifact_bytes,
        "databaseBytes":database_bytes,
        "databaseBudgetBytes":budget_bytes,
        "overBudget":database_bytes > budget_bytes,
        "message":if attention {
            Some("The worker database is using at least 80% of its storage budget. Artifact custody persists until you explicitly delete artifacts you no longer need.")
        } else {
            None
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_artifact_database_usage_surfaces_storage_attention() {
        let value = artifact_storage_attention_value(1_024, 450 * 1_048_576, 512 * 1_048_576);
        assert_eq!(value["state"], "attention");
        assert_eq!(value["artifactBytes"], 1_024);
        assert_eq!(value["databaseBytes"], 450 * 1_048_576);
        assert_eq!(value["overBudget"], false);
    }
}
