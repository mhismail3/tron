//! Content-addressed blob storage and owned payload-reference helpers.

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use super::{
    EncodedBlobContent, PAYLOAD_REF_ENVELOPE_KEY, StorePayloadOptions, StoredPayloadRef,
    ZSTD_COMPRESSION_THRESHOLD_BYTES, ensure_storage_schema, hex_sha256, payload_preview,
};

/// Store bytes in the shared content-addressed blob table.
pub fn store_content_blob(conn: &Connection, content: &[u8], mime_type: &str) -> Result<String> {
    let hash = hex_sha256(content);
    if let Some(existing) = conn
        .query_row(
            "SELECT id FROM blobs WHERE hash = ?1",
            params![hash],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .context("failed to query existing payload blob")?
    {
        let _ = conn.execute(
            "UPDATE blobs SET ref_count = ref_count + 1 WHERE id = ?1",
            params![existing],
        )?;
        return Ok(existing);
    }

    let id = format!("blob_{}", Uuid::now_v7());
    let encoded = encode_blob_content(content);
    conn.execute(
        "INSERT INTO blobs
         (id, hash, content, mime_type, uncompressed_size, size_compressed, compression, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            id,
            hash,
            encoded.content,
            mime_type,
            encoded.uncompressed_size,
            encoded.size_compressed,
            encoded.compression,
            Utc::now().to_rfc3339()
        ],
    )
    .context("failed to store payload blob")?;
    Ok(id)
}

/// Encode bytes for blob storage.
#[must_use]
pub fn encode_blob_content(content: &[u8]) -> EncodedBlobContent {
    if content.len() >= ZSTD_COMPRESSION_THRESHOLD_BYTES
        && let Ok(compressed) = zstd::bulk::compress(content, 3)
        && compressed.len() < content.len()
    {
        return EncodedBlobContent {
            uncompressed_size: i64::try_from(content.len()).unwrap_or(i64::MAX),
            size_compressed: i64::try_from(compressed.len()).unwrap_or(i64::MAX),
            content: compressed,
            compression: "zstd",
        };
    }
    EncodedBlobContent {
        uncompressed_size: i64::try_from(content.len()).unwrap_or(i64::MAX),
        size_compressed: i64::try_from(content.len()).unwrap_or(i64::MAX),
        content: content.to_vec(),
        compression: "none",
    }
}

/// Decode bytes from blob storage.
pub fn decode_blob_content(
    content: &[u8],
    compression: &str,
    original_size: i64,
) -> Result<Vec<u8>> {
    match compression {
        "none" => Ok(content.to_vec()),
        "zstd" => zstd::bulk::decompress(
            content,
            usize::try_from(original_size).unwrap_or(usize::MAX),
        )
        .context("failed to decode zstd blob"),
        other => anyhow::bail!("unsupported blob compression {other}"),
    }
}

/// Store a payload with explicit ownership metadata.
pub fn store_owned_payload_ref(
    conn: &Connection,
    payload: &[u8],
    options: &StorePayloadOptions,
) -> Result<StoredPayloadRef> {
    ensure_storage_schema(conn)?;
    let hash = hex_sha256(payload);
    let preview = payload_preview(payload, 512);
    let existing: Option<(String, Option<String>)> = conn
        .query_row(
            "SELECT id, payload_blob_id FROM storage_payload_refs
             WHERE owner_kind = ?1 AND owner_id = ?2 AND field_name = ?3",
            params![options.owner_kind, options.owner_id, options.field_name],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()
        .context("failed to query existing payload ref")?;
    let blob_id = if payload.len() > options.inline_threshold {
        if let Some((_, Some(existing_blob_id))) = existing.as_ref()
            && blob_hash_matches(conn, existing_blob_id, &hash)?
        {
            Some(existing_blob_id.clone())
        } else {
            Some(store_content_blob(conn, payload, &options.payload_kind)?)
        }
    } else {
        None
    };
    let payload_ref_id = existing
        .as_ref()
        .map(|row| row.0.clone())
        .unwrap_or_else(|| format!("payload_ref_{}", Uuid::now_v7()));
    let created_at = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO storage_payload_refs (
           id, owner_kind, owner_id, field_name, payload_hash, payload_blob_id,
           payload_preview, payload_size_bytes, payload_kind, redaction_level,
           retention_class, trace_id, session_id, workspace_id, expires_at, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
         ON CONFLICT(owner_kind, owner_id, field_name) DO UPDATE SET
           payload_hash = excluded.payload_hash,
           payload_blob_id = excluded.payload_blob_id,
           payload_preview = excluded.payload_preview,
           payload_size_bytes = excluded.payload_size_bytes,
           payload_kind = excluded.payload_kind,
           redaction_level = excluded.redaction_level,
           retention_class = excluded.retention_class,
           trace_id = excluded.trace_id,
           session_id = excluded.session_id,
           workspace_id = excluded.workspace_id,
           expires_at = excluded.expires_at",
        params![
            payload_ref_id,
            options.owner_kind,
            options.owner_id,
            options.field_name,
            hash,
            blob_id,
            preview,
            i64::try_from(payload.len()).unwrap_or(i64::MAX),
            options.payload_kind,
            options.redaction_level,
            options.retention_class,
            options.trace_id,
            options.session_id,
            options.workspace_id,
            options.expires_at,
            created_at,
        ],
    )
    .context("failed to record payload ref owner")?;
    if let Some((_, Some(old_blob_id))) = existing
        && blob_id.as_deref() != Some(old_blob_id.as_str())
    {
        let _ = conn.execute(
            "UPDATE blobs SET ref_count = CASE WHEN ref_count > 0 THEN ref_count - 1 ELSE 0 END
             WHERE id = ?1",
            params![old_blob_id],
        )?;
    }
    Ok(StoredPayloadRef {
        payload_ref_id,
        payload_hash: hash,
        payload_blob_id: blob_id,
        payload_preview: preview,
        payload_size_bytes: payload.len(),
        payload_kind: options.payload_kind.clone(),
        redaction_level: options.redaction_level.clone(),
        retention_class: options.retention_class.clone(),
    })
}

fn blob_hash_matches(conn: &Connection, blob_id: &str, expected_hash: &str) -> Result<bool> {
    let stored_hash = conn
        .query_row(
            "SELECT hash FROM blobs WHERE id = ?1",
            params![blob_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .context("failed to inspect existing payload blob hash")?;
    Ok(stored_hash.as_deref() == Some(expected_hash))
}

/// Store a JSON value for a DB row, returning either inline JSON or a compact
/// internal payload-ref envelope.
pub fn store_json_value(
    conn: &Connection,
    value: &serde_json::Value,
    options: &StorePayloadOptions,
) -> Result<String> {
    let bytes = serde_json::to_vec(value).context("failed to serialize JSON payload")?;
    store_json_bytes(conn, &bytes, options)
}

/// Store already-serialized JSON bytes for a DB row.
pub fn store_json_bytes(
    conn: &Connection,
    json_bytes: &[u8],
    options: &StorePayloadOptions,
) -> Result<String> {
    let reference = store_owned_payload_ref(conn, json_bytes, options)?;
    if json_bytes.len() <= options.inline_threshold {
        String::from_utf8(json_bytes.to_vec()).context("stored JSON bytes were not UTF-8")
    } else {
        serde_json::to_string(&serde_json::json!({ PAYLOAD_REF_ENVELOPE_KEY: reference }))
            .context("failed to serialize payload ref envelope")
    }
}

/// Resolve a stored JSON column that may contain an internal payload-ref
/// envelope back to the original JSON value.
pub fn resolve_stored_json_value(
    conn: &Connection,
    stored_json: &str,
) -> Result<serde_json::Value> {
    if let Some(bytes) = resolve_payload_ref_envelope(conn, stored_json)? {
        return serde_json::from_slice(&bytes).context("failed to parse blob-backed JSON payload");
    }
    serde_json::from_str(stored_json).context("failed to parse inline JSON payload")
}

/// Resolve a stored JSON column back to original serialized JSON.
pub fn resolve_stored_json_string(conn: &Connection, stored_json: &str) -> Result<String> {
    if let Some(bytes) = resolve_payload_ref_envelope(conn, stored_json)? {
        return String::from_utf8(bytes).context("blob-backed JSON payload was not UTF-8");
    }
    Ok(stored_json.to_owned())
}

/// Register an existing blob as owned by its own domain/product blob id.
pub fn register_existing_blob_owner(
    conn: &Connection,
    blob_id: &str,
    owner_kind: &str,
    field_name: &str,
    retention_class: &str,
) -> Result<()> {
    ensure_storage_schema(conn)?;
    let (hash, uncompressed_size, mime_type): (String, i64, String) = conn
        .query_row(
            "SELECT hash, uncompressed_size, mime_type FROM blobs WHERE id = ?1",
            params![blob_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .context("failed to lookup existing blob owner payload")?;
    let payload_ref_id = format!("payload_ref_{}", Uuid::now_v7());
    conn.execute(
        "INSERT OR IGNORE INTO storage_payload_refs (
           id, owner_kind, owner_id, field_name, payload_hash, payload_blob_id,
           payload_preview, payload_size_bytes, payload_kind, redaction_level,
           retention_class, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, '', ?7, ?8, 'binary', ?9, ?10)",
        params![
            payload_ref_id,
            owner_kind,
            blob_id,
            field_name,
            hash,
            blob_id,
            uncompressed_size,
            mime_type,
            retention_class,
            Utc::now().to_rfc3339(),
        ],
    )
    .context("failed to register existing blob owner")?;
    Ok(())
}

fn resolve_payload_ref_envelope(conn: &Connection, stored_json: &str) -> Result<Option<Vec<u8>>> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(stored_json) else {
        return Ok(None);
    };
    let Some(reference) = value.get(PAYLOAD_REF_ENVELOPE_KEY) else {
        return Ok(None);
    };
    let Some(blob_id) = reference
        .get("payloadBlobId")
        .or_else(|| reference.get("payload_blob_id"))
        .and_then(serde_json::Value::as_str)
    else {
        return Ok(None);
    };
    let (content, compression, original_size): (Vec<u8>, String, i64) = conn
        .query_row(
            "SELECT content, compression, uncompressed_size FROM blobs WHERE id = ?1",
            params![blob_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .with_context(|| format!("failed to load payload blob {blob_id}"))?;
    decode_blob_content(&content, &compression, original_size).map(Some)
}
