//! Immutable worker-to-agent outbox rows.
//!
//! Worker terminal truth and its outbox signal commit together. Importers read
//! without holding a worker transaction, commit agent state independently, and
//! acknowledge only after that commit.

use rusqlite::OptionalExtension;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{WorkerStore, validate_runtime_identifier};
use crate::domains::worker_kernel::agent_delivery_effects::{
    AgentDeliveryEffectBoundary, AgentDeliveryEffectIntent, AgentDeliveryEffectMailboxScope,
    AgentDeliveryEffectWakePolicy, PreparedAgentDeliveryEffect, PreparedAgentDeliveryTarget,
};

const MAX_OUTBOX_ERROR_BYTES: usize = 1_024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::domains::worker_kernel) struct AgentDeliveryOutboxRecord {
    pub outbox_id: String,
    pub deduplication_key: String,
    pub kind: String,
    pub invocation_id: String,
    pub worker_id: String,
    pub payload: Value,
    pub disposition: String,
    pub attempts: u32,
    pub last_error: Option<String>,
    pub created_at: String,
    pub processed_at: Option<String>,
}

pub(super) fn insert_terminal_outbox(
    transaction: &rusqlite::Transaction<'_>,
    invocation_id: &str,
    worker_id: &str,
    payload: &Value,
    created_at: &str,
) -> Result<(), String> {
    transaction
        .execute(
            "INSERT OR IGNORE INTO agent_delivery_outbox(
                outbox_id,deduplication_key,kind,invocation_id,worker_id,
                payload_json,created_at
             ) VALUES (?1,?2,'terminal',?3,?4,?5,?6)",
            params![
                format!("agent_outbox_{}", uuid::Uuid::now_v7()),
                format!("terminal:{invocation_id}"),
                invocation_id,
                worker_id,
                serde_json::to_string(payload).map_err(|error| error.to_string())?,
                created_at,
            ],
        )
        .map_err(|error| format!("record agent terminal outbox signal: {error}"))?;
    Ok(())
}

pub(super) fn insert_effect_outbox(
    transaction: &rusqlite::Transaction<'_>,
    invocation_id: &str,
    worker_id: &str,
    origin_session_id: &Option<String>,
    trace_id: &str,
    root_invocation_id: Option<&str>,
    causal_depth: u32,
    effects: &[PreparedAgentDeliveryEffect],
    created_at: &str,
) -> Result<(), String> {
    for effect in effects {
        let target = match &effect.target {
            PreparedAgentDeliveryTarget::Session { session_id } => {
                serde_json::json!({"kind":"session","sessionId":session_id})
            }
            PreparedAgentDeliveryTarget::Mailbox { scope, name } => serde_json::json!({
                "kind":"mailbox",
                "scope":match scope {
                    AgentDeliveryEffectMailboxScope::Workspace => "workspace",
                    AgentDeliveryEffectMailboxScope::Profile => "profile",
                },
                "name":name,
            }),
        };
        let payload = serde_json::json!({
            "invocationId":invocation_id,
            "workerId":worker_id,
            "originSessionId":origin_session_id,
            "traceId":trace_id,
            "rootInvocationId":root_invocation_id,
            "causalDepth":causal_depth,
            "deduplicationKey":effect.deduplication_key,
            "target":target,
            "content":effect.content,
            "intent":match effect.intent {
                AgentDeliveryEffectIntent::Information => "information",
                AgentDeliveryEffectIntent::Request => "request",
            },
            "wakePolicy":match effect.wake_policy {
                AgentDeliveryEffectWakePolicy::Passive => "passive",
                AgentDeliveryEffectWakePolicy::Wake => "wake",
            },
            "boundary":match effect.boundary {
                AgentDeliveryEffectBoundary::NextTurn => "next_turn",
                AgentDeliveryEffectBoundary::NextRun => "next_run",
            },
            "expiresAt":effect.expires_at,
        });
        transaction
            .execute(
                "INSERT OR IGNORE INTO agent_delivery_outbox(
                    outbox_id,deduplication_key,kind,invocation_id,worker_id,
                    payload_json,created_at
                 ) VALUES (?1,?2,'delivery',?3,?4,?5,?6)",
                params![
                    format!("agent_outbox_{}", uuid::Uuid::now_v7()),
                    format!("effect:{invocation_id}:{}", effect.deduplication_key),
                    invocation_id,
                    worker_id,
                    serde_json::to_string(&payload).map_err(|error| error.to_string())?,
                    created_at,
                ],
            )
            .map_err(|error| format!("record agent delivery effect outbox: {error}"))?;
    }
    Ok(())
}

