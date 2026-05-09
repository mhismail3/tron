//! Constitution audit repository.
//!
//! Stores replay metadata for Constitution-aware context resolution. The large
//! rendered block set is content-addressed in `blobs`; audit tables keep the
//! durable ids, hashes, ordering, reasons, cache classes, and provider surfaces.

use rusqlite::{Connection, params};
use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::sqlite::repositories::blob::BlobRepo;
use crate::shared::constitution::ContextBlock;

/// Input for recording one context-resolution audit.
pub struct ContextResolutionAudit<'a> {
    /// Session id, when this request is session-scoped.
    pub session_id: Option<&'a str>,
    /// Turn number, when this request is turn-scoped.
    pub turn: Option<u32>,
    /// Provider name.
    pub provider: Option<&'a str>,
    /// Model id.
    pub model: Option<&'a str>,
    /// Active instruction profile.
    pub profile: Option<&'a str>,
    /// Compiled context blocks.
    pub blocks: &'a [ContextBlock],
    /// Additional structured request metadata.
    pub metadata: Value,
}

/// Input for recording a provider-payload audit.
pub struct ProviderPayloadAudit<'a> {
    /// Session id, when this request is session-scoped.
    pub session_id: Option<&'a str>,
    /// Turn number, when this request is turn-scoped.
    pub turn: Option<u32>,
    /// Provider name.
    pub provider: Option<&'a str>,
    /// Model id.
    pub model: Option<&'a str>,
    /// Active instruction profile.
    pub profile: Option<&'a str>,
    /// Final provider adapter payload.
    pub payload: &'a Value,
    /// Additional structured request metadata.
    pub metadata: Value,
}

/// Stateless Constitution audit operations.
pub struct ConstitutionAuditRepo;

impl ConstitutionAuditRepo {
    /// Insert a context-resolution audit and all included context block refs.
    pub fn insert_context_resolution(
        conn: &Connection,
        input: &ContextResolutionAudit<'_>,
    ) -> Result<String> {
        let resolution_id = format!("constitution_resolution_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let payload = serde_json::to_vec(&input.blocks)?;
        let effective_hash = sha256_hex(&payload);
        let payload_blob_id = BlobRepo::store(conn, &payload, "application/json")?;
        let metadata_json = serde_json::to_string(&input.metadata)?;
        let turn = input.turn.map(i64::from);

        conn.execute(
            "INSERT INTO constitution_resolution_audit
             (id, occurred_at, session_id, turn, resolution_type, profile, provider, model,
              effective_hash, payload_blob_id, metadata_json)
             VALUES (?1, ?2, ?3, ?4, 'context', ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                resolution_id,
                now,
                input.session_id,
                turn,
                input.profile,
                input.provider,
                input.model,
                effective_hash,
                payload_blob_id,
                metadata_json,
            ],
        )?;

        for block in input.blocks {
            let block_row_id = format!("constitution_block_{}", Uuid::now_v7());
            let metadata_json = serde_json::to_string(&serde_json::json!({
                "auditIds": block.audit_ids,
            }))?;
            conn.execute(
                "INSERT INTO constitution_context_blocks
                 (id, resolution_id, block_id, name, source_home, source_path, source_blob_id,
                  content_hash, token_estimate, sensitivity, inclusion_reason, precedence,
                  cache_class, provider_surface, lifecycle, included, metadata_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, 1, ?16)",
                params![
                    block_row_id,
                    resolution_id,
                    block.id.as_str(),
                    block.name.as_str(),
                    serde_name(&block.home)?,
                    block.source_path.as_deref(),
                    block.source_blob_id.as_deref(),
                    block.hash.as_str(),
                    i64::try_from(block.token_estimate).unwrap_or(i64::MAX),
                    serde_name(&block.sensitivity)?,
                    block.inclusion_reason.as_str(),
                    i64::from(block.precedence),
                    serde_name(&block.cache_class)?,
                    serde_name(&block.provider_surface)?,
                    block.lifecycle.as_str(),
                    metadata_json,
                ],
            )?;
        }

        Ok(resolution_id)
    }

    /// Insert a provider-payload audit row with a content-addressed payload.
    pub fn insert_provider_payload(
        conn: &Connection,
        input: &ProviderPayloadAudit<'_>,
    ) -> Result<String> {
        let resolution_id = format!("constitution_resolution_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let payload = serde_json::to_vec(input.payload)?;
        let effective_hash = sha256_hex(&payload);
        let payload_blob_id = BlobRepo::store(conn, &payload, "application/json")?;
        let metadata_json = serde_json::to_string(&input.metadata)?;
        let turn = input.turn.map(i64::from);

        conn.execute(
            "INSERT INTO constitution_resolution_audit
             (id, occurred_at, session_id, turn, resolution_type, profile, provider, model,
              effective_hash, payload_blob_id, metadata_json)
             VALUES (?1, ?2, ?3, ?4, 'provider_payload', ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                resolution_id,
                now,
                input.session_id,
                turn,
                input.profile,
                input.provider,
                input.model,
                effective_hash,
                payload_blob_id,
                metadata_json,
            ],
        )?;

        Ok(resolution_id)
    }
}

fn serde_name<T: serde::Serialize>(value: &T) -> Result<String> {
    let value = serde_json::to_value(value)?;
    Ok(value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string()))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex::encode(digest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::session::event_store::sqlite::migrations::run_migrations;
    use crate::shared::constitution::{ContextCacheClass, TronHome, context_block_for_text};

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn insert_context_resolution_records_blocks_and_payload_blob() {
        let conn = setup();
        let blocks = vec![context_block_for_text(
            "system.prompt",
            "System Prompt",
            TronHome::Profiles,
            "You are Tron.",
            ContextCacheClass::Foundation,
            10,
        )];

        let id = ConstitutionAuditRepo::insert_context_resolution(
            &conn,
            &ContextResolutionAudit {
                session_id: None,
                turn: Some(1),
                provider: Some("anthropic"),
                model: Some("claude-test"),
                profile: Some("default"),
                blocks: &blocks,
                metadata: serde_json::json!({"messageCount": 1}),
            },
        )
        .unwrap();

        let (resolution_type, provider, blob_id): (String, String, String) = conn
            .query_row(
                "SELECT resolution_type, provider, payload_blob_id
                 FROM constitution_resolution_audit
                 WHERE id = ?1",
                params![id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(resolution_type, "context");
        assert_eq!(provider, "anthropic");
        assert!(blob_id.starts_with("blob_"));

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM constitution_context_blocks WHERE resolution_id = ?1",
                params![id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn insert_provider_payload_records_payload_blob() {
        let conn = setup();
        let id = ConstitutionAuditRepo::insert_provider_payload(
            &conn,
            &ProviderPayloadAudit {
                session_id: None,
                turn: Some(1),
                provider: Some("openai"),
                model: Some("gpt-test"),
                profile: Some("default"),
                payload: &serde_json::json!({"model": "gpt-test", "input": []}),
                metadata: serde_json::json!({"contextResolutionId": "ctx-1"}),
            },
        )
        .unwrap();

        let (resolution_type, blob_id): (String, String) = conn
            .query_row(
                "SELECT resolution_type, payload_blob_id
                 FROM constitution_resolution_audit
                 WHERE id = ?1",
                params![id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(resolution_type, "provider_payload");
        assert!(blob_id.starts_with("blob_"));
    }
}
