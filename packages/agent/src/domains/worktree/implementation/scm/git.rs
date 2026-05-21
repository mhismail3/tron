//! Low-level git command execution.
//!
//! Wraps `tokio::process::Command` with configurable timeout.
//! All commands capture stdout/stderr and return structured results.

use std::path::Path;
use std::time::Duration;

use tracing::{debug, warn};

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::types::{CommitOptions, ConflictKind, ConflictedFile, PushOutput};

/// Parsed entry from `git worktree list --porcelain`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorktreeListEntry {
    /// Absolute path to the worktree.
    pub path: String,
    /// HEAD commit hash.
    pub head: String,
    /// Branch name (None for detached HEAD).
    pub branch: Option<String>,
    /// Whether this is bare.
    pub bare: bool,
}

/// Git command executor with timeout.
#[derive(Clone, Debug)]
pub struct GitExecutor {
    timeout: Duration,
}

impl GitExecutor {
    /// Create a new executor with the given timeout.
    pub fn new(timeout_ms: u64) -> Self {
        Self {
            timeout: Duration::from_millis(timeout_ms),
        }
    }

    /// Check if a path is inside a git repository.
    pub async fn is_git_repo(&self, path: &Path) -> bool {
        self.run_status(path, &["rev-parse", "--git-dir"]).await
    }

    /// Get the root of the repository containing `path`.
    pub async fn repo_root(&self, path: &Path) -> Result<String> {
        self.run(path, &["rev-parse", "--show-toplevel"]).await
    }

    /// Get the HEAD commit hash.
    pub async fn head_commit(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Check whether the repository has at least one commit.
    ///
    /// Returns `false` for empty repos (after `git init` with no commits)
    /// and for non-git directories.
    pub async fn has_commits(&self, path: &Path) -> bool {
        self.run_status(path, &["rev-parse", "--verify", "HEAD"])
            .await
    }

    /// Get the current branch name (None-ish error for detached HEAD).
    pub async fn current_branch(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["symbolic-ref", "--short", "HEAD"]).await
    }

    /// Add a new worktree with a new branch.
    pub async fn worktree_add(
        &self,
        repo: &Path,
        path: &Path,
        branch: &str,
        start_point: &str,
    ) -> Result<()> {
        let path_str = path.to_string_lossy();
        let _ = self
            .run(
                repo,
                &["worktree", "add", "-b", branch, &path_str, start_point],
            )
            .await?;
        Ok(())
    }

    /// Remove a worktree.
    pub async fn worktree_remove(&self, repo: &Path, path: &Path, force: bool) -> Result<()> {
        let path_str = path.to_string_lossy();
        let args = if force {
            vec!["worktree", "remove", "--force", &path_str]
        } else {
            vec!["worktree", "remove", &path_str]
        };
        let _ = self.run(repo, &args).await?;
        Ok(())
    }

    /// List worktrees in porcelain format.
    pub async fn worktree_list(&self, repo: &Path) -> Result<Vec<WorktreeListEntry>> {
        let output = self.run(repo, &["worktree", "list", "--porcelain"]).await?;
        Ok(parse_worktree_porcelain(&output))
    }

    /// Prune stale worktree references.
    pub async fn worktree_prune(&self, repo: &Path) -> Result<()> {
        let _ = self.run(repo, &["worktree", "prune"]).await?;
        Ok(())
    }

    /// Delete a branch.
    pub async fn branch_delete(&self, repo: &Path, branch: &str, force: bool) -> Result<()> {
        let flag = if force { "-D" } else { "-d" };
        let _ = self.run(repo, &["branch", flag, branch]).await?;
        Ok(())
    }

    /// Rename a branch.
    pub async fn branch_rename(&self, repo: &Path, old_name: &str, new_name: &str) -> Result<()> {
        let _ = self
            .run(repo, &["branch", "-m", old_name, new_name])
            .await?;
        Ok(())
    }

    /// Create a new branch ref pointing at `start_point` WITHOUT checking
    /// it out. Fails with `BranchExists` if the branch already exists.
    pub async fn branch_create_from(
        &self,
        repo: &Path,
        new_branch: &str,
        start_point: &str,
    ) -> Result<()> {
        let (_stdout, stderr, ok) = self
            .run_capture(repo, &["branch", new_branch, start_point])
            .await?;
        if ok {
            Ok(())
        } else if stderr.contains("already exists") {
            Err(WorktreeError::BranchExists(new_branch.to_string()))
        } else {
            Err(WorktreeError::Git(stderr))
        }
    }

    /// Check if there are uncommitted changes.
    pub async fn has_changes(&self, dir: &Path) -> Result<bool> {
        let output = self.run(dir, &["status", "--porcelain"]).await?;
        Ok(!output.is_empty())
    }

    /// Paths whose working-copy state differs from `HEAD`.
    ///
    /// Includes tracked modifications/deletions plus untracked, non-ignored
    /// files. Callers use this to seed a newly isolated session worktree with
    /// the operator-visible workspace state instead of bare `HEAD` alone.
    pub async fn working_copy_overlay_paths(&self, dir: &Path) -> Result<Vec<String>> {
        let mut paths = Vec::new();
        let tracked = self
            .run_stdout_bytes(dir, &["diff", "--name-only", "-z", "HEAD", "--"])
            .await?;
        paths.extend(parse_nul_paths(&tracked));

        let untracked = self
            .run_stdout_bytes(dir, &["ls-files", "--others", "--exclude-standard", "-z"])
            .await?;
        paths.extend(parse_nul_paths(&untracked));

        paths.sort();
        paths.dedup();
        Ok(paths)
    }

