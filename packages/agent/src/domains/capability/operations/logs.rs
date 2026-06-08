//! Log primitive execute operations.

use serde_json::{Value, json};

use super::{Deps, internal, ok_result, optional_str, optional_u64};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn log_recent(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let limit = optional_u64(&invocation.payload, "limit")?
        .map(|value| value as i64)
        .unwrap_or(50)
        .clamp(1, 500);
    let trace_id = optional_str(&invocation.payload, "traceId")?.map(str::to_owned);
    let session_id = invocation.causal_context.session_id.clone();
    let pool = deps.event_store.pool().clone();
    let entries = run_blocking_task("execute::log_recent", move || {
        let conn = pool.get().map_err(|error| internal(format!("open log query DB: {error}")))?;
        match (trace_id.as_deref(), session_id.as_deref()) {
            (Some(trace_id), Some(session_id)) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE trace_id = ?1 AND (session_id IS NULL OR session_id = ?2) \
                 ORDER BY id DESC LIMIT ?3",
                rusqlite::params![trace_id, session_id, limit],
            ),
            (Some(trace_id), None) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE trace_id = ?1 AND session_id IS NULL \
                 ORDER BY id DESC LIMIT ?2",
                rusqlite::params![trace_id, limit],
            ),
            (None, Some(session_id)) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE session_id IS NULL OR session_id = ?1 \
                 ORDER BY id DESC LIMIT ?2",
                rusqlite::params![session_id, limit],
            ),
            (None, None) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE session_id IS NULL \
                 ORDER BY id DESC LIMIT ?1",
                rusqlite::params![limit],
            ),
        }
    })
    .await?;

    Ok(ok_result(
        format!("Log entries: {}.", entries.len()),
        json!({
            "primitiveOperation": "log_recent",
            "status": "ok",
            "entries": entries
        }),
    ))
}

fn query_log_rows<P>(
    conn: &rusqlite::Connection,
    sql: &str,
    params: P,
) -> Result<Vec<Value>, CapabilityError>
where
    P: rusqlite::Params,
{
    let mut stmt = conn
        .prepare(sql)
        .map_err(|error| internal(format!("prepare log query: {error}")))?;
    let rows = stmt
        .query_map(params, log_row)
        .map_err(|error| internal(format!("read logs: {error}")))?;
    let mut entries = rows
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|error| internal(format!("decode logs: {error}")))?;
    entries.reverse();
    Ok(entries)
}

fn log_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let id: i64 = row.get(0)?;
    let timestamp: String = row.get(1)?;
    let level: String = row.get(2)?;
    let component: String = row.get(3)?;
    let message: String = row.get(4)?;
    let session_id: Option<String> = row.get(5)?;
    let trace_id: Option<String> = row.get(6)?;
    let error_message: Option<String> = row.get(7)?;
    Ok(json!({
        "id": id,
        "timestamp": timestamp,
        "level": level,
        "component": component,
        "message": message,
        "sessionId": session_id,
        "traceId": trace_id,
        "errorMessage": error_message
    }))
}
