use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "context.getSnapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::rpc::context_queries::ContextQueryService::get_snapshot(
                &session::rpc_context_view(deps),
                session_id,
            )
            .await
        }
        "context.getDetailedSnapshot" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::rpc::context_queries::ContextQueryService::get_detailed_snapshot(
                &session::rpc_context_view(deps),
                session_id,
            )
            .await
        }
        "context.getAuditTrace" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            let turn = payload
                .get("turn")
                .and_then(Value::as_u64)
                .map(u32::try_from)
                .transpose()
                .map_err(|_| RpcError::InvalidParams {
                    message: "turn must fit in u32".into(),
                })?;
            crate::server::rpc::context_queries::ContextQueryService::get_audit_trace(
                &session::rpc_context_view(deps),
                session_id,
                turn,
            )
            .await
        }
        "context.shouldCompact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::rpc::context_queries::ContextQueryService::should_compact(
                &session::rpc_context_view(deps),
                session_id,
            )
            .await
        }
        "context.previewCompaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::rpc::context_queries::ContextQueryService::preview_compaction(
                &session::rpc_context_view(deps),
                session_id,
            )
            .await
        }
        "context.canAcceptTurn" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::rpc::context_queries::ContextQueryService::can_accept_turn(
                &session::rpc_context_view(deps),
                session_id,
            )
            .await
        }
        "context.confirmCompaction" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            let edited_summary = opt_string(Some(payload), "editedSummary");
            crate::server::rpc::context_commands::ContextCommandService::confirm_compaction(
                &session::rpc_context_view(deps),
                session_id,
                edited_summary,
            )
            .await
        }
        "context.clear" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::rpc::context_commands::ContextCommandService::clear(
                &session::rpc_context_view(deps),
                session_id,
            )
            .await
        }
        "context.compact" => {
            let session_id = require_string_param(Some(payload), "sessionId")?;
            crate::server::rpc::context_commands::ContextCommandService::compact(
                &session::rpc_context_view(deps),
                session_id,
            )
            .await
        }
        _ => Err(RpcError::Internal {
            message: format!("context method {method} is not engine-owned"),
        }),
    }
}
