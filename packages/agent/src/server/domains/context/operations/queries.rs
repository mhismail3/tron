//! Context operation implementations.
//!
//! Snapshot reads, compaction checks, and compaction commands live here behind
//! canonical `context::*` functions. The handler file binds operation keys to
//! this module; query/command services keep the actual domain service logic
//! narrow and testable.

use crate::server::domains::context::Deps;
use crate::server::domains::context::commands::ContextCommandService;
use crate::server::domains::context::queries::ContextQueryService;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::{opt_string, require_string_param};
use serde_json::Value;

pub(crate) async fn get_snapshot(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    ContextQueryService::get_snapshot(deps, session_id).await
}

pub(crate) async fn get_detailed_snapshot(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    ContextQueryService::get_detailed_snapshot(deps, session_id).await
}

pub(crate) async fn get_audit_trace(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let turn = payload
        .get("turn")
        .and_then(Value::as_u64)
        .map(u32::try_from)
        .transpose()
        .map_err(|_| CapabilityError::InvalidParams {
            message: "turn must fit in u32".into(),
        })?;
    ContextQueryService::get_audit_trace(deps, session_id, turn).await
}

pub(crate) async fn should_compact(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    ContextQueryService::should_compact(deps, session_id).await
}

pub(crate) async fn preview_compaction(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    ContextQueryService::preview_compaction(deps, session_id).await
}

pub(crate) async fn can_accept_turn(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    ContextQueryService::can_accept_turn(deps, session_id).await
}

pub(crate) async fn confirm_compaction(
    payload: &Value,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let edited_summary = opt_string(Some(payload), "editedSummary");
    ContextCommandService::confirm_compaction(deps, session_id, edited_summary).await
}

pub(crate) async fn clear(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    ContextCommandService::clear(deps, session_id).await
}

pub(crate) async fn compact(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    ContextCommandService::compact(deps, session_id).await
}
