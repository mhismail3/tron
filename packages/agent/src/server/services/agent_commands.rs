//! Shared command-side services for agent capabilities.

use serde_json::{Value, json};

use crate::server::services::context::ServerCapabilityContext;
use crate::server::transport::json_rpc::errors::{self, RpcError};

pub(crate) struct AgentCommandService;

impl AgentCommandService {
    pub(crate) async fn load_prompt_session(
        ctx: &ServerCapabilityContext,
        session_id: &str,
    ) -> Result<crate::events::sqlite::row_types::SessionRow, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id = session_id.to_owned();
        ctx.run_blocking("agent.prompt.load_session", move || {
            session_manager
                .get_session(&session_id)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?
                .ok_or_else(|| RpcError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id}' not found"),
                })
        })
        .await
    }

    pub(crate) fn abort(
        ctx: &ServerCapabilityContext,
        session_id: &str,
    ) -> Result<Value, RpcError> {
        let aborted = ctx
            .orchestrator
            .abort(session_id)
            .map_err(|error| RpcError::Internal {
                message: error.to_string(),
            })?;

        if aborted && let Some(ref broker) = ctx.device_request_broker {
            broker.cancel_session_pending(session_id);
        }

        Ok(json!({ "aborted": aborted }))
    }

    /// Abort a single in-flight tool call without aborting the surrounding turn.
    ///
    /// Returns `{ "aborted": true }` if the tool was in flight (its child
    /// `CancellationToken` was cancelled) or `{ "aborted": false }` when
    /// there is no matching tool — the call already finished, the id is
    /// wrong, or the session has no per-tool registry. Callers treat both
    /// as "nothing to do" rather than errors.
    pub(crate) fn abort_tool(
        ctx: &ServerCapabilityContext,
        session_id: &str,
        tool_call_id: &str,
    ) -> Result<Value, RpcError> {
        let aborted = ctx
            .orchestrator
            .tool_abort_registry()
            .abort(session_id, tool_call_id);
        Ok(json!({ "aborted": aborted }))
    }
}
