//! Worktree CRUD — create, remove, list.

use std::path::{Component, Path, PathBuf};

use tracing::debug;

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::git::GitExecutor;
use crate::domains::worktree::types::{ReleaseInfo, WorktreeConfig, WorktreeInfo};

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

    hydrate_working_copy_overlay(&repo_root, &worktree_path, &config.base_dir_name, git).await?;

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

async fn hydrate_working_copy_overlay(
    repo_root: &Path,
    worktree_path: &Path,
    worktree_base_dir_name: &str,
    git: &GitExecutor,
) -> Result<()> {
    let paths = git.working_copy_overlay_paths(repo_root).await?;
    for path in paths {
        let Some(relative_path) = safe_repo_relative_path(&path, worktree_base_dir_name) else {
            continue;
        };
        let source = repo_root.join(&relative_path);
        let target = worktree_path.join(&relative_path);
        if !source.exists() {
            remove_overlay_target(&target).await?;
            continue;
        }
        copy_overlay_entry(&source, &target).await?;
    }
    Ok(())
}

fn safe_repo_relative_path(path: &str, worktree_base_dir_name: &str) -> Option<PathBuf> {
    let path = Path::new(path);
    if path.is_absolute() {
        return None;
    }

    let mut out = PathBuf::new();
    let mut components = path.components();
    let first = components.next()?;
    let Component::Normal(first_os) = first else {
        return None;
    };
    if first_os == ".git" || first_os == worktree_base_dir_name {
        return None;
    }
    out.push(first_os);

    for component in components {
        let Component::Normal(part) = component else {
            return None;
        };
        out.push(part);
    }
    Some(out)
}

async fn remove_overlay_target(target: &Path) -> Result<()> {
    match tokio::fs::symlink_metadata(target).await {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
            tokio::fs::remove_dir_all(target).await?;
        }
        Ok(_) => {
            tokio::fs::remove_file(target).await?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

async fn copy_overlay_entry(source: &Path, target: &Path) -> Result<()> {
    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let metadata = tokio::fs::symlink_metadata(source).await?;
    if metadata.file_type().is_symlink() {
        #[cfg(unix)]
        {
            let link_target = tokio::fs::read_link(source).await?;
            let _ = tokio::fs::remove_file(target).await;
            std::os::unix::fs::symlink(link_target, target)?;
            return Ok(());
        }
        #[cfg(not(unix))]
        {
            return Ok(());
        }
    }
    if metadata.is_dir() {
        tokio::fs::create_dir_all(target).await?;
        return Ok(());
    }
    let _ = tokio::fs::copy(source, target).await?;
    tokio::fs::set_permissions(target, metadata.permissions()).await?;
    Ok(())
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
                // Recovery path: delete the directory and prune the worktree metadata.
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
    async fn create_hydrates_untracked_non_ignored_workspace_files() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        std::fs::write(dir.path().join("scratch.md"), "operator-visible").unwrap();
        std::fs::write(dir.path().join(".gitignore"), "ignored.log\n").unwrap();
        std::fs::write(dir.path().join("ignored.log"), "do not copy").unwrap();

        let info = create("sess-untracked", dir.path(), &config, &git)
            .await
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(info.worktree_path.join("scratch.md")).unwrap(),
            "operator-visible"
        );
        assert!(!info.worktree_path.join("ignored.log").exists());
        assert!(!info.worktree_path.join(".worktrees").exists());
    }

    #[tokio::test]
    async fn create_hydrates_modified_tracked_workspace_files() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        std::fs::write(dir.path().join("README.md"), "# modified\n").unwrap();

        let info = create("sess-modified", dir.path(), &config, &git)
            .await
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(info.worktree_path.join("README.md")).unwrap(),
            "# modified\n"
        );
    }

    #[tokio::test]
    async fn create_hydrates_tracked_deletions() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        std::fs::remove_file(dir.path().join("README.md")).unwrap();

        let info = create("sess-deleted", dir.path(), &config, &git)
            .await
            .unwrap();

        assert!(!info.worktree_path.join("README.md").exists());
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
        assert!(
            !release.branch_preserved,
            "zero-commit branch should be deleted even when preserve_branches is true"
        );

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
        assert!(
            release.branch_preserved,
            "branch with commits should be preserved"
        );

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
