//! Conflict state machine for `merge` and `rebase`.
//!
//! The caller drives a five-step state machine:
//!
//! ```text
//!   start_merge_keep_conflicts   (A)
//!            │
//!            ▼                      repeat for each file
//!     list_conflicts  ──►   resolve_conflict  ──►  list_conflicts ...
//!            │
//!            ▼
//!     continue_merge  (commits)
//!            │
//!            └──►  abort_conflict_merge  (if resolution fails)
//! ```
//!
//! Unlike `merge_session` in `merge.rs`, these functions DO NOT auto-abort
//! on conflict. The whole point is to keep the merge state in place so the
//! user (or a conflict-resolver subagent) can resolve it incrementally.
//!
//! Source of truth for "is there a merge in progress" is the on-disk
//! `.git/MERGE_HEAD` / `.git/rebase-merge/`. This lets us reconstruct
//! state after a server crash.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use tracing::{debug, warn};

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::git::GitExecutor;
use crate::domains::worktree::types::{
    ConflictResolution, ConflictedFile, MergeOrigin, MergeStrategy, PendingMergeState,
};

/// Start a merge or rebase that deliberately preserves conflict state when
/// the operation produces conflicts. Returns a `PendingMergeState` the
/// caller should stash in the coordinator for recovery.
///
/// Semantics:
/// - **Merge**: `git merge --no-ff <source>` from `target` (caller must be
///   on `target` or this will checkout it first). On clean merge, returns a
///   `PendingMergeState` anyway — the caller inspects
///   `has_merge_in_progress` to know whether conflicts actually happened.
/// - **Rebase**: `git rebase <target>` from `source` (checks `source` out
///   first). Same deal: caller checks `has_rebase_in_progress`.
/// - **Squash**: `git merge --squash <source>` from `target`. Uses the
///   same merge-in-progress file mechanics as a regular merge when it
///   conflicts.
pub async fn start_merge_keep_conflicts(
    repo: &Path,
    session_id: &str,
    source_branch: &str,
    target_branch: &str,
    strategy: MergeStrategy,
    origin: MergeOrigin,
    git: &GitExecutor,
) -> Result<PendingMergeState> {
    match strategy {
        MergeStrategy::Merge => {
            git.checkout(repo, target_branch).await?;
            let _ = git.merge(repo, source_branch).await; // ignore — conflicts are expected
        }
        MergeStrategy::Rebase => {
            git.checkout(repo, source_branch).await?;
            let _ = git.rebase(repo, target_branch).await; // ignore — conflicts expected
        }
        MergeStrategy::Squash => {
            git.checkout(repo, target_branch).await?;
            let _ = git.squash_merge(repo, source_branch).await;
        }
    }

    Ok(PendingMergeState {
        session_id: session_id.to_string(),
        source_branch: source_branch.to_string(),
        target_branch: target_branch.to_string(),
        strategy,
        started_at_ms: now_ms(),
        crash_recovered: false,
        origin,
        auto_stash_ref: None,
    })
}

/// List all unresolved conflicts with their stage contents.
///
/// `strategy` is used only for logging — git's in-tree state is the same
/// shape for merges and rebases.
pub async fn list_conflicts(
    repo: &Path,
    strategy: MergeStrategy,
    git: &GitExecutor,
) -> Result<Vec<ConflictedFile>> {
    let paths = git.conflict_files(repo).await?;
    let mut out = Vec::with_capacity(paths.len());
    for p in paths {
        match git.conflict_sections(repo, &p).await {
            Ok(cf) => out.push(cf),
            Err(e) => warn!(path = %p, ?strategy, ?e, "conflict_sections failed"),
        }
    }
    Ok(out)
}

/// Apply a `ConflictResolution` to a single path.
///
/// `MarkResolved` assumes the caller already wrote the desired content to
/// the working-tree copy of `path` and just needs the stage cleared via
/// `git add`.
pub async fn resolve_conflict(
    repo: &Path,
    path: &str,
    resolution: ConflictResolution,
    git: &GitExecutor,
) -> Result<()> {
    debug!(?resolution, path, "resolve_conflict");
    match resolution {
        ConflictResolution::Ours => git.checkout_ours(repo, path).await,
        ConflictResolution::Theirs => git.checkout_theirs(repo, path).await,
        ConflictResolution::MarkResolved => {
            // `git add --` clears the unmerged entry and stages the current
            // working-tree content. Works for both content- and binary-
            // conflict resolutions the caller prepared manually.
            let _ = git.run(repo, &["add", "--", path]).await?;
            Ok(())
        }
    }
}

