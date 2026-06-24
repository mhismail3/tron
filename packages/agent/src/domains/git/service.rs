use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

use serde_json::{Value, json};

use crate::engine::{Invocation, RUNTIME_METADATA_WORKING_DIRECTORY};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

use super::types::{
    DEFAULT_DIFF_BYTES, DEFAULT_STATUS_BYTES, MAX_DIFF_BYTES, MAX_STATUS_BYTES, RepositoryFacts,
    ResolvedTarget, SCHEMA_VERSION,
};

const MAX_GIT_STDERR_BYTES: usize = 4 * 1024;
static SYNTHETIC_GIT_DIR_COUNTER: AtomicU64 = AtomicU64::new(0);

pub(crate) async fn status_value(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let invocation = invocation.clone();
    let request = payload.clone();
    run_blocking_task("git::status", move || {
        status_value_sync(&invocation, &request)
    })
    .await
}

pub(crate) async fn diff_value(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let invocation = invocation.clone();
    let request = payload.clone();
    run_blocking_task("git::diff", move || diff_value_sync(&invocation, &request)).await
}

fn status_value_sync(invocation: &Invocation, payload: &Value) -> Result<Value, CapabilityError> {
    let target = resolve_target(invocation, payload)?;
    let repository = repository_facts(&target)?;
    let max_status_bytes = optional_usize(payload, "maxStatusBytes")?
        .unwrap_or(DEFAULT_STATUS_BYTES)
        .min(MAX_STATUS_BYTES);
    let status_output = git_output_bounded(
        &repository.worktree_root,
        [
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--",
            repository.pathspec.as_str(),
        ],
        max_status_bytes,
    )?;
    let summary = parse_status(complete_status_records(
        &status_output.stdout,
        status_output.stdout_truncated,
    ));
    let status_porcelain = String::from_utf8_lossy(&status_output.stdout).into_owned();

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "status": "ok",
        "operation": "status",
        "path": path_value(&target),
        "repository": repository_value(&target, &repository),
        "dirty": summary.dirty(),
        "summary": summary.summary_value(),
        "staged": summary.staged,
        "unstaged": summary.unstaged,
        "untracked": summary.untracked,
        "conflicted": summary.conflicted,
        "evidence": {
            "statusPorcelainV1Z": status_porcelain,
            "statusTruncated": status_output.stdout_truncated,
            "statusLimitBytes": max_status_bytes,
            "resourceRefs": []
        }
    }))
}

fn diff_value_sync(invocation: &Invocation, payload: &Value) -> Result<Value, CapabilityError> {
    let target = resolve_target(invocation, payload)?;
    let repository = repository_facts(&target)?;
    let max_diff_bytes = optional_usize(payload, "maxDiffBytes")?
        .unwrap_or(DEFAULT_DIFF_BYTES)
        .min(MAX_DIFF_BYTES);
    let status_output = git_status_counts_bounded(
        &repository.worktree_root,
        [
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--",
            repository.pathspec.as_str(),
        ],
        MAX_STATUS_BYTES,
    )?;
    let staged = git_diff_text(
        &repository.worktree_root,
        true,
        &repository.pathspec,
        max_diff_bytes,
    )?;
    let unstaged = git_diff_text(
        &repository.worktree_root,
        false,
        &repository.pathspec,
        max_diff_bytes,
    )?;
    let truncated = staged.1 || unstaged.1;

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "status": "ok",
        "operation": "diff",
        "path": path_value(&target),
        "repository": repository_value(&target, &repository),
        "dirty": status_output.counts.dirty(),
        "summary": status_output.counts.summary_value(),
        "diffs": {
            "staged": {
                "text": staged.0,
                "truncated": staged.1,
                "limitBytes": max_diff_bytes
            },
            "unstaged": {
                "text": unstaged.0,
                "truncated": unstaged.1,
                "limitBytes": max_diff_bytes
            }
        },
        "truncated": truncated,
        "evidence": {
            "statusPreflightTruncated": status_output.stdout_truncated,
            "statusPreflightLimitBytes": MAX_STATUS_BYTES,
            "statusPreflightRetainedBytes": status_output.stdout.len(),
            "resourceRefs": []
        }
    }))
}

pub(super) fn git_diff_text(
    worktree_root: &Path,
    staged: bool,
    pathspec: &str,
    max_bytes: usize,
) -> Result<(String, bool), CapabilityError> {
    let args = if staged {
        vec![
            "diff",
            "--cached",
            "--no-ext-diff",
            "--no-color",
            "--no-textconv",
            "--",
            pathspec,
        ]
    } else {
        vec![
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--no-textconv",
            "--",
            pathspec,
        ]
    };
    let output = git_output_bounded(worktree_root, args, max_bytes)?;
    Ok((
        String::from_utf8_lossy(&output.stdout).into_owned(),
        output.stdout_truncated,
    ))
}

