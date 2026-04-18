//! Prompt Library RPC handlers.
//!
//! Eight methods split across two groups:
//!
//! ## History (auto-captured, deduped)
//! - `promptHistory.list`   — paginated list, optional search
//! - `promptHistory.delete` — remove a single entry
//! - `promptHistory.clear`  — wipe all history
//!
//! ## Snippets (user-authored)
//! - `promptSnippet.list`   — all snippets, `updated_at DESC`
//! - `promptSnippet.get`    — single snippet by id
//! - `promptSnippet.create` — new snippet
//! - `promptSnippet.update` — partial update (requires ≥1 mutating field)
//! - `promptSnippet.delete` — remove snippet
//!
//! All handlers dispatch to `crate::prompt_library::store` which is the
//! single source of truth for SQL + validation.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::prompt_library::store;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{RpcError, to_json_value};
use crate::server::rpc::handlers::{opt_string, opt_u64, require_string_param};
use crate::server::rpc::registry::MethodHandler;
use crate::server::rpc::validation::{MAX_PROMPT_LENGTH, validate_string_param};

/// Upper bound for the `query` param on `promptHistory.list`.
const MAX_SEARCH_QUERY_LEN: usize = 200;

fn map_store_err(e: crate::events::EventStoreError) -> RpcError {
    use crate::events::EventStoreError as E;
    match e {
        E::InvalidOperation(msg) => RpcError::InvalidParams { message: msg },
        other => RpcError::Internal {
            message: other.to_string(),
        },
    }
}

// ─── promptHistory.list ────────────────────────────────────────────────

/// List prompt history entries (newest first).
pub struct ListHistoryHandler;

#[async_trait]
impl MethodHandler for ListHistoryHandler {
    #[instrument(skip(self, ctx), fields(method = "promptHistory.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let limit_raw = opt_u64(params.as_ref(), "limit", store::DEFAULT_LIST_LIMIT as u64);
        if limit_raw > store::MAX_LIST_LIMIT as u64 {
            return Err(RpcError::InvalidParams {
                message: format!(
                    "'limit' must be ≤ {} (got {limit_raw})",
                    store::MAX_LIST_LIMIT
                ),
            });
        }
        let limit = limit_raw as u32;

        let cursor = opt_string(params.as_ref(), "cursor");
        let query = opt_string(params.as_ref(), "query");
        if let Some(ref q) = query {
            validate_string_param(q, "query", MAX_SEARCH_QUERY_LEN)?;
        }

        let pool = ctx.event_store.pool();
        let page = store::list_history(pool, limit, cursor, query).map_err(map_store_err)?;

        Ok(serde_json::json!({
            "items": to_json_value(&page.items)?,
            "nextCursor": page.next_cursor,
        }))
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
        let deleted =
            store::delete_history(ctx.event_store.pool(), &id).map_err(map_store_err)?;
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

// ─── promptSnippet.list ────────────────────────────────────────────────

/// List all snippets sorted by `updated_at DESC`.
pub struct ListSnippetsHandler;

#[async_trait]
impl MethodHandler for ListSnippetsHandler {
    #[instrument(skip(self, ctx), fields(method = "promptSnippet.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let items = store::list_snippets(ctx.event_store.pool()).map_err(map_store_err)?;
        Ok(serde_json::json!({ "items": to_json_value(&items)? }))
    }
}

// ─── promptSnippet.get ─────────────────────────────────────────────────

/// Get a single snippet by id.
pub struct GetSnippetHandler;

#[async_trait]
impl MethodHandler for GetSnippetHandler {
    #[instrument(skip(self, ctx), fields(method = "promptSnippet.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let id = require_string_param(params.as_ref(), "id")?;
        let snippet = store::get_snippet(ctx.event_store.pool(), &id)
            .map_err(map_store_err)?
            .ok_or_else(|| RpcError::NotFound {
                code: "SNIPPET_NOT_FOUND".into(),
                message: format!("Snippet not found: {id}"),
            })?;
        Ok(serde_json::json!({ "snippet": to_json_value(&snippet)? }))
    }
}

// ─── promptSnippet.create ──────────────────────────────────────────────

/// Create a new snippet.
pub struct CreateSnippetHandler;

#[async_trait]
impl MethodHandler for CreateSnippetHandler {
    #[instrument(skip(self, ctx), fields(method = "promptSnippet.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        let text = require_string_param(params.as_ref(), "text")?;
        validate_string_param(&text, "text", MAX_PROMPT_LENGTH)?;

        let snippet = store::create_snippet(ctx.event_store.pool(), &name, &text)
            .map_err(map_store_err)?;
        Ok(serde_json::json!({ "snippet": to_json_value(&snippet)? }))
    }
}

// ─── promptSnippet.update ──────────────────────────────────────────────

/// Partial-update an existing snippet. Requires at least one of `name`/`text`.
pub struct UpdateSnippetHandler;

#[async_trait]
impl MethodHandler for UpdateSnippetHandler {
    #[instrument(skip(self, ctx), fields(method = "promptSnippet.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let id = require_string_param(params.as_ref(), "id")?;
        let name = opt_string(params.as_ref(), "name");
        let text = opt_string(params.as_ref(), "text");

        if name.is_none() && text.is_none() {
            return Err(RpcError::InvalidParams {
                message: "update requires at least one of 'name' or 'text'".into(),
            });
        }
        if let Some(ref t) = text {
            validate_string_param(t, "text", MAX_PROMPT_LENGTH)?;
        }

        let updated = store::update_snippet(ctx.event_store.pool(), &id, name, text)
            .map_err(map_store_err)?
            .ok_or_else(|| RpcError::NotFound {
                code: "SNIPPET_NOT_FOUND".into(),
                message: format!("Snippet not found: {id}"),
            })?;
        Ok(serde_json::json!({ "snippet": to_json_value(&updated)? }))
    }
}

// ─── promptSnippet.delete ──────────────────────────────────────────────

/// Delete a snippet by id. Idempotent — returns `deleted: false` if missing.
pub struct DeleteSnippetHandler;

#[async_trait]
impl MethodHandler for DeleteSnippetHandler {
    #[instrument(skip(self, ctx), fields(method = "promptSnippet.delete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let id = require_string_param(params.as_ref(), "id")?;
        let deleted =
            store::delete_snippet(ctx.event_store.pool(), &id).map_err(map_store_err)?;
        Ok(serde_json::json!({ "deleted": deleted }))
    }
}

#[cfg(test)]
#[path = "prompt_library_tests.rs"]
mod tests;
