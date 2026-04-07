//! Worktree handlers: getStatus, commit, merge, list, getDiff, acquire, release.
//!
//! All worktree operations require a `WorktreeCoordinator` on `RpcContext`.
//! `GetDiffHandler` is the one exception — it works on any session's working
//! directory (with or without a worktree) since "show me the diff" is useful
//! regardless of isolation mode.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;
use crate::worktree::{count_diff_stats, split_diff_by_file};

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;

// ── Helpers ─────────────────────────────────────────────────────────

fn require_coordinator(ctx: &RpcContext) -> Result<&crate::worktree::WorktreeCoordinator, RpcError> {
    ctx.worktree_coordinator
        .as_deref()
        .ok_or_else(|| RpcError::Internal {
            message: "Worktree isolation is not enabled".into(),
        })
}

fn require_session_working_dir(ctx: &RpcContext, session_id: &str) -> Result<String, RpcError> {
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

/// Resolve the directory to diff for a session.
///
/// Prefers the coordinator's worktree path (if active), otherwise uses the
/// session's original working directory. This is intentionally lenient — getDiff
/// should work for any session, not only those with worktrees.
fn resolve_diff_dir(ctx: &RpcContext, session_id: &str) -> Result<String, RpcError> {
    // Check coordinator for active worktree
    if let Some(ref coord) = ctx.worktree_coordinator
        && let Some(dir) = coord.effective_working_dir(session_id)
    {
        return Ok(dir);
    }

    require_session_working_dir(ctx, session_id)
}

// ── GetStatus ───────────────────────────────────────────────────────

/// Get worktree status for a session.
///
/// Returns enriched status including `isolated`, `hasUncommittedChanges`,
/// and `commitCount` fields that the iOS client expects.
pub struct GetStatusHandler;

#[async_trait]
impl MethodHandler for GetStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.getStatus"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        match coord.get_status(&session_id).await {
            Ok(Some(status)) => Ok(serde_json::json!({
                "hasWorktree": true,
                "worktree": {
                    "isolated": status.isolated,
                    "path": status.path,
                    "branch": status.branch,
                    "baseCommit": status.base_commit,
                    "baseBranch": status.base_branch,
                    "repoRoot": status.repo_root,
                    "hasUncommittedChanges": status.has_uncommitted_changes,
                    "commitCount": status.commit_count,
                    "isMerged": status.is_merged,
                },
            })),
            Ok(None) => Ok(serde_json::json!({
                "hasWorktree": false,
                "worktree": null,
            })),
            Err(e) => Err(RpcError::Internal {
                message: format!("Failed to get worktree status: {e}"),
            }),
        }
    }
}

// ── Commit ──────────────────────────────────────────────────────────

/// Commit worktree changes.
pub struct CommitHandler;

#[async_trait]
impl MethodHandler for CommitHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.commit"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let message = require_string_param(params.as_ref(), "message")?;
        let coord = require_coordinator(ctx)?;

        if coord.get_info(&session_id).is_none() {
            return Err(RpcError::NotFound {
                code: "WORKTREE_NOT_FOUND".into(),
                message: format!("No worktree found for session '{session_id}'"),
            });
        }

        match coord.commit(&session_id, &message).await {
            Ok(Some(result)) => Ok(serde_json::json!({
                "success": true,
                "commitHash": result.commit_hash,
                "message": message,
                "filesChanged": result.files_changed,
                "insertions": result.insertions,
                "deletions": result.deletions,
            })),
            Ok(None) => Ok(serde_json::json!({
                "success": true,
                "commitHash": null,
                "message": "nothing to commit",
            })),
            Err(e) => Err(RpcError::Internal {
                message: format!("Commit failed: {e}"),
            }),
        }
    }
}

// ── Merge ───────────────────────────────────────────────────────────

/// Merge worktree.
pub struct MergeHandler;

