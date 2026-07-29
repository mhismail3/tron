use crate::domains::session::Deps;
use crate::shared::server::errors::ToolError;
use crate::shared::server::params::{opt_bool, opt_string, require_string_param};
use serde_json::Value;

pub(crate) async fn session_resume_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::resume(deps, session_id).await
}
pub(crate) async fn session_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let include_archived = opt_bool(params, "includeArchived").unwrap_or(false);
    let working_directory = match opt_string(params, "workingDirectory") {
        Some(path) => Some(
            crate::shared::foundation::paths::normalize_working_directory(&path)
                .map_err(|message| ToolError::InvalidParams { message })?
                .display()
                .to_string(),
        ),
        None => None,
    };
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as usize);
    let offset = params
        .and_then(|p| p.get("offset"))
        .and_then(Value::as_u64)
        .map(|value| value as usize);
    let cursor: Option<super::SessionListCursor> = opt_string(params, "cursor")
        .map(|cursor| {
            serde_json::from_str(&cursor).map_err(|_| ToolError::InvalidParams {
                message: "cursor must be a session::list cursor returned by the server".into(),
            })
        })
        .transpose()?;
    if let Some(cursor) = cursor.as_ref() {
        if cursor.version != 1 {
            return Err(ToolError::InvalidParams {
                message: "session::list cursor version is not supported".into(),
            });
        }
        if cursor.include_archived != include_archived
            || cursor.working_directory != working_directory
        {
            return Err(ToolError::InvalidParams {
                message: "session::list cursor must be reused with the same filters".into(),
            });
        }
    }
    if cursor.is_some() && offset.is_some() {
        return Err(ToolError::InvalidParams {
            message: "session::list accepts either cursor or offset, not both".into(),
        });
    }
    crate::domains::session::query::SessionQueryService::list(
        deps,
        include_archived,
        limit,
        working_directory,
        offset,
        cursor,
    )
    .await
}
pub(crate) async fn session_get_head_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::get_head(deps, session_id).await
}
pub(crate) async fn session_get_state_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::get_state(deps, session_id).await
}
pub(crate) async fn session_get_history_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as usize);
    let before_id = opt_string(params, "beforeId");
    crate::domains::session::query::SessionQueryService::get_history(
        deps, session_id, limit, before_id,
    )
    .await
}

pub(crate) async fn session_context_requests_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let before_sequence = params
        .and_then(|payload| payload.get("beforeSequence"))
        .and_then(Value::as_i64);
    let limit = params
        .and_then(|payload| payload.get("limit"))
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok());
    crate::domains::session::query::SessionQueryService::context_requests(
        deps,
        session_id,
        before_sequence,
        limit,
    )
    .await
}

pub(crate) async fn session_context_request_detail_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_id = require_string_param(params, "eventId")?;
    crate::domains::session::query::SessionQueryService::context_request_detail(
        deps, session_id, event_id,
    )
    .await
}

pub(crate) async fn session_agent_updates_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let limit = params
        .and_then(|payload| payload.get("limit"))
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok());
    crate::domains::session::query::SessionQueryService::agent_updates(deps, session_id, limit)
        .await
}
pub(crate) async fn session_export_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::export(deps, session_id).await
}

pub(crate) async fn session_replay_manifest_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::replay_manifest(deps, session_id).await
}
