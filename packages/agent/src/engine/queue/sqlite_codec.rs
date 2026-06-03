use chrono::{DateTime, Utc};
use rusqlite::Connection;

use super::*;

pub(super) fn item_params(
    conn: &Connection,
    item: &EngineQueueItem,
) -> Result<rusqlite::ParamsFromIter<Vec<rusqlite::types::Value>>> {
    use rusqlite::types::Value as SqlValue;
    let payload = crate::shared::storage::store_json_value(
        conn,
        &item.payload,
        &crate::shared::storage::StorePayloadOptions::new(
            "engine_queue_item",
            item.receipt_id.clone(),
            "payload",
            "runtime",
        )
        .with_scope(
            Some(item.trace_id.to_string()),
            item.session_id.clone(),
            item.workspace_id.clone(),
        ),
    )
    .map_err(|err| EngineError::LedgerFailure {
        operation: "queue.store_payload",
        message: err.to_string(),
    })?;
    let scopes = serde_json::to_string(&item.authority_scopes).unwrap_or_else(|_| "[]".to_owned());
    let runtime_metadata =
        serde_json::to_string(&item.runtime_metadata).unwrap_or_else(|_| "{}".to_owned());
    let attempt_records =
        serde_json::to_string(&item.attempt_records).unwrap_or_else(|_| "[]".to_owned());
    Ok(params_from_vec(vec![
        SqlValue::Text(item.receipt_id.clone()),
        SqlValue::Text(item.queue.clone()),
        SqlValue::Text(item.function_id.to_string()),
        item.target_revision
            .map(|revision| SqlValue::Integer(revision.0 as i64))
            .unwrap_or(SqlValue::Null),
        SqlValue::Text(payload),
        SqlValue::Text(item.actor_id.to_string()),
        SqlValue::Text(format!("{:?}", item.actor_kind)),
        SqlValue::Text(item.authority_grant_id.to_string()),
        SqlValue::Text(scopes),
        SqlValue::Text(item.trace_id.to_string()),
        item.parent_invocation_id
            .as_ref()
            .map(|id| SqlValue::Text(id.to_string()))
            .unwrap_or(SqlValue::Null),
        item.trigger_id
            .as_ref()
            .map(|id| SqlValue::Text(id.to_string()))
            .unwrap_or(SqlValue::Null),
        item.session_id
            .as_ref()
            .map(|id| SqlValue::Text(id.clone()))
            .unwrap_or(SqlValue::Null),
        item.workspace_id
            .as_ref()
            .map(|id| SqlValue::Text(id.clone()))
            .unwrap_or(SqlValue::Null),
        item.idempotency_key
            .as_ref()
            .map(|key| SqlValue::Text(key.clone()))
            .unwrap_or(SqlValue::Null),
        SqlValue::Text(item.status.as_str().to_owned()),
        SqlValue::Integer(item.attempts as i64),
        item.lease_owner
            .as_ref()
            .map(|owner| SqlValue::Text(owner.clone()))
            .unwrap_or(SqlValue::Null),
        item.lease_expires_at
            .map(|at| SqlValue::Text(at.to_rfc3339()))
            .unwrap_or(SqlValue::Null),
        SqlValue::Text(item.not_before.to_rfc3339()),
        SqlValue::Text(item.created_at.to_rfc3339()),
        SqlValue::Text(item.updated_at.to_rfc3339()),
        SqlValue::Text(runtime_metadata),
        SqlValue::Text(attempt_records),
    ]))
}

fn params_from_vec(
    values: Vec<rusqlite::types::Value>,
) -> rusqlite::ParamsFromIter<Vec<rusqlite::types::Value>> {
    rusqlite::params_from_iter(values)
}

pub(super) fn row_to_queue_item(
    conn: &Connection,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<EngineQueueItem> {
    let payload_json: String = row.get(4)?;
    let payload = crate::shared::storage::resolve_stored_json_value(conn, &payload_json)
        .map_err(storage_to_sql_err)?;
    let scopes_json: String = row.get(8)?;
    let runtime_metadata_json: String = row.get(22)?;
    let attempt_records_json: String = row.get(23)?;
    let target_revision: Option<i64> = row.get(3)?;
    let parent_invocation_id: Option<String> = row.get(10)?;
    let trigger_id: Option<String> = row.get(11)?;
    Ok(EngineQueueItem {
        receipt_id: row.get(0)?,
        queue: row.get(1)?,
        function_id: FunctionId::new(row.get::<_, String>(2)?)
            .expect("stored queue function id should be valid"),
        target_revision: target_revision.map(|value| FunctionRevision(value as u64)),
        payload,
        actor_id: ActorId::new(row.get::<_, String>(5)?)
            .expect("stored queue actor id should be valid"),
        actor_kind: actor_kind_from_str(&row.get::<_, String>(6)?),
        authority_grant_id: AuthorityGrantId::new(row.get::<_, String>(7)?)
            .expect("stored queue authority id should be valid"),
        authority_scopes: serde_json::from_str(&scopes_json).unwrap_or_default(),
        runtime_metadata: serde_json::from_str(&runtime_metadata_json).unwrap_or_default(),
        trace_id: TraceId::new(row.get::<_, String>(9)?)
            .expect("stored queue trace id should be valid"),
        parent_invocation_id: parent_invocation_id.and_then(|id| InvocationId::new(id).ok()),
        trigger_id: trigger_id.and_then(|id| TriggerId::new(id).ok()),
        session_id: row.get(12)?,
        workspace_id: row.get(13)?,
        idempotency_key: row.get(14)?,
        status: status_from_str(&row.get::<_, String>(15)?),
        attempts: row.get::<_, i64>(16)? as u32,
        attempt_records: serde_json::from_str(&attempt_records_json).unwrap_or_default(),
        lease_owner: row.get(17)?,
        lease_expires_at: row
            .get::<_, Option<String>>(18)?
            .and_then(|value| parse_time(&value)),
        not_before: parse_time(&row.get::<_, String>(19)?).unwrap_or_else(Utc::now),
        created_at: parse_time(&row.get::<_, String>(20)?).unwrap_or_else(Utc::now),
        updated_at: parse_time(&row.get::<_, String>(21)?).unwrap_or_else(Utc::now),
    })
}

pub(super) fn validate_queue(queue: &str) -> Result<()> {
    if queue.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "queue name must not be empty".to_owned(),
        ));
    }
    Ok(())
}

fn status_from_str(value: &str) -> QueueItemStatus {
    match value {
        "leased" => QueueItemStatus::Leased,
        "completed" => QueueItemStatus::Completed,
        "cancelled" => QueueItemStatus::Cancelled,
        "dead_lettered" => QueueItemStatus::DeadLettered,
        _ => QueueItemStatus::Ready,
    }
}

fn actor_kind_from_str(value: &str) -> ActorKind {
    match value {
        "Agent" => ActorKind::Agent,
        "Client" => ActorKind::Client,
        "Worker" => ActorKind::Worker,
        "System" => ActorKind::System,
        "Admin" => ActorKind::Admin,
        _ => ActorKind::System,
    }
}

fn storage_to_sql_err(error: anyhow::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error.to_string())))
}

fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .ok()
}

pub(super) fn sqlite_err(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}