#[async_trait]
impl MethodHandler for MergeHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.merge"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let target_branch = opt_string(params.as_ref(), "targetBranch");
        let target_branch = target_branch.as_deref().unwrap_or("main");
        let strategy_str = opt_string(params.as_ref(), "strategy");
        let coord = require_coordinator(ctx)?;

        if coord.get_info(&session_id).is_none() {
            return Err(RpcError::NotFound {
                code: "WORKTREE_NOT_FOUND".into(),
                message: format!("No worktree found for session '{session_id}'"),
            });
        }

        let strategy = match strategy_str.as_deref() {
            Some("rebase") => crate::worktree::MergeStrategy::Rebase,
            Some("squash") => crate::worktree::MergeStrategy::Squash,
            _ => crate::worktree::MergeStrategy::Merge,
        };

        match coord.merge(&session_id, target_branch, strategy).await {
            Ok(result) => {
                let conflicts: Option<Vec<String>> = if result.conflicts.is_empty() {
                    None
                } else {
                    Some(result.conflicts)
                };
                Ok(serde_json::json!({
                    "success": result.success,
                    "mergeCommit": result.merge_commit,
                    "conflicts": conflicts,
                }))
            }
            Err(e) => Err(RpcError::Internal {
                message: format!("Merge failed: {e}"),
            }),
        }
    }
}

// ── List ────────────────────────────────────────────────────────────

/// List worktrees across all sessions.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let coord = require_coordinator(ctx)?;

        let active = coord.list_active();
        let worktrees: Vec<Value> = active
            .iter()
            .map(|info| {
                serde_json::json!({
                    "sessionId": info.session_id,
                    "path": info.worktree_path.to_string_lossy(),
                    "branch": info.branch,
                    "baseCommit": info.base_commit,
                    "baseBranch": info.base_branch,
                    "repoRoot": info.repo_root.to_string_lossy(),
                })
            })
            .collect();
        Ok(serde_json::json!({ "worktrees": worktrees }))
    }
}

// ── Acquire ─────────────────────────────────────────────────────────

/// Explicitly acquire a worktree for a session.
pub struct AcquireHandler;

#[async_trait]
impl MethodHandler for AcquireHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.acquire"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        let working_dir = require_session_working_dir(ctx, &session_id)?;
        let working_dir = std::path::Path::new(&working_dir);

        match coord.maybe_acquire(&session_id, working_dir).await {
            Ok(crate::worktree::AcquireResult::Acquired(info)) => Ok(serde_json::json!({
                "acquired": true,
                "path": info.worktree_path.to_string_lossy(),
                "branch": info.branch,
                "baseCommit": info.base_commit,
                "baseBranch": info.base_branch,
            })),
            Ok(crate::worktree::AcquireResult::Deferred(reason)) => Ok(serde_json::json!({
                "acquired": false,
                "deferred": true,
                "reason": format!("{reason:?}"),
            })),
            Ok(crate::worktree::AcquireResult::Passthrough) => Ok(serde_json::json!({
                "acquired": false,
                "reason": "not a git repo or isolation disabled",
            })),
            Err(e) => Err(RpcError::Internal {
                message: format!("Worktree acquisition failed: {e}"),
            }),
        }
    }
}

// ── Release ─────────────────────────────────────────────────────────

/// Explicitly release a session's worktree.
pub struct ReleaseHandler;

#[async_trait]
impl MethodHandler for ReleaseHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.release"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        coord
            .release(&session_id)
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Worktree release failed: {e}"),
            })?;

        Ok(serde_json::json!({
            "released": true,
            "sessionId": session_id,
        }))
    }
}

// ── ListSessionBranches ─────────────────────────────────────────────

/// List all session branches (active and preserved) for the repo.
pub struct ListSessionBranchesHandler;

#[async_trait]
impl MethodHandler for ListSessionBranchesHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.listSessionBranches"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        let dir = resolve_diff_dir(ctx, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let Ok(repo_root_str) = coord.resolve_repo_root(dir_path).await else {
            return Ok(serde_json::json!({ "branches": [] }));
        };

        let repo_root = std::path::Path::new(&repo_root_str);
        match coord.list_session_branches(repo_root).await {
            Ok(branches) => Ok(serde_json::json!({ "branches": branches })),
            Err(e) => Err(RpcError::Internal {
                message: format!("Failed to list session branches: {e}"),
            }),
        }
    }
}

