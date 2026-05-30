use std::path::Path;

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::git::GitExecutor;

impl GitExecutor {
    // ────────────────────────────────────────────────────────────────
    // Phase 1 primitives — reset & stash
    // ────────────────────────────────────────────────────────────────

    /// Hard-reset the current branch to a commit, discarding the working
    /// tree and index. Used as a rollback primitive — NEVER surface this to
    /// users without safeguards; the plan's invariants forbid discarding
    /// uncommitted work except to restore a pre-op state.
    pub async fn reset_hard(&self, dir: &Path, target: &str) -> Result<()> {
        let _ = self.run(dir, &["reset", "--hard", target]).await?;
        Ok(())
    }

    /// Reset the index to MERGE_HEAD's state — specifically designed to
    /// undo a conflicted `merge --no-commit`. Leaves the working tree alone.
    pub async fn reset_merge(&self, dir: &Path) -> Result<()> {
        let _ = self.run(dir, &["reset", "--merge"]).await?;
        Ok(())
    }

    /// Push a stash entry with a custom message. Returns `Ok(Some(ref))`
    /// with the stash ref (e.g. `stash@{0}`) if a stash was created, or
    /// `Ok(None)` if there was nothing to stash.
    pub async fn stash_push(&self, dir: &Path, message: &str) -> Result<Option<String>> {
        // `git stash push -u -m <msg>` — -u includes untracked.
        let output = self
            .run(dir, &["stash", "push", "-u", "-m", message])
            .await?;
        // git prints "No local changes to save" (to stdout) when there's
        // nothing; on success it prints "Saved working directory..."
        if output.is_empty() || output.contains("No local changes") {
            return Ok(None);
        }
        // The ref is always stash@{0} for the most recent stash.
        Ok(Some("stash@{0}".to_string()))
    }

    /// Stash tracked + untracked changes and return a reference usable
    /// with `stash_pop`.
    ///
    /// Implementation: `git stash push -u -m <msg>` places the entry at
    /// `stash@{0}`. We return that ref directly. The coordinator's
    /// per-repo lock ensures no parallel stash operations can shift our
    /// entry before `stash_pop` runs. Crash recovery reads the same ref
    /// from the sidecar file and pops it — if the user manually pushed
    /// another stash on top during the crash window, recovery falls back
    /// to a warning rather than popping the wrong entry.
    ///
    /// Used by `rebase_on_main` when the worktree is dirty at call time.
    pub async fn stash_create_with_untracked(&self, dir: &Path, message: &str) -> Result<String> {
        let _ = self
            .run(dir, &["stash", "push", "-u", "-m", message])
            .await?;
        Ok("stash@{0}".to_string())
    }

    /// Drop a specific stash entry. Idempotent-ish: git returns a non-zero
    /// exit code if the stash ref doesn't exist — we treat that as success
    /// (same end state: stash is gone). Used by `continue_merge` for
    /// `MergeOrigin::StashPop` to clear the stash once conflicts are
    /// resolved and integrated into the working tree.
    pub async fn stash_drop(&self, dir: &Path, stash_ref: &str) -> Result<()> {
        let (_stdout, stderr, ok) = self.run_capture(dir, &["stash", "drop", stash_ref]).await?;
        if ok {
            return Ok(());
        }
        // Typical failure: `error: <ref> is not a valid reference` — the
        // stash is already gone. Harmless; report clean.
        let s = stderr.to_lowercase();
        if s.contains("not a valid reference") || s.contains("no stash entries") {
            return Ok(());
        }
        Err(WorktreeError::Git(format!(
            "git stash drop {stash_ref} failed: {}",
            stderr.trim()
        )))
    }

    /// Pop a specific stash entry. On success returns an empty `Vec`.
    /// On conflict returns the list of unmerged file paths and LEAVES
    /// the stash on the stack (matching `git stash pop`'s behavior — git
    /// preserves a stash when the pop produces unmerged entries so the
    /// user can retry or drop it manually).
    ///
    /// Callers distinguish "pop conflicted" from "pop failed for other
    /// reasons" by: empty vec == clean, non-empty == conflicts, `Err`
    /// == genuine git error.
    pub async fn stash_pop(&self, dir: &Path, stash_ref: &str) -> Result<Vec<String>> {
        let (_stdout, stderr, ok) = self.run_capture(dir, &["stash", "pop", stash_ref]).await?;
        if ok {
            return Ok(Vec::new());
        }
        // Non-zero exit — typically "CONFLICT: merge conflict in <path>".
        // Query the index for unmerged paths; if any, report them as the
        // conflict set. If none, the failure was something else (ref
        // missing, working tree not clean, etc.) — propagate.
        let conflicts = self.conflict_files(dir).await.unwrap_or_default();
        if conflicts.is_empty() {
            return Err(WorktreeError::Git(format!(
                "git stash pop {stash_ref} failed: {}",
                stderr.trim()
            )));
        }
        Ok(conflicts)
    }