fn git_status_counts_bounded<I, S>(
    dir: &Path,
    args: I,
    stdout_limit: usize,
) -> Result<BoundedGitStatusCounts, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = git_status_command_bounded(dir, args, stdout_limit)?;
    if output.status.success() {
        return Ok(output);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(CapabilityError::Custom {
        code: "GIT_COMMAND_FAILED".to_owned(),
        message: truncate_chars(stderr.trim(), 1_000),
        details: None,
    })
}

pub(super) fn repository_facts(
    target: &ResolvedTarget,
) -> Result<RepositoryFacts, CapabilityError> {
    let git_dir = if target.canonical.is_dir() {
        target.canonical.as_path()
    } else {
        target
            .canonical
            .parent()
            .ok_or_else(|| invalid("git path has no parent directory"))?
    };
    let worktree_stdout = git_output_allow_not_repo(git_dir, ["rev-parse", "--show-toplevel"])?;
    let worktree_root = PathBuf::from(trim_stdout(&worktree_stdout.stdout))
        .canonicalize()
        .map_err(|error| internal(format!("canonicalize git worktree root: {error}")))?;
    if !worktree_root.starts_with(&target.working_root) {
        return Err(invalid(
            "git worktree root escapes trusted working-directory root",
        ));
    }
    let worktree_relative_path = relative_to(&target.working_root, &worktree_root);
    let pathspec = relative_to(&worktree_root, &target.canonical);
    let branch = git_optional_stdout(
        &worktree_root,
        ["symbolic-ref", "--quiet", "--short", "HEAD"],
    )?;
    let head_oid = git_optional_stdout(&worktree_root, ["rev-parse", "--verify", "HEAD"])?;
    let head_tree_oid =
        git_optional_stdout(&worktree_root, ["rev-parse", "--verify", "HEAD^{tree}"])?;
    let index_tree_oid = staged_index_tree_oid(&worktree_root)?;
    let upstream = git_optional_stdout(
        &worktree_root,
        [
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    )?;
    let (ahead, behind) = if upstream.is_some() {
        let counts = git_optional_stdout(
            &worktree_root,
            ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
        )?;
        parse_ahead_behind(counts.as_deref())
    } else {
        (None, None)
    };

    Ok(RepositoryFacts {
        worktree_root,
        worktree_relative_path: if worktree_relative_path.is_empty() {
            ".".to_owned()
        } else {
            worktree_relative_path
        },
        pathspec: if pathspec.is_empty() {
            ".".to_owned()
        } else {
            pathspec
        },
        detached_head: branch.is_none() && head_oid.is_some(),
        branch,
        head_oid,
        head_tree_oid,
        index_tree_oid,
        upstream,
        ahead,
        behind,
    })
}

pub(super) fn resolve_target(
    invocation: &Invocation,
    payload: &Value,
) -> Result<ResolvedTarget, CapabilityError> {
    let working_root = working_root(invocation)?;
    let raw = optional_str(payload, "path")?.unwrap_or(".");
    let path = clean_relative_path(raw)?;
    let candidate = if path.as_os_str().is_empty() {
        working_root.clone()
    } else {
        working_root.join(path)
    };
    let canonical = candidate
        .canonicalize()
        .map_err(|error| map_io_error(error, &candidate))?;
    if !canonical.starts_with(&working_root) {
        return Err(invalid(format!("path escapes trusted root: {raw}")));
    }
    let relative_path = relative_to(&working_root, &canonical);
    Ok(ResolvedTarget {
        working_root,
        canonical,
        relative_path: if relative_path.is_empty() {
            ".".to_owned()
        } else {
            relative_path
        },
    })
}

fn working_root(invocation: &Invocation) -> Result<PathBuf, CapabilityError> {
    let raw = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
        .ok_or_else(|| invalid("git operations require trusted working directory metadata"))?;
    crate::shared::foundation::paths::normalize_working_directory(raw).map_err(internal)
}

fn clean_relative_path(raw: &str) -> Result<PathBuf, CapabilityError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(invalid("path must not be empty"));
    }
    let requested = Path::new(raw);
    if requested.is_absolute() {
        return Err(invalid("git operation paths must be relative"));
    }
    let mut clean = PathBuf::new();
    for component in requested.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => clean.push(part),
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(invalid("git operation paths must not escape the root"));
            }
        }
    }
    Ok(clean)
}

fn git_optional_stdout<I, S>(dir: &Path, args: I) -> Result<Option<String>, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = git_command(dir, args)?;
    if !output.status.success() {
        return Ok(None);
    }
    Ok(Some(trim_stdout(&output.stdout)))
}