impl WorkerStore {
    pub(in crate::domains::worker_kernel) fn pending_agent_delivery_outbox(
        &self,
        limit: u32,
    ) -> Result<Vec<AgentDeliveryOutboxRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT outbox_id,deduplication_key,kind,invocation_id,worker_id,
                        payload_json,disposition,attempts,last_error,created_at,processed_at
                 FROM agent_delivery_outbox
                 WHERE disposition='pending'
                 ORDER BY created_at,outbox_id LIMIT ?1",
            )
            .map_err(|error| format!("prepare agent delivery outbox: {error}"))?;
        statement
            .query_map([limit], map_outbox)
            .map_err(|error| format!("query agent delivery outbox: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode agent delivery outbox: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn mark_agent_delivery_outbox_imported(
        &self,
        outbox_id: &str,
    ) -> Result<bool, String> {
        validate_runtime_identifier(outbox_id, "agent delivery outbox id", 256)?;
        let processed_at = chrono::Utc::now().to_rfc3339();
        self.connection()?
            .execute(
                "UPDATE agent_delivery_outbox
                 SET disposition='imported',processed_at=?2,last_error=NULL
                 WHERE outbox_id=?1 AND disposition='pending'",
                params![outbox_id, processed_at],
            )
            .map(|changed| changed == 1)
            .map_err(|error| format!("acknowledge agent delivery outbox import: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn retry_agent_delivery_outbox(
        &self,
        outbox_id: &str,
        error: &str,
    ) -> Result<(), String> {
        validate_runtime_identifier(outbox_id, "agent delivery outbox id", 256)?;
        let bounded = error
            .chars()
            .take(MAX_OUTBOX_ERROR_BYTES)
            .collect::<String>();
        self.connection()?
            .execute(
                "UPDATE agent_delivery_outbox
                 SET attempts=attempts+1,last_error=?2
                 WHERE outbox_id=?1 AND disposition='pending'",
                params![outbox_id, bounded],
            )
            .map(|_| ())
            .map_err(|error| format!("record agent delivery outbox retry: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn reject_agent_delivery_outbox(
        &self,
        outbox_id: &str,
        error: &str,
    ) -> Result<bool, String> {
        validate_runtime_identifier(outbox_id, "agent delivery outbox id", 256)?;
        let bounded = error
            .chars()
            .take(MAX_OUTBOX_ERROR_BYTES)
            .collect::<String>();
        let processed_at = chrono::Utc::now().to_rfc3339();
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin agent delivery outbox rejection: {error}"))?;
        let Some((worker_id, invocation_id)) = transaction
            .query_row(
                "SELECT worker_id,invocation_id FROM agent_delivery_outbox
                 WHERE outbox_id=?1 AND disposition='pending'",
                [outbox_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(|error| format!("load pending agent delivery outbox rejection: {error}"))?
        else {
            return Ok(false);
        };
        let attention = serde_json::json!({
            "status":"failed",
            "phase":"agent_delivery_import",
            "outboxId":outbox_id,
            "invocationId":invocation_id,
            "error":bounded,
        });
        transaction
            .execute(
                "INSERT OR IGNORE INTO worker_inbox(
                    inbox_id,invocation_id,worker_id,severity,result_json,created_at
                 ) VALUES (?1,?2,?3,'error',?4,?5)",
                params![
                    format!("agent_delivery_outbox_attention_{outbox_id}"),
                    invocation_id,
                    worker_id,
                    serde_json::to_string(&attention).map_err(|error| error.to_string())?,
                    processed_at,
                ],
            )
            .map_err(|error| format!("record rejected agent delivery Attention: {error}"))?;
        let changed = transaction
            .execute(
                "UPDATE agent_delivery_outbox
                 SET disposition='rejected',attempts=attempts+1,last_error=?2,processed_at=?3
                 WHERE outbox_id=?1 AND disposition='pending'",
                params![outbox_id, bounded, processed_at],
            )
            .map_err(|error| format!("reject agent delivery outbox row: {error}"))?;
        if changed != 1 {
            return Err("pending agent delivery outbox changed during rejection".to_owned());
        }
        transaction
            .commit()
            .map_err(|error| format!("commit agent delivery outbox rejection: {error}"))?;
        Ok(true)
    }

    pub(in crate::domains::worker_kernel) fn has_pending_agent_outbox_for_worker(
        &self,
        worker_id: &str,
    ) -> Result<bool, String> {
        validate_runtime_identifier(worker_id, "worker id", 256)?;
        self.connection()?
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM agent_delivery_outbox
                    WHERE worker_id=?1 AND disposition='pending'
                )",
                [worker_id],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("check worker agent outbox: {error}"))
    }

    pub(in crate::domains::worker_kernel) fn invocation_ids_for_worker(
        &self,
        worker_id: &str,
    ) -> Result<Vec<String>, String> {
        validate_runtime_identifier(worker_id, "worker id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT invocation_id FROM worker_invocations
                 WHERE worker_id=?1 ORDER BY invocation_id",
            )
            .map_err(|error| format!("prepare worker invocation grant check: {error}"))?;
        statement
            .query_map([worker_id], |row| row.get::<_, String>(0))
            .map_err(|error| format!("query worker invocation grant check: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode worker invocation grant check: {error}"))
    }

    #[cfg(test)]
    pub(in crate::domains::worker_kernel) fn agent_delivery_outbox(
        &self,
        outbox_id: &str,
    ) -> Result<Option<AgentDeliveryOutboxRecord>, String> {
        self.connection()?
            .query_row(
                "SELECT outbox_id,deduplication_key,kind,invocation_id,worker_id,
                        payload_json,disposition,attempts,last_error,created_at,processed_at
                 FROM agent_delivery_outbox WHERE outbox_id=?1",
                [outbox_id],
                map_outbox,
            )
            .optional()
            .map_err(|error| format!("load agent delivery outbox row: {error}"))
    }
}

fn map_outbox(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentDeliveryOutboxRecord> {
    let payload_json = row.get::<_, String>(5)?;
    let payload = serde_json::from_str(&payload_json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(5, rusqlite::types::Type::Text, Box::new(error))
    })?;
    Ok(AgentDeliveryOutboxRecord {
        outbox_id: row.get(0)?,
        deduplication_key: row.get(1)?,
        kind: row.get(2)?,
        invocation_id: row.get(3)?,
        worker_id: row.get(4)?,
        payload,
        disposition: row.get(6)?,
        attempts: row.get(7)?,
        last_error: row.get(8)?,
        created_at: row.get(9)?,
        processed_at: row.get(10)?,
    })
}
