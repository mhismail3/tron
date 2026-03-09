#![allow(unused_results)]
//! Top-level orchestrator — main public API for worktree isolation.
//!
//! The coordinator manages the lifecycle of worktrees across all sessions,
//! tracks active worktrees, and delegates to specialized modules.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use dashmap::DashMap;
use serde_json::json;
use tokio::sync::broadcast;
use tracing::{debug, info, instrument, warn};

use tron_core::events::{BaseEvent, TronEvent};
use tron_events::sqlite::repositories::session::ListSessionsOptions;
use tron_events::{AppendOptions, EventStore, EventType};

use crate::errors::{Result, WorktreeError};
use crate::git::GitExecutor;
use crate::isolation;
use crate::types::{
    AcquireResult, CommitEntry, CommittedDiffResult, CommittedFileEntry, DiffSummary, MergeResult,
    MergeStrategy, SessionBranchInfo, WorktreeConfig, WorktreeInfo,
};

/// Worktree coordinator — manages worktree lifecycle across sessions.
pub struct WorktreeCoordinator {
    config: WorktreeConfig,
    git: GitExecutor,
    event_store: Arc<EventStore>,
    /// Broadcast sender for real-time WebSocket events.
    broadcast_tx: Option<broadcast::Sender<TronEvent>>,
    /// Active worktrees by session ID.
    active: DashMap<String, WorktreeInfo>,
    /// Sessions grouped by repo root.
    repo_sessions: DashMap<PathBuf, Vec<String>>,
}

impl WorktreeCoordinator {
    /// Create a new coordinator.
    pub fn new(config: WorktreeConfig, event_store: Arc<EventStore>) -> Self {
        let git = GitExecutor::new(config.timeout_ms);
        Self {
            config,
            git,
            event_store,
            broadcast_tx: None,
            active: DashMap::new(),
            repo_sessions: DashMap::new(),
        }
    }

    /// Create a coordinator with WebSocket broadcast support.
    pub fn with_broadcast(
        config: WorktreeConfig,
        event_store: Arc<EventStore>,
        tx: broadcast::Sender<TronEvent>,
    ) -> Self {
        let git = GitExecutor::new(config.timeout_ms);
        Self {
            config,
            git,
            event_store,
            broadcast_tx: Some(tx),
            active: DashMap::new(),
            repo_sessions: DashMap::new(),
        }
    }

    /// Broadcast a `TronEvent` to WebSocket clients (non-blocking, best-effort).
    fn broadcast(&self, event: TronEvent) {
        if let Some(ref tx) = self.broadcast_tx {
            let _ = tx.send(event);
        }
    }

