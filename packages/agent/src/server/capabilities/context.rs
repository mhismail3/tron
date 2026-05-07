use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "context::get_snapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::services::context_queries::ContextQueryService::get_snapshot(
                &session::capability_context_view(deps),
                session_id,
            )
            .await
        }
        "context::get_detailed_snapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::services::context_queries::ContextQueryService::get_detailed_snapshot(
                &session::capability_context_view(deps),
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
            crate::server::services::context_queries::ContextQueryService::get_audit_trace(
                &session::capability_context_view(deps),
                session_id,
                turn,
            )
            .await
        }
        "context::should_compact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::services::context_queries::ContextQueryService::should_compact(
                &session::capability_context_view(deps),
                session_id,
            )
            .await
        }
        "context::preview_compaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::services::context_queries::ContextQueryService::preview_compaction(
                &session::capability_context_view(deps),
                session_id,
            )
            .await
        }
        "context::can_accept_turn" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::services::context_queries::ContextQueryService::can_accept_turn(
                &session::capability_context_view(deps),
                session_id,
            )
            .await
        }
        "context::confirm_compaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            let edited_summary = opt_string(Some(payload), "editedSummary");
            crate::server::services::context_commands::ContextCommandService::confirm_compaction(
                &session::capability_context_view(deps),
                session_id,
                edited_summary,
            )
            .await
        }
        "context::clear" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::services::context_commands::ContextCommandService::clear(
                &session::capability_context_view(deps),
                session_id,
            )
            .await
        }
        "context::compact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::services::context_commands::ContextCommandService::compact(
                &session::capability_context_view(deps),
                session_id,
            )
            .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("context method {method} is not engine-owned"),
        }),
    }
}
