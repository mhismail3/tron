//! Worktree CRUD — create, remove, list.

use std::path::{Path, PathBuf};

use tracing::debug;

use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::git::GitExecutor;
use crate::worktree::types::{ReleaseInfo, WorktreeConfig, WorktreeInfo};

/// Create a new worktree for a session.
///
/// Steps:
/// 1. Resolve repo root from `working_dir`
/// 2. Compute worktree path and branch name
/// 3. Create the worktree via `git worktree add`
pub async fn create(
    session_id: &str,
    working_dir: &Path,
    config: &WorktreeConfig,
    git: &GitExecutor,
) -> Result<WorktreeInfo> {
    let repo_root_str = git
        .repo_root(working_dir)
        .await
        .map_err(|_| WorktreeError::NotGitRepo(working_dir.display().to_string()))?;
    let repo_root = PathBuf::from(&repo_root_str);

    let branch = format!("{}{session_id}", config.branch_prefix);
    let worktree_path = repo_root
        .join(&config.base_dir_name)
        .join("session")
        .join(session_id);

    let base_commit = git.head_commit(&repo_root).await?;
    let base_branch = git.current_branch(&repo_root).await.ok();

    debug!(
        session_id,
        branch,
        worktree_path = %worktree_path.display(),
        base_commit,
        "creating worktree"
    );

    git.worktree_add(&repo_root, &worktree_path, &branch, "HEAD")
        .await
        .map_err(|e| {
            if e.to_string().contains("already exists") {
                WorktreeError::BranchExists(branch.clone())
            } else {
                e
            }
        })?;

    let info = WorktreeInfo {
        session_id: session_id.to_string(),
        worktree_path,
        branch,
        base_commit,
        base_branch,
        original_working_dir: working_dir.to_path_buf(),
        repo_root,
    };

    debug!(
        session_id,
        worktree = %info.worktree_path.display(),
        branch = %info.branch,
        "worktree created"
    );

    Ok(info)
}

