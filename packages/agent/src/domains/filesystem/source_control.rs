//! Narrow Git repository inspection and session-checkout preparation.
//!
//! The iOS workspace picker consumes [`inspect_repository`] to decide whether
//! source-control placement is relevant. Session creation consumes
//! [`prepare_session_checkout`] while holding [`creation_guard`] so repository
//! mutations and durable session creation cannot race another in-process
//! placement request.
//!
//! This is product infrastructure, not a model-facing Git toolbox. Commands
//! use argument arrays (never a shell), disable credential prompting, and have
//! a fixed deadline. A failed durable session insert is compensated through
//! [`PreparedSessionCheckout::rollback`].

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::OnceLock;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tokio::sync::{Mutex, MutexGuard};

use crate::shared::server::errors::ToolError;

const SOURCE_CONTROL_ERROR: &str = "SOURCE_CONTROL_ERROR";
const GIT_DEADLINE: Duration = Duration::from_secs(15);

static SESSION_CREATION_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

/// Source-control placement requested for a newly created session.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SessionCheckoutPlacement {
    /// Keep the selected checkout and its current branch unchanged.
    Existing,
    /// Create and switch the selected checkout to a new session branch.
    Branch,
    /// Create an isolated worktree and branch outside the repository.
    Worktree,
}

/// Closed nested request admitted by `session::create`.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SessionSourceControlRequest {
    pub(crate) placement: SessionCheckoutPlacement,
}

/// Bounded repository facts used by the native workspace picker.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RepositoryInspection {
    pub(crate) is_git_repository: bool,
    pub(crate) current_branch: Option<String>,
}

#[derive(Debug)]
enum RollbackAction {
    DirectBranch {
        repo_root: PathBuf,
        previous_branch: Option<String>,
        previous_commit: String,
        created_branch: String,
    },
    Worktree {
        repo_root: PathBuf,
        worktree_path: PathBuf,
        created_branch: String,
    },
}

/// A resolved session directory plus compensation for pre-commit Git work.
pub(crate) struct PreparedSessionCheckout {
    pub(crate) working_directory: PathBuf,
    rollback: Option<RollbackAction>,
}

impl PreparedSessionCheckout {
    fn unchanged(working_directory: PathBuf) -> Self {
        Self {
            working_directory,
            rollback: None,
        }
    }

    /// Compensate a Git placement after durable session creation fails.
    pub(crate) async fn rollback(mut self) -> Result<(), ToolError> {
        let Some(action) = self.rollback.take() else {
            return Ok(());
        };
        match action {
            RollbackAction::DirectBranch {
                repo_root,
                previous_branch,
                previous_commit,
                created_branch,
            } => {
                if let Some(previous_branch) = previous_branch {
                    git_success(
                        &repo_root,
                        [OsStr::new("switch"), OsStr::new(&previous_branch)],
                    )
                    .await?;
                } else {
                    git_success(
                        &repo_root,
                        [
                            OsStr::new("switch"),
                            OsStr::new("--detach"),
                            OsStr::new(&previous_commit),
                        ],
                    )
                    .await?;
                }
                git_success(
                    &repo_root,
                    [
                        OsStr::new("branch"),
                        OsStr::new("-D"),
                        OsStr::new(&created_branch),
                    ],
                )
                .await
            }
            RollbackAction::Worktree {
                repo_root,
                worktree_path,
                created_branch,
            } => {
                git_success(
                    &repo_root,
                    [
                        OsStr::new("worktree"),
                        OsStr::new("remove"),
                        OsStr::new("--force"),
                        worktree_path.as_os_str(),
                    ],
                )
                .await?;
                git_success(
                    &repo_root,
                    [
                        OsStr::new("branch"),
                        OsStr::new("-D"),
                        OsStr::new(&created_branch),
                    ],
                )
                .await
            }
        }
    }
}

struct RepositoryLocation {
    root: PathBuf,
    current_branch: Option<String>,
    head_commit: String,
}

struct GitOutput {
    success: bool,
    stdout: String,
    stderr: String,
}

