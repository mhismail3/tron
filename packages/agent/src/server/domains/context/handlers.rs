//! Operation binding for the context worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "context::get_snapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::get_snapshot(
                deps.server_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::get_detailed_snapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::get_detailed_snapshot(
                deps.server_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::get_audit_trace" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            let turn = payload
                .get("turn")
                .and_then(Value::as_u64)
                .map(u32::try_from)
                .transpose()
                .map_err(|_| CapabilityError::InvalidParams {
                    message: "turn must fit in u32".into(),
                })?;
            crate::server::domains::context::queries::ContextQueryService::get_audit_trace(
                deps.server_context.as_ref(),
                session_id,
                turn,
            )
            .await
        }
        "context::should_compact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::should_compact(
                deps.server_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::preview_compaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::preview_compaction(
                deps.server_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::can_accept_turn" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::queries::ContextQueryService::can_accept_turn(
                deps.server_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::confirm_compaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            let edited_summary = opt_string(Some(payload), "editedSummary");
            crate::server::domains::context::commands::ContextCommandService::confirm_compaction(
                deps.server_context.as_ref(),
                session_id,
                edited_summary,
            )
            .await
        }
        "context::clear" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::commands::ContextCommandService::clear(
                deps.server_context.as_ref(),
                session_id,
            )
            .await
        }
        "context::compact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::domains::context::commands::ContextCommandService::compact(
                deps.server_context.as_ref(),
                session_id,
            )
            .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("context method {method} is not engine-owned"),
        }),
    }
}
