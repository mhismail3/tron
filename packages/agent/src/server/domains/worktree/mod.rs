//! Canonical worktree engine functions.
//!
//! Client protocols reach these operations through engine triggers targeting
//! canonical `worktree::*` function ids. The operation helpers below are private
//! domain services for the engine-owned function module, not transport-owned
//! dispatch branches.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

pub(crate) mod git_workflow;

use crate::worktree::{count_diff_stats, split_diff_by_file};
use serde_json::Value;
use tracing::instrument;

use crate::server::shared::context::ServerCapabilityContext;
use crate::server::shared::error_mapping::map_worktree_error;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::{opt_bool, opt_string, require_bool, require_string_param};
use crate::worktree::types::CommitOptions;

use super::*;
use crate::engine::Invocation;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let worktree_deps = Deps::from_engine(deps);
    let mut module = super::domain_worker_module(
        "worktree",
        contract::STREAM_TOPICS,
        Vec::new(),
        worktree_deps.clone(),
        super::worktree_handler,
    )?;
    module.functions.extend(
        contract::capabilities()?
            .into_iter()
            .map(|spec| {
                let handler = if matches!(
                    spec.method,
                    "worktree::finalize_session"
                        | "worktree::rebase_on_main"
                        | "worktree::start_merge"
                        | "worktree::list_conflicts"
                        | "worktree::resolve_conflict"
                        | "worktree::continue_merge"
                        | "worktree::abort_merge"
                        | "worktree::resolve_conflicts_with_subagent"
                ) {
                    super::git_workflow_handler
                } else {
                    super::worktree_handler
                };
                super::domain_function_registration(spec, worktree_deps.clone(), handler)
            })
            .collect::<crate::engine::Result<Vec<_>>>()?,
    );
    Ok(module)
}

// ── Helpers ─────────────────────────────────────────────────────────

fn require_coordinator(
    ctx: &ServerCapabilityContext,
) -> Result<&crate::worktree::WorktreeCoordinator, CapabilityError> {
    ctx.worktree_coordinator
        .as_deref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Worktree isolation is not enabled".into(),
        })
}

