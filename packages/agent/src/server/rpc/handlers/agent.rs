//! Agent RPC handlers.
//!
//! ## Submodules
//!
//! - `prompt_runtime`: blocking SQLite reads, prompt bootstrap, session resume,
//!   skill context assembly, and the final `SessionUpdated` payload snapshot.
//! - `prompt_service`: active-run lifecycle, prompt execution, hook dispatch,
//!   event persistence, and completion broadcasts.
//!
//! ## Invariants
//!
//! - `agent.prompt` rejects an already-active session before slower prompt
//!   setup, starts exactly one orchestrator run per accepted prompt, and always
//!   releases the run guard when execution ends.
//! - Completion should emit a best-effort `session_updated` event after SQLite
//!   persistence flushes. The snapshot read retries transient SQLite
//!   busy/locked errors so clients do not miss the final inactive/status update
//!   during high-concurrency test and dogfood runs.

#[cfg(test)]
use crate::events::EventType;
use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::agent_commands::AgentCommandService;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{RpcError, SESSION_BUSY};
use crate::server::rpc::handlers::{opt_array, opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;
#[path = "agent_prompt_runtime.rs"]
pub(crate) mod prompt_runtime;
#[path = "agent_prompt_service.rs"]
pub(crate) mod prompt_service;

#[cfg(test)]
use prompt_runtime::{
    build_user_event_payload, format_subagent_results, get_pending_subagent_results,
};
use prompt_service::{PromptRequest, spawn_prompt_run};

/// Submit a prompt to the agent for a session.
pub struct PromptHandler;

#[async_trait]
impl MethodHandler for PromptHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.prompt", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let prompt = require_string_param(params.as_ref(), "prompt")?;

        crate::server::rpc::validation::validate_string_param(
            &prompt,
            "prompt",
            crate::server::rpc::validation::MAX_PROMPT_LENGTH,
        )?;

        // Extract optional extra params
        let reasoning_level = opt_string(params.as_ref(), "reasoningLevel");
        let images = opt_array(params.as_ref(), "images").cloned();
        let attachments = opt_array(params.as_ref(), "attachments").cloned();

        // Validate attachment sizes before processing.
        if let Some(ref imgs) = images {
            for img in imgs {
                if let Some(data) = img.get("data").and_then(|v| v.as_str()) {
                    crate::server::rpc::validation::validate_attachment_size(data)?;
                }
            }
        }
        if let Some(ref atts) = attachments {
            for att in atts {
                if let Some(data) = att.get("data").and_then(|v| v.as_str()) {
                    crate::server::rpc::validation::validate_attachment_size(data)?;
                }
            }
        }

        // Preserve the wire contract for a running session before doing
        // slower session/provider work that can surface less specific errors.
        // `begin_run` below remains the atomic guard for concurrent requests
        // that race past this preflight.
        if let Some(active_run_id) = ctx.orchestrator.get_run_id(&session_id) {
            return Err(RpcError::Custom {
                code: SESSION_BUSY.into(),
                message: format!(
                    "Session '{session_id}' is already processing run '{active_run_id}'"
                ),
                details: Some(serde_json::json!({ "runId": active_run_id })),
            });
        }

        // Verify the session exists and get its details
        let session = AgentCommandService::load_prompt_session(ctx, &session_id).await?;

        let deps = ctx
            .agent_deps
            .as_ref()
            .ok_or_else(|| RpcError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();

        // Register the run with the orchestrator (tracks CancellationToken).
        // If the session already has an active run, this returns an error.
        let started_run = ctx
            .orchestrator
            .begin_run(&session_id, &run_id)
            .map_err(|e| RpcError::Custom {
                code: e.category().to_uppercase(),
                message: e.to_string(),
                details: None,
            })?;

        // Record prompt to history. Interactive prompts only — skip when caller
        // passed `"source": "cron"` (or anything starting with `"cron"`).
        // Failures are logged but never propagated: the user's prompt must not
        // fail because history couldn't be written. Prompt text is never logged.
        let source = opt_string(params.as_ref(), "source");
        let is_cron = source
            .as_deref()
            .map(|s| s.starts_with("cron"))
            .unwrap_or(false);
        let prompt_library_settings = crate::settings::get_settings().prompt_library.clone();
        if !is_cron && prompt_library_settings.history_enabled {
            let pool = ctx.event_store.pool().clone();
            let text_for_history = prompt.clone();
            let auto_prune = prompt_library_settings.history_auto_prune;
            let max_entries = auto_prune
                .then_some(prompt_library_settings.history_max_entries)
                .filter(|n| *n > 0);
            let max_age_days = auto_prune
                .then_some(prompt_library_settings.history_max_age_days)
                .filter(|n| *n > 0);
            // Fire-and-forget: the user's prompt must never fail because
            // history couldn't be written. The detached task is still routed
            // through the RPC blocking supervisor so shutdown can drain it.
            ctx.spawn_blocking_detached("agent.prompt.history", move || {
                match crate::prompt_library::store::record_prompt_and_prune(
                    &pool,
                    &text_for_history,
                    max_entries,
                    max_age_days,
                ) {
                    Ok(outcome) => {
                        let char_count = text_for_history.chars().count();
                        tracing::debug!(char_count, ?outcome, "recorded prompt history");
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "failed to record prompt history");
                    }
                }
                Ok(())
            });
        }

        spawn_prompt_run(
            ctx,
            deps,
            &session,
            started_run,
            run_id.clone(),
            PromptRequest {
                session_id,
                prompt,
                reasoning_level,
                images,
                attachments,
                message_metadata: None,
            },
        );

        Ok(serde_json::json!({
            "acknowledged": true,
            "runId": run_id,
        }))
    }
}

