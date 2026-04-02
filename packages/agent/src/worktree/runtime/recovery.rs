//! Orphan cleanup on server restart.
//!
//! Scans for worktrees with branches matching the session prefix
//! that don't belong to any active session.

use std::collections::HashSet;
use std::path::PathBuf;

use tracing::{debug, info, warn};

use crate::worktree::errors::Result;
use crate::worktree::git::GitExecutor;
use crate::worktree::types::WorktreeConfig;

/// Information about a recovered orphan worktree.
#[derive(Clone, Debug)]
pub struct RecoveredWorktree {
    /// Path of the removed worktree.
    pub path: String,
    /// Branch name.
    pub branch: String,
    /// Whether changes were auto-committed before removal.
    pub auto_committed: bool,
    /// Whether the branch was deleted (no commits over base).
    pub branch_deleted: bool,
}

/// Detect the default branch for a repo (tries main, then master, then HEAD).
async fn detect_default_branch(repo_root: &std::path::Path, git: &GitExecutor) -> String {
    let branches = git
        .list_branches_matching(repo_root, "*")
        .await
        .unwrap_or_default();
    for candidate in &["main", "master"] {
        if branches.iter().any(|b| b == candidate) {
            return candidate.to_string();
        }
    }
    git.current_branch(repo_root)
        .await
        .unwrap_or_else(|_| "main".to_string())
}