/// Serialize the short critical section spanning Git placement and durable
/// session insertion. New-session creation is rare, so one process-wide lock
/// is simpler and more reliable than a retained repository-lock registry.
pub(crate) async fn creation_guard() -> MutexGuard<'static, ()> {
    SESSION_CREATION_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .await
}

/// Inspect only enough repository state to conditionally render placement UI.
pub(crate) async fn inspect_repository(path: &Path) -> Result<RepositoryInspection, ToolError> {
    let repository = repository_location(path).await?;
    Ok(match repository {
        Some(repository) => RepositoryInspection {
            is_git_repository: true,
            current_branch: repository.current_branch,
        },
        None => RepositoryInspection {
            is_git_repository: false,
            current_branch: None,
        },
    })
}

/// Resolve and, when requested, materialize the checkout a new session owns.
///
/// The caller must hold [`creation_guard`] until durable session creation has
/// either committed or invoked [`PreparedSessionCheckout::rollback`].
pub(crate) async fn prepare_session_checkout(
    selected_directory: &Path,
    request: SessionSourceControlRequest,
    session_id: &str,
    worktree_storage_root: &Path,
) -> Result<PreparedSessionCheckout, ToolError> {
    let selected_directory = selected_directory.canonicalize().map_err(|error| {
        source_control_error(format!("Could not resolve the selected workspace: {error}"))
    })?;
    let repository = repository_location(&selected_directory)
        .await?
        .ok_or_else(|| ToolError::InvalidParams {
            message: "Source-control placement requires a Git working tree.".to_owned(),
        })?;
    let relative_directory = selected_directory
        .strip_prefix(&repository.root)
        .map_err(|_| source_control_error("Selected workspace is outside its Git root."))?
        .to_path_buf();
    let branch = session_branch_name(session_id);

    match request.placement {
        SessionCheckoutPlacement::Existing => Ok(PreparedSessionCheckout::unchanged(
            selected_directory.clone(),
        )),
        SessionCheckoutPlacement::Branch => {
            git_success(
                &repository.root,
                [OsStr::new("switch"), OsStr::new("-c"), OsStr::new(&branch)],
            )
            .await?;
            Ok(PreparedSessionCheckout {
                working_directory: selected_directory,
                rollback: Some(RollbackAction::DirectBranch {
                    repo_root: repository.root,
                    previous_branch: repository.current_branch,
                    previous_commit: repository.head_commit,
                    created_branch: branch,
                }),
            })
        }
        SessionCheckoutPlacement::Worktree => {
            std::fs::create_dir_all(worktree_storage_root).map_err(|error| {
                source_control_error(format!(
                    "Could not prepare the session worktree directory: {error}"
                ))
            })?;
            let worktree_path = worktree_storage_root.join(session_id);
            if worktree_path.exists() {
                return Err(source_control_error(
                    "The generated session worktree path already exists.",
                ));
            }
            git_success(
                &repository.root,
                [
                    OsStr::new("worktree"),
                    OsStr::new("add"),
                    OsStr::new("-b"),
                    OsStr::new(&branch),
                    worktree_path.as_os_str(),
                    OsStr::new("HEAD"),
                ],
            )
            .await?;

            let prepared = PreparedSessionCheckout {
                working_directory: worktree_path.join(relative_directory),
                rollback: Some(RollbackAction::Worktree {
                    repo_root: repository.root,
                    worktree_path,
                    created_branch: branch,
                }),
            };
            if let Err(error) = std::fs::create_dir_all(&prepared.working_directory) {
                let create_error = source_control_error(format!(
                    "Could not preserve the selected folder inside the new worktree: {error}"
                ));
                if let Err(rollback_error) = prepared.rollback().await {
                    return Err(source_control_error(format!(
                        "{create_error}; cleanup also failed: {rollback_error}"
                    )));
                }
                return Err(create_error);
            }
            match prepared.working_directory.canonicalize() {
                Ok(working_directory) => Ok(PreparedSessionCheckout {
                    working_directory,
                    rollback: prepared.rollback,
                }),
                Err(error) => {
                    let create_error = source_control_error(format!(
                        "The new session worktree did not contain the selected folder: {error}"
                    ));
                    if let Err(rollback_error) = prepared.rollback().await {
                        return Err(source_control_error(format!(
                            "{create_error}; cleanup also failed: {rollback_error}"
                        )));
                    }
                    Err(create_error)
                }
            }
        }
    }
}

