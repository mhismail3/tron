//! Shared command-side memory services used by RPC handlers.

use serde_json::{Value, json};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::memory_ledger::{LedgerWriteDeps, execute_ledger_write};

/// Manual target selection for `memory.updateLedger`.
pub(crate) enum LedgerUpdateTarget {
    SessionId(String),
    WorkingDirectory(String),
}

/// Shared command logic for manual memory RPCs.
pub(crate) struct MemoryCommandService;

impl MemoryCommandService {
    pub(crate) async fn update_ledger(
        ctx: &RpcContext,
        target: LedgerUpdateTarget,
    ) -> Result<Value, RpcError> {
        let Some(session_id) = Self::resolve_target_session_id(ctx, target).await? else {
            return Ok(json!({
                "written": false,
                "title": null,
                "entryType": null,
                "reason": "no sessions found for workspace",
            }));
        };

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(tron_core::events::TronEvent::MemoryUpdating {
                base: tron_core::events::BaseEvent::now(&session_id),
            });

        let deps = LedgerWriteDeps {
            event_store: ctx.event_store.clone(),
            subagent_manager: ctx.subagent_manager.clone(),
            embedding_controller: ctx.embedding_controller.clone(),
            shutdown_coordinator: ctx.shutdown_coordinator.clone(),
        };
        let result = execute_ledger_write(&session_id, &deps, "manual").await;

        Self::emit_memory_updated(ctx, &session_id, &result);
        Ok(Self::rpc_response(&result))
    }

    async fn resolve_target_session_id(
        ctx: &RpcContext,
        target: LedgerUpdateTarget,
    ) -> Result<Option<String>, RpcError> {
        match target {
            LedgerUpdateTarget::SessionId(session_id) => Ok(Some(session_id)),
            LedgerUpdateTarget::WorkingDirectory(working_directory) => {
                let working_directory_for_filter = working_directory.clone();
                let session_manager = ctx.session_manager.clone();
                ctx.run_blocking("memory.resolve_latest_session", move || {
                    let filter = tron_runtime::SessionFilter {
                        workspace_path: Some(working_directory_for_filter),
                        limit: Some(1),
                        ..Default::default()
                    };
                    let sessions =
                        session_manager
                            .list_sessions(&filter)
                            .map_err(|error| RpcError::Internal {
                                message: format!(
                                    "Failed to list sessions for workspace '{working_directory}': {error}"
                                ),
                            })?;
                    Ok(sessions.first().map(|session| session.id.clone()))
                })
                .await
            }
        }
    }

    fn emit_memory_updated(
        ctx: &RpcContext,
        session_id: &str,
        result: &tron_events::memory::types::LedgerWriteResult,
    ) {
        let (title, entry_type, event_id) = if result.written {
            (
                result.title.clone(),
                result.entry_type.clone(),
                result.event_id.clone(),
            )
        } else {
            let entry_type = result
                .entry_type
                .clone()
                .unwrap_or_else(|| "skipped".to_string());
            let title = (entry_type == "error")
                .then(|| result.reason.clone())
                .flatten();
            (title, Some(entry_type), None)
        };

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(tron_core::events::TronEvent::MemoryUpdated {
                base: tron_core::events::BaseEvent::now(session_id),
                title,
                entry_type,
                event_id,
            });
    }

    fn rpc_response(result: &tron_events::memory::types::LedgerWriteResult) -> Value {
        json!({
            "written": result.written,
            "title": result.title,
            "entryType": result.entry_type,
            "reason": result.reason.as_deref().unwrap_or(if result.written { "written" } else { "unknown" }),
        })
    }
}
