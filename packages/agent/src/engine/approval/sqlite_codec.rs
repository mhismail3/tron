use chrono::{DateTime, Utc};
use rusqlite::Connection;

use super::{ApprovalStatus, EngineApprovalRecord};
use crate::engine::discovery::ActorKind;
use crate::engine::errors::{EngineError, Result};
use crate::engine::ids::{ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId};
use crate::engine::types::DeliveryMode;

pub(super) fn row_to_record(
    conn: &Connection,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<EngineApprovalRecord> {
    let actor_kind: String = row.get("actor_kind")?;
    let delivery_mode: String = row.get("delivery_mode")?;
    let status: String = row.get("status")?;
    let payload_json: String = row.get("payload_json")?;
    let payload_json = crate::shared::storage::resolve_stored_json_string(conn, &payload_json)
        .map_err(storage_to_sql_err)?;
    let authority_scopes_json: String = row.get("authority_scopes_json")?;
    let result_json: Option<String> = row
        .get::<_, Option<String>>("result_json")?
        .map(|json| crate::shared::storage::resolve_stored_json_string(conn, &json))
        .transpose()
        .map_err(storage_to_sql_err)?;
    let error_json: Option<String> = row
        .get::<_, Option<String>>("error_json")?
        .map(|json| crate::shared::storage::resolve_stored_json_string(conn, &json))
        .transpose()
        .map_err(storage_to_sql_err)?;
    let created_at: String = row.get("created_at")?;
    let updated_at: String = row.get("updated_at")?;
    let decided_at: Option<String> = row.get("decided_at")?;
    let target_metadata_json: Option<String> = row.get("target_metadata_json")?;
    Ok(EngineApprovalRecord {
        approval_id: row.get("approval_id")?,
        function_id: FunctionId::new(row.get::<_, String>("function_id")?)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        payload: serde_json::from_str(&payload_json)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        payload_fingerprint: row.get("payload_fingerprint")?,
        actor_id: ActorId::new(row.get::<_, String>("actor_id")?)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        actor_kind: parse_actor_kind(&actor_kind)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        authority_grant_id: AuthorityGrantId::new(row.get::<_, String>("authority_grant_id")?)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        authority_scopes: serde_json::from_str(&authority_scopes_json)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        trace_id: TraceId::new(row.get::<_, String>("trace_id")?)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        parent_invocation_id: row
            .get::<_, Option<String>>("parent_invocation_id")?
            .map(InvocationId::new)
            .transpose()
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        trigger_id: row
            .get::<_, Option<String>>("trigger_id")?
            .map(TriggerId::new)
            .transpose()
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        session_id: row.get("session_id")?,
        workspace_id: row.get("workspace_id")?,
        idempotency_key: row.get("idempotency_key")?,
        delivery_mode: parse_delivery_mode(&delivery_mode)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        target_metadata: target_metadata_json
            .map(|value| serde_json::from_str(&value))
            .transpose()
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        status: parse_status(&status)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        decision_actor_id: row
            .get::<_, Option<String>>("decision_actor_id")?
            .map(ActorId::new)
            .transpose()
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        decided_at: decided_at
            .map(|value| DateTime::parse_from_rfc3339(&value).map(|dt| dt.with_timezone(&Utc)))
            .transpose()
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        result: result_json
            .map(|value| serde_json::from_str(&value))
            .transpose()
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        error: error_json
            .map(|value| serde_json::from_str(&value))
            .transpose()
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        created_at: DateTime::parse_from_rfc3339(&created_at)
            .map(|dt| dt.with_timezone(&Utc))
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
        updated_at: DateTime::parse_from_rfc3339(&updated_at)
            .map(|dt| dt.with_timezone(&Utc))
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
    })
}

fn parse_status(value: &str) -> Result<ApprovalStatus> {
    match value {
        "pending" => Ok(ApprovalStatus::Pending),
        "approved" => Ok(ApprovalStatus::Approved),
        "denied" => Ok(ApprovalStatus::Denied),
        "executed" => Ok(ApprovalStatus::Executed),
        "failed" => Ok(ApprovalStatus::Failed),
        other => Err(EngineError::PolicyViolation(format!(
            "unknown approval status {other}"
        ))),
    }
}

fn parse_actor_kind(value: &str) -> Result<ActorKind> {
    match value {
        "Agent" => Ok(ActorKind::Agent),
        "Client" => Ok(ActorKind::Client),
        "Worker" => Ok(ActorKind::Worker),
        "System" => Ok(ActorKind::System),
        "Admin" => Ok(ActorKind::Admin),
        other => Err(EngineError::PolicyViolation(format!(
            "unknown actor kind {other}"
        ))),
    }
}

fn parse_delivery_mode(value: &str) -> Result<DeliveryMode> {
    match value {
        "sync" => Ok(DeliveryMode::Sync),
        "void" => Ok(DeliveryMode::Void),
        "enqueue" => Ok(DeliveryMode::Enqueue),
        other => Err(EngineError::PolicyViolation(format!(
            "unknown delivery mode {other}"
        ))),
    }
}

pub(super) fn sqlite_err(operation: &'static str, message: String) -> EngineError {
    EngineError::LedgerFailure { operation, message }
}

pub(super) fn json_err(err: serde_json::Error) -> EngineError {
    EngineError::LedgerFailure {
        operation: "approval.json",
        message: err.to_string(),
    }
}

pub(super) fn storage_err(err: anyhow::Error) -> EngineError {
    EngineError::LedgerFailure {
        operation: "approval.storage",
        message: err.to_string(),
    }
}

fn storage_to_sql_err(err: anyhow::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(err.to_string())))
}
