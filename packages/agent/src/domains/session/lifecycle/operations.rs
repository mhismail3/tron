use crate::domains::session::Deps;
use crate::shared::server::errors::ToolError;
use crate::shared::server::params::{opt_string, require_string_param};
use serde_json::Value;

pub(crate) async fn session_create_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let working_directory = require_string_param(params, "workingDirectory")?;
    let model =
        opt_string(params, "model").unwrap_or_else(|| "claude-sonnet-4-20250514".to_owned());
    let title = opt_string(params, "title");
    let source_control = params
        .and_then(|params| params.get("sourceControl"))
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|error| ToolError::InvalidParams {
            message: format!("Invalid session sourceControl params: {error}"),
        })?;
    crate::domains::session::lifecycle::SessionLifecycleService::create(
        deps,
        crate::domains::session::lifecycle::CreateSessionRequest {
            working_directory,
            model,
            title,
            source_control,
        },
    )
    .await
}
pub(crate) async fn session_delete_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::lifecycle::SessionLifecycleService::delete(deps, session_id).await
}
pub(crate) async fn session_fork_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let from_event_id = opt_string(params, "fromEventId");
    let title = opt_string(params, "title");
    crate::domains::session::lifecycle::SessionLifecycleService::fork(
        deps,
        session_id,
        from_event_id,
        title,
    )
    .await
}
pub(crate) async fn session_archive_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::lifecycle::SessionLifecycleService::archive(deps, session_id).await
}
pub(crate) async fn session_unarchive_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::lifecycle::SessionLifecycleService::unarchive(deps, session_id).await
}
pub(crate) async fn session_archive_older_than_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let days_raw = params
        .and_then(|p| p.get("days"))
        .and_then(Value::as_u64)
        .ok_or_else(|| ToolError::InvalidParams {
            message: "missing required parameter 'days' (non-negative integer)".into(),
        })?;
    let days = u32::try_from(days_raw).unwrap_or(u32::MAX);
    crate::domains::session::lifecycle::SessionLifecycleService::archive_older_than(deps, days)
        .await
}
