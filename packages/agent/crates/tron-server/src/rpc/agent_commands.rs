//! Shared command-side services for agent RPC handlers.

use serde_json::{Value, json};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};

pub(crate) struct AgentCommandService;

impl AgentCommandService {
    pub(crate) async fn load_prompt_session(
        ctx: &RpcContext,
        session_id: &str,
    ) -> Result<tron_events::sqlite::row_types::SessionRow, RpcError> {
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

    pub(crate) fn abort(ctx: &RpcContext, session_id: &str) -> Result<Value, RpcError> {
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
}