    /// Attempt to acquire a worktree for a session.
    ///
    /// Consults isolation policy, creates worktree if needed,
    /// emits `worktree.acquired` event, and tracks state.
    #[instrument(skip(self), fields(session_id, working_dir = %working_dir.display()))]
    pub async fn maybe_acquire(
        &self,
        session_id: &str,
        working_dir: &std::path::Path,
    ) -> Result<AcquireResult> {
        // Idempotent: return existing worktree
        if let Some(info) = self.active.get(session_id) {
            return Ok(AcquireResult::Acquired(info.clone()));
        }

        let is_git = self.git.is_git_repo(working_dir).await;
        let repo_count = if is_git {
            if let Ok(root) = self.git.repo_root(working_dir).await {
                let root_path = PathBuf::from(&root);
                self.repo_sessions.get(&root_path).map_or(0, |v| v.len())
            } else {
                0
            }
        } else {
            0
        };

        if !isolation::should_isolate(&self.config.mode, is_git, repo_count, false) {
            return Ok(AcquireResult::Passthrough);
        }

        let info =
            crate::lifecycle::create(session_id, working_dir, &self.config, &self.git).await?;

        // Emit event
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeAcquired,
            payload: json!({
                "path": info.worktree_path.to_string_lossy(),
                "branch": info.branch,
                "baseCommit": info.base_commit,
                "baseBranch": info.base_branch,
                "repoRoot": info.repo_root.to_string_lossy(),
                "isolated": true,
                "forkedFrom": null
            }),
            parent_id: None,
        });

        // Track
        self.active.insert(session_id.to_string(), info.clone());
        self.repo_sessions
            .entry(info.repo_root.clone())
            .or_default()
            .push(session_id.to_string());

        // Broadcast to WebSocket clients
        self.broadcast(TronEvent::WorktreeAcquired {
            base: BaseEvent::now(session_id),
            path: info.worktree_path.to_string_lossy().to_string(),
            branch: info.branch.clone(),
            base_commit: info.base_commit.clone(),
            base_branch: info.base_branch.clone(),
        });

        debug!(session_id, branch = %info.branch, "worktree acquired");
        Ok(AcquireResult::Acquired(info))
    }

    /// Release a session's worktree.
    ///
    /// Auto-commits, removes worktree directory, preserves branch per config.
    /// Emits `worktree.released` event.
    #[instrument(skip(self), fields(session_id))]
    pub async fn release(&self, session_id: &str) -> Result<()> {
        let Some((_, info)) = self.active.remove(session_id) else {
            debug!(session_id, "no active worktree to release");
            return Ok(());
        };

        let release_info = crate::lifecycle::remove(&info, &self.config, &self.git).await?;

        // Emit event
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeReleased,
            payload: json!({
                "finalCommit": release_info.final_commit,
                "deleted": release_info.deleted,
                "branchPreserved": release_info.branch_preserved,
            }),
            parent_id: None,
        });

        // Broadcast to WebSocket clients
        self.broadcast(TronEvent::WorktreeReleased {
            base: BaseEvent::now(session_id),
            final_commit: release_info.final_commit.clone(),
            branch_preserved: release_info.branch_preserved,
            deleted: release_info.deleted,
        });

        // Untrack from repo_sessions
        if let Some(mut sessions) = self.repo_sessions.get_mut(&info.repo_root) {
            sessions.retain(|s| s != session_id);
        }

        Ok(())
    }

    /// Get the effective working directory for a session.
    ///
    /// Returns the worktree path if active, None otherwise.
    pub fn effective_working_dir(&self, session_id: &str) -> Option<String> {
        self.active
            .get(session_id)
            .map(|info| info.worktree_path.to_string_lossy().to_string())
    }

    /// Commit changes in a session's worktree.
    ///
    /// Emits `worktree.commit` event with file list and diff stats.
    /// Returns `None` if there are no changes to commit.
    pub async fn commit(
        &self,
        session_id: &str,
        message: &str,
    ) -> Result<Option<crate::types::CommitResult>> {
        let info = self
            .active
            .get(session_id)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;

        if !self.git.has_changes(&info.worktree_path).await? {
            return Ok(None);
        }

        // Capture pre-commit HEAD to compute diff stats after commit
        let pre_commit = self
            .git
            .head_commit(&info.worktree_path)
            .await
            .unwrap_or_default();

        let sha = self.git.commit_all(&info.worktree_path, message).await?;

        // Gather files changed and diff stats between pre-commit and new HEAD
        let files_changed = if pre_commit.is_empty() {
            Vec::new()
        } else {
            self.git
                .changed_files_since(&info.worktree_path, &pre_commit)
                .await
                .unwrap_or_default()
        };

        let (insertions, deletions) = if pre_commit.is_empty() {
            (0, 0)
        } else {
            self.git
                .diff_numstat_total(&info.worktree_path, &pre_commit, &sha)
                .await
                .unwrap_or((0, 0))
        };

        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeCommit,
            payload: json!({
                "commitHash": sha,
                "message": message,
                "filesChanged": files_changed,
                "insertions": insertions,
                "deletions": deletions
            }),
            parent_id: None,
        });

        // Broadcast to WebSocket clients
        self.broadcast(TronEvent::WorktreeCommit {
            base: BaseEvent::now(session_id),
            commit_hash: sha.clone(),
            message: message.to_string(),
            files_changed: files_changed.clone(),
            insertions,
            deletions,
        });

        debug!(session_id, commit = %sha, files = files_changed.len(), "committed in worktree");
        Ok(Some(crate::types::CommitResult {
            commit_hash: sha,
            files_changed,
            insertions,
            deletions,
        }))
    }

    /// Merge a session's branch into a target branch.
    ///
    /// Emits `worktree.merged` event on success.
    pub async fn merge(
        &self,
        session_id: &str,
        target_branch: &str,
        strategy: MergeStrategy,
    ) -> Result<MergeResult> {
        let info = self
            .active
            .get(session_id)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;

        let result = crate::merge::merge_session(
            &info.repo_root,
            &info.branch,
            target_branch,
            strategy,
            &self.git,
        )
        .await?;

        if result.success {
            let strategy_str = serde_json::to_value(&result.strategy)
                .ok()
                .and_then(|v| v.as_str().map(String::from))
                .unwrap_or_else(|| format!("{:?}", result.strategy).to_lowercase());

            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreeMerged,
                payload: json!({
                    "sourceBranch": info.branch,
                    "targetBranch": target_branch,
                    "mergeCommit": result.merge_commit,
                    "strategy": result.strategy
                }),
                parent_id: None,
            });

            // Broadcast to WebSocket clients
            self.broadcast(TronEvent::WorktreeMerged {
                base: BaseEvent::now(session_id),
                source_branch: info.branch.clone(),
                target_branch: target_branch.to_string(),
                merge_commit: result.merge_commit.clone(),
                strategy: strategy_str,
            });
        }

        Ok(result)
    }

    /// List all active worktrees.
    pub fn list_active(&self) -> Vec<WorktreeInfo> {
        self.active.iter().map(|r| r.value().clone()).collect()
    }

    /// List worktrees for a specific repo via `git worktree list`.
    pub async fn list_for_repo(
        &self,
        repo_root: &std::path::Path,
    ) -> Result<Vec<crate::git::WorktreeListEntry>> {
        self.git.worktree_list(repo_root).await
    }

    /// Get info for a specific session's worktree.
    pub fn get_info(&self, session_id: &str) -> Option<WorktreeInfo> {
        self.active.get(session_id).map(|r| r.value().clone())
    }

    /// Get enriched status for a session's worktree.
    ///
    /// Queries git for uncommitted changes and commit count since base.
    pub async fn get_status(
        &self,
        session_id: &str,
    ) -> Result<Option<crate::types::WorktreeStatus>> {
        let info = match self.active.get(session_id) {
            Some(r) => r.value().clone(),
            None => return Ok(None),
        };

        let has_changes = self
            .git
            .has_changes(&info.worktree_path)
            .await
            .unwrap_or(false);

        let commit_count = self
            .git
            .commit_count_since(&info.worktree_path, &info.base_commit)
            .await
            .unwrap_or(0);

        // Check if this branch has been merged into its base branch.
        let base_branch = info.base_branch.as_deref().unwrap_or("main");
        let is_merged = if commit_count > 0 {
            self.git
                .is_ancestor(&info.repo_root, &info.branch, base_branch)
                .await
        } else {
            false
        };

        Ok(Some(crate::types::WorktreeStatus {
            isolated: true,
            branch: info.branch,
            base_commit: info.base_commit,
            base_branch: info.base_branch,
            path: info.worktree_path.to_string_lossy().to_string(),
            repo_root: info.repo_root.to_string_lossy().to_string(),
            has_uncommitted_changes: has_changes,
            commit_count,
            is_merged,
        }))
    }

    /// Rebuild active worktree state from persisted events.
    ///
    /// Scans for sessions with `worktree.acquired` events (without a subsequent
    /// `worktree.released`) and re-populates the in-memory `active` `DashMap`.
    /// Must be called before `recover_orphans` to prevent deleting valid worktrees.
    pub fn rebuild_from_events(&self) {
        let sessions = self
            .event_store
            .list_sessions(&ListSessionsOptions {
                ended: Some(false),
                ..Default::default()
            })
            .unwrap_or_default();

        let mut restored = 0usize;
        for session in &sessions {
            let Ok(Some(acq)) = self.event_store.get_active_worktree(&session.id) else {
                continue;
            };

            let payload: serde_json::Value = match serde_json::from_str(&acq.payload) {
                Ok(v) => v,
                Err(_) => continue,
            };

            let branch = payload["branch"].as_str().unwrap_or_default();
            let base_commit = payload["baseCommit"].as_str().unwrap_or_default();
            let path = payload["path"].as_str().unwrap_or_default();
            let repo_root = payload["repoRoot"].as_str().unwrap_or_default();
            let base_branch = payload["baseBranch"].as_str().map(String::from);

            if branch.is_empty() || path.is_empty() {
                continue;
            }

            // Only restore if the worktree directory still exists
            let wt_path = PathBuf::from(path);
            if !wt_path.exists() {
                debug!(session_id = %session.id, path, "worktree dir gone, skipping rebuild");
                continue;
            }

            let info = WorktreeInfo {
                session_id: session.id.clone(),
                worktree_path: wt_path,
                branch: branch.to_string(),
                base_commit: base_commit.to_string(),
                original_working_dir: PathBuf::from(&session.working_directory),
                repo_root: PathBuf::from(repo_root),
                base_branch,
            };

            self.active.insert(session.id.clone(), info);
            restored += 1;
        }

        if restored > 0 {
            info!(restored, "rebuilt active worktrees from events");
        }
    }

    /// Recover orphaned worktrees across all known workspaces.
    ///
    /// Called on server startup (fire-and-forget).
    /// IMPORTANT: Call `rebuild_from_events` first to avoid deleting valid worktrees.
    pub async fn recover_orphans(&self) -> usize {
        let workspaces = self.event_store.list_workspaces().unwrap_or_default();
        let active_ids: HashSet<String> = self.active.iter().map(|r| r.key().clone()).collect();

        let mut total = 0;
        for ws in &workspaces {
            let repo_root = PathBuf::from(&ws.path);
            if !self.git.is_git_repo(&repo_root).await {
                continue;
            }
            match crate::recovery::recover_repo(&repo_root, &active_ids, &self.config, &self.git)
                .await
            {
                Ok(recovered) => total += recovered.len(),
                Err(e) => {
                    warn!(repo = %repo_root.display(), error = %e, "orphan recovery failed");
                }
            }
        }

        if total > 0 {
            info!(total, "orphan worktrees recovered");
        }
        total
    }

    /// List all session branches (active and preserved) for a repo.
    ///
    /// Scans for branches matching the configured prefix, cross-references
    /// with active worktrees for live state, and queries the event store
    /// for `baseBranch` on preserved branches.
    pub async fn list_session_branches(
        &self,
        repo_root: &std::path::Path,
    ) -> Result<Vec<SessionBranchInfo>> {
        let pattern = format!("{}*", self.config.branch_prefix);
        let branches = self.git.list_branches_matching(repo_root, &pattern).await?;

        // Build branch→base_branch map from events for preserved branches
        let event_base_branches = self.load_base_branches_from_events();

        let mut results = Vec::with_capacity(branches.len());
        for branch in &branches {
            let log = match self.git.branch_log(repo_root, branch, 1).await {
                Ok(entries) if !entries.is_empty() => entries[0].clone(),
                _ => continue,
            };

            // Cross-reference with active map to get session_id, is_active, and base_branch
            let (is_active, session_id, base_branch) =
                if let Some(entry) = self.active.iter().find(|r| r.value().branch == *branch) {
                    (
                        true,
                        Some(entry.key().clone()),
                        entry.value().base_branch.clone(),
                    )
                } else {
                    let event_base = event_base_branches.get(branch.as_str()).cloned();
                    let base = match event_base {
                        Some(b) => b,
                        None => self.detect_default_branch(repo_root).await,
                    };
                    (false, None, Some(base))
                };

            let commit_count = if let Some(ref base) = base_branch {
                let mb = self.git.merge_base(repo_root, base, branch).await.ok();
                if let Some(ref merge_base_sha) = mb {
                    self.git
                        .commit_count_between(repo_root, merge_base_sha, branch)
                        .await
                        .unwrap_or(0)
                } else {
                    0
                }
            } else {
                0
            };

            results.push(SessionBranchInfo {
                branch: branch.clone(),
                is_active,
                session_id,
                commit_count,
                last_commit_hash: log.0,
                last_commit_message: log.1,
                last_commit_date: log.2,
                base_branch,
            });
        }

        results.sort_by(|a, b| b.last_commit_date.cmp(&a.last_commit_date));
        Ok(results)
    }

    /// Build a `branch→base_branch` map by scanning `WorktreeAcquired` events.
    fn load_base_branches_from_events(&self) -> std::collections::HashMap<String, String> {
        let mut map = std::collections::HashMap::new();
        let events = self
            .event_store
            .get_all_events_by_types(&["worktree.acquired"], Some(500), None)
            .unwrap_or_default();
        for event in &events {
            if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
                && let (Some(branch), Some(base)) = (
                    payload.get("branch").and_then(|v| v.as_str()),
                    payload.get("baseBranch").and_then(|v| v.as_str()),
                )
            {
                map.insert(branch.to_string(), base.to_string());
            }
        }
        map
    }

    /// Get committed diff for a session's worktree branch.
    ///
    /// For active worktrees, uses the worktree path. For preserved branches,
    /// computes diff from repo root without checkout.
    pub async fn get_committed_diff(
        &self,
        session_id: &str,
    ) -> Result<Option<CommittedDiffResult>> {
        // First check active worktrees
        if let Some(info) = self.active.get(session_id) {
            return self
                .committed_diff_for_branch(&info.repo_root, &info.branch, &info.base_commit)
                .await
                .map(Some);
        }

        // For preserved branches: find branch and base from WorktreeAcquired events
        let branch_prefix = format!(
            "{}{}",
            self.config.branch_prefix,
            &session_id[..session_id.len().min(12)]
        );

        // Try event store first — it has the original baseBranch and repoRoot
        let events = self
            .event_store
            .get_events_by_type(session_id, &["worktree.acquired"], Some(1))
            .unwrap_or_default();
        if let Some(event) = events.first()
            && let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
            && let (Some(branch), Some(base_branch)) = (
                payload.get("branch").and_then(|v| v.as_str()),
                payload.get("baseBranch").and_then(|v| v.as_str()),
            )
        {
            // Find the repo root from event payload or by scanning workspaces
            let repo_root = if let Some(root) = payload.get("repoRoot").and_then(|v| v.as_str()) {
                PathBuf::from(root)
            } else {
                // Fallback: scan workspaces
                match self.find_repo_for_branch(branch).await {
                    Some(root) => root,
                    None => return Ok(None),
                }
            };

            let base = self.git.merge_base(&repo_root, base_branch, branch).await?;
            return self
                .committed_diff_for_branch(&repo_root, branch, &base)
                .await
                .map(Some);
        }

        // Fallback: scan workspaces for matching branch (for sessions before baseBranch was persisted)
        let workspaces = self.event_store.list_workspaces().unwrap_or_default();
        for ws in &workspaces {
            let repo_root = PathBuf::from(&ws.path);
            if !self.git.is_git_repo(&repo_root).await {
                continue;
            }
            let pattern = format!("{branch_prefix}*");
            let branches = self
                .git
                .list_branches_matching(&repo_root, &pattern)
                .await
                .unwrap_or_default();
            if let Some(branch) = branches.first() {
                let base_branch = self.detect_default_branch(&repo_root).await;
                let base = self
                    .git
                    .merge_base(&repo_root, &base_branch, branch)
                    .await?;
                return self
                    .committed_diff_for_branch(&repo_root, branch, &base)
                    .await
                    .map(Some);
            }
        }

        Ok(None)
    }

    /// Internal: compute committed diff for a branch relative to a base commit.
    async fn committed_diff_for_branch(
        &self,
        repo_root: &std::path::Path,
        branch: &str,
        base_commit: &str,
    ) -> Result<CommittedDiffResult> {
        const MAX_DIFF_BYTES: usize = 1_024 * 1_024;

        let commit_count = self
            .git
            .commit_count_between(repo_root, base_commit, branch)
            .await
            .unwrap_or(0);

        let commits: Vec<CommitEntry> = if commit_count > 0 {
            self.git
                .branch_log(repo_root, branch, commit_count)
                .await
                .unwrap_or_default()
                .into_iter()
                .map(|(hash, message, date)| CommitEntry {
                    hash,
                    message,
                    date,
                })
                .collect()
        } else {
            Vec::new()
        };

        if commits.is_empty() {
            return Ok(CommittedDiffResult {
                commits: Vec::new(),
                files: Vec::new(),
                summary: DiffSummary {
                    total_files: 0,
                    total_additions: 0,
                    total_deletions: 0,
                },
                truncated: false,
            });
        }

        let name_status = self
            .git
            .diff_name_status(repo_root, base_commit, branch)
            .await
            .unwrap_or_default();

        let raw_diff = self
            .git
            .diff_between(repo_root, base_commit, branch)
            .await
            .unwrap_or_default();

        let truncated = raw_diff.len() > MAX_DIFF_BYTES;
        let diff_str = if truncated {
            let safe_end = raw_diff.floor_char_boundary(MAX_DIFF_BYTES);
            &raw_diff[..safe_end]
        } else {
            &raw_diff
        };

        let diff_map = split_diff_by_file(diff_str);

        let mut files = Vec::new();
        let mut total_additions = 0usize;
        let mut total_deletions = 0usize;

        for (status, path) in &name_status {
            let (diff_text, additions, deletions) = if let Some(chunk) = diff_map.get(path) {
                if chunk.contains("Binary files") && chunk.contains("differ") {
                    (None, 0, 0)
                } else {
                    let (a, d) = count_diff_stats(chunk);
                    (Some(chunk.clone()), a, d)
                }
            } else {
                (None, 0, 0)
            };

            total_additions += additions;
            total_deletions += deletions;

            files.push(CommittedFileEntry {
                path: path.clone(),
                status: status.clone(),
                diff: diff_text,
                additions,
                deletions,
            });
        }

        Ok(CommittedDiffResult {
            commits,
            files: files.clone(),
            summary: DiffSummary {
                total_files: files.len(),
                total_additions,
                total_deletions,
            },
            truncated,
        })
    }

    /// Scan known workspaces to find which repo contains a given branch.
    async fn find_repo_for_branch(&self, branch: &str) -> Option<PathBuf> {
        let workspaces = self.event_store.list_workspaces().unwrap_or_default();
        for ws in &workspaces {
            let repo_root = PathBuf::from(&ws.path);
            if !self.git.is_git_repo(&repo_root).await {
                continue;
            }
            let branches = self
                .git
                .list_branches_matching(&repo_root, branch)
                .await
                .unwrap_or_default();
            if branches.iter().any(|b| b == branch) {
                return Some(repo_root);
            }
        }
        None
    }

    /// Detect the default branch for a repo (tries main, then master, then current).
    async fn detect_default_branch(&self, repo_root: &std::path::Path) -> String {
        let branches = self
            .git
            .list_branches_matching(repo_root, "*")
            .await
            .unwrap_or_default();
        for candidate in &["main", "master"] {
            if branches.iter().any(|b| b == candidate) {
                return candidate.to_string();
            }
        }
        self.git
            .current_branch(repo_root)
            .await
            .unwrap_or_else(|_| "main".to_string())
    }

    /// Get the configuration.
    pub fn config(&self) -> &WorktreeConfig {
        &self.config
    }

    /// Resolve the git repository root for a given path.
    pub async fn resolve_repo_root(&self, path: &std::path::Path) -> Result<String> {
        self.git.repo_root(path).await
    }
}

