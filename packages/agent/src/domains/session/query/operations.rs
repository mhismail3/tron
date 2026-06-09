use crate::domains::session::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::{opt_bool, opt_string, require_string_param};
use serde_json::Value;

pub(crate) async fn session_resume_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::resume(deps, session_id).await
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
    crate::domains::session::query::SessionQueryService::list(
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
    crate::domains::session::query::SessionQueryService::get_head(deps, session_id).await
}
pub(crate) async fn session_get_state_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::get_state(deps, session_id).await
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
    crate::domains::session::query::SessionQueryService::get_history(
        deps, session_id, limit, before_id,
    )
    .await
}
pub(crate) async fn session_export_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::export(deps, session_id).await
}

pub(crate) async fn session_replay_manifest_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::domains::session::query::SessionQueryService::replay_manifest(deps, session_id).await
}
