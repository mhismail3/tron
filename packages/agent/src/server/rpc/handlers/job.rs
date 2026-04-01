//! Job management RPC handlers — unified interface for processes and subagents.
//!
//! Replaces the old `process.*` namespace with `job.*`. Routes through
//! `JobManager` to support both process IDs (`proc-*`) and subagent IDs.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::instrument;

use crate::core::events::{BaseEvent, TronEvent};
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

        let pm = ctx.process_manager.as_ref().ok_or_else(|| RpcError::Internal {
            message: "Process manager not available".into(),
        })?;

        pm.promote_to_background(&job_id).map_err(|e| RpcError::Internal {
            message: format!("Failed to background: {e}"),
        })?;

        // Persist notification for context injection on next turn.
        let label = pm
            .list_processes(&session_id)
            .into_iter()
            .find(|p| p.process_id == job_id)
            .map(|p| p.label)
            .unwrap_or_default();

        persist_user_action(&ctx.event_store, &session_id, &job_id, "backgrounded", &label);

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
            jm.cancel_job(&job_id).map_err(|e| RpcError::Internal {
                message: format!("Failed to cancel: {e}"),
            })?;
        } else if let Some(ref pm) = ctx.process_manager {
            pm.cancel_process(&job_id).map_err(|e| RpcError::Internal {
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
// job.list — list all jobs for a session
// =============================================================================

/// List all jobs (processes + subagents) for a session.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "job.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        if let Some(ref jm) = ctx.job_manager {
            let jobs = jm.list_jobs(&session_id);
            Ok(json!({ "jobs": jobs }))
        } else if let Some(ref pm) = ctx.process_manager {
            let processes = pm.list_processes(&session_id);
            Ok(json!({ "jobs": processes }))
        } else {
            Ok(json!({ "jobs": [] }))
        }
    }
}

// =============================================================================
// job.subscribe — start streaming output for a job
// =============================================================================

/// Subscribe to real-time output streaming for a job.
/// Replays buffered output, then tails live chunks as `agent.tool_output` events.
pub struct SubscribeHandler;

/// Tracks active output subscriptions so they can be cancelled on unsubscribe.
static ACTIVE_SUBSCRIPTIONS: std::sync::LazyLock<
    dashmap::DashMap<String, CancellationToken>,
> = std::sync::LazyLock::new(dashmap::DashMap::new);

#[async_trait]
impl MethodHandler for SubscribeHandler {
    #[instrument(skip(self, ctx), fields(method = "job.subscribe"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let job_id = require_string_param(params.as_ref(), "jobId")?;

        let registry = ctx.output_buffer_registry.as_ref().ok_or_else(|| RpcError::Internal {
            message: "Output buffer registry not available".into(),
        })?;

        let (buffer, tool_call_id) = registry.get(&job_id).ok_or_else(|| RpcError::InvalidParams {
            message: format!("No output buffer for job: {job_id}"),
        })?;

        // Cancel any existing subscription for this job.
        if let Some((_, old_cancel)) = ACTIVE_SUBSCRIPTIONS.remove(&job_id) {
            old_cancel.cancel();
        }

        let cancel = CancellationToken::new();
        let _ = ACTIVE_SUBSCRIPTIONS.insert(job_id.clone(), cancel.clone());

        let emitter = ctx.orchestrator.broadcast().clone();
        let session_id = {
            // Try to get session_id from process manager
            let sid = if let Some(ref pm) = ctx.process_manager {
                pm.list_processes("")
                    .into_iter()
                    .find(|p| p.process_id == job_id)
                    .map(|p| p.session_id)
            } else {
                None
            };
            sid.unwrap_or_default()
        };

        let sub_job_id = job_id.clone();
        let _ = tokio::spawn(async move {
            run_subscriber(buffer, &tool_call_id, &session_id, &emitter, cancel).await;
            let _ = ACTIVE_SUBSCRIPTIONS.remove(&sub_job_id);
        });

        Ok(json!({
            "subscribed": true,
            "jobId": job_id,
        }))
    }
}

/// Subscriber task: replays buffered output then tails live chunks.
async fn run_subscriber(
    buffer: Arc<crate::runtime::orchestrator::output_buffer::SharedOutputBuffer>,
    tool_call_id: &str,
    session_id: &str,
    emitter: &Arc<crate::runtime::agent::event_emitter::EventEmitter>,
    cancel: CancellationToken,
) {
    let mut offset = 0;

    loop {
        // Read any new chunks.
        let (chunks, new_offset) = buffer.read_from(offset);
        offset = new_offset;

        for chunk in chunks {
            let _ = emitter.emit(TronEvent::ToolExecutionUpdate {
                base: BaseEvent::now(session_id),
                tool_call_id: tool_call_id.to_owned(),
                update: chunk,
            });
        }

        // If buffer is closed, we've drained everything — exit.
        if buffer.is_closed() {
            // Final drain.
            let (final_chunks, _) = buffer.read_from(offset);
            for chunk in final_chunks {
                let _ = emitter.emit(TronEvent::ToolExecutionUpdate {
                    base: BaseEvent::now(session_id),
                    tool_call_id: tool_call_id.to_owned(),
                    update: chunk,
                });
            }
            break;
        }

        // Wait for more data or cancellation.
        tokio::select! {
            () = cancel.cancelled() => break,
            () = buffer.notifier().notified() => {}
        }
    }
}

// =============================================================================
// job.unsubscribe — stop streaming output for a job
// =============================================================================

/// Stop streaming output for a job.
pub struct UnsubscribeHandler;

#[async_trait]
impl MethodHandler for UnsubscribeHandler {
    #[instrument(skip(self, _ctx), fields(method = "job.unsubscribe"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let job_id = require_string_param(params.as_ref(), "jobId")?;

        let cancelled = if let Some((_, cancel)) = ACTIVE_SUBSCRIPTIONS.remove(&job_id) {
            cancel.cancel();
            true
        } else {
            false
        };

        Ok(json!({
            "jobId": job_id,
            "unsubscribed": cancelled,
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
    let _ = event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::NotificationUserJobAction,
        payload: json!({
            "jobId": job_id,
            "action": action,
            "label": label,
        }),
        parent_id: None,
    });
}