fn git_output_allow_not_repo<I, S>(
    dir: &Path,
    args: I,
) -> Result<std::process::Output, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = git_command(dir, args)?;
    if output.status.success() {
        return Ok(output);
    }
    Err(CapabilityError::NotFound {
        code: "GIT_REPOSITORY_NOT_FOUND".to_owned(),
        message: "path is not inside a Git worktree".to_owned(),
    })
}

pub(super) fn git_output_bounded<I, S>(
    dir: &Path,
    args: I,
    stdout_limit: usize,
) -> Result<BoundedGitOutput, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = git_command_bounded(dir, args, stdout_limit)?;
    if output.status.success() {
        return Ok(output);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(CapabilityError::Custom {
        code: "GIT_COMMAND_FAILED".to_owned(),
        message: truncate_chars(stderr.trim(), 1_000),
        details: None,
    })
}

pub(super) fn git_output_status_bounded<I, S>(
    dir: &Path,
    args: I,
    stdout_limit: usize,
) -> Result<BoundedGitOutput, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    git_command_bounded(dir, args, stdout_limit)
}

pub(super) fn git_symbolic_head_ref(
    worktree_root: &Path,
) -> Result<Option<String>, CapabilityError> {
    git_optional_stdout(worktree_root, ["symbolic-ref", "--quiet", "HEAD"])
}

pub(super) fn git_commit_tree_output_bounded(
    dir: &Path,
    tree_oid: &str,
    parent_oid: &str,
    message: &str,
    stdout_limit: usize,
) -> Result<BoundedGitOutput, CapabilityError> {
    let mut child = git_command_base(dir)
        .arg("-c")
        .arg("commit.gpgSign=false")
        .arg("-c")
        .arg("gpg.program=false")
        .arg("-c")
        .arg("core.pager=cat")
        .arg("-c")
        .arg("credential.helper=")
        .arg("commit-tree")
        .arg(tree_oid)
        .arg("-p")
        .arg(parent_oid)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .env("PAGER", "cat")
        .env("GIT_ASKPASS", "/bin/false")
        .env("SSH_ASKPASS", "/bin/false")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| internal(format!("run git commit-tree: {error}")))?;
    child
        .stdin
        .take()
        .ok_or_else(|| internal("open git commit-tree stdin"))?
        .write_all(message.as_bytes())
        .map_err(|error| internal(format!("write git commit-tree stdin: {error}")))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| internal("capture git commit-tree stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| internal("capture git commit-tree stderr"))?;
    let stdout_reader = thread::spawn(move || read_bounded(stdout, stdout_limit));
    let stderr_reader = thread::spawn(move || read_bounded(stderr, MAX_GIT_STDERR_BYTES));
    let status = child
        .wait()
        .map_err(|error| internal(format!("wait for git commit-tree: {error}")))?;
    let (stdout, stdout_truncated) = stdout_reader
        .join()
        .map_err(|_| internal("join git commit-tree stdout reader"))?
        .map_err(|error| internal(format!("read git commit-tree stdout: {error}")))?;
    let (stderr, _stderr_truncated) = stderr_reader
        .join()
        .map_err(|_| internal("join git commit-tree stderr reader"))?
        .map_err(|error| internal(format!("read git commit-tree stderr: {error}")))?;
    Ok(BoundedGitOutput {
        status,
        stdout,
        stdout_truncated,
        stderr,
    })
}

pub(super) fn git_update_ref_git_dir_output_bounded(
    git_dir: &Path,
    ref_name: &str,
    new_oid: &str,
    expected_old_oid: &str,
    stdout_limit: usize,
) -> Result<BoundedGitOutput, CapabilityError> {
    let mut child = Command::new("git")
        .arg("--no-optional-locks")
        .arg("--git-dir")
        .arg(git_dir)
        .arg("update-ref")
        .arg(ref_name)
        .arg(new_oid)
        .arg(expected_old_oid)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| internal(format!("run git update-ref: {error}")))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| internal("capture git update-ref stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| internal("capture git update-ref stderr"))?;
    let stdout_reader = thread::spawn(move || read_bounded(stdout, stdout_limit));
    let stderr_reader = thread::spawn(move || read_bounded(stderr, MAX_GIT_STDERR_BYTES));
    let status = child
        .wait()
        .map_err(|error| internal(format!("wait for git update-ref: {error}")))?;
    let (stdout, stdout_truncated) = stdout_reader
        .join()
        .map_err(|_| internal("join git update-ref stdout reader"))?
        .map_err(|error| internal(format!("read git update-ref stdout: {error}")))?;
    let (stderr, _stderr_truncated) = stderr_reader
        .join()
        .map_err(|_| internal("join git update-ref stderr reader"))?
        .map_err(|error| internal(format!("read git update-ref stderr: {error}")))?;
    Ok(BoundedGitOutput {
        status,
        stdout,
        stdout_truncated,
        stderr,
    })
}