    /// Get diff stat.
    pub async fn diff_stat(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["diff", "--stat"]).await
    }

    /// Stage all and commit.
    ///
    /// Thin wrapper over [`commit_with_options`] that preserves the original
    /// "stage everything, no amend, no signoff" behavior relied on by
    /// lifecycle/recovery paths. New callers should prefer
    /// [`commit_with_options`] and pass flags explicitly.
    pub async fn commit_all(&self, dir: &Path, message: &str) -> Result<String> {
        self.commit_with_options(dir, message, &CommitOptions::default_stage_all())
            .await
    }

    /// Commit with caller-chosen flags.
    ///
    /// Behavior:
    /// - `opts.stage_all`: run `git add -A` before commit. Omit to commit only
    ///   the existing index.
    /// - `opts.amend`: append `--amend` so the previous HEAD commit is
    ///   rewritten in place.
    /// - `opts.signoff`: append `--signoff` so a `Signed-off-by:` trailer is
    ///   added by git.
    ///
    /// Returns the new HEAD SHA. Errors propagate `WorktreeError::Git` with
    /// the raw git stderr so the caller (and ultimately the UI) can surface
    /// it. The `message` is passed via `-m`, so leading dashes and embedded
    /// newlines are preserved as-is.
    pub async fn commit_with_options(
        &self,
        dir: &Path,
        message: &str,
        opts: &CommitOptions,
    ) -> Result<String> {
        if opts.stage_all {
            let _ = self.run(dir, &["add", "-A"]).await?;
        }
        let mut args: Vec<&str> = vec!["commit", "-m", message];
        if opts.amend {
            args.push("--amend");
        }
        if opts.signoff {
            args.push("--signoff");
        }
        let _ = self.run(dir, &args).await?;
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Merge a branch (--no-ff).
    pub async fn merge(&self, dir: &Path, branch: &str) -> Result<String> {
        let _ = self.run(dir, &["merge", "--no-ff", branch]).await?;
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Rebase onto a branch.
    pub async fn rebase(&self, dir: &Path, onto: &str) -> Result<()> {
        let _ = self.run(dir, &["rebase", onto]).await?;
        Ok(())
    }

    /// Squash merge a branch.
    pub async fn squash_merge(&self, dir: &Path, branch: &str) -> Result<()> {
        let _ = self.run(dir, &["merge", "--squash", branch]).await?;
        Ok(())
    }

    /// Abort an in-progress merge.
    pub async fn abort_merge(&self, dir: &Path) -> Result<()> {
        let _ = self.run(dir, &["merge", "--abort"]).await?;
        Ok(())
    }

    /// Abort an in-progress rebase.
    pub async fn abort_rebase(&self, dir: &Path) -> Result<()> {
        let _ = self.run(dir, &["rebase", "--abort"]).await?;
        Ok(())
    }

    /// Checkout a branch.
    pub async fn checkout(&self, dir: &Path, branch: &str) -> Result<()> {
        let _ = self.run(dir, &["checkout", branch]).await?;
        Ok(())
    }

    /// Get list of conflicting files during a merge.
    pub async fn conflict_files(&self, dir: &Path) -> Result<Vec<String>> {
        let output = self
            .run(dir, &["diff", "--name-only", "--diff-filter=U"])
            .await?;
        Ok(output
            .lines()
            .map(std::string::ToString::to_string)
            .collect())
    }

    /// Count commits since a base commit (inclusive of commits after base, exclusive of base).
    pub async fn commit_count_since(&self, dir: &Path, base_commit: &str) -> Result<usize> {
        let range = format!("{base_commit}..HEAD");
        let output = self.run(dir, &["rev-list", "--count", &range]).await?;
        output.parse::<usize>().map_err(|e| {
            WorktreeError::Git(format!("failed to parse commit count '{output}': {e}"))
        })
    }

    /// Get list of files changed since a commit (compared to HEAD).
    pub async fn changed_files_since(&self, dir: &Path, base_commit: &str) -> Result<Vec<String>> {
        let output = self
            .run(dir, &["diff", "--name-only", base_commit, "HEAD"])
            .await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(std::string::ToString::to_string)
            .collect())
    }

    /// Get diff stat summary (insertions, deletions) between two refs.
    pub async fn diff_numstat_total(
        &self,
        dir: &Path,
        base: &str,
        head: &str,
    ) -> Result<(usize, usize)> {
        let output = self.run(dir, &["diff", "--numstat", base, head]).await?;
        let mut insertions = 0usize;
        let mut deletions = 0usize;
        for line in output.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 2 {
                // Binary files show "-" for insertions/deletions
                insertions += parts[0].parse::<usize>().unwrap_or(0);
                deletions += parts[1].parse::<usize>().unwrap_or(0);
            }
        }
        Ok((insertions, deletions))
    }

    /// List branches matching a glob pattern.
    pub async fn list_branches_matching(&self, repo: &Path, pattern: &str) -> Result<Vec<String>> {
        let output = self
            .run(
                repo,
                &["branch", "--list", pattern, "--format=%(refname:short)"],
            )
            .await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.trim().to_string())
            .collect())
    }

    /// List branches on a remote. Returns the branch name with the remote
    /// prefix stripped (e.g. `origin/main` → `main`) and filters the
    /// pseudo-ref `HEAD`. Used for the Merge Changes target picker so only
    /// published/shared branches are offered as merge targets.
    pub async fn list_remote_branches(&self, repo: &Path, remote: &str) -> Result<Vec<String>> {
        let pattern = format!("refs/remotes/{remote}/");
        let output = self
            .run(
                repo,
                &["for-each-ref", "--format=%(refname:short)", &pattern],
            )
            .await?;
        let prefix = format!("{remote}/");
        let mut names: Vec<String> = output
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.trim())
            .filter_map(|l| l.strip_prefix(&prefix).map(str::to_string))
            .filter(|name| name != "HEAD")
            .collect();
        names.sort();
        names.dedup();
        Ok(names)
    }

    /// Get log entries for a branch: (hash, message, date).
    pub async fn branch_log(
        &self,
        repo: &Path,
        branch: &str,
        count: usize,
    ) -> Result<Vec<(String, String, String)>> {
        let count_str = format!("-{count}");
        let output = self
            .run(
                repo,
                &["log", &count_str, "--format=%H%x00%s%x00%aI", branch],
            )
            .await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .filter_map(|line| {
                let mut parts = line.splitn(3, '\0');
                let hash = parts.next()?.to_string();
                let message = parts.next()?.to_string();
                let date = parts.next()?.to_string();
                Some((hash, message, date))
            })
            .collect())
    }

    /// Find the merge base of two refs.
    pub async fn merge_base(&self, repo: &Path, a: &str, b: &str) -> Result<String> {
        self.run(repo, &["merge-base", a, b]).await
    }

    /// Get unified diff between two refs.
    pub async fn diff_between(&self, repo: &Path, base: &str, head: &str) -> Result<String> {
        let range = format!("{base}..{head}");
        self.run(repo, &["diff", &range]).await
    }

    /// Count commits between base (exclusive) and head (inclusive).
    pub async fn commit_count_between(&self, repo: &Path, base: &str, head: &str) -> Result<usize> {
        let range = format!("{base}..{head}");
        let output = self.run(repo, &["rev-list", "--count", &range]).await?;
        output.parse::<usize>().map_err(|e| {
            WorktreeError::Git(format!("failed to parse commit count '{output}': {e}"))
        })
    }

    /// Get (status, path) pairs between two refs via `git diff --name-status`.
    pub async fn diff_name_status(
        &self,
        repo: &Path,
        base: &str,
        head: &str,
    ) -> Result<Vec<(String, String)>> {
        let range = format!("{base}..{head}");
        let output = self.run(repo, &["diff", "--name-status", &range]).await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .filter_map(|line| {
                let mut parts = line.splitn(2, '\t');
                let status = parts.next()?.trim().to_string();
                let path = parts.next()?.trim().to_string();
                Some((status, path))
            })
            .collect())
    }

    /// Check if `potential_ancestor` is an ancestor of `branch`.
    ///
    /// Uses `git merge-base --is-ancestor` which returns exit 0 if true, 1 if not.
    pub async fn is_ancestor(&self, repo: &Path, potential_ancestor: &str, branch: &str) -> bool {
        self.run_status(
            repo,
            &["merge-base", "--is-ancestor", potential_ancestor, branch],
        )
        .await
    }

    // ────────────────────────────────────────────────────────────────
    // Phase 1 primitives — remote operations
    // ────────────────────────────────────────────────────────────────

    /// List configured remote names (e.g. `["origin"]`).
    pub async fn remote_list(&self, repo: &Path) -> Result<Vec<String>> {
        let output = self.run(repo, &["remote"]).await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(std::string::ToString::to_string)
            .collect())
    }

    /// Get the URL for a named remote (`origin` by default if caller wants).
    pub async fn remote_get_url(&self, repo: &Path, remote: &str) -> Result<String> {
        self.run(repo, &["remote", "get-url", remote]).await
    }

    /// Fetch from a remote using the executor's default timeout.
    pub async fn fetch(&self, repo: &Path, remote: &str) -> Result<()> {
        let _ = self.run(repo, &["fetch", remote]).await?;
        Ok(())
    }

    /// Fetch from a remote with a caller-supplied timeout in milliseconds.
    ///
    /// Uses the same stderr classifier as `push` so network / auth errors
    /// surface as typed variants. `prune` maps to `git fetch --prune`, which
    /// removes local remote-tracking refs for branches deleted upstream.
    pub async fn fetch_timeout(
        &self,
        repo: &Path,
        remote: &str,
        timeout_ms: u64,
        prune: bool,
    ) -> Result<()> {
        let mut args: Vec<&str> = vec!["fetch"];
        if prune {
            args.push("--prune");
        }
        args.push(remote);
        self.run_with_timeout(repo, &args, Duration::from_millis(timeout_ms))
            .await
            .map(|_| ())
            .map_err(classify_remote_error)
    }

    /// Resolve the HEAD of a remote branch via `git ls-remote`.
    ///
    /// Returns `Ok(Some(sha))` if the remote has a matching ref, `Ok(None)`
    /// if the remote is reachable but the branch is absent. `Err` surfaces
    /// auth/network failures.
    pub async fn ls_remote_head(
        &self,
        repo: &Path,
        remote: &str,
        branch: &str,
    ) -> Result<Option<String>> {
        let args: &[&str] = &["ls-remote", remote, branch];
        let output = self.run(repo, args).await.map_err(classify_remote_error)?;
        if output.trim().is_empty() {
            return Ok(None);
        }
        // Each line: <sha>\t<ref>. Take the first.
        let first = output.lines().next().unwrap_or("");
        let sha = first.split_whitespace().next().unwrap_or("").to_string();
        if sha.is_empty() {
            Ok(None)
        } else {
            Ok(Some(sha))
        }
    }

    /// Push a branch to a remote. Returns a structured `PushOutput`.
    ///
    /// - `force_with_lease` uses `--force-with-lease` (safer than `--force`).
    /// - `set_upstream` adds `-u` so subsequent pulls use the configured tracking.
    /// - `dry_run` adds `--dry-run` — git will report the refs it would
    ///   update but touches nothing remote.
    ///
    /// Stderr is inspected for the classic "rejected (non-fast-forward)"
    /// phrase so callers can react without re-parsing it.
    pub async fn push(
        &self,
        repo: &Path,
        remote: &str,
        branch: &str,
        force_with_lease: bool,
        set_upstream: bool,
        dry_run: bool,
    ) -> Result<PushOutput> {
        let mut args: Vec<String> = vec!["push".to_string()];
        if force_with_lease {
            args.push("--force-with-lease".to_string());
        }
        if set_upstream {
            args.push("-u".to_string());
        }
        if dry_run {
            args.push("--dry-run".to_string());
        }
        args.push(remote.to_string());
        args.push(branch.to_string());

        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        let (stdout, stderr, ok) = self.run_capture(repo, &arg_refs).await?;

        if !ok {
            return Err(classify_push_error(stderr));
        }

        // Even on success, git writes progress to stderr. Return it so
        // callers can show "To <url>" / per-ref update lines if they want.
        let _ = stdout;
        Ok(PushOutput {
            success: true,
            branch: branch.to_string(),
            remote: remote.to_string(),
            set_upstream,
            dry_run,
            stderr,
        })
    }

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

    // ────────────────────────────────────────────────────────────────
    // Phase 1 primitives — conflict helpers
    // ────────────────────────────────────────────────────────────────

    /// Is there an in-progress merge? (Detected via `.git/MERGE_HEAD`.)
    pub async fn has_merge_in_progress(&self, dir: &Path) -> Result<bool> {
        let git_dir = self.git_dir(dir).await?;
        Ok(Path::new(&git_dir).join("MERGE_HEAD").exists())
    }

    /// Is there an in-progress rebase? (Detected via
    /// `.git/rebase-merge/` or `.git/rebase-apply/`.)
    pub async fn has_rebase_in_progress(&self, dir: &Path) -> Result<bool> {
        let git_dir = self.git_dir(dir).await?;
        let gd = Path::new(&git_dir);
        Ok(gd.join("rebase-merge").is_dir() || gd.join("rebase-apply").is_dir())
    }

    /// List currently staged files (those that would go into the next
    /// commit). Uses `git diff --cached --name-only`.
    pub async fn staged_files(&self, dir: &Path) -> Result<Vec<String>> {
        let output = self.run(dir, &["diff", "--cached", "--name-only"]).await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(std::string::ToString::to_string)
            .collect())
    }

    /// Read the three index stages for a conflicted path and return a
    /// `ConflictedFile` describing the conflict shape.
    ///
    /// Uses `git ls-files --unmerged -z` to determine which stages exist
    /// (1/2/3) and `git show :<stage>:<path>` to read each stage's blob.
    /// Binary detection: we run `git check-attr` — cheap, authoritative,
    /// and respects `.gitattributes`. A NUL byte in any stage is also
    /// considered binary.
    pub async fn conflict_sections(&self, dir: &Path, path: &str) -> Result<ConflictedFile> {
        // 1. Figure out which stages exist. Output from ls-files --unmerged:
        //    <mode> SP <sha> SP <stage>\t<path>\0
        // For simplicity we just split on \t (path may legitimately contain
        // tabs but that's very rare; we ignore that edge case here).
        let (ls_out, _err, ok) = self
            .run_capture(dir, &["ls-files", "--unmerged", "--", path])
            .await?;
        if !ok || ls_out.trim().is_empty() {
            return Err(WorktreeError::Git(format!("not an unmerged path: {path}")));
        }
        let mut have_stage = [false; 4]; // index 1..=3 used
        for line in ls_out.lines() {
            // <mode> <sha> <stage>\t<path>
            let mut iter = line.split_whitespace();
            let _mode = iter.next();
            let _sha = iter.next();
            if let Some(stage_str) = iter.next()
                && let Ok(stage) = stage_str.parse::<usize>()
                && (1..=3).contains(&stage)
            {
                have_stage[stage] = true;
            }
        }

        // 2. Read each stage's blob (if present).
        let base = if have_stage[1] {
            Some(self.show_blob_bytes(dir, &format!(":1:{path}")).await?)
        } else {
            None
        };
        let ours = if have_stage[2] {
            Some(self.show_blob_bytes(dir, &format!(":2:{path}")).await?)
        } else {
            None
        };
        let theirs = if have_stage[3] {
            Some(self.show_blob_bytes(dir, &format!(":3:{path}")).await?)
        } else {
            None
        };

        // 3. Determine conflict kind from stage presence (classic matrix).
        let kind = match (have_stage[1], have_stage[2], have_stage[3]) {
            (true, true, true) => ConflictKind::BothModified,
            (false, true, true) => ConflictKind::BothAdded,
            (true, false, true) => ConflictKind::DeletedByUs,
            (true, true, false) => ConflictKind::DeletedByThem,
            _ => ConflictKind::Other,
        };

        // 4. Binary detection: `check-attr binary <path>` returns
        //    "<path>: binary: set" if .gitattributes marks it binary; else
        //    we fall back to scanning for NUL bytes in any present stage.
        let binary_attr = self
            .run(dir, &["check-attr", "binary", "--", path])
            .await
            .ok()
            .map(|s| s.contains(": set"))
            .unwrap_or(false);
        let nul_in_any = [&base, &ours, &theirs]
            .iter()
            .any(|b| b.as_ref().is_some_and(|v| v.contains(&0u8)));
        let is_binary = binary_attr || nul_in_any;

        Ok(ConflictedFile {
            path: path.to_string(),
            is_binary,
            base,
            ours,
            theirs,
            kind,
        })
    }

    /// Resolve a conflicted path by taking "ours" (stage 2).
    ///
    /// Runs `git checkout --ours -- <path>` then stages the result. For
    /// delete/modify conflicts where "ours" deleted, this leaves the file
    /// deleted (and stages the deletion).
    pub async fn checkout_ours(&self, dir: &Path, path: &str) -> Result<()> {
        // If ours deleted the file, `checkout --ours` errors — recover by
        // removing via `git rm`.
        match self.run(dir, &["checkout", "--ours", "--", path]).await {
            Ok(_) => {
                let _ = self.run(dir, &["add", "--", path]).await?;
                Ok(())
            }
            Err(_) => {
                let _ = self.run(dir, &["rm", "-f", "--", path]).await?;
                Ok(())
            }
        }
    }

    /// Resolve a conflicted path by taking "theirs" (stage 3). Mirror of
    /// `checkout_ours`.
    pub async fn checkout_theirs(&self, dir: &Path, path: &str) -> Result<()> {
        match self.run(dir, &["checkout", "--theirs", "--", path]).await {
            Ok(_) => {
                let _ = self.run(dir, &["add", "--", path]).await?;
                Ok(())
            }
            Err(_) => {
                let _ = self.run(dir, &["rm", "-f", "--", path]).await?;
                Ok(())
            }
        }
    }

    /// Complete an in-progress merge after conflicts were resolved. Uses
    /// `--no-edit` so git accepts the default commit message.
    pub async fn merge_continue(&self, dir: &Path, message: Option<&str>) -> Result<String> {
        match message {
            Some(m) => {
                let _ = self.run(dir, &["commit", "--no-edit", "-m", m]).await?;
            }
            None => {
                let _ = self.run(dir, &["commit", "--no-edit"]).await?;
            }
        }
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Continue an in-progress rebase after conflicts were resolved. Needs
    /// `GIT_EDITOR=true` so git doesn't open an editor on the commit message.
    pub async fn rebase_continue(&self, dir: &Path) -> Result<()> {
        let _ = self
            .run_with_env(dir, &["rebase", "--continue"], &[("GIT_EDITOR", "true")])
            .await?;
        Ok(())
    }

    // ────────────────────────────────────────────────────────────────
    // Internal helpers
    // ────────────────────────────────────────────────────────────────

    /// Public form of `git_dir` — resolves the worktree's `.git` directory
    /// (or worktree git-dir) as an absolute path.
    pub async fn git_dir_path(&self, dir: &Path) -> Result<std::path::PathBuf> {
        self.git_dir(dir).await.map(std::path::PathBuf::from)
    }

    /// Resolve `.git` directory for a worktree / repo.
    async fn git_dir(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["rev-parse", "--git-dir"]).await.map(|s| {
            // If the result is relative (often just ".git"), anchor it to
            // the caller's `dir`.
            let p = Path::new(&s);
            if p.is_absolute() {
                s
            } else {
                dir.join(p).to_string_lossy().to_string()
            }
        })
    }

    /// Read a blob by its `:<stage>:<path>` index address, returning raw
    /// bytes (unlike `run` which is UTF-8-lossy trimmed).
    async fn show_blob_bytes(&self, dir: &Path, spec: &str) -> Result<Vec<u8>> {
        let output = tokio::time::timeout(
            self.timeout,
            tokio::process::Command::new("git")
                .args(["show", spec])
                .current_dir(dir)
                .output(),
        )
        .await
        .map_err(|_| WorktreeError::Timeout(self.timeout.as_millis() as u64))?
        .map_err(|e| WorktreeError::Git(format!("failed to execute git: {e}")))?;
        if output.status.success() {
            Ok(output.stdout)
        } else {
            Err(WorktreeError::Git(
                String::from_utf8_lossy(&output.stderr).trim().to_string(),
            ))
        }
    }

    async fn run_stdout_bytes(&self, dir: &Path, args: &[&str]) -> Result<Vec<u8>> {
        debug!(dir = %dir.display(), args = ?args, "git (stdout bytes)");
        let output = tokio::time::timeout(
            self.timeout,
            tokio::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output(),
        )
        .await
        .map_err(|_| WorktreeError::Timeout(self.timeout.as_millis() as u64))?
        .map_err(|e| WorktreeError::Git(format!("failed to execute git: {e}")))?;
        if output.status.success() {
            Ok(output.stdout)
        } else {
            Err(WorktreeError::Git(
                String::from_utf8_lossy(&output.stderr).trim().to_string(),
            ))
        }
    }

    /// Like `run` but preserves stdout/stderr/status separately. Used by
    /// commands where stderr content is meaningful even on success.
    async fn run_capture(&self, dir: &Path, args: &[&str]) -> Result<(String, String, bool)> {
        debug!(dir = %dir.display(), args = ?args, "git (capture)");
        let output = tokio::time::timeout(
            self.timeout,
            tokio::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output(),
        )
        .await
        .map_err(|_| WorktreeError::Timeout(self.timeout.as_millis() as u64))?
        .map_err(|e| WorktreeError::Git(format!("failed to execute git: {e}")))?;
        Ok((
            String::from_utf8_lossy(&output.stdout).trim().to_string(),
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
            output.status.success(),
        ))
    }

    /// Like `run` but uses the caller-supplied timeout instead of
    /// `self.timeout` (used by long-running network ops).
    async fn run_with_timeout(
        &self,
        dir: &Path,
        args: &[&str],
        timeout: Duration,
    ) -> Result<String> {
        debug!(dir = %dir.display(), args = ?args, timeout_ms = %timeout.as_millis(), "git (custom timeout)");
        let output = tokio::time::timeout(
            timeout,
            tokio::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output(),
        )
        .await
        .map_err(|_| {
            WorktreeError::NetworkTimeout(format!(
                "git {} timed out after {}ms",
                args.join(" "),
                timeout.as_millis()
            ))
        })?
        .map_err(|e| WorktreeError::Git(format!("failed to execute git: {e}")))?;
        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        } else {
            Err(WorktreeError::Git(
                String::from_utf8_lossy(&output.stderr).trim().to_string(),
            ))
        }
    }

    /// Like `run` but with extra environment variables set (e.g.
    /// `GIT_EDITOR=true` so rebase --continue doesn't prompt).
    async fn run_with_env(
        &self,
        dir: &Path,
        args: &[&str],
        env: &[(&str, &str)],
    ) -> Result<String> {
        debug!(dir = %dir.display(), args = ?args, env = ?env, "git (env)");
        let mut cmd = tokio::process::Command::new("git");
        let _ = cmd.args(args).current_dir(dir);
        for (k, v) in env {
            let _ = cmd.env(k, v);
        }
        let output = tokio::time::timeout(self.timeout, cmd.output())
            .await
            .map_err(|_| WorktreeError::Timeout(self.timeout.as_millis() as u64))?
            .map_err(|e| WorktreeError::Git(format!("failed to execute git: {e}")))?;
        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        } else {
            Err(WorktreeError::Git(
                String::from_utf8_lossy(&output.stderr).trim().to_string(),
            ))
        }
    }

    /// Run a git command and return whether it succeeded (exit code 0).
    async fn run_status(&self, dir: &Path, args: &[&str]) -> bool {
        debug!(dir = %dir.display(), args = ?args, "git (status check)");
        let result = tokio::time::timeout(
            self.timeout,
            tokio::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output(),
        )
        .await;
        matches!(result, Ok(Ok(output)) if output.status.success())
    }

    /// Run a git command with timeout.
    pub(crate) async fn run(&self, dir: &Path, args: &[&str]) -> Result<String> {
        debug!(dir = %dir.display(), args = ?args, "git");

        let output = tokio::time::timeout(
            self.timeout,
            tokio::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output(),
        )
        .await
        .map_err(|_| WorktreeError::Timeout(self.timeout.as_millis() as u64))?
        .map_err(|e| WorktreeError::Git(format!("failed to execute git: {e}")))?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            warn!(args = ?args, stderr = %stderr, "git command failed");
            Err(WorktreeError::Git(stderr))
        }
    }
}

