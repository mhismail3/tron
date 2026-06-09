//! Log primitive execute operations.

use serde_json::{Value, json};

use super::{Deps, ok_result, optional_str, optional_u64};
use crate::domains::session::event_store::{LogEntry, LogSessionFilter, RecentLogQuery};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::map_event_store_error;
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
    let event_store = deps.event_store.clone();
    let entries = run_blocking_task("execute::log_recent", move || {
        let session_filter = match session_id.as_deref() {
            Some(session_id) => LogSessionFilter::SessionAndGlobal(session_id),
            None => LogSessionFilter::OnlyGlobal,
        };
        event_store
            .list_recent_logs(RecentLogQuery {
                limit,
                trace_id: trace_id.as_deref(),
                session_filter,
            })
            .map(|entries| entries.into_iter().map(log_entry_value).collect::<Vec<_>>())
            .map_err(map_event_store_error)
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

fn log_entry_value(entry: LogEntry) -> Value {
    json!({
        "id": entry.id,
        "timestamp": entry.timestamp,
        "level": entry.level,
        "component": entry.component,
        "message": entry.message,
        "sessionId": entry.session_id,
        "traceId": entry.trace_id,
        "errorMessage": entry.error_message
    })
}