pub(super) fn git_update_branch_ref_with_locked_head(
    worktree_root: &Path,
    branch_ref: &str,
    new_oid: &str,
    expected_old_oid: &str,
    stdout_limit: usize,
) -> Result<BoundedGitOutput, CapabilityError> {
    let _head_lock = WorktreeHeadLock::acquire(worktree_root)?;
    let actual_head_ref = git_symbolic_head_ref(worktree_root)?
        .ok_or_else(|| invalid("git_commit rejects detached HEAD before ref update"))?;
    if actual_head_ref != branch_ref {
        return Err(invalid(format!(
            "git_commit rejects branch changes before ref update: expected {branch_ref}, actual {actual_head_ref}"
        )));
    }
    let git_dir = SyntheticGitDir::create(worktree_root, expected_old_oid)?;
    git_update_ref_git_dir_output_bounded(
        git_dir.path(),
        branch_ref,
        new_oid,
        expected_old_oid,
        stdout_limit,
    )
}

struct WorktreeHeadLock {
    path: PathBuf,
    _file: File,
}

impl WorktreeHeadLock {
    fn acquire(worktree_root: &Path) -> Result<Self, CapabilityError> {
        let head_path = git_path(worktree_root, "HEAD")?;
        let head_file_name = head_path
            .file_name()
            .ok_or_else(|| internal("git HEAD path has no file name"))?;
        let mut lock_path = head_path.clone();
        lock_path.set_file_name(format!("{}.lock", head_file_name.to_string_lossy()));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
            .map_err(|error| {
                invalid(format!(
                    "git_commit could not lock HEAD before ref update: {error}"
                ))
            })?;
        file.write_all(b"tron git_commit guarded ref update\n")
            .map_err(|error| internal(format!("write git HEAD lock: {error}")))?;
        Ok(Self {
            path: lock_path,
            _file: file,
        })
    }
}

impl Drop for WorktreeHeadLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

struct SyntheticGitDir {
    path: PathBuf,
}