fn require_session_working_dir(
    ctx: &ServerCapabilityContext,
    session_id: &str,
) -> Result<String, CapabilityError> {
    let session = ctx
        .session_manager
        .get_session(session_id)
        .map_err(|e| CapabilityError::Internal {
            message: format!("Session lookup failed: {e}"),
        })?
        .ok_or_else(|| CapabilityError::NotFound {
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
fn resolve_diff_dir(
    ctx: &ServerCapabilityContext,
    session_id: &str,
) -> Result<String, CapabilityError> {
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
pub struct GetStatusOperation;

impl GetStatusOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::get_status"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        // Try the coordinator's tracked worktree first (isolated mode).
        let status = match coord.get_status(&session_id).await {
            Ok(Some(s)) => Some(s),
            Ok(None) => {
                // Passthrough: the session never acquired an isolated
                // worktree (fresh session on `main`, or post-finalize
                // without rebranch). Probe the session's own working
                // directory so the UI still gets a status header.
                let Ok(working_dir) = require_session_working_dir(ctx, &session_id) else {
                    return Ok(serde_json::json!({
                        "hasWorktree": false,
                        "worktree": null,
                    }));
                };
                let path = std::path::Path::new(&working_dir);
                coord
                    .passthrough_status(path)
                    .await
                    .map_err(|e| map_worktree_error(e))?
            }
            Err(e) => {
                return Err(map_worktree_error(e));
            }
        };

        match status {
            Some(status) => Ok(serde_json::json!({
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
            None => Ok(serde_json::json!({
                "hasWorktree": false,
                "worktree": null,
            })),
        }
    }
}

// ── IsGitRepo ───────────────────────────────────────────────────────

/// Quick check: is the given absolute path a git repository?
/// Used by the iOS new-session sheet to decide whether to surface the
/// per-session worktree-isolation toggle.
pub struct IsGitRepoOperation;

impl IsGitRepoOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::is_git_repo"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let path = require_string_param(params.as_ref(), "path")?;
        let coord = require_coordinator(ctx)?;
        let is_git = coord.is_git_repo(std::path::Path::new(&path)).await;
        Ok(serde_json::json!({ "isGitRepo": is_git }))
    }
}

// ── Commit ──────────────────────────────────────────────────────────

/// Commit worktree changes.
pub struct CommitOperation;

impl CommitOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::commit"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let message = require_string_param(params.as_ref(), "message")?;
        let coord = require_coordinator(ctx)?;

        if coord.get_info(&session_id).is_none() {
            return Err(CapabilityError::NotFound {
                code: crate::server::shared::errors::WORKTREE_NOT_FOUND.into(),
                message: format!("No worktree found for session '{session_id}'"),
            });
        }

        // `stageAll` is contractually required — there is no sane server-side
        // default now that iOS ships with an explicit toggle (I7). A client
        // that omits it is bugged and must be fixed, not silently coerced.
        // `amend` and `signoff` remain opt-in feature flags; the vast
        // majority of callers want them off and sending `false` on every
        // wire would be pure overhead.
        let opts = CommitOptions {
            amend: opt_bool(params.as_ref(), "amend").unwrap_or(false),
            signoff: opt_bool(params.as_ref(), "signoff").unwrap_or(false),
            stage_all: require_bool(params.as_ref(), "stageAll")?,
        };

        match coord.commit(&session_id, &message, opts).await {
            Ok(Some(result)) => {
                // Record worktree.commit event for compaction progress signal detection.
                if let Some(handler) = ctx.orchestrator.get_compaction_handler(&session_id) {
                    handler.record_event_type("worktree::commit");
                }
                Ok(serde_json::json!({
                    "commitHash": result.commit_hash,
                    "message": message,
                    "filesChanged": result.files_changed,
                    "insertions": result.insertions,
                    "deletions": result.deletions,
                }))
            }
            Ok(None) => Ok(serde_json::json!({
                "commitHash": null,
                "message": "nothing to commit",
            })),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── Merge ───────────────────────────────────────────────────────────

/// Merge worktree.
pub struct MergeOperation;

impl MergeOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::merge"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let target_branch = opt_string(params.as_ref(), "targetBranch");
        let target_branch = target_branch.as_deref().unwrap_or("main");
        let strategy_str = opt_string(params.as_ref(), "strategy");
        let coord = require_coordinator(ctx)?;

        if coord.get_info(&session_id).is_none() {
            return Err(CapabilityError::NotFound {
                code: crate::server::shared::errors::WORKTREE_NOT_FOUND.into(),
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
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── List ────────────────────────────────────────────────────────────

/// List worktrees across all sessions.
pub struct ListOperation;

impl ListOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::list"))]
    async fn run(
        &self,
        _params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
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
pub struct AcquireOperation;

impl AcquireOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::acquire"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
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
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── Release ─────────────────────────────────────────────────────────

/// Explicitly release a session's worktree.
pub struct ReleaseOperation;

impl ReleaseOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::release"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        coord
            .release(&session_id)
            .await
            .map_err(|e| map_worktree_error(e))?;

        Ok(serde_json::json!({
            "released": true,
            "sessionId": session_id,
        }))
    }
}

// ── ListSessionBranches ─────────────────────────────────────────────

/// List all session branches (active and preserved) for the repo.
pub struct ListSessionBranchesOperation;

impl ListSessionBranchesOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::list_session_branches"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
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
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── GetCommittedDiff ────────────────────────────────────────────────

/// Get committed diff for a session (base..HEAD).
pub struct GetCommittedDiffOperation;

impl GetCommittedDiffOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::get_committed_diff"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        match coord.get_committed_diff(&session_id).await {
            Ok(Some(result)) => {
                serde_json::to_value(&result).map_err(|e| CapabilityError::Internal {
                    message: format!("Serialization failed: {e}"),
                })
            }
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
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── DeleteBranch ────────────────────────────────────────────────────

/// Delete a single session branch.
pub struct DeleteBranchOperation;

impl DeleteBranchOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::delete_branch"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let branch = require_string_param(params.as_ref(), "branch")?;
        let coord = require_coordinator(ctx)?;

        let dir = resolve_diff_dir(ctx, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let repo_root_str = coord
            .resolve_repo_root(dir_path)
            .await
            .map_err(|e| map_worktree_error(e))?;
        let repo_root = std::path::Path::new(&repo_root_str);

        match coord.delete_session_branch(repo_root, &branch).await {
            Ok(result) => serde_json::to_value(&result).map_err(|e| CapabilityError::Internal {
                message: format!("Serialization failed: {e}"),
            }),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── PruneBranches ───────────────────────────────────────────────────

/// Prune all inactive session branches.
pub struct PruneBranchesOperation;

impl PruneBranchesOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::prune_branches"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        let dir = resolve_diff_dir(ctx, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let repo_root_str = coord
            .resolve_repo_root(dir_path)
            .await
            .map_err(|e| map_worktree_error(e))?;
        let repo_root = std::path::Path::new(&repo_root_str);

        match coord.prune_session_branches(repo_root).await {
            Ok(result) => serde_json::to_value(&result).map_err(|e| CapabilityError::Internal {
                message: format!("Serialization failed: {e}"),
            }),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── GetDiff ─────────────────────────────────────────────────────────

const MAX_DIFF_BYTES: usize = 1_024 * 1_024; // 1 MB

/// Get unified diff of all uncommitted changes for a session's working directory.
///
/// Works for any session — uses the worktree path if one is active, otherwise
/// the session's original working directory. Does not require a coordinator.
pub struct GetDiffOperation;

impl GetDiffOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::get_diff"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let dir = resolve_diff_dir(ctx, &session_id)?;

        // A session whose working directory is missing (never existed, or
        // deleted between creation and this call) has no diff to show. Return
        // the same lenient shape as "not a git repo" so the iOS agent-control
        // sheet renders an empty state instead of propagating INTERNAL_ERROR.
        if !std::path::Path::new(&dir).is_dir() {
            return Ok(serde_json::json!({ "isGitRepo": false }));
        }

        // Check if this is a git repo
        let check = tokio::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "--is-inside-work-tree"])
            .output()
            .await
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to run git: {e}"),
            })?;

        if !check.status.success() {
            return Ok(serde_json::json!({ "isGitRepo": false }));
        }

        // Run branch, status, and both diffs concurrently.
        // We split into staged (--cached) and unstaged (worktree vs index) diffs
        // so the iOS client can show them in separate containers.
        let (branch_out, status_out, staged_diff_out, unstaged_diff_out) = tokio::join!(
            tokio::process::Command::new("git")
                .args(["-C", &dir, "branch", "--show-current"])
                .output(),
            tokio::process::Command::new("git")
                .args(["-C", &dir, "status", "--porcelain=v1"])
                .output(),
            // Staged diff: index vs HEAD (or all staged if no commits)
            tokio::process::Command::new("git")
                .args(["-C", &dir, "diff", "--cached"])
                .output(),
            // Unstaged diff: worktree vs index
            tokio::process::Command::new("git")
                .args(["-C", &dir, "diff"])
                .output()
        );

        let branch = branch_out.ok().and_then(|o| {
            let b = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if b.is_empty() { None } else { Some(b) }
        });

        let status_str = status_out
            .map_err(|e| CapabilityError::Internal {
                message: format!("git status failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;

        let staged_diff_str = staged_diff_out
            .map_err(|e| CapabilityError::Internal {
                message: format!("git diff --cached failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;

        let unstaged_diff_str = unstaged_diff_out
            .map_err(|e| CapabilityError::Internal {
                message: format!("git diff failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;

        // Truncation check on combined diff size
        let combined_len = staged_diff_str.len() + unstaged_diff_str.len();
        let truncated = combined_len > MAX_DIFF_BYTES;

        let truncate_str = |s: String, max: usize| -> String {
            if s.len() > max {
                let safe_end = s.floor_char_boundary(max);
                s[..safe_end].to_string()
            } else {
                s
            }
        };

        // Give each diff half the budget if both are large
        let half_budget = MAX_DIFF_BYTES / 2;
        let staged_diff_str = if truncated {
            truncate_str(staged_diff_str, half_budget)
        } else {
            staged_diff_str
        };
        let unstaged_diff_str = if truncated {
            truncate_str(unstaged_diff_str, half_budget)
        } else {
            unstaged_diff_str
        };

        let file_entries = parse_porcelain(&status_str);
        let staged_diff_map = split_diff_by_file(&staged_diff_str);
        let unstaged_diff_map = split_diff_by_file(&unstaged_diff_str);

        let mut files = Vec::new();
        let mut total_additions: usize = 0;
        let mut total_deletions: usize = 0;

        for entry in &file_entries {
            match entry.staging_area {
                "both" => {
                    // Partially staged: emit two entries with separate diffs
                    let (staged_diff, s_add, s_del) = diff_for_file(&entry.path, &staged_diff_map);
                    let (unstaged_diff, u_add, u_del) =
                        diff_for_file(&entry.path, &unstaged_diff_map);

                    total_additions += s_add + u_add;
                    total_deletions += s_del + u_del;

                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "staged",
                        "diff": staged_diff,
                        "additions": s_add,
                        "deletions": s_del,
                    }));
                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "unstaged",
                        "diff": unstaged_diff,
                        "additions": u_add,
                        "deletions": u_del,
                    }));
                }
                "staged" => {
                    let (diff_text, additions, deletions) =
                        diff_for_file(&entry.path, &staged_diff_map);
                    total_additions += additions;
                    total_deletions += deletions;

                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "staged",
                        "diff": diff_text,
                        "additions": additions,
                        "deletions": deletions,
                    }));
                }
                _ => {
                    // "unstaged" (including untracked)
                    let (diff_text, additions, deletions) = if entry.status == "untracked" {
                        // git diff doesn't include untracked files, so read the file
                        // content and synthesize an additions-only diff
                        synthesize_untracked_diff(&dir, &entry.path)
                    } else {
                        diff_for_file(&entry.path, &unstaged_diff_map)
                    };
                    total_additions += additions;
                    total_deletions += deletions;

                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "unstaged",
                        "diff": diff_text,
                        "additions": additions,
                        "deletions": deletions,
                    }));
                }
            }
        }

        // Summary counts unique file paths (a "both" file counts once)
        let unique_paths: std::collections::HashSet<&str> =
            file_entries.iter().map(|e| e.path.as_str()).collect();

        let mut response = serde_json::json!({
            "isGitRepo": true,
            "branch": branch,
            "files": files,
            "summary": {
                "totalFiles": unique_paths.len(),
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

/// Look up a file's diff text and stats from a diff map, handling binary detection.
fn diff_for_file(
    path: &str,
    diff_map: &std::collections::HashMap<String, String>,
) -> (Option<String>, usize, usize) {
    if let Some(chunk) = diff_map.get(path) {
        if is_binary_diff(chunk) {
            (None, 0, 0)
        } else {
            let (a, d) = count_diff_stats(chunk);
            (Some(chunk.clone()), a, d)
        }
    } else {
        (None, 0, 0)
    }
}

/// Synthesize a unified diff for an untracked file by reading its content.
/// Returns a diff where every line is an addition, matching the format
/// `git diff` would produce for a new file.
fn synthesize_untracked_diff(dir: &str, path: &str) -> (Option<String>, usize, usize) {
    let full_path = std::path::Path::new(dir).join(path);
    let content = match std::fs::read(&full_path) {
        Ok(bytes) => bytes,
        Err(_) => return (None, 0, 0),
    };

    // Check for binary content (null bytes in first 8KB)
    let check_len = content.len().min(8192);
    if content[..check_len].contains(&0) {
        return (None, 0, 0);
    }

    let text = match String::from_utf8(content) {
        Ok(s) => s,
        Err(_) => return (None, 0, 0),
    };

    let lines: Vec<&str> = text.lines().collect();
    let line_count = lines.len();
    if line_count == 0 {
        return (None, 0, 0);
    }

    let mut diff = String::new();
    diff.push_str("--- /dev/null\n");
    diff.push_str(&format!("+++ b/{path}\n"));
    diff.push_str(&format!("@@ -0,0 +1,{line_count} @@\n"));
    for line in &lines {
        diff.push('+');
        diff.push_str(line);
        diff.push('\n');
    }

    (Some(diff), line_count, 0)
}

struct FileEntry {
    path: String,
    status: &'static str,
    staging_area: &'static str,
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

        let (status, staging_area) = match xy {
            "??" => ("untracked", "unstaged"),
            "!!" => continue, // ignored files
            _ => {
                let x = xy.as_bytes()[0];
                let y = xy.as_bytes()[1];

                // Determine staging area from XY columns:
                // X encodes index (staged) state, Y encodes worktree (unstaged) state
                let area = if (x == b'U' || y == b'U')
                    || (x == b'A' && y == b'A')
                    || (x == b'D' && y == b'D')
                {
                    // Unmerged states are treated as unstaged
                    "unstaged"
                } else if x != b' ' && y != b' ' {
                    "both"
                } else if x != b' ' {
                    "staged"
                } else {
                    "unstaged"
                };

                // Determine file status
                let file_status = if (x == b'U' || y == b'U')
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
                } else {
                    "modified"
                };

                (file_status, area)
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
            staging_area,
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

// ── Stage / Unstage / Discard handlers ──────────────────────────────

/// Extract `sessionId` and `paths` (non-empty string array) from params.
fn require_session_and_paths(
    params: Option<&Value>,
) -> Result<(String, Vec<String>), CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let paths = params
        .and_then(|p| p.get("paths"))
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    if paths.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "Missing or empty required parameter: paths".into(),
        });
    }
    for path in &paths {
        validate_relative_worktree_path(path)?;
    }
    Ok((session_id, paths))
}

fn validate_relative_worktree_path(path: &str) -> Result<(), CapabilityError> {
    if path.is_empty() || path.contains('\0') {
        return Err(CapabilityError::InvalidParams {
            message: "Path must be a non-empty relative path".into(),
        });
    }
    let candidate = std::path::Path::new(path);
    if candidate.is_absolute()
        || candidate.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir
                    | std::path::Component::RootDir
                    | std::path::Component::Prefix(_)
            )
        })
    {
        return Err(CapabilityError::InvalidParams {
            message: format!("Path escapes repository root: {path}"),
        });
    }
    Ok(())
}

