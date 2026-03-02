//! Worktree handlers: getStatus, commit, merge, list, getDiff.

use std::collections::HashMap;

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::{opt_string, require_string_param};
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

/// Resolve the git directory for a session: prefer worktree, fall back to working_directory.
fn resolve_git_dir(ctx: &RpcContext, session_id: &str) -> Result<String, RpcError> {
    match get_worktree_dir(ctx, session_id) {
        Ok(dir) => Ok(dir),
        Err(RpcError::NotFound { .. }) => {
            let session = ctx
                .session_manager
                .get_session(session_id)
                .map_err(|e| RpcError::Internal {
                    message: format!("Session lookup failed: {e}"),
                })?
                .ok_or_else(|| RpcError::NotFound {
                    code: "SESSION_NOT_FOUND".into(),
                    message: format!("Session '{session_id}' not found"),
                })?;
            Ok(session.working_directory)
        }
        Err(other) => Err(other),
    }
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
        let target_branch = opt_string(params.as_ref(), "targetBranch");
        let target_branch = target_branch.as_deref().unwrap_or("main");

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

// ── GetDiff handler ─────────────────────────────────────────────────

const MAX_DIFF_BYTES: usize = 1_024 * 1_024; // 1 MB

/// Get unified diff of all uncommitted changes for a session's working directory.
pub struct GetDiffHandler;

#[async_trait]
impl MethodHandler for GetDiffHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.getDiff"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let dir = resolve_git_dir(ctx, &session_id)?;

        // Verify directory exists
        if !std::path::Path::new(&dir).is_dir() {
            return Err(RpcError::Internal {
                message: format!("Working directory does not exist: {dir}"),
            });
        }

        // Check if this is a git repo
        let check = tokio::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "--is-inside-work-tree"])
            .output()
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to run git: {e}"),
            })?;

        if !check.status.success() {
            return Ok(serde_json::json!({ "isGitRepo": false }));
        }

        // Check if repo has any commits
        let has_commits = tokio::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "HEAD"])
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false);

        // Run branch, status, and diff concurrently
        let (branch_out, status_out, diff_out) = tokio::join!(
            tokio::process::Command::new("git")
                .args(["-C", &dir, "branch", "--show-current"])
                .output(),
            tokio::process::Command::new("git")
                .args(["-C", &dir, "status", "--porcelain=v1"])
                .output(),
            async {
                if has_commits {
                    tokio::process::Command::new("git")
                        .args(["-C", &dir, "diff", "HEAD"])
                        .output()
                        .await
                } else {
                    // No commits yet: diff --cached for staged files
                    tokio::process::Command::new("git")
                        .args(["-C", &dir, "diff", "--cached"])
                        .output()
                        .await
                }
            }
        );

        let branch = branch_out
            .ok()
            .map(|o| {
                let b = String::from_utf8_lossy(&o.stdout).trim().to_string();
                if b.is_empty() { None } else { Some(b) }
            })
            .unwrap_or(None);

        let status_str = status_out
            .map_err(|e| RpcError::Internal {
                message: format!("git status failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;

        let diff_str = diff_out
            .map_err(|e| RpcError::Internal {
                message: format!("git diff failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;

        let truncated = diff_str.len() > MAX_DIFF_BYTES;
        let diff_str = if truncated {
            // floor_char_boundary avoids panicking on multi-byte UTF-8 boundaries
            let safe_end = diff_str.floor_char_boundary(MAX_DIFF_BYTES);
            diff_str[..safe_end].to_string()
        } else {
            diff_str
        };

        let file_entries = parse_porcelain(&status_str);
        let diff_map = split_diff_by_file(&diff_str);

        let mut files = Vec::new();
        let mut total_additions: usize = 0;
        let mut total_deletions: usize = 0;

        for entry in &file_entries {
            let (diff_text, additions, deletions) = if let Some(chunk) = diff_map.get(&entry.path) {
                if is_binary_diff(chunk) {
                    (None, 0, 0)
                } else {
                    let (a, d) = count_diff_stats(chunk);
                    (Some(chunk.as_str()), a, d)
                }
            } else {
                (None, 0, 0)
            };

            total_additions += additions;
            total_deletions += deletions;

            files.push(serde_json::json!({
                "path": entry.path,
                "status": entry.status,
                "diff": diff_text,
                "additions": additions,
                "deletions": deletions,
            }));
        }

        let mut response = serde_json::json!({
            "isGitRepo": true,
            "branch": branch,
            "files": files,
            "summary": {
                "totalFiles": files.len(),
                "totalAdditions": total_additions,
                "totalDeletions": total_deletions,
            },
        });
        if truncated {
            response["truncated"] = serde_json::json!(true);
        }
        Ok(response)
    }
}

// ── Parsing helpers ─────────────────────────────────────────────────

struct FileEntry {
    path: String,
    status: &'static str,
}

/// Parse `git status --porcelain=v1` output into file entries.
fn parse_porcelain(output: &str) -> Vec<FileEntry> {
    let mut entries = Vec::new();
    for line in output.lines() {
        if line.len() < 4 {
            continue;
        }
        let xy = &line[..2];
        let raw_path = &line[3..];

        // Handle quoted paths (git quotes paths with special characters)
        let path = unquote_path(raw_path);

        let status = match xy {
            "??" => "untracked",
            "!!" => continue, // ignored files
            _ => {
                let x = xy.as_bytes()[0];
                let y = xy.as_bytes()[1];
                // Check for unmerged states
                if (x == b'U' || y == b'U')
                    || (x == b'A' && y == b'A')
                    || (x == b'D' && y == b'D')
                {
                    "unmerged"
                } else if x == b'R' || y == b'R' {
                    "renamed"
                } else if x == b'C' || y == b'C' {
                    "copied"
                } else if x == b'A' || y == b'A' {
                    "added"
                } else if x == b'D' || y == b'D' {
                    "deleted"
                } else if x == b'M' || y == b'M' {
                    "modified"
                } else {
                    "modified"
                }
            }
        };

        // For renames/copies, the path format is "old -> new"
        let final_path = if status == "renamed" || status == "copied" {
            if let Some((_old, new)) = path.split_once(" -> ") {
                unquote_path(new)
            } else {
                path
            }
        } else {
            path
        };

        entries.push(FileEntry {
            path: final_path,
            status,
        });
    }
    entries
}

/// Remove surrounding quotes and unescape if git quoted the path.
fn unquote_path(raw: &str) -> String {
    if raw.starts_with('"') && raw.ends_with('"') && raw.len() >= 2 {
        let inner = &raw[1..raw.len() - 1];
        inner
            .replace("\\\\", "\x00")
            .replace("\\\"", "\"")
            .replace("\\n", "\n")
            .replace("\\t", "\t")
            .replace('\x00', "\\")
    } else {
        raw.to_string()
    }
}

/// Split combined diff output by file, returning (path, diff_chunk) pairs.
fn split_diff_by_file(diff: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let mut current_path: Option<String> = None;
    let mut current_chunk = String::new();

    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("diff --git a/") {
            // Flush previous chunk
            if let Some(path) = current_path.take() {
                let _ = map.insert(path, current_chunk.clone());
            }
            current_chunk.clear();

            // Parse path from "diff --git a/foo b/foo"
            // Find the " b/" separator — the path after "b/" is the actual file path
            if let Some(b_idx) = rest.rfind(" b/") {
                current_path = Some(rest[b_idx + 3..].to_string());
            }
        } else if current_path.is_some() {
            if !current_chunk.is_empty() {
                current_chunk.push('\n');
            }
            current_chunk.push_str(line);
        }
    }

    // Flush last chunk
    if let Some(path) = current_path {
        let _ = map.insert(path, current_chunk);
    }

    map
}

/// Count additions and deletions in a diff chunk.
fn count_diff_stats(chunk: &str) -> (usize, usize) {
    let mut additions = 0;
    let mut deletions = 0;
    for line in chunk.lines() {
        if line.starts_with('+') && !line.starts_with("+++") {
            additions += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            deletions += 1;
        }
    }
    (additions, deletions)
}

/// Detect if diff shows a binary file.
fn is_binary_diff(chunk: &str) -> bool {
    chunk.contains("Binary files") && chunk.contains("differ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    // ── Existing tests ──────────────────────────────────────────────

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

    // ── Parsing helper tests ────────────────────────────────────────

    #[test]
    fn parse_porcelain_modified() {
        let entries = parse_porcelain(" M src/main.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "src/main.rs");
        assert_eq!(entries[0].status, "modified");
    }

    #[test]
    fn parse_porcelain_index_modified() {
        let entries = parse_porcelain("M  src/main.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].status, "modified");
    }

    #[test]
    fn parse_porcelain_added() {
        let entries = parse_porcelain("A  new.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "new.rs");
        assert_eq!(entries[0].status, "added");
    }

    #[test]
    fn parse_porcelain_deleted() {
        let entries = parse_porcelain(" D old.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "old.rs");
        assert_eq!(entries[0].status, "deleted");
    }

    #[test]
    fn parse_porcelain_untracked() {
        let entries = parse_porcelain("?? file.txt\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "file.txt");
        assert_eq!(entries[0].status, "untracked");
    }

    #[test]
    fn parse_porcelain_renamed() {
        let entries = parse_porcelain("R  old.rs -> new.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "new.rs");
        assert_eq!(entries[0].status, "renamed");
    }

    #[test]
    fn parse_porcelain_mixed() {
        let input = " M src/main.rs\nA  new.rs\n D old.rs\n?? untracked.txt\n";
        let entries = parse_porcelain(input);
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[0].status, "modified");
        assert_eq!(entries[1].status, "added");
        assert_eq!(entries[2].status, "deleted");
        assert_eq!(entries[3].status, "untracked");
    }

    #[test]
    fn parse_porcelain_empty() {
        let entries = parse_porcelain("");
        assert!(entries.is_empty());
    }

    #[test]
    fn parse_porcelain_quoted_path() {
        let entries = parse_porcelain("?? \"path with spaces/file.txt\"\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "path with spaces/file.txt");
    }

    #[test]
    fn parse_porcelain_unmerged() {
        let entries = parse_porcelain("UU conflicted.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].status, "unmerged");
    }

    #[test]
    fn parse_porcelain_both_added() {
        let entries = parse_porcelain("AA both_added.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].status, "unmerged");
    }

    #[test]
    fn parse_porcelain_added_then_modified() {
        // AM = added in index, modified in worktree → should be "added"
        let entries = parse_porcelain("AM new_file.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].status, "added");
    }

    #[test]
    fn parse_porcelain_modified_both() {
        // MM = modified in index AND worktree → should be "modified"
        let entries = parse_porcelain("MM src/lib.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].status, "modified");
    }

    #[test]
    fn split_diff_single_file() {
        let diff = "diff --git a/src/main.rs b/src/main.rs\nindex abc..def 100644\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,3 +1,4 @@\n context\n-old\n+new\n+added";
        let map = split_diff_by_file(diff);
        assert_eq!(map.len(), 1);
        assert!(map.contains_key("src/main.rs"));
        assert!(map["src/main.rs"].contains("@@ -1,3 +1,4 @@"));
    }

    #[test]
    fn split_diff_multiple_files() {
        let diff = "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/b.rs b/b.rs\n--- a/b.rs\n+++ b/b.rs\n@@ -1 +1 @@\n-x\n+y";
        let map = split_diff_by_file(diff);
        assert_eq!(map.len(), 2);
        assert!(map.contains_key("a.rs"));
        assert!(map.contains_key("b.rs"));
    }

    #[test]
    fn split_diff_empty() {
        let map = split_diff_by_file("");
        assert!(map.is_empty());
    }

    #[test]
    fn count_diff_stats_basic() {
        let chunk = "@@ -1,3 +1,4 @@\n context\n-old\n+new\n+added";
        let (a, d) = count_diff_stats(chunk);
        assert_eq!(a, 2);
        assert_eq!(d, 1);
    }

    #[test]
    fn count_diff_stats_ignores_headers() {
        let chunk = "--- a/file.rs\n+++ b/file.rs\n@@ -1 +1 @@\n-old\n+new";
        let (a, d) = count_diff_stats(chunk);
        assert_eq!(a, 1);
        assert_eq!(d, 1);
    }

    #[test]
    fn is_binary_diff_true() {
        assert!(is_binary_diff(
            "Binary files a/image.png and b/image.png differ"
        ));
    }

    #[test]
    fn is_binary_diff_false() {
        assert!(!is_binary_diff("@@ -1 +1 @@\n-old\n+new"));
    }

    // ── GetDiff handler tests ───────────────────────────────────────

    /// Helper: create a temp git repo with initial commit, return (TempDir, dir_str).
    fn make_git_repo() -> (tempfile::TempDir, String) {
        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path().to_str().unwrap().to_string();
        for (args, _) in [
            (vec!["init", &dir], "init"),
            (vec!["-C", &dir, "config", "user.email", "t@t.com"], "email"),
            (vec!["-C", &dir, "config", "user.name", "T"], "name"),
        ] {
            std::process::Command::new("git")
                .args(&args)
                .output()
                .unwrap();
        }
        std::fs::write(tmp.path().join("init.txt"), "init").unwrap();
        std::process::Command::new("git")
            .args(["-C", &dir, "add", "-A"])
            .output()
            .unwrap();
        std::process::Command::new("git")
            .args(["-C", &dir, "commit", "-m", "init"])
            .output()
            .unwrap();
        (tmp, dir)
    }

    #[tokio::test]
    async fn get_diff_missing_session() {
        let ctx = make_test_context();
        let err = GetDiffHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_diff_not_git_repo() {
        let ctx = make_test_context();
        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path().to_str().unwrap();
        let sid = ctx
            .session_manager
            .create_session("m", dir, None)
            .unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isGitRepo"], false);
    }

    #[tokio::test]
    async fn get_diff_nonexistent_directory() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/nonexistent/path/xyz", None)
            .unwrap();

        let err = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("does not exist"));
    }

    #[tokio::test]
    async fn get_diff_clean_repo() {
        let ctx = make_test_context();
        let (_tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isGitRepo"], true);
        assert_eq!(result["files"].as_array().unwrap().len(), 0);
        assert_eq!(result["summary"]["totalFiles"], 0);
        // truncated should not be present for normal responses
        assert!(result.get("truncated").is_none());
    }

    #[tokio::test]
    async fn get_diff_with_modified_file() {
        let ctx = make_test_context();
        let (tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        // Modify the committed file
        std::fs::write(tmp.path().join("init.txt"), "modified content").unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let files = result["files"].as_array().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0]["status"], "modified");
        assert!(files[0]["diff"].is_string());
        assert!(files[0]["additions"].as_u64().unwrap() >= 1);
        assert!(files[0]["deletions"].as_u64().unwrap() >= 1);
    }

    #[tokio::test]
    async fn get_diff_with_new_file() {
        let ctx = make_test_context();
        let (tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        std::fs::write(tmp.path().join("new.txt"), "new content").unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let files = result["files"].as_array().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0]["status"], "untracked");
        // Untracked files have no diff from git diff HEAD
        assert!(files[0]["diff"].is_null());
    }

    #[tokio::test]
    async fn get_diff_with_deleted_file() {
        let ctx = make_test_context();
        let (tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        std::fs::remove_file(tmp.path().join("init.txt")).unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let files = result["files"].as_array().unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0]["status"], "deleted");
        assert!(files[0]["deletions"].as_u64().unwrap() >= 1);
    }

    #[tokio::test]
    async fn get_diff_with_staged_and_unstaged() {
        let ctx = make_test_context();
        let (tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        // Stage a change
        std::fs::write(tmp.path().join("init.txt"), "staged").unwrap();
        std::process::Command::new("git")
            .args(["-C", &dir, "add", "init.txt"])
            .output()
            .unwrap();

        // Make another unstaged change
        std::fs::write(tmp.path().join("init.txt"), "unstaged on top").unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let files = result["files"].as_array().unwrap();
        // init.txt should show as modified with both staged + unstaged changes in diff
        assert_eq!(files.len(), 1);
        assert_eq!(files[0]["status"], "modified");
        assert!(files[0]["diff"].is_string());
    }

    #[tokio::test]
    async fn get_diff_empty_repo_no_commits() {
        let ctx = make_test_context();
        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path().to_str().unwrap();
        std::process::Command::new("git")
            .args(["init", dir])
            .output()
            .unwrap();
        std::fs::write(tmp.path().join("new.txt"), "content").unwrap();

        let sid = ctx
            .session_manager
            .create_session("m", dir, None)
            .unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isGitRepo"], true);
        // Should report the untracked file without crashing
        let files = result["files"].as_array().unwrap();
        assert!(!files.is_empty());
    }

    #[tokio::test]
    async fn get_diff_branch_name() {
        let ctx = make_test_context();
        let (_tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        std::process::Command::new("git")
            .args(["-C", &dir, "checkout", "-b", "feature/test"])
            .output()
            .unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["branch"], "feature/test");
    }

    #[tokio::test]
    async fn get_diff_detached_head() {
        let ctx = make_test_context();
        let (_tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        // Get HEAD hash and checkout detached
        let hash = std::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "HEAD"])
            .output()
            .unwrap();
        let hash = String::from_utf8_lossy(&hash.stdout).trim().to_string();
        std::process::Command::new("git")
            .args(["-C", &dir, "checkout", &hash])
            .stderr(std::process::Stdio::null())
            .output()
            .unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["branch"].is_null());
    }

    #[tokio::test]
    async fn get_diff_worktree_preferred() {
        let ctx = make_test_context();
        let (tmp_wt, dir_wt) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Add worktree event pointing to a different dir
        ctx.event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::WorktreeAcquired,
                payload: json!({"workingDirectory": dir_wt}),
                parent_id: None,
            })
            .unwrap();

        // Modify a file in the worktree dir
        std::fs::write(tmp_wt.path().join("init.txt"), "changed").unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isGitRepo"], true);
        // Should see the modified file from worktree dir, not /tmp
        let files = result["files"].as_array().unwrap();
        assert!(!files.is_empty());
    }

    #[tokio::test]
    async fn get_diff_falls_back_to_working_directory() {
        let ctx = make_test_context();
        let (_tmp, dir) = make_git_repo();
        // No worktree event — should fall back to session working_directory
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isGitRepo"], true);
    }

    #[tokio::test]
    async fn get_diff_multiple_files() {
        let ctx = make_test_context();
        let (tmp, dir) = make_git_repo();

        // Create additional committed files
        std::fs::write(tmp.path().join("a.txt"), "a").unwrap();
        std::fs::write(tmp.path().join("b.txt"), "b").unwrap();
        std::fs::write(tmp.path().join("c.txt"), "c").unwrap();
        std::process::Command::new("git")
            .args(["-C", &dir, "add", "-A"])
            .output()
            .unwrap();
        std::process::Command::new("git")
            .args(["-C", &dir, "commit", "-m", "add files"])
            .output()
            .unwrap();

        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        // Modify 2 files, delete 1, add 1 new, leave 1 unchanged
        std::fs::write(tmp.path().join("a.txt"), "modified-a").unwrap();
        std::fs::write(tmp.path().join("b.txt"), "modified-b").unwrap();
        std::fs::remove_file(tmp.path().join("c.txt")).unwrap();
        std::fs::write(tmp.path().join("new.txt"), "new").unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let files = result["files"].as_array().unwrap();
        // 2 modified + 1 deleted + 1 untracked = 4
        assert_eq!(files.len(), 4);
        assert_eq!(result["summary"]["totalFiles"], 4);
    }

    #[tokio::test]
    async fn get_diff_binary_file() {
        let ctx = make_test_context();
        let (tmp, dir) = make_git_repo();
        let sid = ctx
            .session_manager
            .create_session("m", &dir, None)
            .unwrap();

        // Create a binary file with NUL bytes (git detects binary via NUL), commit it, then modify
        let bin_data: Vec<u8> = vec![0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x1A, 0x0A];
        std::fs::write(tmp.path().join("image.png"), &bin_data).unwrap();
        std::process::Command::new("git")
            .args(["-C", &dir, "add", "-A"])
            .output()
            .unwrap();
        std::process::Command::new("git")
            .args(["-C", &dir, "commit", "-m", "add binary"])
            .output()
            .unwrap();

        // Modify the binary
        let mut modified = bin_data.clone();
        modified.extend_from_slice(&[0xFF, 0x00]);
        std::fs::write(tmp.path().join("image.png"), &modified).unwrap();

        let result = GetDiffHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let files = result["files"].as_array().unwrap();
        let png_file = files.iter().find(|f| f["path"] == "image.png");
        assert!(png_file.is_some());
        let f = png_file.unwrap();
        // Binary files should have null diff and 0 stats
        assert!(f["diff"].is_null());
        assert_eq!(f["additions"], 0);
        assert_eq!(f["deletions"], 0);
    }
}