fn session_branch_name(session_id: &str) -> String {
    format!("tron/{session_id}")
}

async fn repository_location(path: &Path) -> Result<Option<RepositoryLocation>, ToolError> {
    let inside = run_git(
        path,
        [OsStr::new("rev-parse"), OsStr::new("--is-inside-work-tree")],
    )
    .await?;
    if !inside.success || inside.stdout.trim() != "true" {
        return Ok(None);
    }

    let root = git_stdout(
        path,
        [OsStr::new("rev-parse"), OsStr::new("--show-toplevel")],
    )
    .await?;
    let root = PathBuf::from(root)
        .canonicalize()
        .map_err(|error| source_control_error(format!("Could not resolve Git root: {error}")))?;
    let head_commit = git_stdout(
        &root,
        [
            OsStr::new("rev-parse"),
            OsStr::new("--verify"),
            OsStr::new("HEAD"),
        ],
    )
    .await?;
    let branch_output = run_git(
        &root,
        [
            OsStr::new("symbolic-ref"),
            OsStr::new("--quiet"),
            OsStr::new("--short"),
            OsStr::new("HEAD"),
        ],
    )
    .await?;
    let current_branch = branch_output
        .success
        .then(|| branch_output.stdout.trim().to_owned())
        .filter(|branch| !branch.is_empty());
    Ok(Some(RepositoryLocation {
        root,
        current_branch,
        head_commit,
    }))
}

async fn git_stdout<'a>(
    cwd: &Path,
    args: impl IntoIterator<Item = &'a OsStr>,
) -> Result<String, ToolError> {
    let output = run_git(cwd, args).await?;
    if !output.success {
        return Err(git_failure(output));
    }
    Ok(output.stdout.trim().to_owned())
}

async fn git_success<'a>(
    cwd: &Path,
    args: impl IntoIterator<Item = &'a OsStr>,
) -> Result<(), ToolError> {
    let output = run_git(cwd, args).await?;
    if output.success {
        Ok(())
    } else {
        Err(git_failure(output))
    }
}