/// Stage files: `git add -- <paths>`
pub struct StageFilesOperation;

impl StageFilesOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::stage_files"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let (session_id, paths) = require_session_and_paths(params.as_ref())?;
        let dir = resolve_diff_dir(ctx, &session_id)?;

        let mut args = vec!["-C".to_string(), dir, "add".to_string(), "--".to_string()];
        args.extend(paths);

        let output = tokio::process::Command::new("git")
            .args(&args)
            .output()
            .await
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to run git add: {e}"),
            })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(CapabilityError::Internal {
                message: format!("git add failed: {stderr}"),
            });
        }

        Ok(serde_json::json!({ "success": true }))
    }
}

/// Unstage files: `git restore --staged -- <paths>` (or `git rm --cached` for repos with no commits)
pub struct UnstageFilesOperation;

impl UnstageFilesOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::unstage_files"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let (session_id, paths) = require_session_and_paths(params.as_ref())?;
        let dir = resolve_diff_dir(ctx, &session_id)?;

        // Check if repo has commits
        let has_commits = tokio::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "HEAD"])
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false);

        let output = if has_commits {
            let mut args = vec![
                "-C".to_string(),
                dir,
                "restore".to_string(),
                "--staged".to_string(),
                "--".to_string(),
            ];
            args.extend(paths);
            tokio::process::Command::new("git")
                .args(&args)
                .output()
                .await
        } else {
            // No commits: use git rm --cached
            let mut args = vec![
                "-C".to_string(),
                dir,
                "rm".to_string(),
                "--cached".to_string(),
                "--".to_string(),
            ];
            args.extend(paths);
            tokio::process::Command::new("git")
                .args(&args)
                .output()
                .await
        };

        let output = output.map_err(|e| CapabilityError::Internal {
            message: format!("Failed to run git unstage: {e}"),
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(CapabilityError::Internal {
                message: format!("git unstage failed: {stderr}"),
            });
        }

        Ok(serde_json::json!({ "success": true }))
    }
}

