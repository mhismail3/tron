//! Agent workflow operations.
use super::AgentCommandService;
use crate::domains::agent::Deps;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn status_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
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
        return Err(CapabilityError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: format!("Session '{session_id}' not found"),
        });
    }

    let run_id = deps.orchestrator.get_run_id(&session_id);
    let phase = if run_id.is_some() {
        "processing"
    } else {
        "idle"
    };
    let current_capability = deps
        .orchestrator
        .turn_accumulators()
        .current_running_capability(&session_id);
    let event_store = deps.event_store.clone();
    let sid_for_latest = session_id.clone();
    let latest_timestamp = run_blocking_task("agent.status.latest_event", move || {
        let pool = event_store.pool().clone();
        let conn = pool.get().map_err(|e| CapabilityError::Internal {
            message: format!("DB connection failed: {e}"),
        })?;
        crate::domains::session::event_store::sqlite::repositories::event::EventRepo::get_latest(
            &conn,
            &sid_for_latest,
        )
        .map(|opt| opt.map(|row| row.timestamp))
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
    let current_capability_value = current_capability.map(|snap| {
        json!({
            "name": snap.model_primitive_name,
            "invocationId": snap.invocation_id,
            "startedAt": snap.started_at,
        })
    });

    Ok(json!({
        "sessionId": session_id,
        "phase": phase,
        "runId": run_id,
        "currentCapability": current_capability_value,
        "lastEventTimestamp": latest_timestamp,
        "timeSinceLastEventMs": time_since_last_event_ms,
    }))
}

pub(crate) async fn abort_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    AgentCommandService::abort(deps, &session_id)
}

pub(crate) async fn abort_invocation_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let invocation_id = require_string_param(params, "invocationId")?;
    AgentCommandService::abort_invocation(deps, &session_id, &invocation_id)
}