async fn run_git<'a>(
    cwd: &Path,
    args: impl IntoIterator<Item = &'a OsStr>,
) -> Result<GitOutput, ToolError> {
    let args = args
        .into_iter()
        .map(OsString::from)
        .collect::<Vec<OsString>>();
    let mut command = Command::new("git");
    let _ = command
        .args(&args)
        .current_dir(cwd)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(GIT_DEADLINE, command.output())
        .await
        .map_err(|_| source_control_error("Git did not finish within 15 seconds."))?
        .map_err(|error| source_control_error(format!("Could not launch Git: {error}")))?;
    Ok(GitOutput {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

fn git_failure(output: GitOutput) -> ToolError {
    let detail = output.stderr.trim();
    source_control_error(if detail.is_empty() {
        "Git rejected the requested session placement.".to_owned()
    } else {
        format!("Git rejected the requested session placement: {detail}")
    })
}

fn source_control_error(message: impl Into<String>) -> ToolError {
    ToolError::Custom {
        code: SOURCE_CONTROL_ERROR.to_owned(),
        message: message.into(),
        details: None,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::Command as StdCommand;

    use tempfile::tempdir;

    use super::*;

    fn git(cwd: &Path, args: &[&str]) {
        let status = StdCommand::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_TERMINAL_PROMPT", "0")
            .status()
            .expect("launch git");
        assert!(status.success(), "git {args:?}");
    }

    fn git_succeeds(cwd: &Path, args: &[&str]) -> bool {
        StdCommand::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_TERMINAL_PROMPT", "0")
            .status()
            .expect("launch git")
            .success()
    }

    fn repository() -> tempfile::TempDir {
        let repository = tempdir().expect("repository");
        git(repository.path(), &["init", "--quiet"]);
        git(repository.path(), &["config", "user.name", "Tron Test"]);
        git(
            repository.path(),
            &["config", "user.email", "test@example.invalid"],
        );
        fs::create_dir(repository.path().join("Sources")).expect("source directory");
        fs::write(repository.path().join("README.md"), "test\n").expect("fixture");
        git(repository.path(), &["add", "README.md"]);
        git(repository.path(), &["commit", "--quiet", "-m", "Initial"]);
        repository
    }

    #[tokio::test]
    async fn inspection_distinguishes_git_and_plain_directories() {
        let plain = tempdir().expect("plain");
        assert_eq!(
            inspect_repository(plain.path()).await.expect("plain"),
            RepositoryInspection {
                is_git_repository: false,
                current_branch: None,
            }
        );

        let repository = repository();
        let inspected = inspect_repository(repository.path())
            .await
            .expect("repository");
        assert!(inspected.is_git_repository);
        assert!(inspected.current_branch.is_some());
    }

    #[test]
    fn placement_request_is_closed_and_uses_stable_wire_values() {
        let request: SessionSourceControlRequest = serde_json::from_value(serde_json::json!({
            "placement": "worktree"
        }))
        .expect("valid placement");
        assert_eq!(request.placement, SessionCheckoutPlacement::Worktree);
        assert!(
            serde_json::from_value::<SessionSourceControlRequest>(serde_json::json!({
                "placement": "worktree",
                "branchName": "untrusted"
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<SessionSourceControlRequest>(serde_json::json!({
                "placement": "arbitrary"
            }))
            .is_err()
        );
    }

    #[tokio::test]
    async fn branch_placement_switches_and_rolls_back_exactly() {
        let repository = repository();
        let before = inspect_repository(repository.path())
            .await
            .expect("before")
            .current_branch;
        let storage = tempdir().expect("storage");
        let prepared = prepare_session_checkout(
            repository.path(),
            SessionSourceControlRequest {
                placement: SessionCheckoutPlacement::Branch,
            },
            "sess_branch_test",
            storage.path(),
        )
        .await
        .expect("prepare branch");
        assert_eq!(
            prepared.working_directory,
            repository.path().canonicalize().unwrap()
        );
        assert_eq!(
            inspect_repository(repository.path())
                .await
                .expect("after")
                .current_branch
                .as_deref(),
            Some("tron/sess_branch_test")
        );
        prepared.rollback().await.expect("rollback");
        assert_eq!(
            inspect_repository(repository.path())
                .await
                .expect("rolled back")
                .current_branch,
            before
        );
        assert!(!git_succeeds(
            repository.path(),
            &[
                "show-ref",
                "--verify",
                "--quiet",
                "refs/heads/tron/sess_branch_test"
            ]
        ));
    }

    #[tokio::test]
    async fn worktree_placement_preserves_selected_subdirectory() {
        let repository = repository();
        let original_branch = inspect_repository(repository.path())
            .await
            .expect("before")
            .current_branch;
        let storage = tempdir().expect("storage");
        let prepared = prepare_session_checkout(
            &repository.path().join("Sources"),
            SessionSourceControlRequest {
                placement: SessionCheckoutPlacement::Worktree,
            },
            "sess_worktree_test",
            storage.path(),
        )
        .await
        .expect("prepare worktree");
        assert!(
            prepared
                .working_directory
                .ends_with("sess_worktree_test/Sources")
        );
        assert!(prepared.working_directory.is_dir());
        assert_eq!(
            inspect_repository(repository.path())
                .await
                .expect("main checkout")
                .current_branch,
            original_branch
        );
        assert_eq!(
            inspect_repository(&prepared.working_directory)
                .await
                .expect("worktree checkout")
                .current_branch
                .as_deref(),
            Some("tron/sess_worktree_test")
        );
        let checkout_root = storage.path().join("sess_worktree_test");
        prepared.rollback().await.expect("rollback");
        assert!(!checkout_root.exists());
        assert!(!git_succeeds(
            repository.path(),
            &[
                "show-ref",
                "--verify",
                "--quiet",
                "refs/heads/tron/sess_worktree_test"
            ]
        ));
    }
}
