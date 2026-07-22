//! Isolated Git worktree and bounded test-process mechanics for core proposals.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::io::AsyncWriteExt;

use super::{MAX_CORE_TEST_EVIDENCE_BYTES, bounded};
use crate::domains::worker_kernel::process::{
    ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};

pub(super) async fn cleanup_failed_worktree(
    repository: &Path,
    proposal_dir: &Path,
    worktree: &Path,
    branch: &str,
) -> Result<(), String> {
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
    let _ = if worktree.exists() {
        std::fs::remove_dir_all(worktree)
    } else {
        Ok(())
    };
    let _ = run_git(repository, &["worktree", "prune"], None).await;
    let branch_ref = format!("refs/heads/{branch}");
    if run_git(
        repository,
        &["show-ref", "--verify", "--quiet", &branch_ref],
        None,
    )
    .await
    .is_ok()
    {
        let _ = run_git(repository, &["branch", "-D", branch], None).await;
    }
    let _ = if proposal_dir.exists() {
        std::fs::remove_dir_all(proposal_dir)
    } else {
        Ok(())
    };

    let mut failures = Vec::new();
    if worktree.exists() {
        failures.push(format!(
            "core proposal worktree still exists at {}",
            worktree.display()
        ));
    }
    if proposal_dir.exists() {
        failures.push(format!(
            "core proposal directory still exists at {}",
            proposal_dir.display()
        ));
    }
    match run_git(repository, &["worktree", "list", "--porcelain"], None).await {
        Ok(list) if worktree_is_registered(&list, worktree) => failures.push(format!(
            "core proposal worktree remains registered at {}",
            worktree.display()
        )),
        Ok(_) => {}
        Err(error) => failures.push(format!("verify core proposal worktree cleanup: {error}")),
    }
    match run_git(repository, &["branch", "--list", branch], None).await {
        Ok(branches) if !branches.trim().is_empty() => {
            failures.push(format!("core proposal branch still exists: {branch}"));
        }
        Ok(_) => {}
        Err(error) => failures.push(format!("verify core proposal branch cleanup: {error}")),
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}

/// Remove the temporary worktree after its tested commit has been captured.
/// The proposal branch remains as the durable Git owner of that commit until
/// the proposal is applied or explicitly discarded.
pub(super) async fn cleanup_prepared_worktree(
    repository: &Path,
    worktree: &Path,
) -> Result<(), String> {
    run_git(
        repository,
        &[
            "worktree",
            "remove",
            "--force",
            worktree.to_string_lossy().as_ref(),
        ],
        None,
    )
    .await?;
    run_git(repository, &["worktree", "prune"], None).await?;
    let registered = run_git(repository, &["worktree", "list", "--porcelain"], None).await?;
    if worktree.exists() || worktree_is_registered(&registered, worktree) {
        return Err(format!(
            "prepared core proposal worktree still exists at {}",
            worktree.display()
        ));
    }
    Ok(())
}

fn worktree_is_registered(list: &str, worktree: &Path) -> bool {
    let expected = worktree.to_string_lossy();
    list.lines()
        .filter_map(|line| line.strip_prefix("worktree "))
        .any(|registered| registered == expected)
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
