//! Job management RPC handlers — unified interface for processes and subagents.
//!
//! Replaces the old `process.*` namespace with `job.*`. Routes through
//! `JobManager` to support both process IDs (`proc-*`) and subagent IDs.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tracing::instrument;

use crate::events::{AppendOptions, EventType};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

// =============================================================================
// job.background — promote a blocking job to background
// =============================================================================

/// Promote a blocking process to background. Fires the promote_tx oneshot
/// in ProcessManager, which unblocks the tool call.
pub struct BackgroundHandler;

#[async_trait]
impl MethodHandler for BackgroundHandler {
    #[instrument(skip(self, ctx), fields(method = "job.background"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let job_id = require_string_param(params.as_ref(), "jobId")?;
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let pm = ctx
            .process_manager
            .as_ref()
            .ok_or_else(|| RpcError::Internal {
                message: "Process manager not available".into(),
            })?;

        pm.promote_to_background(&job_id)
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to background: {e}"),
            })?;

        // Persist notification for context injection on next turn.
        let label = pm
            .list_processes(&session_id)
            .into_iter()
            .find(|p| p.process_id == job_id)
            .map(|p| p.label)
            .unwrap_or_default();

        persist_user_action(
            &ctx.event_store,
            &session_id,
            &job_id,
            "backgrounded",
            &label,
        );

        Ok(json!({
            "jobId": job_id,
            "backgrounded": true,
        }))
    }
}

// =============================================================================
// job.cancel — cancel a running job
// =============================================================================

/// Cancel a running job (process or subagent).
pub struct CancelHandler;

#[async_trait]
impl MethodHandler for CancelHandler {
    #[instrument(skip(self, ctx), fields(method = "job.cancel"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let job_id = require_string_param(params.as_ref(), "jobId")?;
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Try job manager (routes to process or subagent), fall back to process manager.
        if let Some(ref jm) = ctx.job_manager {
            jm.cancel_job(&job_id, true)
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to cancel: {e}"),
                })?;
        } else if let Some(ref pm) = ctx.process_manager {
            pm.cancel_process(&job_id, true)
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to cancel: {e}"),
                })?;
        } else {
            return Err(RpcError::Internal {
                message: "No job manager available".into(),
            });
        }

        // Persist notification for context injection on next turn.
        let label = if let Some(ref pm) = ctx.process_manager {
            pm.list_processes(&session_id)
                .into_iter()
                .find(|p| p.process_id == job_id)
                .map(|p| p.label)
                .unwrap_or_default()
        } else {
            String::new()
        };

        persist_user_action(&ctx.event_store, &session_id, &job_id, "cancelled", &label);

        Ok(json!({
            "jobId": job_id,
            "cancelled": true,
        }))
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Persist a `notification.user_job_action` event for context injection.
fn persist_user_action(
    event_store: &Arc<crate::events::EventStore>,
    session_id: &str,
    job_id: &str,
    action: &str,
    label: &str,
) {
    match event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::NotificationUserJobAction,
        payload: json!({
            "jobId": job_id,
            "action": action,
            "label": label,
        }),
        parent_id: None,
        sequence: None,
    }) {
        Ok(event) => {
            tracing::info!(
                job_id,
                action,
                session_id,
                event_id = %event.id,
                "persisted user job action"
            );
        }
        Err(e) => {
            tracing::error!(
                job_id,
                action,
                session_id,
                error = %e,
                "failed to persist user job action"
            );
        }
    }
}
