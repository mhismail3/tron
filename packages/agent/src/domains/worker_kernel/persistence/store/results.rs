//! Canonical typed-result ownership and schema-v10 backfill.
//!
//! Successful worker output has one logical owner: its durable invocation.
//! Small JSON stays inline in `worker_invocations.output_json`; larger values
//! use the shared payload-ref envelope and compressed blob tables in the same
//! SQLite transaction. Inbox rows and public projections carry references,
//! never a second exact result. A retained historical invocation whose
//! immutable bundle version was explicitly purged is the sole read-only
//! exception: run-history projections resolve its still-owned output as legacy
//! inline evidence because the original output-schema digest no longer exists.

use super::*;

const RESULT_OWNER_KIND: &str = "worker_invocation";
const RESULT_FIELD_NAME: &str = "output";
const RESULT_RETENTION_CLASS: &str = "audit";

#[derive(Debug)]
struct LegacyResultRow {
    invocation_id: String,
    trace_id: String,
    origin_session_id: Option<String>,
    stored_output: String,
}

#[derive(Debug)]
struct ProviderProjectionRow {
    invocation_id: String,
    worker_id: String,
    worker_version: String,
    worker_name: String,
    status: String,
    origin_session_id: Option<String>,
    interaction_mode: String,
    error: Option<String>,
    stored_output: Option<String>,
}

