//! Direct trusted-local host primitives.
//!
//! These operations deliberately use the Tron user's ordinary host access.
//! Their constraints are reliability ceilings, not an application sandbox:
//! blocking filesystem work stays off the async executor, reads and traversal
//! are bounded, process trees have bounded I/O and deadlines, and mutations
//! publish through a same-directory atomic rename.

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{Invocation, RUNTIME_METADATA_WORKING_DIRECTORY};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

use super::contract::{
    DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS, DEFAULT_TEXT_SEARCH_WALK_ENTRIES,
    MAX_TEXT_SEARCH_TIMEOUT_SECONDS, MAX_TEXT_SEARCH_WALK_ENTRIES,
};
use super::process::{
    MAX_PROCESS_CAPTURE_BYTES, ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};
use super::runtime::WorkerRuntime;

const DEFAULT_FILE_READ_BYTES: usize = 262_144;
const MAX_FILE_BYTES: usize = 4 * 1_048_576;
const MAX_HASH_INPUT_BYTES: u64 = 64 * 1_048_576;
const DEFAULT_DIRECTORY_RESULTS: usize = 500;
const MAX_DIRECTORY_RESULTS: usize = 5_000;
const DEFAULT_DIRECTORY_WALK_ENTRIES: usize = 10_000;
const MAX_DIRECTORY_WALK_ENTRIES: usize = 50_000;
const DEFAULT_TEXT_SEARCH_RESULTS: usize = 200;
const MAX_TEXT_SEARCH_RESULTS: usize = 1_000;
const MAX_TEXT_SEARCH_FILE_BYTES: u64 = 1_048_576;
const MAX_EDIT_REPLACEMENTS: usize = 128;
const MAX_PROCESS_ARGUMENTS: usize = 256;
const MAX_PROCESS_INPUT_BYTES: usize = 4 * 1_048_576;
const DEFAULT_WEB_FETCH_BYTES: usize = 1_048_576;
const DEFAULT_IGNORED_SEARCH_DIRECTORIES: &[&str] = &[
    ".git",
    ".cache",
    ".build",
    ".venv",
    "Library",
    "DerivedData",
    "Pods",
    "build",
    "dist",
    "node_modules",
    "target",
    "vendor",
    "venv",
];

