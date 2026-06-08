//! Session operation implementations.
//!
//! Each function here is the executable body behind one canonical `session::*`
//! operation key. The session root module owns registration only; handlers bind
//! operation keys to these functions.

use crate::domains::session::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::{opt_bool, opt_string, require_string_param};
use serde_json::Value;

pub(crate) async fn session_resume_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::queries::SessionQueryService::resume(deps, session_id).await
}

pub(crate) async fn session_create_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let working_directory = require_string_param(params, "workingDirectory")?;
    let model =
        opt_string(params, "model").unwrap_or_else(|| "claude-sonnet-4-20250514".to_owned());
    let title = opt_string(params, "title");
    crate::domains::session::commands::SessionCommandService::create(
        deps,
        crate::domains::session::commands::CreateSessionRequest {
            working_directory,
            model,
            title,
        },
    )
    .await
}

pub(crate) async fn session_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let include_archived = opt_bool(params, "includeArchived").unwrap_or(false);
    let working_directory = match opt_string(params, "workingDirectory") {
        Some(path) => Some(
            crate::shared::foundation::paths::normalize_working_directory(&path)
                .map_err(|message| CapabilityError::InvalidParams { message })?
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
    crate::domains::session::queries::SessionQueryService::list(
        deps,
        include_archived,
        limit,
        working_directory,
        offset,
    )
    .await
}

pub(crate) async fn session_get_head_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::queries::SessionQueryService::get_head(deps, session_id).await
}

pub(crate) async fn session_delete_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::commands::SessionCommandService::delete(deps, session_id).await
}

pub(crate) async fn session_fork_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let from_event_id = opt_string(params, "fromEventId");
    let title = opt_string(params, "title");
    crate::domains::session::commands::SessionCommandService::fork(
        deps,
        session_id,
        from_event_id,
        title,
    )
    .await
}

pub(crate) async fn session_get_state_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::queries::SessionQueryService::get_state(deps, session_id).await
}

pub(crate) async fn session_get_history_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as usize);
    let before_id = opt_string(params, "beforeId");
    crate::domains::session::queries::SessionQueryService::get_history(
        deps, session_id, limit, before_id,
    )
    .await
}

pub(crate) async fn session_reconstruct_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as i64);
    let before_event_id = opt_string(params, "beforeEventId");
    crate::domains::session::reconstruct::SessionReconstructService::reconstruct(
        deps,
        session_id,
        limit,
        before_event_id,
    )
    .await
}

pub(crate) async fn session_archive_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::commands::SessionCommandService::archive(deps, session_id).await
}

pub(crate) async fn session_unarchive_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::commands::SessionCommandService::unarchive(deps, session_id).await
}

pub(crate) async fn session_archive_older_than_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let days_raw = params
        .and_then(|p| p.get("days"))
        .and_then(Value::as_u64)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "missing required parameter 'days' (non-negative integer)".into(),
        })?;
    let days = u32::try_from(days_raw).unwrap_or(u32::MAX);
    crate::domains::session::commands::SessionCommandService::archive_older_than(deps, days).await
}

pub(crate) async fn session_export_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::queries::SessionQueryService::export(deps, session_id).await
}