/// Split combined diff output by file, returning (path, `diff_chunk`) pairs.
pub fn split_diff_by_file(diff: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let mut current_path: Option<String> = None;
    let mut current_chunk = String::new();

    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("diff --git a/") {
            if let Some(path) = current_path.take() {
                let _ = map.insert(path, current_chunk.clone());
            }
            current_chunk.clear();
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

    if let Some(path) = current_path {
        let _ = map.insert(path, current_chunk);
    }
    map
}

/// Count additions and deletions in a diff chunk.
pub fn count_diff_stats(chunk: &str) -> (usize, usize) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use tron_events::{ConnectionConfig, new_in_memory, run_migrations};

    fn make_store() -> Arc<EventStore> {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    async fn init_repo(dir: &std::path::Path) {
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
    }

    async fn run_cmd(dir: &std::path::Path, args: &[&str]) {
        let status = tokio::process::Command::new(args[0])
            .args(&args[1..])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(
            status.status.success(),
            "cmd {:?} failed: {}",
            args,
            String::from_utf8_lossy(&status.stderr)
        );
    }

    #[tokio::test]
    async fn acquire_in_git_repo() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let _ = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let result = coord.maybe_acquire("test-sess", dir.path()).await.unwrap();
        assert!(matches!(result, AcquireResult::Acquired(_)));

        if let AcquireResult::Acquired(info) = result {
            assert!(info.worktree_path.exists());
            assert!(info.branch.starts_with("session/"));
        }
    }

    #[tokio::test]
    async fn acquire_non_git_passthrough() {
        let dir = tempdir().unwrap();
        let store = make_store();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let result = coord.maybe_acquire("test-sess", dir.path()).await.unwrap();
        assert!(matches!(result, AcquireResult::Passthrough));
    }

    #[tokio::test]
    async fn acquire_idempotent() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let _ = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let r1 = coord.maybe_acquire("test-idem", dir.path()).await.unwrap();
        let r2 = coord.maybe_acquire("test-idem", dir.path()).await.unwrap();

        if let (AcquireResult::Acquired(i1), AcquireResult::Acquired(i2)) = (&r1, &r2) {
            assert_eq!(i1.worktree_path, i2.worktree_path);
        } else {
            panic!("expected both to be Acquired");
        }
    }

    #[tokio::test]
    async fn acquire_mode_never() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let config = WorktreeConfig {
            mode: tron_settings::types::IsolationMode::Never,
            ..WorktreeConfig::default()
        };
        let coord = WorktreeCoordinator::new(config, store);

        let result = coord.maybe_acquire("test-never", dir.path()).await.unwrap();
        assert!(matches!(result, AcquireResult::Passthrough));
    }

    #[tokio::test]
    async fn release_unknown_session() {
        let store = make_store();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
        coord.release("nonexistent").await.unwrap(); // Should not error
    }

    #[tokio::test]
    async fn full_lifecycle() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let session = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let sid = &session.session.id;
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        // Acquire
        let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
        let info = match result {
            AcquireResult::Acquired(i) => i,
            AcquireResult::Passthrough => panic!("expected Acquired"),
        };

        assert!(coord.effective_working_dir(sid).is_some());
        assert_eq!(coord.list_active().len(), 1);

        // Write a file in worktree
        std::fs::write(info.worktree_path.join("work.txt"), "progress").unwrap();

        // Commit
        let commit_result = coord.commit(sid, "wip").await.unwrap();
        assert!(commit_result.is_some());
        let cr = commit_result.unwrap();
        assert_eq!(cr.commit_hash.len(), 40);
        assert!(!cr.files_changed.is_empty());

        // Release
        coord.release(sid).await.unwrap();
        assert!(coord.effective_working_dir(sid).is_none());
        assert!(coord.list_active().is_empty());
    }

    #[tokio::test]
    async fn get_status_returns_enriched_info() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let session = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let sid = &session.session.id;
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        // Acquire
        let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
        let info = match result {
            AcquireResult::Acquired(i) => i,
            AcquireResult::Passthrough => panic!("expected Acquired"),
        };

        // Initially: no changes, no commits
        let status = coord.get_status(sid).await.unwrap().unwrap();
        assert!(status.isolated);
        assert!(!status.has_uncommitted_changes);
        assert_eq!(status.commit_count, 0);
        assert_eq!(status.branch, info.branch);

        // Write a file → uncommitted changes
        std::fs::write(info.worktree_path.join("work.txt"), "wip").unwrap();
        let status = coord.get_status(sid).await.unwrap().unwrap();
        assert!(status.has_uncommitted_changes);
        assert_eq!(status.commit_count, 0);

        // Commit → committed, no uncommitted
        coord.commit(sid, "first commit").await.unwrap();
        let status = coord.get_status(sid).await.unwrap().unwrap();
        assert!(!status.has_uncommitted_changes);
        assert_eq!(status.commit_count, 1);

        // Second commit
        std::fs::write(info.worktree_path.join("more.txt"), "more").unwrap();
        coord.commit(sid, "second commit").await.unwrap();
        let status = coord.get_status(sid).await.unwrap().unwrap();
        assert_eq!(status.commit_count, 2);
    }

    #[tokio::test]
    async fn get_status_none_for_unknown_session() {
        let store = make_store();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
        assert!(coord.get_status("nonexistent").await.unwrap().is_none());
    }

    #[tokio::test]
    async fn commit_populates_files_and_stats() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let session = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let sid = &session.session.id;
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());

        let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
        let info = match result {
            AcquireResult::Acquired(i) => i,
            AcquireResult::Passthrough => panic!("expected Acquired"),
        };

        // Create files and commit
        std::fs::write(info.worktree_path.join("new.txt"), "hello\nworld\n").unwrap();
        std::fs::write(info.worktree_path.join("other.txt"), "line1\n").unwrap();
        coord.commit(sid, "add files").await.unwrap();

        // Check the persisted event
        let events = store.get_events_since(sid, 0).unwrap();
        let commit_event = events
            .iter()
            .find(|e| e.event_type == "worktree.commit")
            .expect("commit event should exist");

        let payload: serde_json::Value = serde_json::from_str(&commit_event.payload).unwrap();
        let files = payload["filesChanged"].as_array().unwrap();
        assert!(files.len() >= 2);
        assert!(payload["insertions"].as_u64().unwrap() >= 3);
        assert_eq!(payload["deletions"].as_u64().unwrap(), 0);
    }

    #[tokio::test]
    async fn concurrent_sessions_same_repo() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let r1 = coord
            .maybe_acquire("aaaa-session-a1", dir.path())
            .await
            .unwrap();
        let r2 = coord
            .maybe_acquire("bbbb-session-b2", dir.path())
            .await
            .unwrap();

        if let (AcquireResult::Acquired(i1), AcquireResult::Acquired(i2)) = (&r1, &r2) {
            assert_ne!(i1.worktree_path, i2.worktree_path);
            assert_ne!(i1.branch, i2.branch);
        } else {
            panic!("expected both Acquired");
        }

        assert_eq!(coord.list_active().len(), 2);
    }

    // ── list_session_branches tests ────────────────────────────────

    #[tokio::test]
    async fn list_branches_empty_repo() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
        let branches = coord.list_session_branches(dir.path()).await.unwrap();
        assert!(branches.is_empty());
    }

    #[tokio::test]
    async fn list_branches_with_active_worktree() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let _ = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let result = coord.maybe_acquire("sess-1", dir.path()).await.unwrap();
        assert!(matches!(result, AcquireResult::Acquired(_)));

        let branches = coord.list_session_branches(dir.path()).await.unwrap();
        assert_eq!(branches.len(), 1);
        assert!(branches[0].is_active);
        assert_eq!(branches[0].session_id.as_deref(), Some("sess-1"));
        assert!(branches[0].branch.starts_with("session/"));
    }

    #[tokio::test]
    async fn list_branches_with_preserved_branch() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let _ = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        // Acquire then release (branch preserved by default)
        let result = coord.maybe_acquire("sess-2", dir.path()).await.unwrap();
        let AcquireResult::Acquired(info) = result else {
            panic!("expected Acquired");
        };
        // Write something so there's a commit
        std::fs::write(info.worktree_path.join("work.txt"), "data").unwrap();
        coord.commit("sess-2", "wip").await.unwrap();
        coord.release("sess-2").await.unwrap();

        let branches = coord.list_session_branches(dir.path()).await.unwrap();
        assert_eq!(branches.len(), 1);
        assert!(!branches[0].is_active);
        assert!(branches[0].session_id.is_none());
        assert!(branches[0].commit_count > 0);
    }

    #[tokio::test]
    async fn list_branches_ignores_non_session_branches() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "feature/xyz"]).await;
        run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;

        let store = make_store();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let branches = coord.list_session_branches(dir.path()).await.unwrap();
        assert_eq!(branches.len(), 1);
        assert_eq!(branches[0].branch, "session/abc");
    }

    // ── get_committed_diff tests ────────────────────────────────────

    #[tokio::test]
    async fn committed_diff_no_commits() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let _ = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        coord.maybe_acquire("sess-cd1", dir.path()).await.unwrap();

        let result = coord.get_committed_diff("sess-cd1").await.unwrap();
        assert!(result.is_some());
        let diff = result.unwrap();
        assert!(diff.commits.is_empty());
        assert!(diff.files.is_empty());
        assert_eq!(diff.summary.total_files, 0);
    }

    #[tokio::test]
    async fn committed_diff_single_commit() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let _ = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let result = coord.maybe_acquire("sess-cd2", dir.path()).await.unwrap();
        let AcquireResult::Acquired(info) = result else {
            panic!("expected Acquired");
        };

        std::fs::write(info.worktree_path.join("new.txt"), "hello\nworld\n").unwrap();
        coord.commit("sess-cd2", "add file").await.unwrap();

        let diff = coord.get_committed_diff("sess-cd2").await.unwrap().unwrap();
        assert_eq!(diff.commits.len(), 1);
        assert_eq!(diff.commits[0].message, "add file");
        assert!(!diff.files.is_empty());
        assert!(diff.summary.total_additions > 0);
    }

    #[tokio::test]
    async fn committed_diff_no_active_worktree() {
        let store = make_store();
        let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

        let result = coord.get_committed_diff("nonexistent").await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn broadcasts_worktree_events() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let session = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
            )
            .unwrap();
        let sid = &session.session.id;

        // Create coordinator with broadcast channel
        let (tx, _) = tokio::sync::broadcast::channel(16);
        let mut rx = tx.subscribe();
        let coord = WorktreeCoordinator::with_broadcast(WorktreeConfig::default(), store, tx);

        // Acquire — should broadcast WorktreeAcquired
        let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
        let info = match result {
            AcquireResult::Acquired(i) => i,
            AcquireResult::Passthrough => panic!("expected Acquired"),
        };
        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "worktree.acquired");
        assert_eq!(event.session_id(), sid.as_str());

        // Commit — should broadcast WorktreeCommit
        std::fs::write(info.worktree_path.join("work.txt"), "data").unwrap();
        coord.commit(sid, "wip").await.unwrap();
        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "worktree.commit");

        // Release — should broadcast WorktreeReleased
        coord.release(sid).await.unwrap();
        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "worktree.released");
    }
}