impl SyntheticGitDir {
    fn create(worktree_root: &Path, expected_head: &str) -> Result<Self, CapabilityError> {
        let common_dir = git_common_dir(worktree_root)?;
        let base = std::env::temp_dir();
        let sequence = SYNTHETIC_GIT_DIR_COUNTER.fetch_add(1, Ordering::Relaxed);
        for attempt in 0..1024 {
            let path = base.join(format!("tron-update-ref-{sequence}-{attempt}"));
            match fs::create_dir(&path) {
                Ok(()) => {
                    fs::write(
                        path.join("commondir"),
                        format!("{}\n", common_dir.display()),
                    )
                    .map_err(|error| internal(format!("write synthetic git commondir: {error}")))?;
                    fs::write(path.join("HEAD"), format!("{expected_head}\n"))
                        .map_err(|error| internal(format!("write synthetic git HEAD: {error}")))?;
                    return Ok(Self { path });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(internal(format!("create synthetic git dir: {error}")));
                }
            }
        }
        Err(internal("create synthetic git dir: exhausted unique names"))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for SyntheticGitDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn git_common_dir(worktree_root: &Path) -> Result<PathBuf, CapabilityError> {
    let output = git_output_bounded(
        worktree_root,
        ["rev-parse", "--git-common-dir"],
        MAX_GIT_STDERR_BYTES,
    )?;
    let raw = trim_stdout(&output.stdout);
    if raw.is_empty() {
        return Err(internal("git rev-parse returned empty common dir"));
    }
    Ok(resolve_git_path_output(worktree_root, &raw))
}

fn git_path(worktree_root: &Path, path: &str) -> Result<PathBuf, CapabilityError> {
    let output = git_output_bounded(
        worktree_root,
        ["rev-parse", "--git-path", path],
        MAX_GIT_STDERR_BYTES,
    )?;
    let raw = trim_stdout(&output.stdout);
    if raw.is_empty() {
        return Err(internal(format!(
            "git rev-parse returned empty git path for {path}"
        )));
    }
    Ok(resolve_git_path_output(worktree_root, &raw))
}

fn resolve_git_path_output(worktree_root: &Path, raw: &str) -> PathBuf {
    let path = PathBuf::from(raw);
    if path.is_absolute() {
        path
    } else {
        worktree_root.join(path)
    }
}

fn staged_index_tree_oid(worktree_root: &Path) -> Result<Option<String>, CapabilityError> {
    staged_index_tree_oid_with_limit(worktree_root, MAX_STATUS_BYTES)
}

fn staged_index_tree_oid_with_limit(
    worktree_root: &Path,
    stdout_limit: usize,
) -> Result<Option<String>, CapabilityError> {
    let output = git_output_bounded(worktree_root, ["ls-files", "-s", "-z"], stdout_limit)?;
    if output.stdout_truncated {
        return Err(invalid(
            "git index tree calculation refused truncated index listing",
        ));
    }
    let mut root = TreeNode::default();
    for record in output.stdout.split(|byte| *byte == 0) {
        if record.is_empty() {
            continue;
        }
        let Some(tab_index) = record.iter().position(|byte| *byte == b'\t') else {
            return Err(internal("parse git index entry"));
        };
        let metadata = String::from_utf8_lossy(&record[..tab_index]);
        let mut parts = metadata.split_whitespace();
        let mode = parts
            .next()
            .ok_or_else(|| internal("parse git index entry mode"))?
            .as_bytes()
            .to_vec();
        let oid = parts
            .next()
            .ok_or_else(|| internal("parse git index entry oid"))?
            .to_owned();
        let stage = parts
            .next()
            .ok_or_else(|| internal("parse git index entry stage"))?;
        if stage != "0" {
            return Ok(None);
        }
        root.insert(&record[tab_index + 1..], mode, oid)?;
    }
    hash_tree_node(worktree_root, &root).map(Some)
}

fn hash_tree_node(worktree_root: &Path, node: &TreeNode) -> Result<String, CapabilityError> {
    let mut content = Vec::new();
    for (name, entry) in node.sorted_entries() {
        match entry {
            TreeEntry::Blob { mode, oid } => {
                content.extend_from_slice(mode);
                content.push(b' ');
                content.extend_from_slice(name);
                content.push(0);
                content.extend_from_slice(
                    &hex::decode(oid).map_err(|error| internal(format!("decode oid: {error}")))?,
                );
            }
            TreeEntry::Tree(child) => {
                let oid = hash_tree_node(worktree_root, child)?;
                content.extend_from_slice(b"40000 ");
                content.extend_from_slice(name);
                content.push(0);
                content.extend_from_slice(
                    &hex::decode(oid).map_err(|error| internal(format!("decode oid: {error}")))?,
                );
            }
        }
    }
    git_hash_tree_content(worktree_root, &content)
}

fn git_hash_tree_content(worktree_root: &Path, content: &[u8]) -> Result<String, CapabilityError> {
    let mut child = git_command_base(worktree_root)
        .arg("hash-object")
        .arg("-t")
        .arg("tree")
        .arg("--stdin")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| internal(format!("run git hash-object: {error}")))?;
    child
        .stdin
        .take()
        .ok_or_else(|| internal("open git hash-object stdin"))?
        .write_all(content)
        .map_err(|error| internal(format!("write git hash-object stdin: {error}")))?;
    let output = child
        .wait_with_output()
        .map_err(|error| internal(format!("wait for git hash-object: {error}")))?;
    if output.status.success() {
        return Ok(trim_stdout(&output.stdout));
    }
    Err(CapabilityError::Custom {
        code: "GIT_COMMAND_FAILED".to_owned(),
        message: truncate_chars(String::from_utf8_lossy(&output.stderr).trim(), 1_000),
        details: None,
    })
}

#[derive(Default)]
struct TreeNode {
    entries: BTreeMap<Vec<u8>, TreeEntry>,
}

impl TreeNode {
    fn insert(&mut self, path: &[u8], mode: Vec<u8>, oid: String) -> Result<(), CapabilityError> {
        let mut components = path.split(|byte| *byte == b'/').collect::<Vec<_>>();
        if components.is_empty() || components[0].is_empty() {
            return Err(internal("parse empty git index path"));
        }
        let name = components.remove(0);
        if components.is_empty() {
            self.entries
                .insert(name.to_vec(), TreeEntry::Blob { mode, oid });
            return Ok(());
        }
        let entry = self
            .entries
            .entry(name.to_vec())
            .or_insert_with(|| TreeEntry::Tree(TreeNode::default()));
        let TreeEntry::Tree(child) = entry else {
            return Err(internal(
                "git index contains file and directory path collision",
            ));
        };
        child.insert(&components.join(&b'/'), mode, oid)
    }