impl WorkerStore {
    pub(super) fn record_result_association(
        &self,
        worker_invocation_id: &str,
        model_tool_invocation_id: Option<&str>,
    ) -> Result<(), String> {
        let Some(model_tool_invocation_id) = model_tool_invocation_id else {
            return Ok(());
        };
        let connection = self.connection()?;
        let created_at = chrono::Utc::now().to_rfc3339();
        let changed = connection
            .execute(
                "INSERT OR IGNORE INTO worker_model_tool_result_associations(
                    model_tool_invocation_id,
                    worker_invocation_id,
                    created_at
                 )
                 SELECT ?1,invocation_id,?3
                 FROM worker_invocations
                 WHERE invocation_id=?2",
                params![model_tool_invocation_id, worker_invocation_id, created_at],
            )
            .map_err(|error| format!("record replayed worker result association: {error}"))?;
        if changed == 0 {
            let exists = connection
                .query_row(
                    "SELECT EXISTS(
                        SELECT 1
                        FROM worker_model_tool_result_associations
                        WHERE model_tool_invocation_id=?1
                          AND worker_invocation_id=?2
                     )",
                    params![model_tool_invocation_id, worker_invocation_id],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(|error| format!("verify replayed worker result association: {error}"))?;
            if !exists {
                return Err(format!(
                    "worker invocation '{worker_invocation_id}' disappeared while recording its model-tool result association"
                ));
            }
        }
        Ok(())
    }

    pub(super) fn store_result_in_transaction(
        transaction: &rusqlite::Transaction<'_>,
        invocation_id: &str,
        output: &Value,
        trace_id: &str,
        origin_session_id: Option<&str>,
    ) -> Result<String, String> {
        crate::shared::storage::store_json_value(
            transaction,
            output,
            &crate::shared::storage::StorePayloadOptions::new(
                RESULT_OWNER_KIND,
                invocation_id,
                RESULT_FIELD_NAME,
                RESULT_RETENTION_CLASS,
            )
            .with_scope(
                Some(trace_id.to_owned()),
                origin_session_id.map(ToOwned::to_owned),
                None,
            ),
        )
        .map_err(|error| format!("store durable worker result: {error:#}"))
    }

    pub fn resolve_result(&self, invocation_id: &str) -> Result<Option<Value>, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let connection = self.connection()?;
        resolve_result_from_connection(&connection, invocation_id)
    }

    pub fn result_reference(&self, invocation_id: &str) -> Result<Option<Value>, String> {
        validate_runtime_identifier(invocation_id, "invocation id", 256)?;
        let connection = self.connection()?;
        result_reference_from_connection(&connection, invocation_id).map(Some)
    }

    /// Resolve canonical worker-result projections for provider tool evidence.
    ///
    /// This is an internal kernel read, not model vocabulary. Historical reads
    /// use ownership metadata only; a caller-designated fresh small result is
    /// integrity-verified and hydrated for one provider turn.
    #[allow(clippy::too_many_arguments)]
    pub fn provider_result_projections(
        &self,
        model_tool_invocation_ids: &[String],
        invocation_ids: &[String],
        fresh_model_tool_invocation_ids: &HashSet<String>,
        fresh_invocation_ids: &HashSet<String>,
        origin_session_id: Option<&str>,
        trace_id: Option<&str>,
    ) -> Result<Vec<Value>, String> {
        if model_tool_invocation_ids
            .len()
            .saturating_add(invocation_ids.len())
            > 256
        {
            return Err("worker result projection exceeds 256 associations".to_owned());
        }
        if origin_session_id.is_none() && trace_id.is_none() {
            return Err(
                "worker result projection requires an originating session or causal trace"
                    .to_owned(),
            );
        }
        let connection = self.connection()?;
        let mut projected = Vec::new();
        let mut seen_invocations = HashSet::new();
        for model_tool_invocation_id in model_tool_invocation_ids {
            validate_runtime_identifier(model_tool_invocation_id, "model tool invocation id", 256)?;
            let rows = provider_projection_rows(
                &connection,
                "EXISTS (
                    SELECT 1
                    FROM worker_model_tool_result_associations association
                    WHERE association.worker_invocation_id=i.invocation_id
                      AND association.model_tool_invocation_id=?1
                 )",
                model_tool_invocation_id,
                origin_session_id,
                trace_id,
            )?;
            if rows.len() > 1 {
                return Err(format!(
                    "model tool invocation '{model_tool_invocation_id}' has ambiguous worker result ownership"
                ));
            }
            let Some(row) = rows.into_iter().next() else {
                continue;
            };
            if seen_invocations.insert(row.invocation_id.clone()) {
                projected.push(provider_projection_value(
                    &connection,
                    row,
                    Some(model_tool_invocation_id),
                    fresh_model_tool_invocation_ids.contains(model_tool_invocation_id),
                )?);
            }
        }
        for invocation_id in invocation_ids {
            validate_runtime_identifier(invocation_id, "worker invocation id", 256)?;
            let rows = provider_projection_rows(
                &connection,
                "i.invocation_id=?1",
                invocation_id,
                origin_session_id,
                trace_id,
            )?;
            if rows.len() > 1 {
                return Err(format!(
                    "worker invocation '{invocation_id}' has ambiguous result ownership"
                ));
            }
            let Some(row) = rows.into_iter().next() else {
                continue;
            };
            if seen_invocations.insert(row.invocation_id.clone()) {
                projected.push(provider_projection_value(
                    &connection,
                    row,
                    None,
                    fresh_invocation_ids.contains(invocation_id),
                )?);
            }
        }
        Ok(projected)
    }

    pub(super) fn migrate_results_v10(&self, connection: &mut Connection) -> Result<(), String> {
        crate::shared::storage::ensure_storage_schema(connection)
            .map_err(|error| format!("initialize worker result storage: {error:#}"))?;
        let already_applied = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM worker_schema WHERE version=10)",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("inspect worker schema v10: {error}"))?
            != 0;
        if already_applied {
            verify_result_storage_metadata(connection)?;
            return Ok(());
        }

        connection
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS worker_result_migration_v10 (
                    invocation_id TEXT PRIMARY KEY,
                    stored_output TEXT NOT NULL,
                    receipt_json TEXT NOT NULL
                 );",
            )
            .map_err(|error| format!("initialize worker result migration staging: {error}"))?;
        let stale_staged_ids = {
            let mut statement = connection
                .prepare(
                    "SELECT staged.invocation_id
                     FROM worker_result_migration_v10 staged
                     LEFT JOIN worker_invocations invocation
                       ON invocation.invocation_id=staged.invocation_id
                      AND invocation.status='completed'
                      AND invocation.output_json IS NOT NULL
                     WHERE invocation.invocation_id IS NULL
                     ORDER BY staged.invocation_id",
                )
                .map_err(|error| format!("prepare stale result migration cleanup: {error}"))?;
            statement
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|error| format!("query stale result migration cleanup: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode stale result migration cleanup: {error}"))?
        };
        if !stale_staged_ids.is_empty() {
            let transaction = connection
                .transaction()
                .map_err(|error| format!("start stale result migration cleanup: {error}"))?;
            Self::delete_result_owners(&transaction, &stale_staged_ids)?;
            for invocation_id in stale_staged_ids {
                transaction
                    .execute(
                        "DELETE FROM worker_result_migration_v10 WHERE invocation_id=?1",
                        [invocation_id],
                    )
                    .map_err(|error| format!("remove stale result migration row: {error}"))?;
            }
            transaction
                .commit()
                .map_err(|error| format!("commit stale result migration cleanup: {error}"))?;
        }

        let rows = {
            let mut statement = connection
                .prepare(
                    "SELECT invocation_id,trace_id,origin_session_id,output_json
                     FROM worker_invocations
                     WHERE status='completed' AND output_json IS NOT NULL
                     ORDER BY created_at,invocation_id",
                )
                .map_err(|error| format!("prepare worker result migration: {error}"))?;
            statement
                .query_map([], |row| {
                    Ok(LegacyResultRow {
                        invocation_id: row.get(0)?,
                        trace_id: row.get(1)?,
                        origin_session_id: row.get(2)?,
                        stored_output: row.get(3)?,
                    })
                })
                .map_err(|error| format!("query worker result migration: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode worker result migration: {error}"))?
        };

        for row in rows {
            let output =
                crate::shared::storage::resolve_stored_json_value(connection, &row.stored_output)
                    .map_err(|error| {
                    format!(
                        "resolve legacy result for '{}': {error:#}",
                        row.invocation_id
                    )
                })?;
            let transaction = connection
                .transaction()
                .map_err(|error| format!("start worker result migration batch: {error}"))?;
            let stored = Self::store_result_in_transaction(
                &transaction,
                &row.invocation_id,
                &output,
                &row.trace_id,
                row.origin_session_id.as_deref(),
            )?;
            let reference = result_reference_from_connection(&transaction, &row.invocation_id)?;
            let receipt = completed_result_receipt(&reference);
            transaction
                .execute(
                    "INSERT INTO worker_result_migration_v10(
                        invocation_id,stored_output,receipt_json
                     ) VALUES (?1,?2,?3)
                     ON CONFLICT(invocation_id) DO UPDATE SET
                        stored_output=excluded.stored_output,
                        receipt_json=excluded.receipt_json",
                    params![
                        row.invocation_id,
                        stored,
                        serde_json::to_string(&receipt).map_err(|error| error.to_string())?,
                    ],
                )
                .map_err(|error| format!("stage migrated worker result: {error}"))?;
            transaction
                .commit()
                .map_err(|error| format!("commit worker result migration batch: {error}"))?;
        }

        let transaction = connection
            .transaction()
            .map_err(|error| format!("start worker result migration cutover: {error}"))?;
        let expected: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM worker_invocations
                 WHERE status='completed' AND output_json IS NOT NULL",
                [],
                |row| row.get(0),
            )
            .map_err(|error| format!("count completed worker results: {error}"))?;
        let staged: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM worker_result_migration_v10",
                [],
                |row| row.get(0),
            )
            .map_err(|error| format!("count staged worker results: {error}"))?;
        if staged != expected {
            return Err(format!(
                "worker result migration staged {staged} of {expected} completed results"
            ));
        }
        let missing_staged: i64 = transaction
            .query_row(
                "SELECT COUNT(*)
                 FROM worker_invocations invocation
                 LEFT JOIN worker_result_migration_v10 staged
                   ON staged.invocation_id=invocation.invocation_id
                 WHERE invocation.status='completed'
                   AND invocation.output_json IS NOT NULL
                   AND staged.invocation_id IS NULL",
                [],
                |row| row.get(0),
            )
            .map_err(|error| format!("verify staged worker result identities: {error}"))?;
        if missing_staged != 0 {
            return Err(format!(
                "worker result migration is missing {missing_staged} completed result(s)"
            ));
        }
        transaction
            .execute(
                "UPDATE worker_invocations
                 SET output_json=(
                    SELECT staged.stored_output
                    FROM worker_result_migration_v10 staged
                    WHERE staged.invocation_id=worker_invocations.invocation_id
                 )
                 WHERE invocation_id IN (
                    SELECT invocation_id FROM worker_result_migration_v10
                 )",
                [],
            )
            .map_err(|error| format!("publish migrated worker result envelopes: {error}"))?;
        transaction
            .execute(
                "UPDATE worker_inbox
                 SET result_json=(
                    SELECT staged.receipt_json
                    FROM worker_result_migration_v10 staged
                    WHERE staged.invocation_id=worker_inbox.invocation_id
                 )
                 WHERE severity='info'
                   AND invocation_id IN (
                    SELECT invocation_id FROM worker_result_migration_v10
                 )",
                [],
            )
            .map_err(|error| format!("publish migrated worker inbox receipts: {error}"))?;
        transaction
            .execute(
                "INSERT INTO worker_inbox(
                    inbox_id,invocation_id,worker_id,severity,result_json,
                    context_attached,created_at
                 )
                 SELECT 'worker_inbox_' || lower(hex(randomblob(16))),
                        invocation.invocation_id,invocation.worker_id,'info',
                        staged.receipt_json,
                        CASE WHEN invocation.trigger_kind LIKE 'engine_hook:%' THEN 1 ELSE 0 END,
                        COALESCE(invocation.completed_at,invocation.created_at)
                 FROM worker_invocations invocation
                 JOIN worker_result_migration_v10 staged
                   ON staged.invocation_id=invocation.invocation_id
                 WHERE NOT EXISTS (
                    SELECT 1 FROM worker_inbox inbox
                    WHERE inbox.invocation_id=invocation.invocation_id
                      AND inbox.severity='info'
                 )",
                [],
            )
            .map_err(|error| format!("restore missing migrated inbox receipts: {error}"))?;
        verify_result_storage_cutover(&transaction)?;
        transaction
            .execute(
                "INSERT INTO worker_schema(version,applied_at)
                 VALUES(10,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                [],
            )
            .map_err(|error| format!("record worker schema v10: {error}"))?;
        transaction
            .execute("DROP TABLE worker_result_migration_v10", [])
            .map_err(|error| format!("finish worker result migration staging: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit worker result migration cutover: {error}"))?;
        Ok(())
    }

    pub(super) fn delete_result_owners(
        transaction: &rusqlite::Transaction<'_>,
        invocation_ids: &[String],
    ) -> Result<(), String> {
        for invocation_id in invocation_ids {
            crate::shared::storage::delete_owned_payload_refs(
                transaction,
                RESULT_OWNER_KIND,
                invocation_id,
            )
            .map_err(|error| format!("remove worker result ownership: {error:#}"))?;
        }
        crate::shared::storage::delete_unowned_blobs(transaction)
            .map_err(|error| format!("remove unowned worker result blobs: {error:#}"))?;
        Ok(())
    }
}

