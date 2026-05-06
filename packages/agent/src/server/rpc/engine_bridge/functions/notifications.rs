use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "notifications.list" => notifications_list_value(Some(payload), deps).await,
        "notifications.markRead" => notifications_mark_read_value(Some(payload), deps).await,
        "notifications.markAllRead" => notifications_mark_all_read_value(Some(payload), deps).await,
        _ => Err(RpcError::Internal {
            message: format!("notifications method {method} is not engine-owned"),
        }),
    }
}

async fn notifications_list_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let limit = opt_u64(params, "limit", 50).min(100);
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.list", move || {
        let conn = pool.get().map_err(|error| RpcError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::list(&conn, limit)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_read_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let event_id = require_string_param(params, "eventId")?;
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_read", move || {
        let conn = pool.get().map_err(|error| RpcError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_read(&conn, &event_id)
    })
    .await?;
    to_json_value(&result)
}

async fn notifications_mark_all_read_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = opt_string(params, "sessionId");
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("notifications.mark_all_read", move || {
        let conn = pool.get().map_err(|error| RpcError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        NotificationInboxService::mark_all_read(&conn, session_id.as_deref())
    })
    .await?;
    to_json_value(&result)
}