    // ────────────────────────────────────────────────────────────────
    // Phase 1 primitives — config & refs
    // ────────────────────────────────────────────────────────────────

    /// Read a config value. Returns `Ok(None)` if the key is unset (git
    /// returns a non-zero exit code for missing keys).
    pub async fn config_get(&self, dir: &Path, key: &str) -> Result<Option<String>> {
        let (stdout, _stderr, ok) = self.run_capture(dir, &["config", "--get", key]).await?;
        if ok {
            Ok(Some(stdout.trim().to_string()))
        } else {
            Ok(None)
        }
    }

    /// Verify a ref exists (`git show-ref --verify --quiet <full-ref>`).
    ///
    /// `full_ref` must be fully qualified, e.g. `refs/heads/main`.
    pub async fn show_ref_verify(&self, dir: &Path, full_ref: &str) -> bool {
        self.run_status(dir, &["show-ref", "--verify", "--quiet", full_ref])
            .await
    }

    /// Pick the first ref from `candidates` that exists, returning its
    /// short name (e.g. `"main"`), or `None` if none exist.
    ///
    /// Used for default-branch detection (`main` or `master`).
    pub async fn for_each_ref_first_existing(
        &self,
        dir: &Path,
        candidates: &[&str],
    ) -> Option<String> {
        for c in candidates {
            let full = format!("refs/heads/{c}");
            if self.show_ref_verify(dir, &full).await {
                return Some((*c).to_string());
            }
        }
        None
    }

    /// `git rev-parse --verify <ref>` — returns `Ok(sha)` on success,
    /// `Err` if the ref is missing. Strict form of `head_commit`.
    pub async fn rev_parse_verify(&self, dir: &Path, rev: &str) -> Result<String> {
        self.run(dir, &["rev-parse", "--verify", rev]).await
    }

    /// Fast-forward-only merge. If `target` is not an ancestor of HEAD's
    /// upstream, git refuses and this returns an error; the working tree
    /// stays at its pre-merge state.
    pub async fn merge_ff_only(&self, dir: &Path, source: &str) -> Result<String> {
        let _ = self.run(dir, &["merge", "--ff-only", source]).await?;
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    // ────────────────────────────────────────────────────────────────
    // Phase 1 primitives — branch / worktree
    // ────────────────────────────────────────────────────────────────

    /// Create a new branch from a start point and check it out.
    ///
    /// Fails with `WorktreeError::BranchExists` if the branch already
    /// exists — callers that want idempotence should check first.
    pub async fn checkout_new_branch_from(
        &self,
        dir: &Path,
        new_branch: &str,
        start_point: &str,
    ) -> Result<()> {
        let (_stdout, stderr, ok) = self
            .run_capture(dir, &["checkout", "-b", new_branch, start_point])
            .await?;
        if ok {
            Ok(())
        } else if stderr.contains("already exists") {
            Err(WorktreeError::BranchExists(new_branch.to_string()))
        } else {
            Err(WorktreeError::Git(stderr))
        }
    }

    /// Force-checkout a branch or ref, discarding local changes. Used as
    /// an internal rollback primitive; unsafe to expose directly.
    pub async fn force_checkout(&self, dir: &Path, branch: &str) -> Result<()> {
        let _ = self.run(dir, &["checkout", "--force", branch]).await?;
        Ok(())
    }

    /// Update a ref to point at a new value.
    ///
    /// Thin wrapper over `git update-ref` — callers must know the ref
    /// name is fully qualified (e.g. `refs/heads/main`).
    pub async fn update_ref(&self, dir: &Path, full_ref: &str, new_sha: &str) -> Result<()> {
        let _ = self.run(dir, &["update-ref", full_ref, new_sha]).await?;
        Ok(())
    }
}