fn provider_projection_rows(
    connection: &Connection,
    identity_condition: &str,
    identity: &str,
    origin_session_id: Option<&str>,
    trace_id: Option<&str>,
) -> Result<Vec<ProviderProjectionRow>, String> {
    let mut statement = connection
        .prepare(&format!(
            "SELECT i.invocation_id,i.worker_id,i.worker_version,
                    COALESCE(w.name,i.worker_id),i.status,i.origin_session_id,
                    i.interaction_mode,i.error,i.output_json
             FROM worker_invocations i
             LEFT JOIN workers w ON w.worker_id=i.worker_id
             WHERE {identity_condition}
               AND (
                    (?2 IS NOT NULL AND i.origin_session_id=?2)
                    OR (?3 IS NOT NULL AND i.trace_id=?3)
               )
             ORDER BY i.created_at,i.invocation_id
             LIMIT 2"
        ))
        .map_err(|error| format!("prepare worker result projection: {error}"))?;
    statement
        .query_map(params![identity, origin_session_id, trace_id], |row| {
            Ok(ProviderProjectionRow {
                invocation_id: row.get(0)?,
                worker_id: row.get(1)?,
                worker_version: row.get(2)?,
                worker_name: row.get(3)?,
                status: row.get(4)?,
                origin_session_id: row.get(5)?,
                interaction_mode: row.get(6)?,
                error: row.get(7)?,
                stored_output: row.get(8)?,
            })
        })
        .map_err(|error| format!("query worker result projection: {error}"))?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|error| format!("decode worker result projection: {error}"))
}