/// Map a `run`-style error from a remote/push operation onto a typed
/// `WorktreeError` variant by pattern-matching on the stderr string.
///
/// Falls back to the original `Git(String)` variant if no pattern matches,
/// so callers still get the raw message for surfacing to the user.
pub(crate) fn classify_remote_error(e: WorktreeError) -> WorktreeError {
    let msg = match &e {
        WorktreeError::Git(m) => m.clone(),
        _ => return e,
    };
    let lower = msg.to_lowercase();
    if lower.contains("authentication failed")
        || lower.contains("could not read username")
        || lower.contains("permission denied (publickey)")
        || lower.contains("permission denied")
        || lower.contains("terminal prompts disabled")
        || lower.contains("403 forbidden")
        || lower.contains("401 unauthorized")
    {
        WorktreeError::AuthFailure(msg)
    } else if lower.contains("could not resolve host")
        || lower.contains("connection refused")
        || lower.contains("connection timed out")
        || lower.contains("connection reset")
        || lower.contains("network is unreachable")
        || lower.contains("operation timed out")
    {
        WorktreeError::NetworkTimeout(msg)
    } else if lower.contains("no such remote")
        || lower.contains("does not appear to be a git repository")
        || lower.contains("no configured push destination")
    {
        WorktreeError::NoRemoteConfigured(msg)
    } else {
        WorktreeError::Git(msg)
    }
}

