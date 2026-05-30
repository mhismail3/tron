use std::path::Path;
use std::time::Duration;

use crate::domains::worktree::errors::Result;
use crate::domains::worktree::git::{GitExecutor, classify_push_error, classify_remote_error};
use crate::domains::worktree::types::PushOutput;

impl GitExecutor {
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
}