/// Recover orphaned worktrees in a single repository.
///
/// 1. List all worktrees with branches matching the session prefix
/// 2. For worktrees whose branch is not in `active_branches`:
///    - Auto-commit any changes with `[auto-recovered]` message
///    - Remove the worktree
/// 3. Prune stale refs
#[allow(clippy::implicit_hasher)]
pub async fn recover_repo(
    repo_root: &std::path::Path,
    active_branches: &HashSet<String>,
    config: &WorktreeConfig,
    git: &GitExecutor,
) -> Result<Vec<RecoveredWorktree>> {
    let worktrees_dir = repo_root.join(&config.base_dir_name);
    if !worktrees_dir.exists() {
        debug!(repo = %repo_root.display(), "no worktrees directory, skipping");
        return Ok(vec![]);
    }

    let entries = git.worktree_list(repo_root).await?;
    let mut recovered = Vec::new();

    for entry in &entries {
        let branch = match &entry.branch {
            Some(b) if b.starts_with(&config.branch_prefix) => b,
            _ => continue,
        };

        // Check if the branch belongs to an active worktree
        let is_active = active_branches.contains(branch.as_str());

        if is_active {
            debug!(branch, "worktree branch is active, skipping");
            continue;
        }

        let wt_path = PathBuf::from(&entry.path);
        let mut auto_committed = false;

        // Auto-commit any changes
        if wt_path.exists()
            && let Ok(true) = git.has_changes(&wt_path).await
        {
            match git
                .commit_all(&wt_path, "[auto-recovered] orphaned session changes")
                .await
            {
                Ok(sha) => {
                    info!(branch, commit = %sha, "auto-committed orphan changes");
                    auto_committed = true;
                }
                Err(e) => {
                    warn!(branch, error = %e, "failed to auto-commit orphan");
                }
            }
        }

        // Remove the worktree
        if wt_path.exists() {
            match git.worktree_remove(repo_root, &wt_path, true).await {
                Ok(()) => {
                    info!(branch, path = %wt_path.display(), "removed orphan worktree");
                }
                Err(e) => {
                    warn!(branch, error = %e, "failed to remove orphan worktree");
                    // Try manual cleanup
                    let _ = tokio::fs::remove_dir_all(&wt_path).await;
                }
            }
        }

        // Delete branch if it has no commits over the default branch.
        // Branches with work (committed or auto-committed) are preserved.
        let has_commits = if auto_committed {
            true
        } else {
            let default_branch = detect_default_branch(repo_root, git).await;
            match git.merge_base(repo_root, &default_branch, branch).await {
                Ok(mb) => git
                    .commit_count_between(repo_root, &mb, branch)
                    .await
                    .unwrap_or(0)
                    > 0,
                Err(_) => false,
            }
        };

        let branch_deleted = if !has_commits {
            match git.branch_delete(repo_root, branch, true).await {
                Ok(()) => {
                    info!(branch, "deleted empty orphan branch");
                    true
                }
                Err(e) => {
                    warn!(branch, error = %e, "failed to delete orphan branch");
                    false
                }
            }
        } else {
            false
        };

        recovered.push(RecoveredWorktree {
            path: entry.path.clone(),
            branch: branch.clone(),
            auto_committed,
            branch_deleted,
        });
    }

    // Prune stale refs
    let _ = git.worktree_prune(repo_root).await;

    if !recovered.is_empty() {
        info!(
            repo = %repo_root.display(),
            count = recovered.len(),
            "recovered orphan worktrees"
        );
    }

    Ok(recovered)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    async fn init_repo(dir: &std::path::Path) -> GitExecutor {
        let git = GitExecutor::new(30_000);
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
        git
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
    async fn recover_no_worktrees_dir() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();
        let active: HashSet<String> = HashSet::new();

        let result = recover_repo(dir.path(), &active, &config, &git)
            .await
            .unwrap();
        assert!(result.is_empty());
    }

    #[tokio::test]
    async fn recover_orphan_worktree() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        // Create a worktree that simulates an orphaned session
        let wt_path = dir
            .path()
            .join(".worktrees")
            .join("session")
            .join("orphaned");
        git.worktree_add(dir.path(), &wt_path, "session/orphaned", "HEAD")
            .await
            .unwrap();
        assert!(wt_path.exists());

        // No active sessions
        let active: HashSet<String> = HashSet::new();
        let result = recover_repo(dir.path(), &active, &config, &git)
            .await
            .unwrap();

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].branch, "session/orphaned");
        assert!(!result[0].auto_committed);
        assert!(result[0].branch_deleted, "empty orphan branch should be deleted");
    }

    #[tokio::test]
    async fn recover_skips_active_session() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let wt_path = dir
            .path()
            .join(".worktrees")
            .join("session")
            .join("active12");
        git.worktree_add(dir.path(), &wt_path, "session/active12", "HEAD")
            .await
            .unwrap();

        let mut active: HashSet<String> = HashSet::new();
        assert!(active.insert("session/active12".to_string()));

        let result = recover_repo(dir.path(), &active, &config, &git)
            .await
            .unwrap();

        assert!(result.is_empty());
        assert!(wt_path.exists()); // Should not have been removed
    }

    #[tokio::test]
    async fn recover_with_uncommitted_changes() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let wt_path = dir
            .path()
            .join(".worktrees")
            .join("session")
            .join("dirty123");
        git.worktree_add(dir.path(), &wt_path, "session/dirty123", "HEAD")
            .await
            .unwrap();

        // Make changes in the orphaned worktree
        std::fs::write(wt_path.join("work.txt"), "uncommitted work").unwrap();

        let active: HashSet<String> = HashSet::new();
        let result = recover_repo(dir.path(), &active, &config, &git)
            .await
            .unwrap();

        assert_eq!(result.len(), 1);
        assert!(result[0].auto_committed);
        assert!(!result[0].branch_deleted, "branch with auto-committed work should be preserved");
    }

    #[tokio::test]
    async fn recover_skips_renamed_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let wt_path = dir
            .path()
            .join(".worktrees")
            .join("session")
            .join("abc123");
        git.worktree_add(dir.path(), &wt_path, "session/abc123", "HEAD")
            .await
            .unwrap();

        // Simulate rename: branch is now session/fuzzy-purple-elephant
        git.branch_rename(
            dir.path(),
            "session/abc123",
            "session/fuzzy-purple-elephant",
        )
        .await
        .unwrap();

        let mut active: HashSet<String> = HashSet::new();
        active.insert("session/fuzzy-purple-elephant".to_string());

        let result = recover_repo(dir.path(), &active, &config, &git)
            .await
            .unwrap();
        assert!(
            result.is_empty(),
            "renamed active branch should not be treated as orphan"
        );
    }

    #[tokio::test]
    async fn recover_preserves_branch_with_committed_work() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let wt_path = dir
            .path()
            .join(".worktrees")
            .join("session")
            .join("committed1");
        git.worktree_add(dir.path(), &wt_path, "session/committed1", "HEAD")
            .await
            .unwrap();

        // Make a commit in the worktree (simulating agent work)
        std::fs::write(wt_path.join("work.txt"), "committed work").unwrap();
        let _ = git.commit_all(&wt_path, "agent work").await.unwrap();

        let active: HashSet<String> = HashSet::new();
        let result = recover_repo(dir.path(), &active, &config, &git)
            .await
            .unwrap();

        assert_eq!(result.len(), 1);
        assert!(!result[0].auto_committed);
        assert!(!result[0].branch_deleted, "branch with committed work should be preserved");
    }
}