fn provider_projection_value(
    connection: &Connection,
    row: ProviderProjectionRow,
    model_tool_invocation_id: Option<&str>,
    fresh: bool,
) -> Result<Value, String> {
    let reference = if row.status == "completed" {
        Some(result_reference_from_connection(
            connection,
            &row.invocation_id,
        )?)
    } else {
        None
    };
    let provider_value = match (row.status.as_str(), reference.as_ref()) {
        ("completed", Some(reference)) if fresh => {
            let payload = crate::shared::storage::owned_payload_ref(
                connection,
                RESULT_OWNER_KIND,
                &row.invocation_id,
                RESULT_FIELD_NAME,
            )
            .map_err(|error| format!("load fresh worker result ownership: {error:#}"))?
            .ok_or_else(|| {
                format!(
                    "fresh worker invocation '{}' has no result ownership",
                    row.invocation_id
                )
            })?;
            if payload.payload_size_bytes
                <= crate::shared::protocol::model_tools::DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES
            {
                let stored_output = row.stored_output.as_deref().ok_or_else(|| {
                    format!(
                        "fresh worker invocation '{}' has no stored output",
                        row.invocation_id
                    )
                })?;
                resolve_stored_result(connection, &row.invocation_id, stored_output)?
            } else {
                reference.clone()
            }
        }
        ("completed", Some(reference)) => reference.clone(),
        ("queued" | "running", _) => json!({
            "kind":"worker_invocation_receipt",
            "status":row.status,
            "mode":"background",
            "invocationId":row.invocation_id,
            "workerId":row.worker_id,
            "workerName":row.worker_name,
            "originSessionId":row.origin_session_id,
            "message":crate::domains::worker_kernel::contract::background_worker_receipt_message(
                &row.invocation_id,
            ),
        }),
        _ => json!({
            "kind":"worker_invocation_failure",
            "status":row.status,
            "invocationId":row.invocation_id,
            "workerId":row.worker_id,
            "workerName":row.worker_name,
            "error":row.error.as_deref().map(|error| {
                crate::shared::foundation::text::truncate_with_suffix(error, 4_096, "...")
            }),
        }),
    };
    Ok(json!({
        "modelToolInvocationId":model_tool_invocation_id,
        "invocationId":row.invocation_id,
        "workerId":row.worker_id,
        "workerVersion":row.worker_version,
        "status":row.status,
        "interactionMode":row.interaction_mode,
        "reference":reference,
        "providerValue":provider_value,
        "fresh":fresh,
    }))
}