/// Like `classify_remote_error` but also recognises the non-fast-forward
/// rejection patterns that can come out of `git push`.
pub(crate) fn classify_push_error(stderr: String) -> WorktreeError {
    let lower = stderr.to_lowercase();
    if lower.contains("(non-fast-forward)")
        || lower.contains("rejected")
            && (lower.contains("non-fast-forward") || lower.contains("fetch first"))
    {
        return WorktreeError::NonFastForward(stderr);
    }
    if lower.contains("stale info") || lower.contains("force-with-lease") {
        // Stale force-with-lease — also a non-FF variant. Surface as non-FF.
        return WorktreeError::NonFastForward(stderr);
    }
    // Delegate the rest to the generic remote classifier.
    classify_remote_error(WorktreeError::Git(stderr))
}

/// Parse `git worktree list --porcelain` output.
fn parse_worktree_porcelain(output: &str) -> Vec<WorktreeListEntry> {
    let mut entries = Vec::new();
    let mut path = None;
    let mut head = None;
    let mut branch = None;
    let mut bare = false;

    for line in output.lines() {
        if line.starts_with("worktree ") {
            // Save previous entry if complete
            if let (Some(p), Some(h)) = (path.take(), head.take()) {
                entries.push(WorktreeListEntry {
                    path: p,
                    head: h,
                    branch: branch.take(),
                    bare,
                });
                bare = false;
            }
            path = Some(line.strip_prefix("worktree ").unwrap_or("").to_string());
        } else if line.starts_with("HEAD ") {
            head = Some(line.strip_prefix("HEAD ").unwrap_or("").to_string());
        } else if line.starts_with("branch ") {
            let full = line.strip_prefix("branch ").unwrap_or("");
            branch = Some(full.strip_prefix("refs/heads/").unwrap_or(full).to_string());
        } else if line == "bare" {
            bare = true;
        }
    }

    // Push last entry
    if let (Some(p), Some(h)) = (path, head) {
        entries.push(WorktreeListEntry {
            path: p,
            head: h,
            branch,
            bare,
        });
    }

    entries
}