pub(super) async fn filesystem_read(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let max_bytes = bounded_usize(
        &invocation.payload,
        "maxBytes",
        DEFAULT_FILE_READ_BYTES,
        MAX_FILE_BYTES,
    );
    run_blocking("worker_kernel::filesystem_read", move || {
        let file =
            File::open(&path).map_err(|error| format!("read {}: {error}", path.display()))?;
        let declared_bytes = file.metadata().ok().map(|metadata| metadata.len());
        let mut bytes = Vec::with_capacity(max_bytes.saturating_add(1));
        file.take(max_bytes.saturating_add(1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|error| format!("read {}: {error}", path.display()))?;
        let truncated =
            bytes.len() > max_bytes || declared_bytes.is_some_and(|size| size > max_bytes as u64);
        bytes.truncate(max_bytes);
        let content = decode_bounded_utf8(bytes, truncated, &path)?;
        Ok(json!({
            "path": path,
            "content": content,
            "bytes": declared_bytes,
            "retainedBytes": content.len(),
            "truncated": truncated,
        }))
    })
    .await
}

pub(super) async fn filesystem_list(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let requested = invocation
        .payload
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let path = resolve_path(invocation, requested)?;
    let max_results = bounded_usize(
        &invocation.payload,
        "maxResults",
        DEFAULT_DIRECTORY_RESULTS,
        MAX_DIRECTORY_RESULTS,
    );
    let max_walk_entries = bounded_usize(
        &invocation.payload,
        "maxWalkEntries",
        DEFAULT_DIRECTORY_WALK_ENTRIES,
        MAX_DIRECTORY_WALK_ENTRIES,
    );
    run_blocking("worker_kernel::filesystem_list", move || {
        let directory = std::fs::read_dir(&path)
            .map_err(|error| format!("list {}: {error}", path.display()))?;
        let mut entries = BTreeMap::<String, Value>::new();
        let mut visited_entries = 0usize;
        let mut walk_limit_reached = false;
        let mut result_limit_reached = false;
        for entry in directory {
            if visited_entries >= max_walk_entries {
                walk_limit_reached = true;
                break;
            }
            visited_entries += 1;
            let Ok(entry) = entry else { continue };
            let name = entry.file_name().to_string_lossy().into_owned();
            let file_type = entry.file_type().ok();
            let metadata = entry.metadata().ok();
            let _ = entries.insert(
                name.clone(),
                json!({
                    "name": name,
                    "path": entry.path(),
                    "isDirectory": file_type.as_ref().is_some_and(std::fs::FileType::is_dir),
                    "isFile": file_type.as_ref().is_some_and(std::fs::FileType::is_file),
                    "isSymbolicLink": file_type.as_ref().is_some_and(std::fs::FileType::is_symlink),
                    "size": metadata.as_ref().map(std::fs::Metadata::len),
                }),
            );
            if entries.len() > max_results {
                result_limit_reached = true;
                let _ = entries.pop_last();
            }
        }
        Ok(json!({
            "path": path,
            "entries": entries.into_values().collect::<Vec<_>>(),
            "visitedEntries": visited_entries,
            "resultLimitReached": result_limit_reached,
            "walkLimitReached": walk_limit_reached,
            "truncated": result_limit_reached || walk_limit_reached,
        }))
    })
    .await
}

pub(super) async fn filesystem_search_text(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let requested = invocation
        .payload
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let path = resolve_path(invocation, requested)?;
    let query = required_string(&invocation.payload, "query")?;
    let max_results = bounded_usize(
        &invocation.payload,
        "maxResults",
        DEFAULT_TEXT_SEARCH_RESULTS,
        MAX_TEXT_SEARCH_RESULTS,
    );
    let max_walk_entries = bounded_usize(
        &invocation.payload,
        "maxWalkEntries",
        DEFAULT_TEXT_SEARCH_WALK_ENTRIES,
        MAX_TEXT_SEARCH_WALK_ENTRIES,
    );
    let timeout = Duration::from_secs(
        invocation
            .payload
            .get("timeoutSeconds")
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS)
            .clamp(1, MAX_TEXT_SEARCH_TIMEOUT_SECONDS),
    );
    let include_hidden = invocation
        .payload
        .get("includeHidden")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let include_ignored_directories = invocation
        .payload
        .get("includeIgnoredDirectories")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    run_blocking("worker_kernel::filesystem_search_text", move || {
        bounded_text_search(
            &path,
            &query,
            max_results,
            max_walk_entries,
            timeout,
            include_hidden,
            include_ignored_directories,
        )
    })
    .await
}

pub(super) async fn filesystem_write(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let content = invocation
        .payload
        .get("content")
        .and_then(Value::as_str)
        .ok_or_else(|| "content is required".to_owned())?
        .as_bytes()
        .to_vec();
    if content.len() > MAX_FILE_BYTES {
        return Err(format!(
            "content exceeds the {MAX_FILE_BYTES}-byte reliability ceiling"
        ));
    }
    let create_parents = invocation
        .payload
        .get("createParents")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let expected_sha256 = invocation
        .payload
        .get("expectedSha256")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    run_blocking("worker_kernel::filesystem_write", move || {
        atomic_publish(&path, &content, create_parents, expected_sha256.as_deref())
    })
    .await
}

