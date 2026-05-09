//! Orphan cleanup on server restart.
//!
//! Scans for worktrees with branches matching the session prefix
//! that don't belong to any active session.
//!
//! Also scans active session worktrees for in-progress merges/rebases
//! (`.git/MERGE_HEAD`, `.git/rebase-merge/`) and reconstructs
//! `PendingMergeState` entries so the coordinator's conflict-resolution
//! state survives a crash mid-merge.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use tracing::{debug, info, warn};

use crate::domains::worktree::errors::Result;
use crate::domains::worktree::git::GitExecutor;
use crate::domains::worktree::types::{
    MergeOrigin, MergeStrategy, PendingMergeState, WorktreeConfig, WorktreeInfo,
};

/// Information about a recovered orphan worktree.
#[derive(Clone, Debug)]
pub struct RecoveredWorktree {
    /// Path of the removed worktree.
    pub path: String,
    /// Branch name.
    pub branch: String,
    /// Whether changes were auto-committed before removal.
    pub auto_committed: bool,
    /// SHA of the auto-recovery commit, when [`Self::auto_committed`]
    /// is `true`. `None` otherwise. Surfaces through the
    /// `worktree.auto_recovered_commits` event so iOS can offer the
    /// user a recoverable-commit notice.
    pub auto_committed_sha: Option<String>,
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
        let mut auto_committed_sha: Option<String> = None;

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
                    auto_committed_sha = Some(sha);
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
                Ok(mb) => {
                    git.commit_count_between(repo_root, &mb, branch)
                        .await
                        .unwrap_or(0)
                        > 0
                }
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
            auto_committed_sha,
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

/// Scan a session's worktree for an in-progress merge or rebase and
/// return a reconstructed `PendingMergeState` if one exists.
///
/// Source of truth is `.git/MERGE_HEAD` (for merges) or `.git/rebase-merge/`
/// (for rebases). These stick around across a server restart, so we can
/// surface them to the UI and let the user decide whether to continue or
/// abort.
///
/// Best-effort: if we can't read any metadata (e.g. MERGE_MSG missing) we
/// still return a `PendingMergeState` with placeholder source/target.
pub async fn reconstruct_pending_merge(
    info: &WorktreeInfo,
    git: &GitExecutor,
) -> Option<PendingMergeState> {
    let has_merge = git
        .has_merge_in_progress(&info.worktree_path)
        .await
        .unwrap_or(false);
    let has_rebase = git
        .has_rebase_in_progress(&info.worktree_path)
        .await
        .unwrap_or(false);
    if !has_merge && !has_rebase {
        return None;
    }

    let strategy = if has_rebase {
        MergeStrategy::Rebase
    } else {
        MergeStrategy::Merge
    };

    // Best-effort source/target recovery.
    let (source_branch, target_branch) = recover_merge_source_target(&info.worktree_path, git)
        .await
        .unwrap_or_else(|| (info.branch.clone(), default_target_branch(info)));

    let started_at_ms = file_mtime_ms(
        info.worktree_path
            .join(if has_rebase {
                ".git/rebase-merge"
            } else {
                ".git/MERGE_HEAD"
            })
            .as_path(),
    )
    .unwrap_or_else(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    });

    Some(PendingMergeState {
        session_id: info.session_id.clone(),
        source_branch,
        target_branch,
        strategy,
        started_at_ms,
        crash_recovered: true,
        // Default `origin` / `auto_stash_ref` — coordinator-level
        // `rebuild_pending_merges` overlays sidecar data when present
        // (rebase_on_main writes the sidecar before touching git).
        origin: MergeOrigin::Finalize,
        auto_stash_ref: None,
    })
}

/// Best-effort extraction of `(source, target)` for an in-progress merge.
///
/// Tries `.git/MERGE_MSG` first (git writes `Merge branch 'foo' into bar`
/// style content) then `.git/rebase-merge/head-name` + `onto_name`.
async fn recover_merge_source_target(
    worktree: &Path,
    git: &GitExecutor,
) -> Option<(String, String)> {
    let git_dir: PathBuf = git.git_dir_path(worktree).await.ok()?;

    // Merge form.
    if let Ok(msg) = std::fs::read_to_string(git_dir.join("MERGE_MSG"))
        && let Some((src, tgt)) = parse_merge_msg(&msg)
    {
        return Some((src, tgt));
    }

    // Rebase form.
    let rb = git_dir.join("rebase-merge");
    if rb.is_dir() {
        let head_name = std::fs::read_to_string(rb.join("head-name"))
            .ok()
            .map(|s| s.trim().trim_start_matches("refs/heads/").to_string());
        let onto_name = std::fs::read_to_string(rb.join("onto_name"))
            .ok()
            .map(|s| s.trim().to_string())
            .or_else(|| std::fs::read_to_string(rb.join("onto")).ok());
        if let (Some(src), Some(tgt)) = (head_name, onto_name) {
            return Some((src, tgt.trim().to_string()));
        }
    }
    None
}

