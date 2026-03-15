//! Memory handlers: getLedger, updateLedger, search.
//!
//! The ledger write pipeline is shared between two callers:
//! - **Auto path**: `MemoryManager.on_cycle_complete()` → `RuntimeMemoryDeps.write_ledger_entry()`
//! - **Manual path**: `UpdateLedgerHandler` (RPC `memory.updateLedger`)
//!
//! Both call [`execute_ledger_write()`] — the ONLY difference is what triggers the call.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

#[cfg(test)]
use crate::core::messages::{Message, UserMessageContent};

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::memory_commands::{LedgerUpdateTarget, MemoryCommandService};
#[cfg(test)]
use crate::server::rpc::memory_ledger::{
    LedgerWriteDeps, build_cycle_snapshot as compute_cycle_messages, cron_assistant_text_len,
    execute_ledger_write, prepare_cron_transcript,
};
use crate::server::rpc::memory_queries::MemoryQueryService;
use crate::server::rpc::registry::MethodHandler;

use super::{opt_array, opt_string, opt_u64};

// =============================================================================
// RPC Handlers
// =============================================================================

/// Get ledger entries, optionally scoped to a workspace.
///
/// When `workingDirectory` is provided, returns entries for that workspace and
/// its children (prefix match). When omitted (or null), returns ALL ledger
/// entries across all workspaces.
pub struct GetLedgerHandler;

#[async_trait]
impl MethodHandler for GetLedgerHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.getLedger"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir: Option<String> =
            opt_string(params.as_ref(), "workingDirectory").filter(|s| !s.is_empty());

        let limit = i64::try_from(opt_u64(params.as_ref(), "limit", 50)).unwrap_or(50);

        let offset = i64::try_from(opt_u64(params.as_ref(), "offset", 0)).unwrap_or(0);

        let tags_filter: Option<Vec<String>> = opt_array(params.as_ref(), "tags").map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        });

        let event_store = ctx.event_store.clone();
        ctx.run_blocking("memory.get_ledger", move || {
            MemoryQueryService::get_ledger(
                &event_store,
                working_dir.as_deref(),
                limit,
                offset,
                tags_filter.as_deref(),
            )
        })
        .await
    }
}

/// Trigger a memory ledger update for a session.
pub struct UpdateLedgerHandler;

#[async_trait]
impl MethodHandler for UpdateLedgerHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.updateLedger"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let target = if let Some(session_id) = opt_string(params.as_ref(), "sessionId") {
            LedgerUpdateTarget::SessionId(session_id)
        } else if let Some(wd) = opt_string(params.as_ref(), "workingDirectory") {
            LedgerUpdateTarget::WorkingDirectory(wd)
        } else {
            return Err(RpcError::InvalidParams {
                message: "Missing required parameter: sessionId or workingDirectory".into(),
            });
        };

        MemoryCommandService::update_ledger(ctx, target).await
    }
}

/// Search memory entries across sessions.
pub struct SearchMemoryHandler;

#[async_trait]
impl MethodHandler for SearchMemoryHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.search"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let search_text = opt_string(params.as_ref(), "searchText").unwrap_or_default();

        let type_filter = opt_string(params.as_ref(), "type");

        let limit = usize::try_from(opt_u64(params.as_ref(), "limit", 20)).unwrap_or(usize::MAX);

        let event_store = ctx.event_store.clone();
        let session_manager = ctx.session_manager.clone();
        ctx.run_blocking("memory.search", move || {
            MemoryQueryService::search(
                &event_store,
                &session_manager,
                &search_text,
                type_filter.as_deref(),
                limit,
            )
        })
        .await
    }
}

#[cfg(test)]
#[path = "memory/tests.rs"]
mod tests;