    fn sorted_entries(&self) -> Vec<(&Vec<u8>, &TreeEntry)> {
        let mut entries = self.entries.iter().collect::<Vec<_>>();
        entries.sort_by(|(left_name, left_entry), (right_name, right_entry)| {
            git_tree_name_cmp(
                left_name,
                matches!(left_entry, TreeEntry::Tree(_)),
                right_name,
                matches!(right_entry, TreeEntry::Tree(_)),
            )
        });
        entries
    }
}

enum TreeEntry {
    Blob { mode: Vec<u8>, oid: String },
    Tree(TreeNode),
}

fn git_tree_name_cmp(
    left: &[u8],
    left_tree: bool,
    right: &[u8],
    right_tree: bool,
) -> std::cmp::Ordering {
    let common = left.len().min(right.len());
    match left[..common].cmp(&right[..common]) {
        std::cmp::Ordering::Equal => {}
        ordering => return ordering,
    }
    let left_char = if left.len() == common {
        if left_tree { b'/' } else { 0 }
    } else {
        left[common]
    };
    let right_char = if right.len() == common {
        if right_tree { b'/' } else { 0 }
    } else {
        right[common]
    };
    left_char.cmp(&right_char)
}

fn git_command<I, S>(dir: &Path, args: I) -> Result<std::process::Output, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    git_command_base(dir)
        .args(args)
        .output()
        .map_err(|error| internal(format!("run git: {error}")))
}

fn git_command_base(dir: &Path) -> Command {
    let mut command = Command::new("git");
    command
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(dir)
        .env("GIT_TERMINAL_PROMPT", "0");
    command
}

fn git_command_bounded<I, S>(
    dir: &Path,
    args: I,
    stdout_limit: usize,
) -> Result<BoundedGitOutput, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut child = git_command_base(dir)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| internal(format!("run git: {error}")))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| internal("capture git stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| internal("capture git stderr"))?;
    let stdout_reader = thread::spawn(move || read_bounded(stdout, stdout_limit));
    let stderr_reader = thread::spawn(move || read_bounded(stderr, MAX_GIT_STDERR_BYTES));
    let status = child
        .wait()
        .map_err(|error| internal(format!("wait for git: {error}")))?;
    let (stdout, stdout_truncated) = stdout_reader
        .join()
        .map_err(|_| internal("join git stdout reader"))?
        .map_err(|error| internal(format!("read git stdout: {error}")))?;
    let (stderr, _stderr_truncated) = stderr_reader
        .join()
        .map_err(|_| internal("join git stderr reader"))?
        .map_err(|error| internal(format!("read git stderr: {error}")))?;
    Ok(BoundedGitOutput {
        status,
        stdout,
        stdout_truncated,
        stderr,
    })
}

fn git_status_command_bounded<I, S>(
    dir: &Path,
    args: I,
    stdout_limit: usize,
) -> Result<BoundedGitStatusCounts, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut child = git_command_base(dir)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| internal(format!("run git: {error}")))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| internal("capture git stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| internal("capture git stderr"))?;
    let stdout_reader = thread::spawn(move || read_status_counts_bounded(stdout, stdout_limit));
    let stderr_reader = thread::spawn(move || read_bounded(stderr, MAX_GIT_STDERR_BYTES));
    let status = child
        .wait()
        .map_err(|error| internal(format!("wait for git: {error}")))?;
    let (stdout, stdout_truncated, counts) = stdout_reader
        .join()
        .map_err(|_| internal("join git stdout reader"))?
        .map_err(|error| internal(format!("read git stdout: {error}")))?;
    let (stderr, _stderr_truncated) = stderr_reader
        .join()
        .map_err(|_| internal("join git stderr reader"))?
        .map_err(|error| internal(format!("read git stderr: {error}")))?;
    Ok(BoundedGitStatusCounts {
        status,
        stdout,
        stdout_truncated,
        stderr,
        counts,
    })
}

fn read_bounded<R: Read>(mut reader: R, max_bytes: usize) -> std::io::Result<(Vec<u8>, bool)> {
    let mut stored = Vec::with_capacity(max_bytes.min(8 * 1024));
    let mut truncated = false;
    let mut buffer = [0u8; 8 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        let remaining = max_bytes.saturating_sub(stored.len());
        if remaining == 0 {
            truncated = true;
            continue;
        }
        let take = read.min(remaining);
        stored.extend_from_slice(&buffer[..take]);
        if take < read {
            truncated = true;
        }
    }
    Ok((stored, truncated))
}

fn read_status_counts_bounded<R: Read>(
    mut reader: R,
    max_bytes: usize,
) -> std::io::Result<(Vec<u8>, bool, GitStatusCounts)> {
    let mut stored = Vec::with_capacity(max_bytes.min(8 * 1024));
    let mut truncated = false;
    let mut counts = GitStatusCounts::default();
    let mut record = Vec::new();
    let mut skip_next_path = false;
    let mut buffer = [0u8; 8 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        let remaining = max_bytes.saturating_sub(stored.len());
        if remaining == 0 {
            truncated = true;
        } else {
            let take = read.min(remaining);
            stored.extend_from_slice(&buffer[..take]);
            if take < read {
                truncated = true;
            }
        }
        for byte in &buffer[..read] {
            if *byte == 0 {
                counts.push_record(&record, &mut skip_next_path);
                record.clear();
            } else {
                record.push(*byte);
            }
        }
    }
    Ok((stored, truncated, counts))
}