/// Extract source/target from a MERGE_MSG file body.
///
/// Examples the parser accepts:
/// - `Merge branch 'feature/a' into main`
/// - `Merge branch 'feature/a'` (target defaults to `main`)
fn parse_merge_msg(msg: &str) -> Option<(String, String)> {
    let first = msg.lines().next()?;
    // Crude but reliable: look for single-quoted source.
    let src_start = first.find('\'')?;
    let src_end = first[src_start + 1..].find('\'')?;
    let source = first[src_start + 1..src_start + 1 + src_end].to_string();

    let after = &first[src_start + 1 + src_end + 1..];
    let target = after
        .split_whitespace()
        .nth(1) // "into <branch>"
        .map(std::string::ToString::to_string)
        .unwrap_or_else(|| "main".to_string());
    Some((source, target))
}

fn default_target_branch(info: &WorktreeInfo) -> String {
    info.base_branch.clone().unwrap_or_else(|| "main".into())
}

fn file_mtime_ms(path: &Path) -> Option<i64> {
    let md = std::fs::metadata(path).ok()?;
    let mt = md.modified().ok()?;
    let d = mt.duration_since(UNIX_EPOCH).ok()?;
    Some(d.as_millis() as i64)
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
        assert!(
            result[0].branch_deleted,
            "empty orphan branch should be deleted"
        );
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
        let sha = result[0]
            .auto_committed_sha
            .as_deref()
            .expect("auto_committed_sha must be populated when auto_committed is true");
        assert_eq!(sha.len(), 40, "expected a full-length git sha, got {sha:?}");
        assert!(
            sha.chars().all(|c| c.is_ascii_hexdigit()),
            "sha must be hexadecimal: {sha:?}"
        );
        assert!(
            !result[0].branch_deleted,
            "branch with auto-committed work should be preserved"
        );
    }

    #[tokio::test]
    async fn recover_leaves_sha_none_when_no_dirty_changes() {
        // Clean orphan: no commit is made, so the SHA must remain None
        // regardless of branch_deleted outcome. Prevents a regression
        // where a callsite forgets to guard on `auto_committed` and
        // emits a ghost event with an empty sha.
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let wt_path = dir
            .path()
            .join(".worktrees")
            .join("session")
            .join("clean-orphan");
        git.worktree_add(dir.path(), &wt_path, "session/clean-orphan", "HEAD")
            .await
            .unwrap();

        let active: HashSet<String> = HashSet::new();
        let result = recover_repo(dir.path(), &active, &config, &git)
            .await
            .unwrap();

        assert_eq!(result.len(), 1);
        assert!(!result[0].auto_committed);
        assert!(
            result[0].auto_committed_sha.is_none(),
            "no commit made, sha must be None"
        );
    }

    #[tokio::test]
    async fn recover_skips_renamed_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let config = WorktreeConfig::default();

        let wt_path = dir.path().join(".worktrees").join("session").join("abc123");
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
    async fn reconstruct_pending_merge_from_merge_head() {
        use crate::domains::worktree::test_fixtures as tf;
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        tf::make_conflict(dir.path(), "a", "b", "f.txt").await;
        // Kick off a conflicting merge without aborting.
        crate::domains::worktree::conflict::start_merge_keep_conflicts(
            dir.path(),
            "sess-1",
            "b",
            "a",
            crate::domains::worktree::types::MergeStrategy::Merge,
            crate::domains::worktree::types::MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        // Simulate coordinator restart: fabricate a WorktreeInfo pointing
        // at the same dir (no worktree separation in this test).
        let info = WorktreeInfo {
            session_id: "sess-1".into(),
            worktree_path: dir.path().to_path_buf(),
            branch: "b".into(),
            base_commit: git.head_commit(dir.path()).await.unwrap(),
            base_branch: Some("a".into()),
            original_working_dir: dir.path().to_path_buf(),
            repo_root: dir.path().to_path_buf(),
        };
        let pending = reconstruct_pending_merge(&info, &git)
            .await
            .expect("pending merge must be reconstructed");
        assert_eq!(pending.session_id, "sess-1");
        assert!(pending.crash_recovered);
        assert_eq!(pending.strategy, MergeStrategy::Merge);
    }

    #[tokio::test]
    async fn reconstruct_pending_merge_none_when_clean() {
        use crate::domains::worktree::test_fixtures as tf;
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        let info = WorktreeInfo {
            session_id: "sess-clean".into(),
            worktree_path: dir.path().to_path_buf(),
            branch: "main".into(),
            base_commit: git.head_commit(dir.path()).await.unwrap(),
            base_branch: Some("main".into()),
            original_working_dir: dir.path().to_path_buf(),
            repo_root: dir.path().to_path_buf(),
        };
        assert!(reconstruct_pending_merge(&info, &git).await.is_none());
    }

    #[test]
    fn parse_merge_msg_shapes() {
        assert_eq!(
            parse_merge_msg("Merge branch 'feature/a' into main\n"),
            Some(("feature/a".to_string(), "main".to_string()))
        );
        assert_eq!(
            parse_merge_msg("Merge branch 'foo'"),
            Some(("foo".to_string(), "main".to_string()))
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
        assert!(
            !result[0].branch_deleted,
            "branch with committed work should be preserved"
        );
    }
}