pub(super) async fn filesystem_edit(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let replacements = invocation
        .payload
        .get("replacements")
        .and_then(Value::as_array)
        .ok_or_else(|| "replacements must be an array".to_owned())?;
    if replacements.is_empty() || replacements.len() > MAX_EDIT_REPLACEMENTS {
        return Err(format!(
            "replacements must contain 1 to {MAX_EDIT_REPLACEMENTS} exact edits"
        ));
    }
    let replacements = replacements
        .iter()
        .map(|replacement| {
            let old = replacement
                .get("oldText")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| "each replacement requires non-empty oldText".to_owned())?;
            let new = replacement
                .get("newText")
                .and_then(Value::as_str)
                .ok_or_else(|| "each replacement requires newText".to_owned())?;
            let expected = replacement
                .get("expectedOccurrences")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .clamp(1, 10_000) as usize;
            Ok((old.to_owned(), new.to_owned(), expected))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let expected_sha256 = invocation
        .payload
        .get("expectedSha256")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    run_blocking("worker_kernel::filesystem_edit", move || {
        let bytes = read_file_bounded(&path, MAX_FILE_BYTES)?;
        let previous_sha256 = sha256(&bytes);
        verify_expected_hash(&path, Some(&previous_sha256), expected_sha256.as_deref())?;
        let content = String::from_utf8(bytes)
            .map_err(|_| format!("edit {}: file is not UTF-8", path.display()))?;
        let (content, applied) = apply_exact_replacements(&path, content, &replacements)?;
        if sha256(content.as_bytes()) == previous_sha256 {
            return Ok(json!({
                "path": path,
                "changed": false,
                "replacementsApplied": applied,
                "previousSha256": previous_sha256,
                "sha256": previous_sha256,
                "bytes": content.len(),
            }));
        }
        atomic_publish_bytes(&path, content.as_bytes(), Some(&previous_sha256))?;
        Ok(json!({
            "path": path,
            "changed": true,
            "replacementsApplied": applied,
            "previousSha256": previous_sha256,
            "sha256": sha256(content.as_bytes()),
            "bytes": content.len(),
        }))
    })
    .await
}

pub(super) async fn process_run(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let command = invocation
        .payload
        .get("command")
        .and_then(Value::as_array)
        .ok_or_else(|| "command must be an array".to_owned())?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| "command entries must be strings".to_owned())
        })
        .collect::<Result<Vec<_>, _>>()?;
    if command.is_empty() || command.len() > MAX_PROCESS_ARGUMENTS {
        return Err(format!(
            "command must contain 1 to {MAX_PROCESS_ARGUMENTS} entries"
        ));
    }
    let (program, arguments) = command.split_first().expect("non-empty command");
    let cwd = invocation
        .payload
        .get("cwd")
        .and_then(Value::as_str)
        .map_or_else(
            || resolve_path(invocation, "."),
            |path| resolve_path(invocation, path),
        )?;
    let timeout = invocation
        .payload
        .get("timeoutSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(300)
        .clamp(1, 7_200);
    let input = invocation.payload.get("stdin").map(|input| {
        input.as_str().map_or_else(
            || serde_json::to_vec(input).unwrap_or_default(),
            |text| text.as_bytes().to_vec(),
        )
    });
    if input
        .as_ref()
        .is_some_and(|input| input.len() > MAX_PROCESS_INPUT_BYTES)
    {
        return Err(format!(
            "process stdin exceeds the {MAX_PROCESS_INPUT_BYTES}-byte reliability ceiling"
        ));
    }
    let mut process = tokio::process::Command::new(program);
    process
        .args(arguments)
        .current_dir(&cwd)
        .env("PATH", trusted_local_command_path(None)?)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child =
        ProcessTree::spawn(&mut process).map_err(|error| format!("start process: {error}"))?;
    let output = wait_with_bounded_output(
        child,
        input,
        Duration::from_secs(timeout),
        format!("process timed out after {timeout} seconds"),
        MAX_PROCESS_CAPTURE_BYTES,
    )
    .await
    .map_err(|error| format!("wait for process: {error}"))?;
    if let Some((kind, error)) = output.input_error
        && kind != std::io::ErrorKind::BrokenPipe
    {
        return Err(format!("write process input: {error}"));
    }
    Ok(json!({
        "command": command,
        "cwd": cwd,
        "status": output.status.code(),
        "success": output.status.success(),
        "stdout": String::from_utf8_lossy(&output.stdout),
        "stderr": String::from_utf8_lossy(&output.stderr),
        "stdoutTruncated": output.stdout_truncated,
        "stderrTruncated": output.stderr_truncated,
    }))
}

pub(super) async fn web_fetch(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    require_autonomous(runtime)?;
    let url = required_string(&invocation.payload, "url")?;
    let parsed = url::Url::parse(&url).map_err(|error| format!("invalid URL: {error}"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("web_fetch supports only HTTP and HTTPS".to_owned());
    }
    let max_bytes = bounded_usize(
        &invocation.payload,
        "maxBytes",
        DEFAULT_WEB_FETCH_BYTES,
        MAX_FILE_BYTES,
    );
    let mut response = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|error| error.to_string())?
        .get(parsed)
        .send()
        .await
        .map_err(|error| format!("fetch URL: {error}"))?;
    let status = response.status();
    let final_url = response.url().to_string();
    let content_length = response.content_length();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let mut content =
        Vec::with_capacity(content_length.unwrap_or_default().min(max_bytes as u64) as usize);
    let mut observed_bytes = 0_u64;
    let mut truncated = content_length.is_some_and(|length| length > max_bytes as u64);
    while content.len() <= max_bytes {
        let Some(chunk) = response.chunk().await.map_err(|error| error.to_string())? else {
            break;
        };
        observed_bytes = observed_bytes.saturating_add(chunk.len() as u64);
        let remaining = max_bytes.saturating_add(1).saturating_sub(content.len());
        content.extend_from_slice(&chunk[..remaining.min(chunk.len())]);
        if content.len() > max_bytes || chunk.len() > remaining {
            truncated = true;
            break;
        }
    }
    content.truncate(max_bytes);
    let content = decode_bounded_utf8(content, truncated, Path::new(&final_url))?;
    Ok(json!({
        "url": final_url,
        "status": status.as_u16(),
        "contentType": content_type,
        "contentLength": content_length,
        "observedBytes": observed_bytes,
        "retainedBytes": content.len(),
        "truncated": truncated,
        "content": content,
    }))
}

