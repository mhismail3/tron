//! Tree handlers: getVisualization, getBranches, getSubtree, getAncestors, compareBranches.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get tree visualization for a session.
pub struct GetVisualizationHandler;

#[async_trait]
impl MethodHandler for GetVisualizationHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let session = ctx
            .event_store
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let opts = tron_events::sqlite::repositories::event::ListEventsOptions {
            limit: None,
            offset: None,
        };
        let events = ctx
            .event_store
            .get_events_by_session(&session_id, &opts)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let nodes: Vec<Value> = events
            .iter()
            .map(|e| {
                serde_json::json!({
                    "id": e.id,
                    "parentId": e.parent_id,
                    "type": e.event_type,
                    "sequence": e.sequence,
                    "depth": e.depth,
                })
            })
            .collect();

        Ok(serde_json::json!({
            "sessionId": session_id,
            "rootEventId": session.root_event_id,
            "headEventId": session.head_event_id,
            "nodes": nodes,
            "totalEvents": events.len(),
        }))
    }
}

/// Get branches for a session.
pub struct GetBranchesHandler;

#[async_trait]
impl MethodHandler for GetBranchesHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let branches = ctx
            .event_store
            .get_branches(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let wire: Vec<Value> = branches
            .iter()
            .map(|b| {
                serde_json::json!({
                    "id": b.id,
                    "name": b.name,
                    "rootEventId": b.root_event_id,
                    "headEventId": b.head_event_id,
                    "isDefault": b.is_default,
                })
            })
            .collect();

        let main_branch = branches.iter().find(|b| b.is_default).map(|b| &b.id);

        Ok(serde_json::json!({
            "branches": wire,
            "mainBranch": main_branch,
        }))
    }
}

/// Get a subtree rooted at a specific event.
pub struct GetSubtreeHandler;

#[async_trait]
impl MethodHandler for GetSubtreeHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let event_id = require_string_param(params.as_ref(), "eventId")?;

        let descendants = ctx
            .event_store
            .get_descendants(&event_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let nodes: Vec<Value> = descendants
            .iter()
            .map(|e| {
                serde_json::json!({
                    "id": e.id,
                    "parentId": e.parent_id,
                    "type": e.event_type,
                    "sequence": e.sequence,
                })
            })
            .collect();

        Ok(serde_json::json!({
            "rootEventId": event_id,
            "nodes": nodes,
        }))
    }
}

/// Get ancestor chain for an event.
pub struct GetAncestorsHandler;

#[async_trait]
impl MethodHandler for GetAncestorsHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let event_id = require_string_param(params.as_ref(), "eventId")?;

        let ancestors = ctx
            .event_store
            .get_ancestors(&event_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let nodes: Vec<Value> = ancestors
            .iter()
            .map(|e| {
                serde_json::json!({
                    "id": e.id,
                    "parentId": e.parent_id,
                    "type": e.event_type,
                    "sequence": e.sequence,
                })
            })
            .collect();

        Ok(serde_json::json!({ "ancestors": nodes }))
    }
}

/// Compare two branches.
pub struct CompareBranchesHandler;

#[async_trait]
impl MethodHandler for CompareBranchesHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _branch_a = require_string_param(params.as_ref(), "branchA")?;
        let _branch_b = require_string_param(params.as_ref(), "branchB")?;
        // Branch comparison requires walking both ancestor chains to find divergence
        Ok(serde_json::json!({
            "divergencePoint": null,
            "branchAOnly": [],
            "branchBOnly": [],
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_visualization_with_events() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetVisualizationHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["sessionId"].as_str().unwrap(), sid);
        assert!(result["rootEventId"].is_string());
        assert!(result["headEventId"].is_string());
        assert!(result["nodes"].is_array());
        assert_eq!(result["totalEvents"], 1); // session.start
    }

    #[tokio::test]
    async fn get_visualization_has_required_fields() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetVisualizationHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        assert!(result.get("sessionId").is_some());
        assert!(result.get("rootEventId").is_some());
        assert!(result.get("headEventId").is_some());
        assert!(result.get("nodes").is_some());
        assert!(result.get("totalEvents").is_some());
    }

    #[tokio::test]
    async fn get_visualization_missing_session() {
        let ctx = make_test_context();
        let err = GetVisualizationHandler
            .handle(Some(json!({"sessionId": "nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_branches_empty() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetBranchesHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["branches"].is_array());
    }

    #[tokio::test]
    async fn get_subtree_empty() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();
        let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
        let root_id = session.root_event_id.unwrap();

        let result = GetSubtreeHandler
            .handle(Some(json!({"eventId": root_id})), &ctx)
            .await
            .unwrap();
        // Root with no children = empty nodes
        assert!(result["nodes"].is_array());
    }

    #[tokio::test]
    async fn get_ancestors_from_root() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();
        let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
        let root_id = session.root_event_id.unwrap();

        let result = GetAncestorsHandler
            .handle(Some(json!({"eventId": root_id})), &ctx)
            .await
            .unwrap();
        // Root's ancestor chain is just itself
        assert_eq!(result["ancestors"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn compare_branches_missing_param() {
        let ctx = make_test_context();
        let err = CompareBranchesHandler
            .handle(Some(json!({"branchA": "a"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn get_visualization_missing_param() {
        let ctx = make_test_context();
        let err = GetVisualizationHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
