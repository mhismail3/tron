//! Session handlers for command-owned operations.
//!
//! Safe session reads (`session.list`, `session.getHead`,
//! `session.getState`, `session.getHistory`, and `session.reconstruct`) are
//! collapsed into canonical engine functions and registered through generic
//! JSON-RPC trigger markers. This module keeps session command handlers plus
//! test-only read wrappers for the existing wire-format regression suite.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::params::require_string_param;
#[cfg(test)]
use crate::server::rpc::params::{opt_bool, opt_string};
use crate::server::rpc::registry::MethodHandler;
#[cfg(test)]
use crate::server::rpc::session_commands::{CreateSessionRequest, SessionCommandService};
use crate::server::rpc::session_queries::SessionQueryService;
#[cfg(test)]
use crate::server::rpc::session_reconstruct::SessionReconstructService;

/// Create a new session.
#[cfg(test)]
pub struct CreateSessionHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for CreateSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = require_string_param(params.as_ref(), "workingDirectory")?;
        let model = opt_string(params.as_ref(), "model")
            .unwrap_or_else(|| "claude-sonnet-4-20250514".to_string());
        let title = opt_string(params.as_ref(), "title");
        let source = opt_string(params.as_ref(), "source");
        let profile = opt_string(params.as_ref(), "profile");
        let use_worktree = opt_bool(params.as_ref(), "useWorktree");

        SessionCommandService::create(
            ctx,
            CreateSessionRequest {
                working_directory: working_dir,
                model,
                title,
                source,
                profile,
                use_worktree,
            },
        )
        .await
    }
}

/// Resume an existing session.
pub struct ResumeSessionHandler;

#[async_trait]
impl MethodHandler for ResumeSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.resume", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionQueryService::resume(ctx, session_id).await
    }
}

/// List sessions with optional filters.
#[cfg(test)]
pub struct ListSessionsHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for ListSessionsHandler {
    #[instrument(skip(self, ctx), fields(method = "session.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let include_archived = opt_bool(params.as_ref(), "includeArchived").unwrap_or(false);

        #[allow(clippy::cast_possible_truncation)]
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .map(|v| v as usize);
        SessionQueryService::list(ctx, include_archived, limit).await
    }
}

/// Delete a session.
#[cfg(test)]
pub struct DeleteSessionHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for DeleteSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.delete", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionCommandService::delete(ctx, session_id).await
    }
}

/// Fork a session at the current head (or a specific event).
#[cfg(test)]
pub struct ForkSessionHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for ForkSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.fork", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let from_event_id = opt_string(params.as_ref(), "fromEventId");
        let title = opt_string(params.as_ref(), "title");
        SessionCommandService::fork(ctx, session_id, from_event_id, title).await
    }
}

/// Get the head event ID for a session.
#[cfg(test)]
pub struct GetHeadHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for GetHeadHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getHead", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionQueryService::get_head(ctx, session_id).await
    }
}

/// Get reconstructed state for a session.
#[cfg(test)]
pub struct GetStateHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for GetStateHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getState", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionQueryService::get_state(ctx, session_id).await
    }
}

/// Archive a session.
#[cfg(test)]
pub struct ArchiveSessionHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for ArchiveSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.archive", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionCommandService::archive(ctx, session_id).await
    }
}

/// Get conversation history for a session (reconstructed messages).
#[cfg(test)]
pub struct GetHistoryHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for GetHistoryHandler {
    #[instrument(skip(self, ctx), fields(method = "session.getHistory", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        #[allow(clippy::cast_possible_truncation)]
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .map(|v| v as usize);

        let before_id = opt_string(params.as_ref(), "beforeId");
        SessionQueryService::get_history(ctx, session_id, limit, before_id).await
    }
}

/// Unarchive a session.
#[cfg(test)]
pub struct UnarchiveSessionHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for UnarchiveSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.unarchive", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionCommandService::unarchive(ctx, session_id).await
    }
}

/// Archive all user-facing sessions whose `last_activity_at` is older than
/// `days` days. Returns a batch report — `archivedCount`,
/// `archivedSessionIds`, and `skipped` — so callers can surface partial
/// success without another round-trip.
#[cfg(test)]
pub struct ArchiveOlderThanHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for ArchiveOlderThanHandler {
    #[instrument(skip(self, ctx), fields(method = "session.archiveOlderThan"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let days_raw = params
            .as_ref()
            .and_then(|p| p.get("days"))
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::InvalidParams {
                message: "missing required parameter 'days' (non-negative integer)".into(),
            })?;
        // Hard cap at ~30 years so an accidental `i64::MAX` doesn't underflow
        // the chrono subtraction. Any realistic retention window fits here.
        let days = u32::try_from(days_raw).unwrap_or(u32::MAX);
        SessionCommandService::archive_older_than(ctx, days).await
    }
}

/// Full session dump — session row plus every event — under a stable
/// `format: "tron.session.v1"` envelope. Backs the "Export" user action
/// so users can back up or inspect a session offline without touching
/// `~/.tron/internal/database/` directly.
#[cfg(test)]
pub struct ExportSessionHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for ExportSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "session.export", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        SessionQueryService::export(ctx, session_id).await
    }
}

/// Reconstruct full session state for reconnection.
#[cfg(test)]
pub struct ReconstructHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for ReconstructHandler {
    #[instrument(skip(self, ctx), fields(method = "session.reconstruct", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_i64);
        let before_sequence = params
            .as_ref()
            .and_then(|p| p.get("beforeSequence"))
            .and_then(Value::as_i64);
        SessionReconstructService::reconstruct(ctx, session_id, limit, before_sequence).await
    }
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
