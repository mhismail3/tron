//! Worktree CRUD — create, remove, list.

use std::path::{Path, PathBuf};

use tracing::debug;

use crate::errors::{Result, WorktreeError};
use crate::git::GitExecutor;
use crate::types::{ReleaseInfo, WorktreeConfig, WorktreeInfo};

/// Create a new worktree for a session.
///
/// Steps:
/// 1. Resolve repo root from `working_dir`
/// 2. Compute worktree path and branch name
/// 3. Create the worktree via `git worktree add`
/// 4. Ensure `.worktrees` is gitignored
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

    let prefix = &session_id[..session_id.len().min(12)];
    let branch = format!("{}{prefix}", config.branch_prefix);
    let worktree_path = repo_root
        .join(&config.base_dir_name)
        .join("session")
        .join(prefix);

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

    ensure_gitignore(&repo_root, &config.base_dir_name).await?;

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

    // Delete branch if not preserving
    let branch_preserved = if config.preserve_branches {
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

/// Ensure the worktree base dir is in `.gitignore`.
async fn ensure_gitignore(repo_root: &Path, base_dir_name: &str) -> Result<()> {
    use std::fmt::Write;
    let gitignore = repo_root.join(".gitignore");
    let pattern = format!("{base_dir_name}/");

    let content = if gitignore.exists() {
        tokio::fs::read_to_string(&gitignore).await?
    } else {
        String::new()
    };

    if content.lines().any(|l| l.trim() == pattern) {
        return Ok(());
    }

    let mut new_content = content;
    if !new_content.is_empty() && !new_content.ends_with('\n') {
        new_content.push('\n');
    }
    let _ = write!(new_content, "\n# Tron agent worktrees\n{pattern}\n");

    tokio::fs::write(&gitignore, new_content).await?;
    debug!(path = %gitignore.display(), "added {pattern} to .gitignore");
    Ok(())
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
        assert_eq!(info.branch, "session/test-session");
        assert_eq!(info.session_id, "test-session-abc");
        assert!(!info.base_commit.is_empty());
    }

    #[tokio::test]
    async fn create_updates_gitignore() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let _ = create("session-123456", dir.path(), &config, &git)
            .await
            .unwrap();

        let gitignore = std::fs::read_to_string(dir.path().join(".gitignore")).unwrap();
        assert!(gitignore.contains(".worktrees/"));
    }

    #[tokio::test]
    async fn create_gitignore_idempotent() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let _ = create("session-aaaa1234", dir.path(), &config, &git)
            .await
            .unwrap();

        // Remove worktree so we can create another
        let wt_path = dir
            .path()
            .join(".worktrees")
            .join("session")
            .join("session-");
        let _ = git.worktree_remove(dir.path(), &wt_path, true).await;
        let _ = git
            .branch_delete(dir.path(), "session/session-", true)
            .await;

        let _ = create("session-bbbb5678", dir.path(), &config, &git)
            .await
            .unwrap();

        let gitignore = std::fs::read_to_string(dir.path().join(".gitignore")).unwrap();
        let count = gitignore.matches(".worktrees/").count();
        assert_eq!(count, 1, "gitignore should not have duplicates");
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
        assert!(release.branch_preserved);
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
    async fn create_not_git_repo() {
        let dir = tempdir().unwrap();
        let git = GitExecutor::new(30_000);
        let config = WorktreeConfig::default();

        let result = create("sess-nogit", dir.path(), &config, &git).await;
        assert!(matches!(result, Err(WorktreeError::NotGitRepo(_))));
    }
}
