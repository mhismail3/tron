//! Memory handlers: getLedger, updateLedger.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get ledger entries for a workspace.
pub struct GetLedgerHandler;

#[async_trait]
impl MethodHandler for GetLedgerHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = require_string_param(params.as_ref(), "workingDirectory")?;

        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(50);

        // Query ledger events from the event store for sessions matching this workspace
        let filter = tron_runtime::SessionFilter {
            workspace_path: Some(working_dir),
            ..Default::default()
        };

        let sessions = ctx
            .session_manager
            .list_sessions(&filter)
            .unwrap_or_default();

        let mut entries = Vec::new();
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);

        for session in sessions {
            let events = ctx
                .event_store
                .get_events_by_type(
                    &session.id,
                    &["memory.ledger"],
                    Some(i64::try_from(limit).unwrap_or(i64::MAX)),
                )
                .unwrap_or_default();

            for event in events {
                if let Ok(parsed) = serde_json::from_str::<Value>(&event.payload) {
                    entries.push(parsed);
                }
            }
            if entries.len() >= limit {
                break;
            }
        }

        entries.truncate(limit);

        Ok(serde_json::json!({
            "entries": entries,
        }))
    }
}

/// Trigger a memory ledger update.
pub struct UpdateLedgerHandler;

#[async_trait]
impl MethodHandler for UpdateLedgerHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _working_dir = require_string_param(params.as_ref(), "workingDirectory")?;

        // In the TypeScript server, this triggers a one-shot memory ledger update
        // via the memory manager. For now we acknowledge the request.
        // The actual ledger update will be implemented when the memory manager
        // is integrated into the agent run loop.
        Ok(serde_json::json!({
            "acknowledged": true,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_ledger_returns_entries() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp"})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["entries"].is_array());
    }

    #[tokio::test]
    async fn get_ledger_missing_working_dir() {
        let ctx = make_test_context();
        let err = GetLedgerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn update_ledger_returns_acknowledged() {
        let ctx = make_test_context();
        let result = UpdateLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn update_ledger_missing_working_dir() {
        let ctx = make_test_context();
        let err = UpdateLedgerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