// ── GetCommittedDiff ────────────────────────────────────────────────

/// Get committed diff for a session (base..HEAD).
pub struct GetCommittedDiffHandler;

#[async_trait]
impl MethodHandler for GetCommittedDiffHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.getCommittedDiff"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        match coord.get_committed_diff(&session_id).await {
            Ok(Some(result)) => serde_json::to_value(&result).map_err(|e| RpcError::Internal {
                message: format!("Serialization failed: {e}"),
            }),
            Ok(None) => Ok(serde_json::json!({
                "commits": [],
                "files": [],
                "summary": {
                    "totalFiles": 0,
                    "totalAdditions": 0,
                    "totalDeletions": 0,
                },
                "truncated": false,
            })),
            Err(e) => Err(RpcError::Internal {
                message: format!("Failed to get committed diff: {e}"),
            }),
        }
    }
}

// ── DeleteBranch ────────────────────────────────────────────────────

/// Delete a single session branch.
pub struct DeleteBranchHandler;

#[async_trait]
impl MethodHandler for DeleteBranchHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.deleteBranch"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let branch = require_string_param(params.as_ref(), "branch")?;
        let coord = require_coordinator(ctx)?;

        let dir = resolve_diff_dir(ctx, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let repo_root_str = coord.resolve_repo_root(dir_path).await.map_err(|e| {
            RpcError::Internal {
                message: format!("Failed to resolve repo root: {e}"),
            }
        })?;
        let repo_root = std::path::Path::new(&repo_root_str);

        match coord.delete_session_branch(repo_root, &branch).await {
            Ok(result) => serde_json::to_value(&result).map_err(|e| RpcError::Internal {
                message: format!("Serialization failed: {e}"),
            }),
            Err(crate::worktree::WorktreeError::BranchActive(_)) => Err(RpcError::InvalidParams {
                message: format!("Branch '{branch}' is active and cannot be deleted"),
            }),
            Err(e) => Err(RpcError::Internal {
                message: format!("Failed to delete branch: {e}"),
            }),
        }
    }
}

// ── PruneBranches ───────────────────────────────────────────────────

/// Prune all inactive session branches.
pub struct PruneBranchesHandler;

#[async_trait]
impl MethodHandler for PruneBranchesHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.pruneBranches"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        let dir = resolve_diff_dir(ctx, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let repo_root_str = coord.resolve_repo_root(dir_path).await.map_err(|e| {
            RpcError::Internal {
                message: format!("Failed to resolve repo root: {e}"),
            }
        })?;
        let repo_root = std::path::Path::new(&repo_root_str);

        match coord.prune_session_branches(repo_root).await {
            Ok(result) => serde_json::to_value(&result).map_err(|e| RpcError::Internal {
                message: format!("Serialization failed: {e}"),
            }),
            Err(e) => Err(RpcError::Internal {
                message: format!("Failed to prune branches: {e}"),
            }),
        }
    }
}

// ── GetDiff ─────────────────────────────────────────────────────────

const MAX_DIFF_BYTES: usize = 1_024 * 1_024; // 1 MB

/// Get unified diff of all uncommitted changes for a session's working directory.
///
/// Works for any session — uses the worktree path if one is active, otherwise
/// the session's original working directory. Does not require a coordinator.
pub struct GetDiffHandler;

#[async_trait]
impl MethodHandler for GetDiffHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.getDiff"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let dir = resolve_diff_dir(ctx, &session_id)?;

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

        let branch = branch_out.ok().and_then(|o| {
            let b = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if b.is_empty() { None } else { Some(b) }
        });

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
                if (x == b'U' || y == b'U') || (x == b'A' && y == b'A') || (x == b'D' && y == b'D')
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

/// Detect if diff shows a binary file.
fn is_binary_diff(chunk: &str) -> bool {
    chunk.contains("Binary files") && chunk.contains("differ")
}


#[cfg(test)]
#[path = "worktree_tests.rs"]
mod tests;