pub(super) fn resolve_path(invocation: &Invocation, value: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        return Ok(path);
    }
    let base = invocation
        .causal_context
        .runtime_metadata
        .get(RUNTIME_METADATA_WORKING_DIRECTORY)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    Ok(base.join(path))
}

#[allow(clippy::too_many_arguments)]
fn bounded_text_search(
    path: &Path,
    query: &str,
    max_results: usize,
    max_walk_entries: usize,
    timeout: Duration,
    include_hidden: bool,
    include_ignored_directories: bool,
) -> Result<Value, String> {
    let started = Instant::now();
    let mut matches = Vec::new();
    let mut visited_entries = 0usize;
    let mut skipped_directories = 0usize;
    let mut result_limit_reached = false;
    let mut walk_limit_reached = false;
    let mut time_limit_reached = false;
    let root = path.to_path_buf();
    let mut walker = walkdir::WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .filter_entry(|entry| {
            if entry.path() == root {
                return true;
            }
            let name = entry.file_name().to_string_lossy();
            let hidden = name.starts_with('.');
            let ignored = entry.file_type().is_dir()
                && DEFAULT_IGNORED_SEARCH_DIRECTORIES.contains(&name.as_ref());
            let include = (include_hidden || !hidden) && (include_ignored_directories || !ignored);
            if !include && entry.file_type().is_dir() {
                skipped_directories += 1;
            }
            include
        });
    'walk: loop {
        if started.elapsed() >= timeout {
            time_limit_reached = true;
            break;
        }
        let Some(entry) = walker.next() else { break };
        let Ok(entry) = entry else { continue };
        if visited_entries >= max_walk_entries {
            walk_limit_reached = true;
            break;
        }
        visited_entries += 1;
        if !entry.file_type().is_file() {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if metadata.len() > MAX_TEXT_SEARCH_FILE_BYTES {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        for (index, line) in content.lines().enumerate() {
            if started.elapsed() >= timeout {
                time_limit_reached = true;
                break 'walk;
            }
            if line.contains(query) {
                matches.push(json!({"path":entry.path(),"line":index + 1,"text":line}));
                if matches.len() >= max_results {
                    result_limit_reached = true;
                    break 'walk;
                }
            }
        }
    }
    drop(walker);
    Ok(json!({
        "query": query,
        "path": path,
        "matches": matches,
        "visitedEntries": visited_entries,
        "skippedDirectories": skipped_directories,
        "resultLimitReached": result_limit_reached,
        "walkLimitReached": walk_limit_reached,
        "timeLimitReached": time_limit_reached,
        "truncated": result_limit_reached || walk_limit_reached || time_limit_reached,
    }))
}

fn atomic_publish(
    path: &Path,
    content: &[u8],
    create_parents: bool,
    expected_sha256: Option<&str>,
) -> Result<Value, String> {
    if create_parents
        && let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("create {}: {error}", parent.display()))?;
    }
    let previous_sha256 = if path.exists() {
        Some(hash_file(path)?)
    } else {
        None
    };
    verify_expected_hash(path, previous_sha256.as_deref(), expected_sha256)?;
    let new_sha256 = sha256(content);
    if previous_sha256.as_deref() == Some(new_sha256.as_str()) {
        return Ok(json!({
            "path": path,
            "bytes": content.len(),
            "written": false,
            "changed": false,
            "previousSha256": previous_sha256,
            "sha256": new_sha256,
        }));
    }
    atomic_publish_bytes(
        path,
        content,
        Some(previous_sha256.as_deref().unwrap_or("absent")),
    )?;
    Ok(json!({
        "path": path,
        "bytes": content.len(),
        "written": true,
        "changed": true,
        "previousSha256": previous_sha256,
        "sha256": new_sha256,
    }))
}

