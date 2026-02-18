//! Worktree handlers: getStatus, commit, merge, list.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Get worktree status for a session.
pub struct GetStatusHandler;

#[async_trait]
impl MethodHandler for GetStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.getStatus"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Check if session has worktree.acquired events
        let events = ctx
            .event_store
            .get_events_by_type(&session_id, &["worktree.acquired"], Some(1))
            .unwrap_or_default();

        let has_worktree = !events.is_empty();
        let worktree = if has_worktree {
            events
                .first()
                .and_then(|e| serde_json::from_str::<Value>(&e.payload).ok())
        } else {
            None
        };

        Ok(serde_json::json!({
            "hasWorktree": has_worktree,
            "worktree": worktree,
        }))
    }
}

/// Look up the worktree working directory from session events.
fn get_worktree_dir(ctx: &RpcContext, session_id: &str) -> Result<String, RpcError> {
    let events = ctx
        .event_store
        .get_events_by_type(session_id, &["worktree.acquired"], Some(1))
        .unwrap_or_default();

    let event = events.first().ok_or_else(|| RpcError::NotFound {
        code: "WORKTREE_NOT_FOUND".into(),
        message: format!("No worktree found for session '{session_id}'"),
    })?;

    let payload: Value = serde_json::from_str(&event.payload).map_err(|e| RpcError::Internal {
        message: format!("Failed to parse worktree event: {e}"),
    })?;

    payload
        .get("workingDirectory")
        .or_else(|| payload.get("path"))
        .and_then(Value::as_str)
        .map(String::from)
        .ok_or_else(|| RpcError::Internal {
            message: "Worktree event missing working directory".into(),
        })
}

/// Commit worktree changes.
pub struct CommitHandler;

#[async_trait]
impl MethodHandler for CommitHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.commit"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let message = require_string_param(params.as_ref(), "message")?;

        let dir = get_worktree_dir(ctx, &session_id)?;

        // Stage all changes
        let add_output = tokio::process::Command::new("git")
            .args(["-C", &dir, "add", "-A"])
            .output()
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to run git add: {e}"),
            })?;

        if !add_output.status.success() {
            let stderr = String::from_utf8_lossy(&add_output.stderr);
            return Err(RpcError::Internal {
                message: format!("git add failed: {stderr}"),
            });
        }

        // Commit
        let commit_output = tokio::process::Command::new("git")
            .args(["-C", &dir, "commit", "-m", &message])
            .output()
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to run git commit: {e}"),
            })?;

        if !commit_output.status.success() {
            let stderr = String::from_utf8_lossy(&commit_output.stderr);
            let stdout = String::from_utf8_lossy(&commit_output.stdout);
            // "nothing to commit" is not a real error
            if stdout.contains("nothing to commit") || stderr.contains("nothing to commit") {
                return Ok(serde_json::json!({
                    "success": true,
                    "commitHash": null,
                    "message": "nothing to commit",
                }));
            }
            return Err(RpcError::Internal {
                message: format!("git commit failed: {stderr}"),
            });
        }

        // Get the commit hash
        let rev_output = tokio::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "HEAD"])
            .output()
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to get commit hash: {e}"),
            })?;

        let commit_hash = String::from_utf8_lossy(&rev_output.stdout)
            .trim()
            .to_string();

        Ok(serde_json::json!({
            "success": true,
            "commitHash": commit_hash,
            "message": message,
        }))
    }
}

/// Merge worktree.
pub struct MergeHandler;

#[async_trait]
impl MethodHandler for MergeHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.merge"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let target_branch = params
            .as_ref()
            .and_then(|p| p.get("targetBranch"))
            .and_then(Value::as_str)
            .unwrap_or("main");

        let dir = get_worktree_dir(ctx, &session_id)?;

        let merge_output = tokio::process::Command::new("git")
            .args(["-C", &dir, "merge", target_branch, "--no-edit"])
            .output()
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to run git merge: {e}"),
            })?;

        if !merge_output.status.success() {
            let stderr = String::from_utf8_lossy(&merge_output.stderr);
            let stdout = String::from_utf8_lossy(&merge_output.stdout);

            // Check for merge conflicts
            if stdout.contains("CONFLICT") || stderr.contains("CONFLICT") {
                return Ok(serde_json::json!({
                    "success": false,
                    "merged": false,
                    "conflicts": true,
                    "message": stdout.trim(),
                }));
            }

            return Err(RpcError::Internal {
                message: format!("git merge failed: {stderr}"),
            });
        }

        Ok(serde_json::json!({
            "success": true,
            "merged": true,
            "conflicts": false,
            "message": String::from_utf8_lossy(&merge_output.stdout).trim(),
        }))
    }
}