/// Discard file changes: restores tracked files from HEAD, deletes untracked files.
pub struct DiscardFilesOperation;

impl DiscardFilesOperation {
    #[instrument(skip(self, ctx), fields(method = "worktree::discard_files"))]
    async fn run(
        &self,
        params: Option<Value>,
        ctx: &ServerCapabilityContext,
    ) -> Result<Value, CapabilityError> {
        let (session_id, paths) = require_session_and_paths(params.as_ref())?;
        let dir = resolve_diff_dir(ctx, &session_id)?;
        let repo_root = std::path::Path::new(&dir);

        // Canonicalize repo root once for symlink-safe comparison (macOS /var → /private/var)
        let canonical_root = repo_root
            .canonicalize()
            .unwrap_or_else(|_| repo_root.to_path_buf());

        // Validate all paths before taking any action
        for path in &paths {
            // Reject absolute paths
            if path.starts_with('/') {
                return Err(CapabilityError::InvalidParams {
                    message: format!("Path must be relative: {path}"),
                });
            }
            // Reject path traversal components
            if path.contains("..") {
                return Err(CapabilityError::InvalidParams {
                    message: format!("Path escapes repository root: {path}"),
                });
            }
            // Resolve and check the path stays within repo root
            let resolved = canonical_root.join(path);
            let canonical = resolved.canonicalize().unwrap_or_else(|_| resolved.clone());
            if !canonical.starts_with(&canonical_root) {
                return Err(CapabilityError::InvalidParams {
                    message: format!("Path escapes repository root: {path}"),
                });
            }
        }

        for path in &paths {
            // Check if file is tracked
            let is_tracked = tokio::process::Command::new("git")
                .args(["-C", &dir, "ls-files", "--error-unmatch", path])
                .output()
                .await
                .map(|o| o.status.success())
                .unwrap_or(false);

            if is_tracked {
                // Tracked: restore from HEAD
                let output = tokio::process::Command::new("git")
                    .args(["-C", &dir, "checkout", "--", path])
                    .output()
                    .await
                    .map_err(|e| CapabilityError::Internal {
                        message: format!("Failed to run git checkout: {e}"),
                    })?;
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(CapabilityError::Internal {
                        message: format!("git checkout failed for {path}: {stderr}"),
                    });
                }
            } else {
                // Untracked: delete from filesystem
                let full_path = canonical_root.join(path);
                if full_path.exists() {
                    tokio::fs::remove_file(&full_path).await.map_err(|e| {
                        CapabilityError::Internal {
                            message: format!("Failed to delete {path}: {e}"),
                        }
                    })?;
                } else {
                    return Err(CapabilityError::Internal {
                        message: format!("File not found: {path}"),
                    });
                }
            }
        }

        Ok(serde_json::json!({ "success": true }))
    }
}
