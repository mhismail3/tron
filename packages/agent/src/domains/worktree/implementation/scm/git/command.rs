use std::path::Path;
use std::time::Duration;

use tracing::{debug, warn};

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::git::GitExecutor;

impl GitExecutor {
    // ────────────────────────────────────────────────────────────────
    // Internal helpers
    // ────────────────────────────────────────────────────────────────

    /// Public form of `git_dir` — resolves the worktree's `.git` directory
    /// (or worktree git-dir) as an absolute path.
    pub async fn git_dir_path(&self, dir: &Path) -> Result<std::path::PathBuf> {
        self.git_dir(dir).await.map(std::path::PathBuf::from)
    }

    /// Resolve `.git` directory for a worktree / repo.
    pub(super) async fn git_dir(&self, dir: &Path) -> Result<String> {
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
    pub(super) async fn show_blob_bytes(&self, dir: &Path, spec: &str) -> Result<Vec<u8>> {
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

    pub(super) async fn run_stdout_bytes(&self, dir: &Path, args: &[&str]) -> Result<Vec<u8>> {
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
    pub(super) async fn run_capture(
        &self,
        dir: &Path,
        args: &[&str],
    ) -> Result<(String, String, bool)> {
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
    pub(super) async fn run_with_timeout(
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
    pub(super) async fn run_with_env(
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
    pub(super) async fn run_status(&self, dir: &Path, args: &[&str]) -> bool {
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