/// Finalise a merge/rebase that has all conflicts resolved. Returns the
/// merge commit sha.
///
/// Errors (without leaving half-state) if there are still unresolved files.
pub async fn continue_merge(
    repo: &Path,
    strategy: MergeStrategy,
    message: Option<&str>,
    git: &GitExecutor,
) -> Result<String> {
    let remaining = git.conflict_files(repo).await.unwrap_or_default();
    if !remaining.is_empty() {
        return Err(WorktreeError::Git(format!(
            "cannot continue: {} unresolved file(s): {}",
            remaining.len(),
            remaining.join(", ")
        )));
    }

    match strategy {
        MergeStrategy::Merge | MergeStrategy::Squash => git.merge_continue(repo, message).await,
        MergeStrategy::Rebase => {
            // A rebase may apply multiple commits sequentially; each pick
            // can itself conflict. Loop: call `rebase --continue`, then if
            // the rebase is still in progress OR new conflict markers
            // appeared, surface a `MergeConflicts` error back to the
            // caller so it can resolve the next slice before retrying.
            // Callers drive the state machine; this function does NOT
            // auto-resolve successive picks.
            git.rebase_continue(repo).await?;
            if git.has_rebase_in_progress(repo).await.unwrap_or(false) {
                let more = git.conflict_files(repo).await.unwrap_or_default();
                return Err(WorktreeError::MergeConflicts(more.len()));
            }
            // Rebase finished — current branch tip is the new HEAD.
            git.rev_parse_verify(repo, "HEAD").await
        }
    }
}