fn parse_nul_paths(output: &[u8]) -> Vec<String> {
    output
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
        .map(|part| String::from_utf8_lossy(part).to_string())
        .filter(|path| !path.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn parse_worktree_porcelain_single() {
        let output = "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n";
        let entries = parse_worktree_porcelain(output);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "/repo");
        assert_eq!(entries[0].head, "abc123");
        assert_eq!(entries[0].branch.as_deref(), Some("main"));
        assert!(!entries[0].bare);
    }

    #[test]
    fn parse_worktree_porcelain_multiple() {
        let output = "\
worktree /repo
HEAD abc123
branch refs/heads/main

worktree /repo/.worktrees/session/x
HEAD def456
branch refs/heads/session/x
";
        let entries = parse_worktree_porcelain(output);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[1].branch.as_deref(), Some("session/x"));
    }

    #[test]
    fn parse_worktree_porcelain_bare() {
        let output = "worktree /repo\nHEAD abc123\nbare\n";
        let entries = parse_worktree_porcelain(output);
        assert_eq!(entries.len(), 1);
        assert!(entries[0].bare);
        assert!(entries[0].branch.is_none());
    }

    #[test]
    fn parse_worktree_porcelain_empty() {
        let entries = parse_worktree_porcelain("");
        assert!(entries.is_empty());
    }

    /// Helper: create a git repo with an initial commit.
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

    async fn run_cmd_ok(dir: &Path, args: &[&str]) -> bool {
        tokio::process::Command::new(args[0])
            .args(&args[1..])
            .current_dir(dir)
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    #[tokio::test]
    async fn is_git_repo_true() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(git.is_git_repo(dir.path()).await);
    }

    #[tokio::test]
    async fn is_git_repo_false() {
        let dir = tempdir().unwrap();
        let git = GitExecutor::new(30_000);
        assert!(!git.is_git_repo(dir.path()).await);
    }

    #[tokio::test]
    async fn has_commits_true_with_commits() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(git.has_commits(dir.path()).await);
    }

    #[tokio::test]
    async fn has_commits_false_empty_repo() {
        let dir = tempdir().unwrap();
        run_cmd(dir.path(), &["git", "init"]).await;
        let git = GitExecutor::new(30_000);
        assert!(!git.has_commits(dir.path()).await);
    }

    #[tokio::test]
    async fn has_commits_false_non_git() {
        let dir = tempdir().unwrap();
        let git = GitExecutor::new(30_000);
        assert!(!git.has_commits(dir.path()).await);
    }

    #[tokio::test]
    async fn repo_root_from_subdir() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let sub = dir.path().join("sub");
        std::fs::create_dir_all(&sub).unwrap();
        let root = git.repo_root(&sub).await.unwrap();
        assert_eq!(
            std::path::Path::new(&root).canonicalize().unwrap(),
            dir.path().canonicalize().unwrap()
        );
    }

    #[tokio::test]
    async fn head_commit_returns_sha() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let sha = git.head_commit(dir.path()).await.unwrap();
        assert_eq!(sha.len(), 40);
        assert!(sha.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[tokio::test]
    async fn current_branch_main() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let branch = git.current_branch(dir.path()).await.unwrap();
        // git init creates "main" or "master" depending on config
        assert!(!branch.is_empty());
    }

    #[tokio::test]
    async fn worktree_lifecycle() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        let wt_path = dir.path().join(".worktrees").join("test-wt");

        // Add
        git.worktree_add(dir.path(), &wt_path, "test-branch", "HEAD")
            .await
            .unwrap();
        assert!(wt_path.exists());

        // List
        let entries = git.worktree_list(dir.path()).await.unwrap();
        assert_eq!(entries.len(), 2);
        assert!(
            entries
                .iter()
                .any(|e| e.branch.as_deref() == Some("test-branch"))
        );

        // Remove
        git.worktree_remove(dir.path(), &wt_path, false)
            .await
            .unwrap();
        assert!(!wt_path.exists());

        // Branch still exists
        let branch_output = tokio::process::Command::new("git")
            .args(["branch", "--list", "test-branch"])
            .current_dir(dir.path())
            .output()
            .await
            .unwrap();
        assert!(
            !String::from_utf8_lossy(&branch_output.stdout)
                .trim()
                .is_empty()
        );

        // Delete branch
        git.branch_delete(dir.path(), "test-branch", false)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn has_changes_and_commit() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        assert!(!git.has_changes(dir.path()).await.unwrap());

        std::fs::write(dir.path().join("new.txt"), "hello").unwrap();
        assert!(git.has_changes(dir.path()).await.unwrap());

        let sha = git.commit_all(dir.path(), "add file").await.unwrap();
        assert_eq!(sha.len(), 40);
        assert!(!git.has_changes(dir.path()).await.unwrap());
    }

    // ── commit_with_options ────────────────────────────────────────────

    /// Read the full commit message (body + trailers) of HEAD.
    async fn head_message(dir: &Path) -> String {
        let out = tokio::process::Command::new("git")
            .args(["log", "-1", "--format=%B"])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(out.status.success(), "git log failed");
        String::from_utf8(out.stdout).unwrap()
    }

    async fn head_subject(dir: &Path) -> String {
        let out = tokio::process::Command::new("git")
            .args(["log", "-1", "--format=%s"])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(out.status.success());
        String::from_utf8(out.stdout)
            .unwrap()
            .trim_end()
            .to_string()
    }

    async fn rev_list_count(dir: &Path) -> u64 {
        let out = tokio::process::Command::new("git")
            .args(["rev-list", "--count", "HEAD"])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(out.status.success());
        String::from_utf8(out.stdout)
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    }

    async fn files_at_head(dir: &Path) -> Vec<String> {
        let out = tokio::process::Command::new("git")
            .args(["log", "-1", "--name-only", "--format="])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(out.status.success());
        String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect()
    }

    #[tokio::test]
    async fn commit_with_options_stage_all_adds_and_commits() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        std::fs::write(dir.path().join("new.txt"), "hello").unwrap();
        let opts = CommitOptions {
            stage_all: true,
            ..Default::default()
        };
        let sha = git
            .commit_with_options(dir.path(), "add new", &opts)
            .await
            .unwrap();

        assert_eq!(sha.len(), 40, "sha must be a 40-char hex");
        let files = files_at_head(dir.path()).await;
        assert!(
            files.iter().any(|f| f == "new.txt"),
            "expected new.txt in HEAD, got {files:?}"
        );
        assert!(
            !git.has_changes(dir.path()).await.unwrap(),
            "tree should be clean after commit"
        );
    }

    #[tokio::test]
    async fn commit_with_options_stage_all_false_commits_only_index() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        // Two new files. Stage only the first via raw git; leave the second
        // untracked. With stage_all=false, the commit must include only
        // staged.txt — NOT unstaged.txt.
        std::fs::write(dir.path().join("staged.txt"), "one").unwrap();
        std::fs::write(dir.path().join("unstaged.txt"), "two").unwrap();
        run_cmd(dir.path(), &["git", "add", "staged.txt"]).await;

        let opts = CommitOptions {
            stage_all: false,
            ..Default::default()
        };
        let sha = git
            .commit_with_options(dir.path(), "partial", &opts)
            .await
            .unwrap();
        assert_eq!(sha.len(), 40);

        let files = files_at_head(dir.path()).await;
        assert!(
            files.contains(&"staged.txt".to_string()),
            "staged.txt must be in commit: {files:?}"
        );
        assert!(
            !files.contains(&"unstaged.txt".to_string()),
            "unstaged.txt MUST NOT be in commit: {files:?}"
        );

        // Untracked file still present after commit
        assert!(
            git.has_changes(dir.path()).await.unwrap(),
            "untracked unstaged.txt should keep tree dirty"
        );
    }

    #[tokio::test]
    async fn commit_with_options_amend_rewrites_head() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        // init_repo already produced one commit. Make one more to amend.
        std::fs::write(dir.path().join("a.txt"), "a").unwrap();
        let _ = git.commit_all(dir.path(), "first add").await.unwrap();
        let count_before = rev_list_count(dir.path()).await;

        // Modify and amend with a new message
        std::fs::write(dir.path().join("a.txt"), "a-edited").unwrap();
        let opts = CommitOptions {
            stage_all: true,
            amend: true,
            ..Default::default()
        };
        let sha = git
            .commit_with_options(dir.path(), "first add (amended)", &opts)
            .await
            .unwrap();
        assert_eq!(sha.len(), 40);

        assert_eq!(
            rev_list_count(dir.path()).await,
            count_before,
            "amend must not add a commit"
        );
        assert_eq!(head_subject(dir.path()).await, "first add (amended)");
    }

    #[tokio::test]
    async fn commit_with_options_signoff_adds_trailer() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        std::fs::write(dir.path().join("s.txt"), "s").unwrap();
        let opts = CommitOptions {
            stage_all: true,
            signoff: true,
            ..Default::default()
        };
        let _ = git
            .commit_with_options(dir.path(), "signed change", &opts)
            .await
            .unwrap();

        let body = head_message(dir.path()).await;
        assert!(
            body.lines().any(|l| l.starts_with("Signed-off-by:")),
            "expected Signed-off-by: trailer, got {body:?}"
        );
    }

    #[tokio::test]
    async fn commit_with_options_amend_and_signoff_compose() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        // First commit to amend
        std::fs::write(dir.path().join("x.txt"), "x").unwrap();
        let _ = git.commit_all(dir.path(), "x").await.unwrap();
        let count_before = rev_list_count(dir.path()).await;

        // Amend with signoff
        std::fs::write(dir.path().join("x.txt"), "x2").unwrap();
        let opts = CommitOptions {
            stage_all: true,
            amend: true,
            signoff: true,
        };
        let _ = git
            .commit_with_options(dir.path(), "x (amended)", &opts)
            .await
            .unwrap();

        assert_eq!(rev_list_count(dir.path()).await, count_before);
        let body = head_message(dir.path()).await;
        assert!(body.starts_with("x (amended)"));
        assert!(body.lines().any(|l| l.starts_with("Signed-off-by:")));
    }

    #[tokio::test]
    async fn commit_with_options_no_changes_without_amend_returns_err() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        // git commit exits non-zero when the index is clean; the "nothing to
        // commit" text lands on stdout, not stderr, so we just assert Err
        // rather than probing the message.
        let opts = CommitOptions {
            stage_all: false,
            ..Default::default()
        };
        let result = git.commit_with_options(dir.path(), "empty", &opts).await;
        assert!(
            result.is_err(),
            "expected Err on clean index without --allow-empty"
        );
    }

    #[tokio::test]
    async fn commit_with_options_message_with_newlines_preserved() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        std::fs::write(dir.path().join("m.txt"), "m").unwrap();
        let message = "subject line\n\nbody paragraph\nsecond body line";
        let opts = CommitOptions {
            stage_all: true,
            ..Default::default()
        };
        let _ = git
            .commit_with_options(dir.path(), message, &opts)
            .await
            .unwrap();

        let body = head_message(dir.path()).await;
        // git may append a trailing newline; compare trimmed.
        assert_eq!(body.trim_end(), message);
    }

    #[tokio::test]
    async fn commit_with_options_message_starting_with_dash_not_treated_as_flag() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        std::fs::write(dir.path().join("d.txt"), "d").unwrap();
        let message = "-x do thing";
        let opts = CommitOptions {
            stage_all: true,
            ..Default::default()
        };
        let sha = git
            .commit_with_options(dir.path(), message, &opts)
            .await
            .unwrap();
        assert_eq!(sha.len(), 40);
        assert_eq!(head_subject(dir.path()).await, "-x do thing");
    }

    #[tokio::test]
    async fn commit_count_since_base() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        let base = git.head_commit(dir.path()).await.unwrap();

        // No commits since base
        assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 0);

        // One commit
        std::fs::write(dir.path().join("a.txt"), "a").unwrap();
        let _ = git.commit_all(dir.path(), "first").await.unwrap();
        assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 1);

        // Two commits
        std::fs::write(dir.path().join("b.txt"), "b").unwrap();
        let _ = git.commit_all(dir.path(), "second").await.unwrap();
        assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 2);
    }

    #[tokio::test]
    async fn changed_files_since_base() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        std::fs::write(dir.path().join("new.txt"), "new").unwrap();
        let _ = git.commit_all(dir.path(), "add new").await.unwrap();

        let files = git.changed_files_since(dir.path(), &base).await.unwrap();
        assert_eq!(files, vec!["new.txt"]);
    }

    #[tokio::test]
    async fn diff_numstat_total_basic() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        // Write a file with 3 lines
        std::fs::write(dir.path().join("code.txt"), "line1\nline2\nline3\n").unwrap();
        let _ = git.commit_all(dir.path(), "add code").await.unwrap();
        let head = git.head_commit(dir.path()).await.unwrap();

        let (ins, del) = git
            .diff_numstat_total(dir.path(), &base, &head)
            .await
            .unwrap();
        assert_eq!(ins, 3);
        assert_eq!(del, 0);
    }

    #[tokio::test]
    async fn error_on_non_git_dir() {
        let dir = tempdir().unwrap();
        let git = GitExecutor::new(30_000);
        let result = git.head_commit(dir.path()).await;
        assert!(result.is_err());
    }

    // ── list_branches_matching ──────────────────────────────────────

    #[tokio::test]
    async fn list_branches_no_matches() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let branches = git
            .list_branches_matching(dir.path(), "session/*")
            .await
            .unwrap();
        assert!(branches.is_empty());
    }

    #[tokio::test]
    async fn list_branches_single_match() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;
        let branches = git
            .list_branches_matching(dir.path(), "session/*")
            .await
            .unwrap();
        assert_eq!(branches, vec!["session/abc"]);
    }

    #[tokio::test]
    async fn list_branches_multiple_matches() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "session/aaa"]).await;
        run_cmd(dir.path(), &["git", "branch", "session/bbb"]).await;
        run_cmd(dir.path(), &["git", "branch", "session/ccc"]).await;
        let branches = git
            .list_branches_matching(dir.path(), "session/*")
            .await
            .unwrap();
        assert_eq!(branches.len(), 3);
    }

    #[tokio::test]
    async fn list_branches_ignores_non_matching() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;
        run_cmd(dir.path(), &["git", "branch", "feature/xyz"]).await;
        let branches = git
            .list_branches_matching(dir.path(), "session/*")
            .await
            .unwrap();
        assert_eq!(branches.len(), 1);
        assert_eq!(branches[0], "session/abc");
    }

    // ── branch_log ──────────────────────────────────────────────────

    #[tokio::test]
    async fn branch_log_single_commit() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let entries = git.branch_log(dir.path(), "HEAD", 10).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0.len(), 40); // hash
        assert_eq!(entries[0].1, "init"); // message
        assert!(!entries[0].2.is_empty()); // date
    }

    #[tokio::test]
    async fn branch_log_multiple_commits() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        for i in 1..=5 {
            std::fs::write(dir.path().join(format!("f{i}.txt")), format!("content{i}")).unwrap();
            let _ = git
                .commit_all(dir.path(), &format!("commit {i}"))
                .await
                .unwrap();
        }
        let entries = git.branch_log(dir.path(), "HEAD", 3).await.unwrap();
        assert_eq!(entries.len(), 3);
    }

    #[tokio::test]
    async fn branch_log_nonexistent_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let result = git.branch_log(dir.path(), "nonexistent", 1).await;
        assert!(result.is_err());
    }

    // ── merge_base ──────────────────────────────────────────────────

    #[tokio::test]
    async fn merge_base_simple() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base_sha = git.head_commit(dir.path()).await.unwrap();

        // Create a branch and add a commit
        run_cmd(dir.path(), &["git", "checkout", "-b", "feature"]).await;
        std::fs::write(dir.path().join("f.txt"), "feature").unwrap();
        let _ = git.commit_all(dir.path(), "feature commit").await.unwrap();

        // Checkout default branch (may be main or master)
        let branch = git.current_branch(dir.path()).await.unwrap_or_default();
        if branch != "feature" {
            // Already on default branch from the checkout -b
        }
        // Go back to the branch we started on
        let default = if run_cmd_ok(dir.path(), &["git", "checkout", "main"]).await {
            "main"
        } else {
            run_cmd(dir.path(), &["git", "checkout", "master"]).await;
            "master"
        };
        let _ = default;

        let mb = git.merge_base(dir.path(), "feature", "HEAD").await.unwrap();
        assert_eq!(mb, base_sha);
    }

    #[tokio::test]
    async fn merge_base_nonexistent_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let result = git.merge_base(dir.path(), "nonexistent", "HEAD").await;
        assert!(result.is_err());
    }

    // ── diff_between ────────────────────────────────────────────────

    #[tokio::test]
    async fn diff_between_no_changes() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let head = git.head_commit(dir.path()).await.unwrap();
        let diff = git.diff_between(dir.path(), &head, &head).await.unwrap();
        assert!(diff.is_empty());
    }

    #[tokio::test]
    async fn diff_between_added_file() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        std::fs::write(dir.path().join("new.txt"), "hello\n").unwrap();
        let head = git.commit_all(dir.path(), "add new").await.unwrap();

        let diff = git.diff_between(dir.path(), &base, &head).await.unwrap();
        assert!(diff.contains("+hello"));
    }

    #[tokio::test]
    async fn diff_between_nonexistent_ref() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let result = git.diff_between(dir.path(), "badref", "HEAD").await;
        assert!(result.is_err());
    }

    // ── commit_count_between ────────────────────────────────────────

    #[tokio::test]
    async fn commit_count_between_zero() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let head = git.head_commit(dir.path()).await.unwrap();
        let count = git
            .commit_count_between(dir.path(), &head, &head)
            .await
            .unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn commit_count_between_multiple() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();
        for i in 0..3 {
            std::fs::write(dir.path().join(format!("f{i}.txt")), "x").unwrap();
            let _ = git.commit_all(dir.path(), &format!("c{i}")).await.unwrap();
        }
        let head = git.head_commit(dir.path()).await.unwrap();
        let count = git
            .commit_count_between(dir.path(), &base, &head)
            .await
            .unwrap();
        assert_eq!(count, 3);
    }

    // ── diff_name_status ────────────────────────────────────────────

    #[tokio::test]
    async fn name_status_added() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();
        std::fs::write(dir.path().join("new.txt"), "new").unwrap();
        let head = git.commit_all(dir.path(), "add").await.unwrap();
        let entries = git
            .diff_name_status(dir.path(), &base, &head)
            .await
            .unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "A");
        assert_eq!(entries[0].1, "new.txt");
    }

    #[tokio::test]
    async fn name_status_mixed() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        // Modify existing, add new, delete existing
        std::fs::write(dir.path().join("README.md"), "modified").unwrap();
        std::fs::write(dir.path().join("new.txt"), "new").unwrap();
        let head = git.commit_all(dir.path(), "changes").await.unwrap();

        let entries = git
            .diff_name_status(dir.path(), &base, &head)
            .await
            .unwrap();
        assert!(entries.len() >= 2);
    }

    #[tokio::test]
    async fn name_status_empty() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let head = git.head_commit(dir.path()).await.unwrap();
        let entries = git
            .diff_name_status(dir.path(), &head, &head)
            .await
            .unwrap();
        assert!(entries.is_empty());
    }

    // ── branch_rename tests ────────────────────────────────────────

    #[tokio::test]
    async fn branch_rename_success() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "old-branch"]).await;

        git.branch_rename(dir.path(), "old-branch", "new-branch")
            .await
            .unwrap();

        let branches = git.list_branches_matching(dir.path(), "*").await.unwrap();
        assert!(branches.contains(&"new-branch".to_string()));
        assert!(!branches.contains(&"old-branch".to_string()));
    }

    #[tokio::test]
    async fn branch_rename_nonexistent_fails() {
        let dir = tempdir().unwrap();
        let _git = init_repo(dir.path()).await;

        let git = GitExecutor::new(30_000);
        let result = git
            .branch_rename(dir.path(), "nonexistent", "new-name")
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn branch_rename_to_existing_fails() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "branch-a"]).await;
        run_cmd(dir.path(), &["git", "branch", "branch-b"]).await;

        let result = git.branch_rename(dir.path(), "branch-a", "branch-b").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn branch_rename_worktree_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        let wt_path = dir.path().join(".worktrees").join("session").join("test");
        git.worktree_add(dir.path(), &wt_path, "session/old-name", "HEAD")
            .await
            .unwrap();

        git.branch_rename(dir.path(), "session/old-name", "session/new-name")
            .await
            .unwrap();

        let branches = git
            .list_branches_matching(dir.path(), "session/*")
            .await
            .unwrap();
        assert!(branches.contains(&"session/new-name".to_string()));
        assert!(!branches.contains(&"session/old-name".to_string()));

        // Worktree should still be functional
        assert!(wt_path.exists());
        std::fs::write(wt_path.join("test.txt"), "works").unwrap();
        let has_changes = git.has_changes(&wt_path).await.unwrap();
        assert!(has_changes);
    }
}