/// Abort a running agent in a session.
pub struct AbortHandler;

#[async_trait]
impl MethodHandler for AbortHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.abort", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        AgentCommandService::abort(ctx, &session_id)
    }
}

/// Abort a single in-flight tool call without aborting the turn.
///
/// The tool observes cancellation through its per-tool `CancellationToken`
/// child and returns an `Operation cancelled` result; the surrounding turn
/// keeps running other tools and streaming text. If the tool has already
/// finished (or was never registered) the response is
/// `{ "aborted": false }` — callers treat that as "nothing to do".
pub struct AbortToolHandler;

#[async_trait]
impl MethodHandler for AbortToolHandler {
    #[instrument(
        skip(self, ctx),
        fields(method = "agent.abortTool", session_id, tool_call_id)
    )]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let tool_call_id = require_string_param(params.as_ref(), "toolCallId")?;
        AgentCommandService::abort_tool(ctx, &session_id, &tool_call_id)
    }
}

/// `agent.status` — inspect the in-flight state of a session.
///
/// Returns a snapshot combining orchestrator run registry,
/// turn-accumulator tool state, and the event log's latest
/// timestamp for quick "what is the agent doing right now" queries.
/// Cheap: no writes, no mutex contention beyond short reads.
///
/// Response shape:
/// ```json
/// {
///   "sessionId": "...",
///   "phase": "idle" | "processing",
///   "runId": "..." | null,
///   "currentTool": { "name": "...", "toolCallId": "...", "startedAt": "..." } | null,
///   "lastEventTimestamp": "2026-04-21T22:00:00Z" | null,
///   "timeSinceLastEventMs": 1234 | null
/// }
/// ```
///
/// `currentTool` reflects the most recent tool in the turn accumulator
/// whose status is `running`; `null` means no tool is actively
/// executing (the agent is streaming text, thinking, or between turns).
pub struct StatusHandler;

#[async_trait]
impl MethodHandler for StatusHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.status", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Verify session exists — a typo'd sessionId from the client
        // should error clearly rather than silently returning idle.
        let event_store = ctx.event_store.clone();
        let sid_for_check = session_id.clone();
        let session_exists = ctx
            .run_blocking("agent.status.session_check", move || {
                event_store
                    .get_session(&sid_for_check)
                    .map(|opt| opt.is_some())
                    .map_err(crate::server::rpc::handlers::map_event_store_error)
            })
            .await?;
        if !session_exists {
            return Err(RpcError::NotFound {
                code: "SESSION_NOT_FOUND".into(),
                message: format!("Session '{session_id}' not found"),
            });
        }

        let run_id = ctx.orchestrator.get_run_id(&session_id);
        let phase = if run_id.is_some() {
            "processing"
        } else {
            "idle"
        };

        let current_tool = ctx
            .orchestrator
            .turn_accumulators()
            .current_running_tool(&session_id);

        // Look up the latest event's timestamp to derive time-since
        // signal. Blocking DB query; move off the async thread.
        let event_store = ctx.event_store.clone();
        let sid_for_latest = session_id.clone();
        let latest_timestamp = ctx
            .run_blocking("agent.status.latest_event", move || {
                let pool = event_store.pool().clone();
                let conn = pool.get().map_err(|e| RpcError::Internal {
                    message: format!("DB connection failed: {e}"),
                })?;
                crate::events::sqlite::repositories::event::EventRepo::get_latest(
                    &conn,
                    &sid_for_latest,
                )
                .map(|opt| opt.map(|row| row.timestamp))
                .map_err(crate::server::rpc::handlers::map_event_store_error)
            })
            .await?;

        // Derive elapsed time from the last-event timestamp. If parse
        // fails or the timestamp is in the future (clock skew), return
        // None rather than a nonsensical negative.
        let time_since_last_event_ms = latest_timestamp
            .as_deref()
            .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
            .and_then(|parsed| {
                let now = chrono::Utc::now();
                let delta = now.signed_duration_since(parsed.with_timezone(&chrono::Utc));
                delta.num_milliseconds().try_into().ok()
            })
            .map(|ms: i64| ms.max(0));

        let current_tool_value = current_tool.map(|snap| {
            serde_json::json!({
                "name": snap.tool_name,
                "toolCallId": snap.tool_call_id,
                "startedAt": snap.started_at,
            })
        });

        Ok(serde_json::json!({
            "sessionId": session_id,
            "phase": phase,
            "runId": run_id,
            "currentTool": current_tool_value,
            "lastEventTimestamp": latest_timestamp,
            "timeSinceLastEventMs": time_since_last_event_ms,
        }))
    }
}

#[cfg(test)]
#[path = "agent/tests.rs"]
mod tests;