/// Abort the in-progress merge or rebase, returning the worktree to its
/// pre-op state (modulo any stashed WIP the caller created).
pub async fn abort_conflict_merge(
    repo: &Path,
    strategy: MergeStrategy,
    git: &GitExecutor,
) -> Result<()> {
    match strategy {
        MergeStrategy::Merge | MergeStrategy::Squash => {
            if git.has_merge_in_progress(repo).await.unwrap_or(false) {
                git.abort_merge(repo).await?;
            }
        }
        MergeStrategy::Rebase => {
            if git.has_rebase_in_progress(repo).await.unwrap_or(false) {
                git.abort_rebase(repo).await?;
            }
        }
    }
    Ok(())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::worktree::test_fixtures::{
        init_repo, make_binary_conflict, make_conflict, make_deleted_by_us_conflict,
        make_rename_conflict, run_cmd,
    };
    use tempfile::tempdir;

    #[tokio::test]
    async fn keep_conflict_merge_state_present() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;

        let state = start_merge_keep_conflicts(
            dir.path(),
            "sess-1",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        assert_eq!(state.session_id, "sess-1");
        assert_eq!(state.source_branch, "b");
        assert_eq!(state.target_branch, "a");
        assert!(
            git.has_merge_in_progress(dir.path()).await.unwrap(),
            "merge state must remain on disk"
        );
    }

    #[tokio::test]
    async fn list_conflicts_content_type() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        let conflicts = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert_eq!(conflicts.len(), 1);
        let cf = &conflicts[0];
        assert_eq!(cf.path, "f.txt");
        assert!(!cf.is_binary);
        assert!(cf.ours.is_some());
        assert!(cf.theirs.is_some());
    }

    #[tokio::test]
    async fn list_conflicts_binary() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_binary_conflict(dir.path(), "a", "b", "blob.bin").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        let conflicts = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert_eq!(conflicts.len(), 1);
        assert!(conflicts[0].is_binary, "binary conflict must be flagged");
    }

    #[tokio::test]
    async fn list_conflicts_deleted_by_them() {
        // Mirror of deleted_by_us: branch B deletes the file; branch A
        // modifies it. Merging A into B (or running from A's POV where
        // "theirs" is B) yields the DeletedByThem variant.
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        // Reuse make_deleted_by_us_conflict but swap the merge direction:
        // leave repo on branch B (the modifier) and merge branch A (the
        // deleter) into it. From B's perspective, "theirs" deleted.
        make_deleted_by_us_conflict(dir.path(), "deleter", "modifier", "f.txt").await;
        run_cmd(dir.path(), &["git", "checkout", "modifier"]).await;
        // Start the merge from modifier ⟵ deleter. In the coordinator
        // API this means source=deleter, target=modifier.
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "deleter",
            "modifier",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        let conflicts = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert_eq!(conflicts.len(), 1);
        use crate::domains::worktree::types::ConflictKind;
        assert_eq!(conflicts[0].kind, ConflictKind::DeletedByThem);
    }

    #[tokio::test]
    async fn list_conflicts_deleted_by_us() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_deleted_by_us_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        let conflicts = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert_eq!(conflicts.len(), 1);
        use crate::domains::worktree::types::ConflictKind;
        assert_eq!(conflicts[0].kind, ConflictKind::DeletedByUs);
    }

    #[tokio::test]
    async fn resolve_accept_ours() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        resolve_conflict(dir.path(), "f.txt", ConflictResolution::Ours, &git)
            .await
            .unwrap();

        let remaining = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert!(remaining.is_empty(), "f.txt should no longer be unmerged");
    }

    #[tokio::test]
    async fn resolve_accept_theirs() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        resolve_conflict(dir.path(), "f.txt", ConflictResolution::Theirs, &git)
            .await
            .unwrap();
        let remaining = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert!(remaining.is_empty());
        // Working tree should now hold "from B".
        let body = std::fs::read_to_string(dir.path().join("f.txt")).unwrap();
        assert_eq!(body, "from B\n");
    }

    #[tokio::test]
    async fn resolve_mark_resolved() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        // Manually write desired content.
        std::fs::write(dir.path().join("f.txt"), "hand-resolved\n").unwrap();
        resolve_conflict(dir.path(), "f.txt", ConflictResolution::MarkResolved, &git)
            .await
            .unwrap();
        let remaining = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert!(remaining.is_empty());
    }

    #[tokio::test]
    async fn continue_all_resolved() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();
        resolve_conflict(dir.path(), "f.txt", ConflictResolution::Ours, &git)
            .await
            .unwrap();

        let sha = continue_merge(dir.path(), MergeStrategy::Merge, None, &git)
            .await
            .unwrap();
        assert!(!sha.is_empty());
        assert!(!git.has_merge_in_progress(dir.path()).await.unwrap());
    }

    #[tokio::test]
    async fn continue_with_unresolved_files_errors() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        let err = continue_merge(dir.path(), MergeStrategy::Merge, None, &git)
            .await
            .expect_err("unresolved files must block continue");
        assert!(matches!(err, WorktreeError::Git(_)));
    }

    #[tokio::test]
    async fn abort_clears_merge_state() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();
        assert!(git.has_merge_in_progress(dir.path()).await.unwrap());

        abort_conflict_merge(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert!(!git.has_merge_in_progress(dir.path()).await.unwrap());
    }

    #[tokio::test]
    async fn rebase_conflict_keep_state() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        // Rebase b onto a — reverse direction from merge.
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Rebase,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();
        assert!(
            git.has_rebase_in_progress(dir.path()).await.unwrap(),
            "rebase state must be preserved"
        );
    }

    #[tokio::test]
    async fn rebase_continue_after_resolve() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Rebase,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();
        // In rebase direction b-onto-a: conflict presents with stages; pick ours.
        resolve_conflict(dir.path(), "f.txt", ConflictResolution::Ours, &git)
            .await
            .unwrap();
        continue_merge(dir.path(), MergeStrategy::Rebase, None, &git)
            .await
            .unwrap();
        assert!(!git.has_rebase_in_progress(dir.path()).await.unwrap());
    }

    #[tokio::test]
    async fn rebase_abort_clears_state() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Rebase,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();
        abort_conflict_merge(dir.path(), MergeStrategy::Rebase, &git)
            .await
            .unwrap();
        assert!(!git.has_rebase_in_progress(dir.path()).await.unwrap());
    }

    #[tokio::test]
    async fn conflict_crash_recovery_reconstructs_from_merge_head() {
        // Simulate a crash: leave .git/MERGE_HEAD in place, drop the
        // in-memory state, then re-query list_conflicts.
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();

        // "restart": no in-memory state, but on-disk MERGE_HEAD exists.
        assert!(git.has_merge_in_progress(dir.path()).await.unwrap());
        let conflicts = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        assert_eq!(conflicts.len(), 1);
    }

    #[tokio::test]
    async fn rename_conflict_reports_kind() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_rename_conflict(dir.path(), "a", "b", "orig.txt", "aa.txt", "bb.txt").await;
        start_merge_keep_conflicts(
            dir.path(),
            "s",
            "b",
            "a",
            MergeStrategy::Merge,
            MergeOrigin::Finalize,
            &git,
        )
        .await
        .unwrap();
        let conflicts = list_conflicts(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
        // git reports rename/rename as several entries; just assert we saw
        // at least one and didn't crash.
        assert!(!conflicts.is_empty(), "rename conflict must surface");
        // Clean up so we don't leave a stale merge.
        abort_conflict_merge(dir.path(), MergeStrategy::Merge, &git)
            .await
            .unwrap();
    }
}