// ══════════════════════════════════════════════════════════════════════
// Phase 1 primitive tests
// ══════════════════════════════════════════════════════════════════════
//
// These sit in a separate `#[cfg(test)]` module so they can reach the
// shared fixtures at `crate::domains::worktree::test_fixtures::*` without
// pulling those fixtures into the inline tests above.

#[cfg(test)]
mod phase1_tests {
    use super::*;
    use crate::domains::worktree::test_fixtures::{
        add_commit, checkout_new_branch, init_repo, init_repo_with_origin, make_conflict,
        make_deleted_by_us_conflict, run_cmd, run_cmd_ok,
    };
    use tempfile::tempdir;

    // ── classifier unit tests ──────────────────────────────────────

    #[test]
    fn classify_push_error_non_fast_forward() {
        let e = classify_push_error(
            "! [rejected] main -> main (non-fast-forward)\nerror: failed to push".to_string(),
        );
        matches!(e, WorktreeError::NonFastForward(_))
            .then_some(())
            .expect("expected NonFastForward");
    }

    #[test]
    fn classify_push_error_stale_lease() {
        let e = classify_push_error(
            "! [rejected] main -> main (stale info)\nhint: force-with-lease".to_string(),
        );
        matches!(e, WorktreeError::NonFastForward(_))
            .then_some(())
            .expect("stale lease should classify as NonFastForward");
    }

