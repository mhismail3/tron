//! notifications domain worker.
//!
//! This module owns canonical function execution for the notifications namespace and keeps
//! domain services, schemas, and tests beside the worker that uses them.

pub(crate) mod spec;

use super::*;

pub(crate) mod inbox;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "notifications::list" => notifications_list_value(Some(payload), deps).await,
        "notifications::mark_read" => notifications_mark_read_value(Some(payload), deps).await,
        "notifications::mark_all_read" => {
            notifications_mark_all_read_value(Some(payload), deps).await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("notifications method {method} is not engine-owned"),
        }),
    }
}

async fn notifications_list_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let limit = opt_u64(params, "limit", 50).min(100);
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications::list", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::list(&conn, limit)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_read_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let event_id = require_string_param(params, "eventId")?;
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_read", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_read(&conn, &event_id)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_all_read_value(
    params: Option<&Value>,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let session_id = opt_string(params, "sessionId");
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_all_read", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_all_read(&conn, session_id.as_deref())
    })
    .await?;
    to_json_value(&result)
}
