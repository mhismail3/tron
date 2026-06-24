use std::ffi::OsStr;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
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

fn git_command<I, S>(dir: &Path, args: I) -> Result<std::process::Output, CapabilityError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(|error| internal(format!("run git: {error}")))
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
    let mut child = Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
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
    let mut child = Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
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