    #[test]
    fn classify_remote_error_auth_publickey() {
        let e = classify_remote_error(WorktreeError::Git(
            "Permission denied (publickey). fatal: Could not read from remote repository."
                .to_string(),
        ));
        matches!(e, WorktreeError::AuthFailure(_))
            .then_some(())
            .expect("expected AuthFailure");
    }

    #[test]
    fn classify_remote_error_network_host() {
        let e = classify_remote_error(WorktreeError::Git(
            "fatal: unable to access 'https://x/': Could not resolve host: x".to_string(),
        ));
        matches!(e, WorktreeError::NetworkTimeout(_))
            .then_some(())
            .expect("expected NetworkTimeout");
    }

    #[test]
    fn classify_remote_error_no_remote() {
        let e = classify_remote_error(WorktreeError::Git(
            "fatal: No configured push destination.".to_string(),
        ));
        matches!(e, WorktreeError::NoRemoteConfigured(_))
            .then_some(())
            .expect("expected NoRemoteConfigured");
    }

    #[test]
    fn classify_remote_error_passthrough_unknown() {
        let e = classify_remote_error(WorktreeError::Git("something else entirely".to_string()));
        assert!(matches!(e, WorktreeError::Git(_)));
    }

    // ── remote helpers ─────────────────────────────────────────────

    #[tokio::test]
    async fn remote_list_empty() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(git.remote_list(dir.path()).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn remote_list_and_get_url() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let remotes = git.remote_list(work.path()).await.unwrap();
        assert_eq!(remotes, vec!["origin"]);
        let url = git.remote_get_url(work.path(), "origin").await.unwrap();
        assert!(url.contains(&*origin.path().to_string_lossy()));
    }