fn apply_exact_replacements(
    path: &Path,
    mut content: String,
    replacements: &[(String, String, usize)],
) -> Result<(String, usize), String> {
    let mut applied = 0usize;
    for (index, (old, new, expected)) in replacements.iter().enumerate() {
        let occurrences = content.match_indices(old).count();
        if occurrences != *expected {
            return Err(format!(
                "edit {} replacement {} expected {} occurrence(s), found {}",
                path.display(),
                index + 1,
                expected,
                occurrences
            ));
        }
        content = content.replace(old, new);
        applied = applied.saturating_add(occurrences);
        if content.len() > MAX_FILE_BYTES {
            return Err(format!(
                "edited content exceeds the {MAX_FILE_BYTES}-byte reliability ceiling"
            ));
        }
    }
    Ok((content, applied))
}

fn atomic_publish_bytes(
    path: &Path,
    content: &[u8],
    expected_current_sha256: Option<&str>,
) -> Result<(), String> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let metadata = std::fs::symlink_metadata(path).ok();
    if metadata
        .as_ref()
        .is_some_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(format!(
            "atomic write refuses symbolic-link target {}",
            path.display()
        ));
    }
    let temporary = parent.join(format!(".tron-write-{}.tmp", uuid::Uuid::now_v7()));
    let publish = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| format!("stage {}: {error}", path.display()))?;
        file.write_all(content)
            .map_err(|error| format!("stage {}: {error}", path.display()))?;
        if let Some(metadata) = metadata {
            file.set_permissions(metadata.permissions())
                .map_err(|error| format!("preserve permissions for {}: {error}", path.display()))?;
        }
        file.sync_all()
            .map_err(|error| format!("sync staged {}: {error}", path.display()))?;
        if let Some(expected) = expected_current_sha256 {
            if expected == "absent" {
                if path.exists() {
                    return Err(format!(
                        "write {} lost a concurrent create before publication",
                        path.display()
                    ));
                }
            } else {
                let actual = hash_file(path)?;
                if actual != expected {
                    return Err(format!(
                        "write {} lost a concurrent update: expected {expected}, found {actual}",
                        path.display()
                    ));
                }
            }
        }
        std::fs::rename(&temporary, path)
            .map_err(|error| format!("publish {}: {error}", path.display()))?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("sync directory {}: {error}", parent.display()))?;
        Ok(())
    })();
    if publish.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    publish
}

fn verify_expected_hash(
    path: &Path,
    actual: Option<&str>,
    expected: Option<&str>,
) -> Result<(), String> {
    let Some(expected) = expected else {
        return Ok(());
    };
    if expected.eq_ignore_ascii_case("absent") {
        return if actual.is_none() {
            Ok(())
        } else {
            Err(format!(
                "write {} expected the file to be absent",
                path.display()
            ))
        };
    }
    let expected = normalize_sha256(expected);
    if actual == Some(expected.as_str()) {
        Ok(())
    } else {
        Err(format!(
            "write {} checksum mismatch: expected {}, found {}",
            path.display(),
            expected,
            actual.unwrap_or("absent")
        ))
    }
}

fn hash_file(path: &Path) -> Result<String, String> {
    let metadata =
        std::fs::metadata(path).map_err(|error| format!("inspect {}: {error}", path.display()))?;
    if metadata.len() > MAX_HASH_INPUT_BYTES {
        return Err(format!(
            "checksum input {} exceeds the {MAX_HASH_INPUT_BYTES}-byte reliability ceiling",
            path.display()
        ));
    }
    Ok(sha256(&read_file_bounded(
        path,
        MAX_HASH_INPUT_BYTES as usize,
    )?))
}

fn read_file_bounded(path: &Path, max_bytes: usize) -> Result<Vec<u8>, String> {
    let file = File::open(path).map_err(|error| format!("read {}: {error}", path.display()))?;
    let mut bytes = Vec::with_capacity(max_bytes.min(DEFAULT_FILE_READ_BYTES).saturating_add(1));
    file.take(max_bytes.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("read {}: {error}", path.display()))?;
    if bytes.len() > max_bytes {
        return Err(format!(
            "file {} exceeds the {max_bytes}-byte reliability ceiling",
            path.display()
        ));
    }
    Ok(bytes)
}

fn sha256(bytes: &[u8]) -> String {
    format!("sha256:{:x}", Sha256::digest(bytes))
}

