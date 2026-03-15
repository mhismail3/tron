//! Merge strategies for integrating session work back into a target branch.

use std::path::Path;

use tracing::{debug, warn};

use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::git::GitExecutor;
use crate::worktree::types::{MergeResult, MergeStrategy};

/// Merge a session's branch into a target branch.
///
/// The operation is performed in the repository root (not a worktree).
/// On conflict, the merge/rebase is aborted and conflict files are returned.
pub async fn merge_session(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    strategy: MergeStrategy,
    git: &GitExecutor,
) -> Result<MergeResult> {
    // Remember current branch to restore on failure
    let original_branch = git.current_branch(repo_root).await.ok();

    let result = match strategy {
        MergeStrategy::Merge => do_merge(repo_root, source_branch, target_branch, git).await,
        MergeStrategy::Rebase => do_rebase(repo_root, source_branch, target_branch, git).await,
        MergeStrategy::Squash => do_squash(repo_root, source_branch, target_branch, git).await,
    };

    // On failure, try to restore original branch
    if result.as_ref().is_ok_and(|r| !r.success)
        && let Some(ref branch) = original_branch
    {
        let _ = git.checkout(repo_root, branch).await;
    }

    result
}

async fn do_merge(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    git: &GitExecutor,
) -> Result<MergeResult> {
    git.checkout(repo_root, target_branch).await?;

    match git.merge(repo_root, source_branch).await {
        Ok(commit) => {
            debug!(
                source = source_branch,
                target = target_branch,
                commit,
                "merge complete"
            );
            Ok(MergeResult {
                success: true,
                merge_commit: Some(commit),
                conflicts: vec![],
                strategy: MergeStrategy::Merge,
            })
        }
        Err(WorktreeError::Git(ref msg))
            if msg.contains("CONFLICT") || msg.contains("Merge conflict") =>
        {
            let conflicts = git.conflict_files(repo_root).await.unwrap_or_default();
            warn!(
                source = source_branch,
                target = target_branch,
                ?conflicts,
                "merge conflicts"
            );
            let _ = git.abort_merge(repo_root).await;
            Ok(MergeResult {
                success: false,
                merge_commit: None,
                conflicts,
                strategy: MergeStrategy::Merge,
            })
        }
        Err(e) => Err(e),
    }
}

async fn do_rebase(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    git: &GitExecutor,
) -> Result<MergeResult> {
    git.checkout(repo_root, source_branch).await?;

    match git.rebase(repo_root, target_branch).await {
        Ok(()) => {
            // Fast-forward target
            git.checkout(repo_root, target_branch).await?;
            let commit = git.merge(repo_root, source_branch).await?;
            debug!(
                source = source_branch,
                target = target_branch,
                commit,
                "rebase complete"
            );
            Ok(MergeResult {
                success: true,
                merge_commit: Some(commit),
                conflicts: vec![],
                strategy: MergeStrategy::Rebase,
            })
        }
        Err(WorktreeError::Git(ref msg))
            if msg.contains("CONFLICT") || msg.contains("could not apply") =>
        {
            let conflicts = git.conflict_files(repo_root).await.unwrap_or_default();
            warn!(
                source = source_branch,
                target = target_branch,
                ?conflicts,
                "rebase conflicts"
            );
            let _ = git.abort_rebase(repo_root).await;
            Ok(MergeResult {
                success: false,
                merge_commit: None,
                conflicts,
                strategy: MergeStrategy::Rebase,
            })
        }
        Err(e) => Err(e),
    }
}

async fn do_squash(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    git: &GitExecutor,
) -> Result<MergeResult> {
    git.checkout(repo_root, target_branch).await?;

    match git.squash_merge(repo_root, source_branch).await {
        Ok(()) => {
            let commit = git
                .commit_all(
                    repo_root,
                    &format!("squash merge {source_branch} into {target_branch}"),
                )
                .await?;
            debug!(
                source = source_branch,
                target = target_branch,
                commit,
                "squash merge complete"
            );
            Ok(MergeResult {
                success: true,
                merge_commit: Some(commit),
                conflicts: vec![],
                strategy: MergeStrategy::Squash,
            })
        }
        Err(WorktreeError::Git(ref msg)) if msg.contains("CONFLICT") => {
            let conflicts = git.conflict_files(repo_root).await.unwrap_or_default();
            warn!(
                source = source_branch,
                target = target_branch,
                ?conflicts,
                "squash merge conflicts"
            );
            let _ = git.abort_merge(repo_root).await;
            Ok(MergeResult {
                success: false,
                merge_commit: None,
                conflicts,
                strategy: MergeStrategy::Squash,
            })
        }
        Err(e) => Err(e),
    }
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

    async fn make_branch_with_commit(dir: &std::path::Path, branch: &str, file: &str) {
        run_cmd(dir, &["git", "checkout", "-b", branch]).await;
        std::fs::write(dir.join(file), format!("content of {file}")).unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", &format!("add {file}")]).await;
    }

    #[tokio::test]
    async fn merge_clean() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let main = git.current_branch(dir.path()).await.unwrap();

        make_branch_with_commit(dir.path(), "feature", "feature.txt").await;
        run_cmd(dir.path(), &["git", "checkout", &main]).await;

        let result = merge_session(dir.path(), "feature", &main, MergeStrategy::Merge, &git)
            .await
            .unwrap();

        assert!(result.success);
        assert!(result.merge_commit.is_some());
        assert!(result.conflicts.is_empty());
    }

    #[tokio::test]
    async fn squash_clean() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let main = git.current_branch(dir.path()).await.unwrap();

        make_branch_with_commit(dir.path(), "squash-feature", "squash.txt").await;
        run_cmd(dir.path(), &["git", "checkout", &main]).await;

        let result = merge_session(
            dir.path(),
            "squash-feature",
            &main,
            MergeStrategy::Squash,
            &git,
        )
        .await
        .unwrap();

        assert!(result.success);
        assert!(result.merge_commit.is_some());
        assert_eq!(result.strategy, MergeStrategy::Squash);
    }
}