pub(super) fn resolve_stored_result(
    connection: &Connection,
    invocation_id: &str,
    stored_output: &str,
) -> Result<Value, String> {
    crate::shared::storage::resolve_owned_json_value(
        connection,
        RESULT_OWNER_KIND,
        invocation_id,
        RESULT_FIELD_NAME,
        stored_output,
    )
    .map_err(|error| format!("worker result storage integrity failure: {error:#}"))
}

fn resolve_result_from_connection(
    connection: &Connection,
    invocation_id: &str,
) -> Result<Option<Value>, String> {
    let stored = connection
        .query_row(
            "SELECT output_json FROM worker_invocations WHERE invocation_id=?1",
            [invocation_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(|error| format!("load durable worker result: {error}"))?
        .flatten();
    stored
        .as_deref()
        .map(|value| resolve_stored_result(connection, invocation_id, value))
        .transpose()
}

pub(super) fn result_reference_from_connection(
    connection: &Connection,
    invocation_id: &str,
) -> Result<Value, String> {
    let (worker_id, worker_version, manifest): (String, String, String) = connection
        .query_row(
            "SELECT i.worker_id,i.worker_version,v.manifest_json
             FROM worker_invocations i
             JOIN worker_versions v
               ON v.worker_id=i.worker_id AND v.version=i.worker_version
             WHERE i.invocation_id=?1 AND i.status='completed'
               AND i.output_json IS NOT NULL",
            [invocation_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(|error| format!("load worker result identity: {error}"))?;
    let payload = crate::shared::storage::owned_payload_ref(
        connection,
        RESULT_OWNER_KIND,
        invocation_id,
        RESULT_FIELD_NAME,
    )
    .map_err(|error| format!("load worker result ownership: {error:#}"))?
    .ok_or_else(|| format!("worker invocation '{invocation_id}' has no result ownership"))?;
    let bundle = serde_json::from_str::<WorkerBundle>(&manifest)
        .map_err(|error| format!("decode worker result schema: {error}"))?;
    let schema_bytes =
        serde_json::to_vec(&bundle.output_schema).map_err(|error| error.to_string())?;
    Ok(json!({
        "kind":"worker_result_reference",
        "invocationId":invocation_id,
        "workerId":worker_id,
        "workerVersion":worker_version,
        "outputSchemaSha256":format!(
            "sha256:{}",
            hex::encode(Sha256::digest(schema_bytes))
        ),
        "contentSha256":format!("sha256:{}",payload.payload_hash),
        "sizeBytes":payload.payload_size_bytes,
        "preview":payload.payload_preview,
        "message":"The exact validated result is stored durably. Pass this reference to workers that accept it, or call result_read for only the JSON path/page needed.",
    }))
}

pub(super) fn result_reference_or_legacy_from_connection(
    connection: &Connection,
    invocation_id: &str,
    stored_output: &str,
) -> Result<Value, String> {
    let immutable_version_exists = connection
        .query_row(
            "SELECT EXISTS(
                SELECT 1
                FROM worker_invocations i
                JOIN worker_versions v
                  ON v.worker_id=i.worker_id AND v.version=i.worker_version
                WHERE i.invocation_id=?1
            )",
            [invocation_id],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("inspect worker result version ownership: {error}"))?;
    if immutable_version_exists {
        result_reference_from_connection(connection, invocation_id)
    } else {
        resolve_stored_result(connection, invocation_id, stored_output)
    }
}

pub(super) fn completed_result_receipt(reference: &Value) -> Value {
    json!({
        "status":"completed",
        "reference":reference,
        "preview":reference["preview"],
    })
}

fn verify_result_storage_metadata(connection: &Connection) -> Result<(), String> {
    crate::shared::storage::ensure_storage_schema(connection)
        .map_err(|error| format!("verify worker result storage schema: {error:#}"))?;
    let missing: i64 = connection
        .query_row(
            "SELECT COUNT(*)
             FROM worker_invocations i
             LEFT JOIN storage_payload_refs refs
               ON refs.owner_kind='worker_invocation'
              AND refs.owner_id=i.invocation_id
              AND refs.field_name='output'
             WHERE i.status='completed' AND i.output_json IS NOT NULL
               AND refs.id IS NULL",
            [],
            |row| row.get(0),
        )
        .map_err(|error| format!("verify worker result ownership: {error}"))?;
    if missing != 0 {
        return Err(format!(
            "worker result storage migration left {missing} completed result(s) without ownership"
        ));
    }
    let duplicated: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM worker_inbox
             WHERE severity='info' AND json_extract(result_json,'$.output') IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .map_err(|error| format!("verify worker inbox result receipts: {error}"))?;
    if duplicated != 0 {
        return Err(format!(
            "worker result storage migration left {duplicated} inbox output copy/copies"
        ));
    }
    Ok(())
}

fn verify_result_storage_cutover(connection: &Connection) -> Result<(), String> {
    verify_result_storage_metadata(connection)?;
    let stored_results = {
        let mut statement = connection
            .prepare(
                "SELECT invocation_id,output_json FROM worker_invocations
                 WHERE status='completed' AND output_json IS NOT NULL
                 ORDER BY invocation_id",
            )
            .map_err(|error| format!("prepare worker result integrity scan: {error}"))?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|error| format!("query worker result integrity scan: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker result integrity scan: {error}"))?
    };
    for (invocation_id, stored_output) in stored_results {
        resolve_stored_result(connection, &invocation_id, &stored_output).map_err(|error| {
            format!("worker result '{invocation_id}' failed integrity verification: {error}")
        })?;
    }
    Ok(())
}