fn normalize_sha256(value: &str) -> String {
    if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        format!("sha256:{}", value.to_ascii_lowercase())
    } else {
        value.to_ascii_lowercase()
    }
}

fn decode_bounded_utf8(mut bytes: Vec<u8>, truncated: bool, path: &Path) -> Result<String, String> {
    match String::from_utf8(bytes) {
        Ok(content) => Ok(content),
        Err(error) if truncated && error.utf8_error().error_len().is_none() => {
            let valid = error.utf8_error().valid_up_to();
            bytes = error.into_bytes();
            bytes.truncate(valid);
            String::from_utf8(bytes).map_err(|_| format!("read {}: invalid UTF-8", path.display()))
        }
        Err(_) => Err(format!("read {}: file is not UTF-8", path.display())),
    }
}

fn bounded_usize(payload: &Value, field: &str, default: usize, maximum: usize) -> usize {
    payload
        .get(field)
        .and_then(Value::as_u64)
        .unwrap_or(default as u64)
        .clamp(1, maximum as u64) as usize
}

fn required_string(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("{field} is required"))
}

fn require_autonomous(runtime: &WorkerRuntime) -> Result<(), String> {
    if runtime.autonomous_enabled() {
        Ok(())
    } else {
        Err(
            "autonomous workers are disabled for this profile; set autonomousWorkers=true"
                .to_owned(),
        )
    }
}

async fn run_blocking<F>(operation: &'static str, task: F) -> Result<Value, String>
where
    F: FnOnce() -> Result<Value, String> + Send + 'static,
{
    run_blocking_task(operation, move || {
        task().map_err(|message| CapabilityError::Internal { message })
    })
    .await
    .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_text_search_skips_hidden_and_heavy_directories_by_default() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("visible.txt"), "needle\n").unwrap();
        std::fs::create_dir_all(root.path().join(".hidden")).unwrap();
        std::fs::write(root.path().join(".hidden/secret.txt"), "needle\n").unwrap();
        std::fs::create_dir_all(root.path().join("target")).unwrap();
        std::fs::write(root.path().join("target/generated.txt"), "needle\n").unwrap();

        let result = bounded_text_search(
            root.path(),
            "needle",
            20,
            100,
            Duration::from_secs(1),
            false,
            false,
        )
        .unwrap();
        assert_eq!(result["matches"].as_array().unwrap().len(), 1);
        assert_eq!(result["skippedDirectories"], 2);
        assert_eq!(result["truncated"], false);
    }

    #[test]
    fn bounded_text_search_reports_walk_and_time_ceilings() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("one.txt"), "needle\n").unwrap();
        std::fs::write(root.path().join("two.txt"), "needle\n").unwrap();
        let walked = bounded_text_search(
            root.path(),
            "needle",
            20,
            1,
            Duration::from_secs(1),
            true,
            true,
        )
        .unwrap();
        assert_eq!(walked["walkLimitReached"], true);
        assert_eq!(walked["truncated"], true);
        let timed = bounded_text_search(root.path(), "needle", 20, 100, Duration::ZERO, true, true)
            .unwrap();
        assert_eq!(timed["timeLimitReached"], true);
        assert_eq!(timed["visitedEntries"], 0);
    }

    #[test]
    fn atomic_publish_is_compare_and_swap_and_preserves_the_old_file_on_mismatch() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("value.txt");
        std::fs::write(&path, "before").unwrap();
        let expected = sha256(b"before");
        let result = atomic_publish(&path, b"after", false, Some(&expected)).unwrap();
        assert_eq!(result["changed"], true);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "after");
        let error = atomic_publish(&path, b"lost", false, Some(&expected)).unwrap_err();
        assert!(error.contains("checksum mismatch"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "after");
    }

    #[test]
    fn exact_replacement_admission_rejects_ambiguous_or_stale_text_before_publish() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("value.txt");
        std::fs::write(&path, "same same").unwrap();
        let error = apply_exact_replacements(
            &path,
            std::fs::read_to_string(&path).unwrap(),
            &[("same".to_owned(), "new".to_owned(), 1)],
        )
        .unwrap_err();
        assert!(error.contains("expected 1 occurrence(s), found 2"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "same same");

        let (edited, applied) = apply_exact_replacements(
            &path,
            std::fs::read_to_string(&path).unwrap(),
            &[("same".to_owned(), "new".to_owned(), 2)],
        )
        .unwrap();
        assert_eq!(edited, "new new");
        assert_eq!(applied, 2);
    }
}