pub(super) struct BoundedGitOutput {
    pub(super) status: ExitStatus,
    pub(super) stdout: Vec<u8>,
    pub(super) stdout_truncated: bool,
    pub(super) stderr: Vec<u8>,
}

struct BoundedGitStatusCounts {
    status: ExitStatus,
    stdout: Vec<u8>,
    stdout_truncated: bool,
    stderr: Vec<u8>,
    counts: GitStatusCounts,
}

fn parse_status(bytes: &[u8]) -> GitStatusSummary {
    let records = bytes
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .collect::<Vec<_>>();
    let mut summary = GitStatusSummary::default();
    let mut index = 0usize;
    while index < records.len() {
        let record = String::from_utf8_lossy(records[index]).into_owned();
        if record.len() < 3 {
            index += 1;
            continue;
        }
        let mut chars = record.chars();
        let x = chars.next().unwrap_or(' ');
        let y = chars.next().unwrap_or(' ');
        let path = record[3..].to_owned();
        if x == '?' && y == '?' {
            summary.untracked.push(path);
            index += 1;
            continue;
        }
        let entry = json!({
            "path": path,
            "indexStatus": status_name(x),
            "worktreeStatus": status_name(y)
        });
        if is_conflicted(x, y) {
            summary.conflicted.push(entry.clone());
        }
        if x != ' ' && x != '?' {
            summary.staged.push(entry.clone());
        }
        if y != ' ' && y != '?' {
            summary.unstaged.push(entry);
        }
        index += if matches!(x, 'R' | 'C') && index + 1 < records.len() {
            2
        } else {
            1
        };
    }
    summary
}

fn complete_status_records(bytes: &[u8], truncated: bool) -> &[u8] {
    if !truncated || bytes.last() == Some(&0) {
        return bytes;
    }
    bytes
        .iter()
        .rposition(|byte| *byte == 0)
        .map(|index| &bytes[..=index])
        .unwrap_or(&[])
}

#[derive(Default)]
struct GitStatusCounts {
    staged: usize,
    unstaged: usize,
    untracked: usize,
    conflicted: usize,
}

impl GitStatusCounts {
    fn push_record(&mut self, record: &[u8], skip_next_path: &mut bool) {
        if *skip_next_path {
            *skip_next_path = false;
            return;
        }
        if record.len() < 3 {
            return;
        }
        let x = record[0] as char;
        let y = record[1] as char;
        if x == '?' && y == '?' {
            self.untracked += 1;
            return;
        }
        if is_conflicted(x, y) {
            self.conflicted += 1;
        }
        if x != ' ' && x != '?' {
            self.staged += 1;
        }
        if y != ' ' && y != '?' {
            self.unstaged += 1;
        }
        if matches!(x, 'R' | 'C') {
            *skip_next_path = true;
        }
    }

    fn dirty(&self) -> bool {
        self.staged > 0 || self.unstaged > 0 || self.untracked > 0 || self.conflicted > 0
    }

    fn summary_value(&self) -> Value {
        json!({
            "stagedCount": self.staged,
            "unstagedCount": self.unstaged,
            "untrackedCount": self.untracked,
            "conflictedCount": self.conflicted
        })
    }
}

#[derive(Default)]
struct GitStatusSummary {
    staged: Vec<Value>,
    unstaged: Vec<Value>,
    untracked: Vec<String>,
    conflicted: Vec<Value>,
}

impl GitStatusSummary {
    fn dirty(&self) -> bool {
        !self.staged.is_empty()
            || !self.unstaged.is_empty()
            || !self.untracked.is_empty()
            || !self.conflicted.is_empty()
    }

    fn summary_value(&self) -> Value {
        json!({
            "stagedCount": self.staged.len(),
            "unstagedCount": self.unstaged.len(),
            "untrackedCount": self.untracked.len(),
            "conflictedCount": self.conflicted.len()
        })
    }
}

pub(super) fn repository_value(target: &ResolvedTarget, repository: &RepositoryFacts) -> Value {
    json!({
        "repositoryRoot": {
            "root": "working_directory",
            "relativePath": repository.worktree_relative_path
        },
        "worktreeRoot": {
            "root": "working_directory",
            "relativePath": repository.worktree_relative_path
        },
        "requestedPath": path_value(target),
        "pathspec": repository.pathspec,
        "branch": repository.branch,
        "detachedHead": repository.detached_head,
        "headOid": repository.head_oid,
        "headTreeOid": repository.head_tree_oid,
        "indexTreeOid": repository.index_tree_oid,
        "upstream": repository.upstream,
        "hasUpstream": repository.upstream.is_some(),
        "ahead": repository.ahead,
        "behind": repository.behind
    })
}