/// List worktrees across all sessions.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        // Query all sessions for worktree.acquired events
        let sessions = ctx
            .session_manager
            .list_sessions(&tron_runtime::SessionFilter {
                include_archived: false,
                ..Default::default()
            })
            .unwrap_or_default();

        let mut worktrees = Vec::new();

        for session in sessions {
            let events = ctx
                .event_store
                .get_events_by_type(&session.id, &["worktree.acquired"], Some(1))
                .unwrap_or_default();

            for event in events {
                if let Ok(mut parsed) = serde_json::from_str::<Value>(&event.payload) {
                    if let Some(obj) = parsed.as_object_mut() {
                        let _ = obj.insert("sessionId".into(), serde_json::json!(session.id));
                    }
                    worktrees.push(parsed);
                }
            }
        }

        Ok(serde_json::json!({ "worktrees": worktrees }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_status_no_worktree() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();

        let result = GetStatusHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["hasWorktree"], false);
        assert!(result["worktree"].is_null());
    }

    #[tokio::test]
    async fn commit_no_worktree_returns_not_found() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let err = CommitHandler
            .handle(
                Some(json!({"sessionId": sid, "message": "test commit"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "WORKTREE_NOT_FOUND");
    }

    #[tokio::test]
    async fn commit_missing_message() {
        let ctx = make_test_context();
        let err = CommitHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn merge_no_worktree_returns_not_found() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let err = MergeHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "WORKTREE_NOT_FOUND");
    }

    #[tokio::test]
    async fn commit_with_worktree_nothing_to_commit() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Create a temp git repo
        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path().to_str().unwrap();
        let _ = std::process::Command::new("git")
            .args(["init", dir])
            .output()
            .unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "config", "user.email", "test@test.com"])
            .output()
            .unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "config", "user.name", "Test"])
            .output()
            .unwrap();
        // Create initial commit
        std::fs::write(tmp.path().join("init.txt"), "init").unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "add", "-A"])
            .output()
            .unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "commit", "-m", "init"])
            .output()
            .unwrap();

        // Persist worktree.acquired event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::WorktreeAcquired,
            payload: json!({"workingDirectory": dir}),
            parent_id: None,
        });

        let result = CommitHandler
            .handle(
                Some(json!({"sessionId": sid, "message": "test commit"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["message"], "nothing to commit");
    }

    #[tokio::test]
    async fn commit_with_changes_returns_hash() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Create a temp git repo
        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path().to_str().unwrap();
        let _ = std::process::Command::new("git")
            .args(["init", dir])
            .output()
            .unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "config", "user.email", "test@test.com"])
            .output()
            .unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "config", "user.name", "Test"])
            .output()
            .unwrap();
        // Initial commit
        std::fs::write(tmp.path().join("init.txt"), "init").unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "add", "-A"])
            .output()
            .unwrap();
        let _ = std::process::Command::new("git")
            .args(["-C", dir, "commit", "-m", "init"])
            .output()
            .unwrap();

        // Create a new file to commit
        std::fs::write(tmp.path().join("new.txt"), "new content").unwrap();

        // Persist worktree.acquired event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::WorktreeAcquired,
            payload: json!({"workingDirectory": dir}),
            parent_id: None,
        });

        let result = CommitHandler
            .handle(
                Some(json!({"sessionId": sid, "message": "add new file"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert!(result["commitHash"].is_string());
        assert!(!result["commitHash"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_worktrees_empty() {
        let ctx = make_test_context();
        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert!(result["worktrees"].is_array());
        assert!(result["worktrees"].as_array().unwrap().is_empty());
    }
}
