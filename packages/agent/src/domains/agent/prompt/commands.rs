//! Agent workflow operations.
use super::AgentCommandService;
use crate::domains::agent::Deps;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::ToolError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn status_value(params: Option<&Value>, deps: &Deps) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid_for_check = session_id.clone();
    let session_exists = run_blocking_task("agent.status.session_check", move || {
        event_store
            .get_session(&sid_for_check)
            .map(|opt| opt.is_some())
            .map_err(crate::shared::server::error_mapping::map_event_store_error)
    })
    .await?;
    if !session_exists {
        return Err(ToolError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: format!("Session '{session_id}' not found"),
        });
    }

    let (run_id, current_tool) = deps.orchestrator.agent_status_snapshot(&session_id);
    let phase = if run_id.is_some() {
        "processing"
    } else {
        "idle"
    };
    let event_store = deps.event_store.clone();
    let sid_for_latest = session_id.clone();
    let latest_timestamp = run_blocking_task("agent.status.latest_event", move || {
        event_store
            .get_latest_events(&sid_for_latest, Some(1))
            .map(|mut events| events.pop().map(|row| row.timestamp))
            .map_err(crate::shared::server::error_mapping::map_event_store_error)
    })
    .await?;
    let time_since_last_event_ms = latest_timestamp
        .as_deref()
        .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
        .and_then(|parsed| {
            let now = chrono::Utc::now();
            let delta = now.signed_duration_since(parsed.with_timezone(&chrono::Utc));
            delta.num_milliseconds().try_into().ok()
        })
        .map(|ms: i64| ms.max(0));
    let current_tool_value = current_tool.map(|snap| {
        json!({
            "name": snap.tool_name,
            "invocationId": snap.invocation_id,
            "startedAt": snap.started_at,
        })
    });

    Ok(json!({
        "sessionId": session_id,
        "phase": phase,
        "runId": run_id,
        "currentTool": current_tool_value,
        "lastEventTimestamp": latest_timestamp,
        "timeSinceLastEventMs": time_since_last_event_ms,
    }))
}

pub(crate) async fn abort_value(params: Option<&Value>, deps: &Deps) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    AgentCommandService::abort(deps, &session_id)
}

pub(crate) async fn abort_invocation_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let invocation_id = require_string_param(params, "invocationId")?;
    AgentCommandService::abort_invocation(deps, &session_id, &invocation_id)
}