pub(super) fn path_value(target: &ResolvedTarget) -> Value {
    json!({
        "root": "working_directory",
        "relativePath": target.relative_path
    })
}

fn status_name(status: char) -> &'static str {
    match status {
        ' ' => "unmodified",
        'M' => "modified",
        'A' => "added",
        'D' => "deleted",
        'R' => "renamed",
        'C' => "copied",
        'U' => "unmerged",
        '?' => "untracked",
        '!' => "ignored",
        _ => "unknown",
    }
}

fn is_conflicted(x: char, y: char) -> bool {
    x == 'U' || y == 'U' || matches!((x, y), ('A', 'A') | ('D', 'D'))
}

fn parse_ahead_behind(raw: Option<&str>) -> (Option<u64>, Option<u64>) {
    let Some(raw) = raw else {
        return (None, None);
    };
    let mut parts = raw.split_whitespace();
    let ahead = parts.next().and_then(|value| value.parse::<u64>().ok());
    let behind = parts.next().and_then(|value| value.parse::<u64>().ok());
    (ahead, behind)
}

fn trim_stdout(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).trim().to_owned()
}

#[cfg(test)]
mod service_tests {
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    use tempfile::tempdir;

    use super::{staged_index_tree_oid, staged_index_tree_oid_with_limit};

    #[test]
    fn staged_index_tree_matches_git_write_tree_without_writing_loose_objects() {
        let repo = tempdir().expect("repo");
        init_repo(repo.path());
        write_file(repo.path(), "src/lib.rs", "base\n");
        write_file(repo.path(), "README.md", "base\n");
        git(repo.path(), ["add", "."]);
        git(repo.path(), ["commit", "-m", "base"]);

        write_file(repo.path(), "src/lib.rs", "changed\n");
        write_file(repo.path(), "src/nested/mod.rs", "nested\n");
        git(repo.path(), ["add", "src/lib.rs", "src/nested/mod.rs"]);
        let loose_before = loose_object_count(repo.path());
        let actual = staged_index_tree_oid(repo.path())
            .expect("staged tree")
            .expect("tree oid");
        let loose_after = loose_object_count(repo.path());
        let expected = git_stdout(repo.path(), ["write-tree"]);

        assert_eq!(actual, expected);
        assert_eq!(
            loose_after, loose_before,
            "read-only staged index tree calculation must not write loose objects"
        );
    }

    #[test]
    fn staged_index_tree_refuses_truncated_index_listing() {
        let repo = tempdir().expect("repo");
        init_repo(repo.path());
        write_file(repo.path(), "tracked.txt", "content\n");
        git(repo.path(), ["add", "tracked.txt"]);

        let error = staged_index_tree_oid_with_limit(repo.path(), 1)
            .expect_err("truncated index listing should fail")
            .to_string();
        assert!(
            error.contains("truncated index listing"),
            "unexpected error: {error}"
        );
    }

    fn init_repo(path: &Path) {
        git(path, ["init", "-b", "main"]);
        git(path, ["config", "user.name", "Tron Test"]);
        git(path, ["config", "user.email", "tron-test@invalid.local"]);
    }

    fn write_file(root: &Path, relative: &str, content: &str) {
        let path = root.join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("parent dir");
        }
        fs::write(path, content).expect("write file");
    }

    fn loose_object_count(repo: &Path) -> usize {
        let objects = repo.join(".git/objects");
        fs::read_dir(objects)
            .expect("objects dir")
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().len() == 2)
            .map(|entry| {
                fs::read_dir(entry.path())
                    .expect("object shard")
                    .filter_map(Result::ok)
                    .count()
            })
            .sum()
    }

    fn git<const N: usize>(path: &Path, args: [&str; N]) {
        let output = Command::new("git")
            .arg("-C")
            .arg(path)
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .output()
            .expect("run git");
        assert!(
            output.status.success(),
            "git failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn git_stdout<const N: usize>(path: &Path, args: [&str; N]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(path)
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .output()
            .expect("run git");
        assert!(
            output.status.success(),
            "git failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    }
}

fn truncate_chars(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    let mut end = max;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn relative_to(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .trim_start_matches('/')
        .to_owned()
}

fn optional_str<'a>(payload: &'a Value, field: &str) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value)),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn optional_usize(payload: &Value, field: &str) -> Result<Option<usize>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .filter(|value| *value > 0)
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

fn map_io_error(error: std::io::Error, path: &Path) -> CapabilityError {
    if error.kind() == std::io::ErrorKind::NotFound {
        return CapabilityError::NotFound {
            code: "GIT_PATH_NOT_FOUND".to_owned(),
            message: format!("git path not found: {}", path.display()),
        };
    }
    CapabilityError::Custom {
        code: "GIT_PATH_ERROR".to_owned(),
        message: format!("{}: {error}", path.display()),
        details: None,
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}