    #[tokio::test]
    async fn ls_remote_head_existing_branch() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let sha = git
            .ls_remote_head(work.path(), "origin", "main")
            .await
            .unwrap();
        assert!(sha.is_some(), "expected sha for origin/main");
        assert_eq!(sha.as_ref().unwrap().len(), 40);
    }

    #[tokio::test]
    async fn ls_remote_head_missing_branch_is_none() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let sha = git
            .ls_remote_head(work.path(), "origin", "does-not-exist")
            .await
            .unwrap();
        assert!(sha.is_none());
    }

    // ── push ───────────────────────────────────────────────────────

    #[tokio::test]
    async fn push_dry_run_no_side_effects() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;

        // New commit locally, not yet pushed.
        let head_before_remote = git
            .ls_remote_head(work.path(), "origin", "main")
            .await
            .unwrap();

        add_commit(work.path(), "a.txt", "a", "local a").await;

        let out = git
            .push(
                work.path(),
                "origin",
                "main",
                false,
                false,
                true, /* dry_run */
            )
            .await
            .unwrap();
        assert!(out.success);
        assert!(out.dry_run);

        // Remote head is unchanged.
        let head_after = git
            .ls_remote_head(work.path(), "origin", "main")
            .await
            .unwrap();
        assert_eq!(head_before_remote, head_after);
    }

    #[tokio::test]
    async fn push_real_advances_remote() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let head_before = git
            .ls_remote_head(work.path(), "origin", "main")
            .await
            .unwrap();

        let local_head = add_commit(work.path(), "a.txt", "a", "local a").await;
        let out = git
            .push(work.path(), "origin", "main", false, false, false)
            .await
            .unwrap();
        assert!(out.success);

        let head_after = git
            .ls_remote_head(work.path(), "origin", "main")
            .await
            .unwrap();
        assert_ne!(head_before, head_after);
        assert_eq!(head_after.as_deref(), Some(local_head.as_str()));
    }

    #[tokio::test]
    async fn push_non_ff_rejected() {
        // Two clones of the same origin diverge; the second to push is rejected.
        let base = tempdir().unwrap();
        let origin = base.path().join("origin.git");
        let work_a = base.path().join("a");
        let work_b = base.path().join("b");
        std::fs::create_dir_all(&origin).unwrap();
        run_cmd(&origin, &["git", "init", "--bare"]).await;
        run_cmd(&origin, &["git", "symbolic-ref", "HEAD", "refs/heads/main"]).await;

        // Seed origin via a throwaway clone.
        let seed = base.path().join("seed");
        run_cmd(
            base.path(),
            &[
                "git",
                "clone",
                &origin.to_string_lossy(),
                &seed.to_string_lossy(),
            ],
        )
        .await;
        run_cmd(&seed, &["git", "config", "user.email", "t@t"]).await;
        run_cmd(&seed, &["git", "config", "user.name", "t"]).await;
        run_cmd(&seed, &["git", "config", "commit.gpgsign", "false"]).await;
        std::fs::write(seed.join("README.md"), "init\n").unwrap();
        run_cmd(&seed, &["git", "add", "-A"]).await;
        run_cmd(&seed, &["git", "commit", "-m", "init"]).await;
        run_cmd(&seed, &["git", "push", "origin", "main"]).await;

        // Clone a and b.
        for d in [&work_a, &work_b] {
            run_cmd(
                base.path(),
                &[
                    "git",
                    "clone",
                    &origin.to_string_lossy(),
                    &d.to_string_lossy(),
                ],
            )
            .await;
            run_cmd(d, &["git", "config", "user.email", "t@t"]).await;
            run_cmd(d, &["git", "config", "user.name", "t"]).await;
            run_cmd(d, &["git", "config", "commit.gpgsign", "false"]).await;
        }

        // a commits + pushes.
        std::fs::write(work_a.join("a.txt"), "a").unwrap();
        run_cmd(&work_a, &["git", "add", "-A"]).await;
        run_cmd(&work_a, &["git", "commit", "-m", "a"]).await;
        run_cmd(&work_a, &["git", "push", "origin", "main"]).await;

        // b commits but hasn't fetched; push must be rejected.
        std::fs::write(work_b.join("b.txt"), "b").unwrap();
        run_cmd(&work_b, &["git", "add", "-A"]).await;
        run_cmd(&work_b, &["git", "commit", "-m", "b"]).await;

        let git = GitExecutor::new(30_000);
        let err = git
            .push(&work_b, "origin", "main", false, false, false)
            .await
            .expect_err("push should be rejected");
        assert!(
            matches!(err, WorktreeError::NonFastForward(_)),
            "expected NonFastForward, got {err:?}"
        );
    }

    #[tokio::test]
    async fn push_set_upstream_creates_tracking() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;

        // New branch, no upstream yet.
        checkout_new_branch(work.path(), "feature").await;
        add_commit(work.path(), "f.txt", "f", "feat").await;

        let out = git
            .push(work.path(), "origin", "feature", false, true, false)
            .await
            .unwrap();
        assert!(out.set_upstream);
        assert!(out.success);

        // Confirm tracking exists.
        let upstream = git
            .config_get(work.path(), "branch.feature.merge")
            .await
            .unwrap();
        assert_eq!(upstream.as_deref(), Some("refs/heads/feature"));
    }

    // ── reset_hard / stash ─────────────────────────────────────────

    #[tokio::test]
    async fn reset_hard_discards_wip() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();
        std::fs::write(dir.path().join("wip.txt"), "wip").unwrap();
        run_cmd(dir.path(), &["git", "add", "-A"]).await;
        run_cmd(dir.path(), &["git", "commit", "-m", "wip"]).await;

        git.reset_hard(dir.path(), &base).await.unwrap();
        let head = git.head_commit(dir.path()).await.unwrap();
        assert_eq!(head, base);
        assert!(!dir.path().join("wip.txt").exists());
    }

    #[tokio::test]
    async fn stash_push_returns_none_when_clean() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let r = git.stash_push(dir.path(), "nothing").await.unwrap();
        assert!(r.is_none());
    }

    #[tokio::test]
    async fn stash_push_then_pop_restores_files() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        std::fs::write(dir.path().join("wip.txt"), "contents").unwrap();
        let r = git.stash_push(dir.path(), "msg").await.unwrap();
        assert_eq!(r.as_deref(), Some("stash@{0}"));
        assert!(
            !dir.path().join("wip.txt").exists(),
            "stash should remove wip from working tree"
        );

        let conflicts = git.stash_pop(dir.path(), "stash@{0}").await.unwrap();
        assert!(conflicts.is_empty(), "clean pop should report no conflicts");
        assert_eq!(
            std::fs::read_to_string(dir.path().join("wip.txt")).unwrap(),
            "contents"
        );
    }

    #[tokio::test]
    async fn stash_create_with_untracked_captures_and_pops() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        // Write an untracked file — `-u` flag means it must be captured.
        std::fs::write(dir.path().join("untracked.txt"), "new").unwrap();
        std::fs::write(dir.path().join("README.md"), "# modified").unwrap();

        let stash_ref = git
            .stash_create_with_untracked(dir.path(), "tron-rebase-test")
            .await
            .unwrap();
        assert_eq!(stash_ref, "stash@{0}");
        // Working tree clean after stash.
        assert!(!git.has_changes(dir.path()).await.unwrap());
        assert!(!dir.path().join("untracked.txt").exists());

        let conflicts = git.stash_pop(dir.path(), &stash_ref).await.unwrap();
        assert!(conflicts.is_empty());
        assert_eq!(
            std::fs::read_to_string(dir.path().join("untracked.txt")).unwrap(),
            "new"
        );
    }

    #[tokio::test]
    async fn stash_drop_removes_entry_idempotent() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        std::fs::write(dir.path().join("README.md"), "# modified").unwrap();
        let stash_ref = git
            .stash_create_with_untracked(dir.path(), "tron-drop-test")
            .await
            .unwrap();

        // First drop — stash exists, should succeed.
        git.stash_drop(dir.path(), &stash_ref).await.unwrap();

        // Second drop — stash no longer exists; must succeed (idempotent).
        git.stash_drop(dir.path(), &stash_ref).await.unwrap();
    }

    #[tokio::test]
    async fn stash_pop_reports_unmerged_paths_on_conflict() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        // Commit a baseline f.txt so it's tracked.
        std::fs::write(dir.path().join("f.txt"), "base\n").unwrap();
        let _ = git.commit_all(dir.path(), "base f.txt").await.unwrap();
        // Modify in working tree — stash picks up the tracked change.
        std::fs::write(dir.path().join("f.txt"), "line A\n").unwrap();
        let stash_ref = git
            .stash_create_with_untracked(dir.path(), "A")
            .await
            .unwrap();
        // Commit a different change to the same file so popping conflicts.
        std::fs::write(dir.path().join("f.txt"), "line B\n").unwrap();
        let _ = git.commit_all(dir.path(), "line B").await.unwrap();

        let conflicts = git.stash_pop(dir.path(), &stash_ref).await.unwrap();
        assert!(
            !conflicts.is_empty(),
            "conflicting pop must report unmerged paths"
        );
        assert!(conflicts.iter().any(|p| p == "f.txt"));
    }

    // ── config / refs ──────────────────────────────────────────────

    #[tokio::test]
    async fn config_get_present_and_missing() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        let present = git.config_get(dir.path(), "user.email").await.unwrap();
        assert_eq!(present.as_deref(), Some("test@test.com"));

        let missing = git.config_get(dir.path(), "does.not.exist").await.unwrap();
        assert!(missing.is_none());
    }

    #[tokio::test]
    async fn show_ref_verify_true_false() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(git.show_ref_verify(dir.path(), "refs/heads/main").await);
        assert!(!git.show_ref_verify(dir.path(), "refs/heads/nope").await);
    }

    #[tokio::test]
    async fn for_each_ref_first_existing_picks_main() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let r = git
            .for_each_ref_first_existing(dir.path(), &["master", "main"])
            .await;
        assert_eq!(
            r.as_deref(),
            Some("master").or(Some("main")).and(Some("main"))
        );
        let r = git
            .for_each_ref_first_existing(dir.path(), &["main", "master"])
            .await;
        assert_eq!(r.as_deref(), Some("main"));
        let r = git
            .for_each_ref_first_existing(dir.path(), &["nope", "zzz"])
            .await;
        assert!(r.is_none());
    }

    #[tokio::test]
    async fn rev_parse_verify_valid_and_invalid() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let sha = git.rev_parse_verify(dir.path(), "HEAD").await.unwrap();
        assert_eq!(sha.len(), 40);
        assert!(
            git.rev_parse_verify(dir.path(), "nonexistent")
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn merge_ff_only_succeeds() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();
        checkout_new_branch(dir.path(), "feature").await;
        add_commit(dir.path(), "f.txt", "f", "feat").await;
        let feature_head = git.head_commit(dir.path()).await.unwrap();

        // Go back to main, FF-merge feature.
        run_cmd(dir.path(), &["git", "checkout", "main"]).await;
        assert_eq!(git.head_commit(dir.path()).await.unwrap(), base);
        let new_head = git.merge_ff_only(dir.path(), "feature").await.unwrap();
        assert_eq!(new_head, feature_head);
    }

    #[tokio::test]
    async fn merge_ff_only_rejects_non_ff() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        // diverge: main has a commit that feature doesn't.
        checkout_new_branch(dir.path(), "feature").await;
        add_commit(dir.path(), "f.txt", "f", "feat").await;
        run_cmd(dir.path(), &["git", "checkout", "main"]).await;
        add_commit(dir.path(), "m.txt", "m", "main advance").await;
        let err = git.merge_ff_only(dir.path(), "feature").await;
        assert!(err.is_err(), "non-ff ff-only merge must fail");
    }

    // ── branch / worktree ──────────────────────────────────────────

    #[tokio::test]
    async fn checkout_new_branch_from_success() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        git.checkout_new_branch_from(dir.path(), "feature/new", "HEAD")
            .await
            .unwrap();
        assert_eq!(git.current_branch(dir.path()).await.unwrap(), "feature/new");
    }

    #[tokio::test]
    async fn checkout_new_branch_from_already_exists() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "exists"]).await;
        let err = git
            .checkout_new_branch_from(dir.path(), "exists", "HEAD")
            .await
            .expect_err("should fail");
        assert!(matches!(err, WorktreeError::BranchExists(n) if n == "exists"));
    }

    #[tokio::test]
    async fn force_checkout_drops_wip() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        checkout_new_branch(dir.path(), "other").await;
        run_cmd(dir.path(), &["git", "checkout", "main"]).await;
        std::fs::write(dir.path().join("wip.txt"), "wip").unwrap();
        // checkout would normally refuse with uncommitted wip if conflicting,
        // but untracked files are tolerated — ensure --force path works.
        git.force_checkout(dir.path(), "other").await.unwrap();
        assert_eq!(git.current_branch(dir.path()).await.unwrap(), "other");
    }

    #[tokio::test]
    async fn update_ref_moves_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();
        add_commit(dir.path(), "a.txt", "a", "a").await;
        // Move main to the base commit with update-ref. symbolic-ref still points to
        // main, so `rev-parse refs/heads/main` should now return `base`.
        git.update_ref(dir.path(), "refs/heads/main", &base)
            .await
            .unwrap();
        let r = git
            .rev_parse_verify(dir.path(), "refs/heads/main")
            .await
            .unwrap();
        assert_eq!(r, base);
    }

    // ── conflict helpers ───────────────────────────────────────────

    #[tokio::test]
    async fn has_merge_in_progress_false_then_true() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(!git.has_merge_in_progress(dir.path()).await.unwrap());

        make_conflict(dir.path(), "a", "b", "f.txt").await;
        // Attempt the merge — will conflict, not auto-abort here.
        let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;
        assert!(git.has_merge_in_progress(dir.path()).await.unwrap());
    }

    #[tokio::test]
    async fn has_rebase_in_progress_false_by_default() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(!git.has_rebase_in_progress(dir.path()).await.unwrap());
    }

    #[tokio::test]
    async fn staged_files_reports_added() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(git.staged_files(dir.path()).await.unwrap().is_empty());
        std::fs::write(dir.path().join("a.txt"), "a").unwrap();
        run_cmd(dir.path(), &["git", "add", "a.txt"]).await;
        assert_eq!(git.staged_files(dir.path()).await.unwrap(), vec!["a.txt"]);
    }

    #[tokio::test]
    async fn conflict_sections_both_modified_content() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        // Trigger the merge so the index holds stages 1/2/3.
        let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;

        let cf = git.conflict_sections(dir.path(), "f.txt").await.unwrap();
        assert_eq!(cf.path, "f.txt");
        assert_eq!(cf.kind, ConflictKind::BothModified);
        assert!(!cf.is_binary);
        assert_eq!(cf.base.as_deref(), Some(b"base line\n".as_slice()));
        assert_eq!(cf.ours.as_deref(), Some(b"from A\n".as_slice()));
        assert_eq!(cf.theirs.as_deref(), Some(b"from B\n".as_slice()));
    }

    #[tokio::test]
    async fn conflict_sections_deleted_by_us() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_deleted_by_us_conflict(dir.path(), "a", "b", "gone.txt").await;
        let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;
        let cf = git.conflict_sections(dir.path(), "gone.txt").await.unwrap();
        assert_eq!(cf.kind, ConflictKind::DeletedByUs);
        assert!(cf.base.is_some());
        assert!(cf.ours.is_none());
        assert!(cf.theirs.is_some());
    }

    #[tokio::test]
    async fn checkout_ours_resolves_content_conflict() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;

        git.checkout_ours(dir.path(), "f.txt").await.unwrap();
        let contents = std::fs::read_to_string(dir.path().join("f.txt")).unwrap();
        assert_eq!(contents, "from A\n");
        // The file is no longer unmerged (conflict_files reports empty).
        // Note: `staged_files` (diff --cached) may be empty because "ours"
        // content already matches HEAD for the current branch — that's
        // correct behaviour.
        let conflicts = git.conflict_files(dir.path()).await.unwrap();
        assert!(
            conflicts.iter().all(|f| f != "f.txt"),
            "f.txt should no longer be unmerged, got {conflicts:?}"
        );
    }

    #[tokio::test]
    async fn checkout_theirs_resolves_content_conflict() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;

        git.checkout_theirs(dir.path(), "f.txt").await.unwrap();
        let contents = std::fs::read_to_string(dir.path().join("f.txt")).unwrap();
        assert_eq!(contents, "from B\n");
    }

    #[tokio::test]
    async fn merge_continue_commits_resolved() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        make_conflict(dir.path(), "a", "b", "f.txt").await;
        let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;
        git.checkout_theirs(dir.path(), "f.txt").await.unwrap();

        let sha = git.merge_continue(dir.path(), None).await.unwrap();
        assert_eq!(sha.len(), 40);
        assert!(!git.has_merge_in_progress(dir.path()).await.unwrap());
    }
}