/// Remove a worktree for a session.
///
/// Steps:
/// 1. Auto-commit if configured and there are changes
/// 2. Remove worktree directory if configured
/// 3. Delete branch if configured
pub async fn remove(
    info: &WorktreeInfo,
    config: &WorktreeConfig,
    git: &GitExecutor,
) -> Result<ReleaseInfo> {
    let mut final_commit = None;

    // Auto-commit uncommitted changes
    if config.auto_commit_on_release
        && info.worktree_path.exists()
        && let Ok(true) = git.has_changes(&info.worktree_path).await
    {
        match git
            .commit_all(
                &info.worktree_path,
                &format!(
                    "[auto] session {} final commit",
                    &info.session_id[..8.min(info.session_id.len())]
                ),
            )
            .await
        {
            Ok(sha) => {
                debug!(session_id = %info.session_id, commit = %sha, "auto-committed changes");
                final_commit = Some(sha);
            }
            Err(e) => {
                tracing::warn!(
                    session_id = %info.session_id,
                    error = %e,
                    "failed to auto-commit"
                );
            }
        }
    }

    // Check if the branch has any commits over the base (used to decide branch deletion)
    let has_commits = git
        .commit_count_between(&info.repo_root, &info.base_commit, &info.branch)
        .await
        .unwrap_or(0)
        > 0;

    // Remove worktree directory
    let deleted = if config.delete_on_release && info.worktree_path.exists() {
        match git
            .worktree_remove(&info.repo_root, &info.worktree_path, true)
            .await
        {
            Ok(()) => true,
            Err(e) => {
                tracing::warn!(
                    session_id = %info.session_id,
                    error = %e,
                    "failed to remove worktree, trying force cleanup"
                );
                // Fallback: just delete the directory and prune
                if info.worktree_path.exists() {
                    let _ = tokio::fs::remove_dir_all(&info.worktree_path).await;
                }
                let _ = git.worktree_prune(&info.repo_root).await;
                true
            }
        }
    } else {
        false
    };

    // Delete branch if not preserving, or if zero commits (no point keeping empty branches)
    let branch_preserved = if config.preserve_branches && has_commits {
        true
    } else if let Err(e) = git.branch_delete(&info.repo_root, &info.branch, true).await {
        tracing::warn!(branch = %info.branch, error = %e, "failed to delete branch");
        true // branch still exists
    } else {
        false
    };

    debug!(
        session_id = %info.session_id,
        deleted,
        branch_preserved,
        "worktree released"
    );

    Ok(ReleaseInfo {
        final_commit,
        deleted,
        branch_preserved,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    async fn init_repo(dir: &Path) -> GitExecutor {
        let git = GitExecutor::new(30_000);
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
        git
    }

    async fn run_cmd(dir: &Path, args: &[&str]) {
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
    async fn create_worktree() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let info = create("test-session-abc", dir.path(), &config, &git)
            .await
            .unwrap();

        assert!(info.worktree_path.exists());
        assert_eq!(info.branch, "session/test-session-abc");
        assert_eq!(info.session_id, "test-session-abc");
        assert!(!info.base_commit.is_empty());
    }

    #[tokio::test]
    async fn create_uses_full_session_id_for_unique_branch_names() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let first = create("sess_sameprefix_aaaa", dir.path(), &config, &git)
            .await
            .unwrap();
        let second = create("sess_sameprefix_bbbb", dir.path(), &config, &git)
            .await
            .unwrap();

        assert_ne!(first.branch, second.branch);
        assert_ne!(first.worktree_path, second.worktree_path);
    }

    #[tokio::test]
    async fn remove_with_auto_commit() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let info = create("sess-autocommit", dir.path(), &config, &git)
            .await
            .unwrap();

        // Make a change in the worktree
        std::fs::write(info.worktree_path.join("new.txt"), "hello").unwrap();

        let release = remove(&info, &config, &git).await.unwrap();
        assert!(release.final_commit.is_some());
        assert!(release.deleted);
        assert!(release.branch_preserved);
    }

    #[tokio::test]
    async fn remove_clean_worktree() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let info = create("sess-clean123", dir.path(), &config, &git)
            .await
            .unwrap();

        let release = remove(&info, &config, &git).await.unwrap();
        assert!(release.final_commit.is_none());
        assert!(release.deleted);
        // Zero-commit branches are auto-pruned even when preserve_branches is true
        assert!(!release.branch_preserved);
    }

    #[tokio::test]
    async fn remove_deletes_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig {
            preserve_branches: false,
            ..WorktreeConfig::default()
        };

        let info = create("sess-delbranch", dir.path(), &config, &git)
            .await
            .unwrap();
        let branch = info.branch.clone();

        let release = remove(&info, &config, &git).await.unwrap();
        assert!(release.deleted);
        assert!(!release.branch_preserved);

        // Verify branch is gone
        let entries = git.worktree_list(dir.path()).await.unwrap();
        assert!(entries.iter().all(|e| e.branch.as_deref() != Some(&branch)));
    }

    #[tokio::test]
    async fn create_nested_working_dir() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let sub = dir.path().join("src").join("lib");
        std::fs::create_dir_all(&sub).unwrap();

        let info = create("sess-nested1", &sub, &config, &git).await.unwrap();
        assert!(info.worktree_path.exists());
        assert_eq!(
            info.repo_root.canonicalize().unwrap(),
            dir.path().canonicalize().unwrap()
        );
    }

    #[tokio::test]
    async fn remove_deletes_zero_commit_branch_even_when_preserving() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig {
            preserve_branches: true,
            ..WorktreeConfig::default()
        };

        let info = create("sess-zerocommit", dir.path(), &config, &git)
            .await
            .unwrap();
        let branch = info.branch.clone();

        // No changes made — zero commits over base
        let release = remove(&info, &config, &git).await.unwrap();
        assert!(release.deleted);
        assert!(!release.branch_preserved, "zero-commit branch should be deleted even when preserve_branches is true");

        // Verify branch is actually gone
        let branches = git
            .list_branches_matching(dir.path(), "session/*")
            .await
            .unwrap();
        assert!(!branches.contains(&branch));
    }

    #[tokio::test]
    async fn remove_preserves_branch_with_commits() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig {
            preserve_branches: true,
            ..WorktreeConfig::default()
        };

        let info = create("sess-withcommits", dir.path(), &config, &git)
            .await
            .unwrap();
        let branch = info.branch.clone();

        // Make a change and commit it
        std::fs::write(info.worktree_path.join("change.txt"), "content").unwrap();
        run_cmd(&info.worktree_path, &["git", "add", "-A"]).await;
        run_cmd(&info.worktree_path, &["git", "commit", "-m", "real work"]).await;

        let release = remove(&info, &config, &git).await.unwrap();
        assert!(release.deleted);
        assert!(release.branch_preserved, "branch with commits should be preserved");

        // Verify branch still exists
        let branches = git
            .list_branches_matching(dir.path(), "session/*")
            .await
            .unwrap();
        assert!(branches.contains(&branch));
    }

    #[tokio::test]
    async fn create_not_git_repo() {
        let dir = tempdir().unwrap();
        let git = GitExecutor::new(30_000);
        let config = WorktreeConfig::default();

        let result = create("sess-nogit", dir.path(), &config, &git).await;
        assert!(matches!(result, Err(WorktreeError::NotGitRepo(_))));
    }
}
