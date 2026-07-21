//! Isolated Git worktree and bounded test-process mechanics for core proposals.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::io::AsyncWriteExt;

use super::{MAX_CORE_TEST_EVIDENCE_BYTES, bounded};
use crate::domains::worker_kernel::process::{
    ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};

pub(super) async fn cleanup_failed_worktree(repository: &Path, worktree: &Path, branch: &str) {
    let _ = run_git(
        repository,
        &[
            "worktree",
            "remove",
            "--force",
            worktree.to_string_lossy().as_ref(),
        ],
        None,
    )
    .await;
    let _ = run_git(repository, &["branch", "-D", branch], None).await;
}

pub(super) async fn git_state_path(repository: &Path, state: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(
        run_git(repository, &["rev-parse", "--git-path", state], None)
            .await?
            .trim(),
    );
    Ok(if path.is_absolute() {
        path
    } else {
        repository.join(path)
    })
}

pub(super) async fn run_git(
    cwd: &Path,
    arguments: &[&str],
    stdin: Option<&str>,
) -> Result<String, String> {
    let mut command = tokio::process::Command::new("git");
    command
        .args(arguments)
        .current_dir(cwd)
        .env("PATH", trusted_local_command_path(None)?)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|error| format!("start git: {error}"))?;
    if let (Some(value), Some(mut child_stdin)) = (stdin, child.stdin.take()) {
        child_stdin
            .write_all(value.as_bytes())
            .await
            .map_err(|error| format!("write git stdin: {error}"))?;
    }
    let output = child
        .wait_with_output()
        .await
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "git {} failed: {}",
            arguments.join(" "),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

pub(super) async fn run_command(cwd: &Path, command: &[String]) -> Result<String, String> {
    let (program, arguments) = command
        .split_first()
        .ok_or_else(|| "core proposal test command is empty".to_owned())?;
    let mut command = tokio::process::Command::new(program);
    command
        .args(arguments)
        .current_dir(cwd)
        .env("PATH", trusted_local_command_path(None)?)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child = ProcessTree::spawn(&mut command)
        .map_err(|error| format!("run core proposal tests: {error}"))?;
    let output = wait_with_bounded_output(
        child,
        None,
        std::time::Duration::from_secs(7_200),
        "core proposal tests exceeded two hours".to_owned(),
        MAX_CORE_TEST_EVIDENCE_BYTES,
    )
    .await
    .map_err(|error| format!("run core proposal tests: {error}"))?;
    let mut combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if output.stdout_truncated || output.stderr_truncated {
        combined.push_str("\n[test output truncated while the remaining pipes were drained]");
    }
    if !output.status.success() {
        return Err(format!(
            "core proposal tests failed: {}",
            bounded(combined, MAX_CORE_TEST_EVIDENCE_BYTES)
        ));
    }
    Ok(combined)
}
