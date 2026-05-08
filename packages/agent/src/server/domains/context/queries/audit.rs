use super::params;
use super::payload_preview::{load_payload_preview, parse_json_value, sql_error};
use crate::server::shared::errors::CapabilityError;
use rusqlite::OptionalExtension;
use serde_json::Value;
use serde_json::json;

struct AuditResolution {
    id: String,
    occurred_at: String,
    turn: Option<i64>,
    profile: Option<String>,
    provider: Option<String>,
    model: Option<String>,
    effective_hash: Option<String>,
    payload_blob_id: Option<String>,
    metadata: Value,
}

pub(super) fn load_audit_trace(
    conn: &rusqlite::Connection,
    session_id: &str,
    turn: Option<u32>,
) -> Result<Option<Value>, CapabilityError> {
    let context = load_context_resolution(conn, session_id, turn)?;
    let Some(context) = context else {
        return Ok(None);
    };
    let blocks = load_context_blocks(conn, &context.id)?;
    let provider_payload = load_provider_payload_resolution(conn, session_id, &context, turn)?;

    Ok(Some(json!({
        "sessionId": session_id,
        "turn": context.turn,
        "contextResolution": resolution_json(&context),
        "contextBlocks": blocks,
        "cachePolicy": blocks.iter().map(|block| json!({
            "blockId": block.get("blockId").cloned().unwrap_or(Value::Null),
            "cacheClass": block.get("cacheClass").cloned().unwrap_or(Value::Null),
            "providerSurface": block.get("providerSurface").cloned().unwrap_or(Value::Null),
        })).collect::<Vec<_>>(),
        "providerPayload": provider_payload,
    })))
}

fn load_context_resolution(
    conn: &rusqlite::Connection,
    session_id: &str,
    turn: Option<u32>,
) -> Result<Option<AuditResolution>, CapabilityError> {
    let sql = if turn.is_some() {
        "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
         FROM constitution_resolution_audit
         WHERE session_id = ?1 AND resolution_type = 'context' AND turn = ?2
         ORDER BY occurred_at DESC
         LIMIT 1"
    } else {
        "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
         FROM constitution_resolution_audit
         WHERE session_id = ?1 AND resolution_type = 'context'
         ORDER BY turn DESC, occurred_at DESC
         LIMIT 1"
    };

    let turn_value = turn.map(i64::from);
    let mut stmt = conn.prepare(sql).map_err(sql_error)?;
    let row = if let Some(turn_value) = turn_value {
        stmt.query_row(params![session_id, turn_value], map_resolution_row)
            .optional()
            .map_err(sql_error)?
    } else {
        stmt.query_row(params![session_id], map_resolution_row)
            .optional()
            .map_err(sql_error)?
    };
    Ok(row)
}

fn load_provider_payload_resolution(
    conn: &rusqlite::Connection,
    session_id: &str,
    context: &AuditResolution,
    turn: Option<u32>,
) -> Result<Value, CapabilityError> {
    let by_context: Option<AuditResolution> = conn
        .query_row(
            "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
             FROM constitution_resolution_audit
             WHERE session_id = ?1
               AND resolution_type = 'provider_payload'
               AND json_extract(metadata_json, '$.contextResolutionId') = ?2
             ORDER BY occurred_at DESC
             LIMIT 1",
            params![session_id, context.id.as_str()],
            map_resolution_row,
        )
        .optional()
        .map_err(sql_error)?;

    let provider = match by_context {
        Some(row) => Some(row),
        None => {
            let target_turn = turn.map(i64::from).or(context.turn).unwrap_or_default();
            conn.query_row(
                "SELECT id, occurred_at, turn, profile, provider, model, effective_hash, payload_blob_id, metadata_json
                 FROM constitution_resolution_audit
                 WHERE session_id = ?1 AND resolution_type = 'provider_payload' AND turn = ?2
                 ORDER BY occurred_at DESC
                 LIMIT 1",
                params![session_id, target_turn],
                map_resolution_row,
            )
            .optional()
            .map_err(sql_error)?
        }
    };

    let Some(provider) = provider else {
        return Ok(Value::Null);
    };

    let preview = provider
        .payload_blob_id
        .as_deref()
        .and_then(|blob_id| load_payload_preview(conn, blob_id).transpose())
        .transpose()?
        .unwrap_or(Value::Null);

    Ok(json!({
        "resolution": resolution_json(&provider),
        "redactedPreview": preview,
    }))
}

fn load_context_blocks(
    conn: &rusqlite::Connection,
    resolution_id: &str,
) -> Result<Vec<Value>, CapabilityError> {
    let mut stmt = conn
        .prepare(
            "SELECT block_id, name, source_home, source_path, source_blob_id, content_hash,
                    token_estimate, sensitivity, inclusion_reason, precedence, cache_class,
                    provider_surface, lifecycle, included, metadata_json
             FROM constitution_context_blocks
             WHERE resolution_id = ?1
             ORDER BY precedence ASC",
        )
        .map_err(sql_error)?;

    let rows = stmt
        .query_map(params![resolution_id], |row| {
            let metadata_json: String = row.get(14)?;
            let metadata = parse_json_value(&metadata_json);
            Ok(json!({
                "blockId": row.get::<_, String>(0)?,
                "name": row.get::<_, String>(1)?,
                "sourceHome": row.get::<_, String>(2)?,
                "sourcePath": row.get::<_, Option<String>>(3)?,
                "sourceBlobId": row.get::<_, Option<String>>(4)?,
                "contentHash": row.get::<_, String>(5)?,
                "tokenEstimate": row.get::<_, i64>(6)?,
                "sensitivity": row.get::<_, String>(7)?,
                "inclusionReason": row.get::<_, String>(8)?,
                "precedence": row.get::<_, i64>(9)?,
                "cacheClass": row.get::<_, String>(10)?,
                "providerSurface": row.get::<_, String>(11)?,
                "lifecycle": row.get::<_, String>(12)?,
                "included": row.get::<_, i64>(13)? == 1,
                "metadata": metadata,
            }))
        })
        .map_err(sql_error)?;

    rows.collect::<Result<Vec<_>, _>>().map_err(sql_error)
}

fn map_resolution_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AuditResolution> {
    let metadata_json: String = row.get(8)?;
    Ok(AuditResolution {
        id: row.get(0)?,
        occurred_at: row.get(1)?,
        turn: row.get(2)?,
        profile: row.get(3)?,
        provider: row.get(4)?,
        model: row.get(5)?,
        effective_hash: row.get(6)?,
        payload_blob_id: row.get(7)?,
        metadata: parse_json_value(&metadata_json),
    })
}

fn resolution_json(row: &AuditResolution) -> Value {
    json!({
        "id": row.id,
        "occurredAt": row.occurred_at,
        "turn": row.turn,
        "profile": row.profile,
        "provider": row.provider,
        "model": row.model,
        "effectiveHash": row.effective_hash,
        "payloadBlobId": row.payload_blob_id,
        "metadata": row.metadata,
    })
}
