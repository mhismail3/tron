//! Prompt Library RPC handlers.
//!
//! Eight methods split across two groups:
//!
//! ## History (auto-captured, deduped)
//! - `promptHistory.list`   — engine bridge generic trigger
//! - `promptHistory.delete` — remove a single entry
//! - `promptHistory.clear`  — wipe all history
//!
//! ## Snippets (user-authored)
//! - `promptSnippet.list`   — engine bridge generic trigger
//! - `promptSnippet.get`    — engine bridge generic trigger
//! - `promptSnippet.create` — engine bridge generic trigger
//! - `promptSnippet.update` — engine bridge generic trigger
//! - `promptSnippet.delete` — engine bridge generic trigger
//!
//! Remaining method-specific handlers and migrated engine bridge functions
//! dispatch to `crate::prompt_library::store`, which is the single source of
//! truth for SQL + validation.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::prompt_library::store;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

fn map_store_err(e: crate::events::EventStoreError) -> RpcError {
    use crate::events::EventStoreError as E;
    match e {
        E::InvalidOperation(msg) => RpcError::InvalidParams { message: msg },
        other => RpcError::Internal {
            message: other.to_string(),
        },
    }
}

// ─── promptHistory.delete ──────────────────────────────────────────────

/// Delete a single history entry by id.
pub struct DeleteHistoryHandler;

#[async_trait]
impl MethodHandler for DeleteHistoryHandler {
    #[instrument(skip(self, ctx), fields(method = "promptHistory.delete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let id = require_string_param(params.as_ref(), "id")?;
        let deleted = store::delete_history(ctx.event_store.pool(), &id).map_err(map_store_err)?;
        Ok(serde_json::json!({ "deleted": deleted }))
    }
}

// ─── promptHistory.clear ───────────────────────────────────────────────

/// Clear the entire history table.
pub struct ClearHistoryHandler;

#[async_trait]
impl MethodHandler for ClearHistoryHandler {
    #[instrument(skip(self, ctx), fields(method = "promptHistory.clear"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let n = store::clear_history(ctx.event_store.pool()).map_err(map_store_err)?;
        Ok(serde_json::json!({ "deletedCount": n }))
    }
}

#[cfg(test)]
#[path = "prompt_library_tests.rs"]
mod tests;
