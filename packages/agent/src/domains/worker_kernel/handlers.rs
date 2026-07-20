use std::sync::Arc;
use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::{Duration, Instant},
};

use serde_json::{Value, json};

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;
use crate::engine::RUNTIME_METADATA_WORKING_DIRECTORY;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

use super::contract::{
    DEFAULT_TEXT_SEARCH_TIMEOUT_SECONDS, DEFAULT_TEXT_SEARCH_WALK_ENTRIES,
    MAX_TEXT_SEARCH_TIMEOUT_SECONDS, MAX_TEXT_SEARCH_WALK_ENTRIES,
};
use super::runtime::WorkerRuntime;
use super::types::{InvokeRequest, WorkerBundle};

const DEFAULT_TEXT_SEARCH_RESULTS: usize = 200;
const MAX_TEXT_SEARCH_RESULTS: usize = 1_000;
const MAX_TEXT_SEARCH_FILE_BYTES: u64 = 1_048_576;
const MAX_WORKER_SOURCE_FILES: usize = 1_024;
const MAX_WORKER_SOURCE_BYTES: u64 = 16 * 1_048_576;
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

#[derive(Clone)]
pub(super) struct Deps {
    pub(super) runtime: Arc<WorkerRuntime>,
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "filesystem_read" => |invocation, deps| { response(invocation, filesystem_read(invocation, deps).await) },
        "filesystem_list" => |invocation, deps| { response(invocation, filesystem_list(invocation, deps).await) },
        "filesystem_search_text" => |invocation, deps| { response(invocation, filesystem_search_text(invocation, deps).await) },
        "filesystem_write" => |invocation, deps| { response(invocation, filesystem_write(invocation, deps).await) },
        "process_run" => |invocation, deps| { response(invocation, process_run(invocation, deps).await) },
        "web_fetch" => |invocation, deps| { response(invocation, web_fetch(invocation, deps).await) },
        "core_proposal_create" => |invocation, deps| { response(invocation, core_proposal_create(invocation, deps).await) },
        "core_proposal_list" => |invocation, deps| { response(invocation, core_proposal_list(invocation, deps).await) },
        "core_proposal_inspect" => |invocation, deps| { response(invocation, core_proposal_inspect(invocation, deps).await) },
        "core_proposal_apply" => |invocation, deps| { response(invocation, core_proposal_apply(invocation, deps).await) },
        "upsert" => |invocation, deps| { response(invocation, upsert(invocation, deps).await) },
        "discover" => |invocation, deps| { response(invocation, discover(invocation, deps).await) },
        "list" => |invocation, deps| { response(invocation, list(invocation, deps).await) },
        "inspect" => |invocation, deps| { response(invocation, inspect(invocation, deps).await) },
        "invoke" => |invocation, deps| { response(invocation, invoke_worker(invocation, deps).await) },
        "disable" => |invocation, deps| { response(invocation, set_enabled(invocation, deps, false).await) },
        "enable" => |invocation, deps| { response(invocation, set_enabled(invocation, deps, true).await) },
        "rollback" => |invocation, deps| { response(invocation, rollback(invocation, deps).await) },
        "retire" => |invocation, deps| { response(invocation, retire(invocation, deps).await) },
        "purge" => |invocation, deps| { response(invocation, purge(invocation, deps).await) },
        "inbox" => |invocation, deps| { response(invocation, inbox(invocation, deps).await) },
        "inbox_attach" => |invocation, deps| { response(invocation, inbox_attach(invocation, deps).await) },
        "runs" => |invocation, deps| { response(invocation, runs(invocation, deps).await) },
        "webhook_rotate" => |invocation, deps| { response(invocation, rotate_webhook(invocation, deps).await) },
        "stop_all" => |invocation, deps| { response(invocation, stop_all(invocation, deps).await) },
        "webhook_invoke" => |invocation, deps| { response(invocation, webhook(invocation, deps).await) },
    ];
}

async fn core_proposal_create(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let test_command = invocation
        .payload
        .get("testCommand")
        .and_then(Value::as_array)
        .ok_or_else(|| "testCommand must be an array".to_owned())?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| "testCommand entries must be strings".to_owned())
        })
        .collect::<Result<Vec<_>, _>>()?;
    serde_json::to_value(
        deps.runtime
            .create_core_proposal(
                required_string(&invocation.payload, "title")?,
                required_string(&invocation.payload, "intent")?,
                required_string(&invocation.payload, "repositoryPath")?,
                required_string(&invocation.payload, "patch")?,
                test_command,
            )
            .await?,
    )
    .map_err(|error| error.to_string())
}

async fn core_proposal_list(_invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    Ok(json!({"proposals":deps.runtime.list_core_proposals()?}))
}

async fn core_proposal_inspect(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    serde_json::to_value(
        deps.runtime
            .inspect_core_proposal(&required_string(&invocation.payload, "proposalId")?)?,
    )
    .map_err(|error| error.to_string())
}

async fn core_proposal_apply(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    serde_json::to_value(
        deps.runtime
            .apply_core_proposal(
                &required_string(&invocation.payload, "proposalId")?,
                &required_string(&invocation.payload, "approvalSessionId")?,
                &required_string(&invocation.payload, "approvalMessageId")?,
            )
            .await?,
    )
    .map_err(|error| error.to_string())
}

async fn filesystem_read(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let max_bytes = invocation
        .payload
        .get("maxBytes")
        .and_then(Value::as_u64)
        .unwrap_or(262_144)
        .min(4_194_304) as usize;
    let bytes =
        std::fs::read(&path).map_err(|error| format!("read {}: {error}", path.display()))?;
    let truncated = bytes.len() > max_bytes;
    let content = String::from_utf8_lossy(&bytes[..bytes.len().min(max_bytes)]).into_owned();
    Ok(json!({"path":path,"content":content,"bytes":bytes.len(),"truncated":truncated}))
}

async fn filesystem_list(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let requested = invocation
        .payload
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let path = resolve_path(invocation, requested)?;
    let max = invocation
        .payload
        .get("maxResults")
        .and_then(Value::as_u64)
        .unwrap_or(500)
        .min(5_000) as usize;
    let mut entries = std::fs::read_dir(&path)
        .map_err(|error| format!("list {}: {error}", path.display()))?
        .filter_map(Result::ok)
        .map(|entry| {
            let metadata = entry.metadata().ok();
            json!({
                "name": entry.file_name().to_string_lossy(),
                "path": entry.path(),
                "isDirectory": metadata.as_ref().is_some_and(std::fs::Metadata::is_dir),
                "size": metadata.as_ref().map(std::fs::Metadata::len),
            })
        })
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| left["name"].as_str().cmp(&right["name"].as_str()));
    let truncated = entries.len() > max;
    entries.truncate(max);
    Ok(json!({"path":path,"entries":entries,"truncated":truncated}))
}

async fn filesystem_search_text(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let requested = invocation
        .payload
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let path = resolve_path(invocation, requested)?;
    let query = required_string(&invocation.payload, "query")?;
    let max = invocation
        .payload
        .get("maxResults")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_TEXT_SEARCH_RESULTS as u64)
        .clamp(1, MAX_TEXT_SEARCH_RESULTS as u64) as usize;
    let max_walk_entries = invocation
        .payload
        .get("maxWalkEntries")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_TEXT_SEARCH_WALK_ENTRIES as u64)
        .clamp(1, MAX_TEXT_SEARCH_WALK_ENTRIES as u64) as usize;
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
    run_blocking_task("worker_kernel::filesystem_search_text", move || {
        bounded_text_search(
            &path,
            &query,
            max,
            max_walk_entries,
            timeout,
            include_hidden,
            include_ignored_directories,
        )
        .map_err(|message| CapabilityError::Internal { message })
    })
    .await
    .map_err(|error| error.to_string())
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
        let Some(entry) = walker.next() else {
            break;
        };
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
        "query":query,
        "path":path,
        "matches":matches,
        "visitedEntries":visited_entries,
        "skippedDirectories":skipped_directories,
        "resultLimitReached":result_limit_reached,
        "walkLimitReached":walk_limit_reached,
        "timeLimitReached":time_limit_reached,
        "truncated":result_limit_reached || walk_limit_reached || time_limit_reached,
    }))
}

async fn filesystem_write(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let path = resolve_path(invocation, &required_string(&invocation.payload, "path")?)?;
    let content = invocation
        .payload
        .get("content")
        .and_then(Value::as_str)
        .ok_or_else(|| "content is required".to_owned())?;
    if invocation
        .payload
        .get("createParents")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && let Some(parent) = path.parent()
    {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    std::fs::write(&path, content).map_err(|error| format!("write {}: {error}", path.display()))?;
    Ok(json!({"path":path,"bytes":content.len(),"written":true}))
}

async fn process_run(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
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
    let (program, arguments) = command
        .split_first()
        .ok_or_else(|| "command must contain a program".to_owned())?;
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
        .min(7_200);
    let mut child = tokio::process::Command::new(program)
        .args(arguments)
        .current_dir(&cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("start process: {error}"))?;
    if let Some(input) = invocation.payload.get("stdin")
        && let Some(mut stdin) = child.stdin.take()
    {
        use tokio::io::AsyncWriteExt;
        let bytes = input.as_str().map_or_else(
            || serde_json::to_vec(input).unwrap_or_default(),
            |text| text.as_bytes().to_vec(),
        );
        stdin
            .write_all(&bytes)
            .await
            .map_err(|error| error.to_string())?;
    }
    let output = tokio::time::timeout(Duration::from_secs(timeout), child.wait_with_output())
        .await
        .map_err(|_| format!("process timed out after {timeout} seconds"))?
        .map_err(|error| format!("wait for process: {error}"))?;
    let max = 4_194_304;
    let stdout = String::from_utf8_lossy(&output.stdout[..output.stdout.len().min(max)]);
    let stderr = String::from_utf8_lossy(&output.stderr[..output.stderr.len().min(max)]);
    Ok(json!({
        "command":command,"cwd":cwd,"status":output.status.code(),"success":output.status.success(),
        "stdout":stdout,"stderr":stderr,
        "stdoutTruncated":output.stdout.len()>max,"stderrTruncated":output.stderr.len()>max
    }))
}

async fn web_fetch(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let url = required_string(&invocation.payload, "url")?;
    let parsed = url::Url::parse(&url).map_err(|error| format!("invalid URL: {error}"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("web_fetch supports only HTTP and HTTPS".to_owned());
    }
    let max = invocation
        .payload
        .get("maxBytes")
        .and_then(Value::as_u64)
        .unwrap_or(1_048_576)
        .min(4_194_304) as usize;
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|error| error.to_string())?
        .get(parsed)
        .send()
        .await
        .map_err(|error| format!("fetch URL: {error}"))?;
    let status = response.status();
    let final_url = response.url().to_string();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let bytes = response.bytes().await.map_err(|error| error.to_string())?;
    let truncated = bytes.len() > max;
    let content = String::from_utf8_lossy(&bytes[..bytes.len().min(max)]).into_owned();
    Ok(
        json!({"url":final_url,"status":status.as_u16(),"contentType":content_type,"bytes":bytes.len(),"truncated":truncated,"content":content}),
    )
}

fn resolve_path(invocation: &Invocation, value: &str) -> Result<PathBuf, String> {
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

fn require_autonomous(deps: &Deps) -> Result<(), String> {
    if deps.runtime.autonomous_enabled() {
        Ok(())
    } else {
        Err(
            "autonomous workers are disabled for this profile; set autonomousWorkers=true"
                .to_owned(),
        )
    }
}

async fn upsert(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let mut bundle: WorkerBundle = serde_json::from_value(
        invocation
            .payload
            .get("bundle")
            .cloned()
            .ok_or_else(|| "worker_upsert requires bundle".to_owned())?,
    )
    .map_err(|error| format!("decode worker bundle: {error}"))?;
    let source_import = if invocation.payload.get("sourceDirectory").is_some() {
        let source_directory = resolve_path(
            invocation,
            &required_string(&invocation.payload, "sourceDirectory")?,
        )?;
        let (imported_bundle, summary) =
            run_blocking_task("worker_kernel::import_source_directory", move || {
                let summary = import_source_directory(&source_directory, &mut bundle)
                    .map_err(|message| CapabilityError::Internal { message })?;
                Ok((bundle, summary))
            })
            .await
            .map_err(|error| error.to_string())?;
        bundle = imported_bundle;
        Some(summary)
    } else {
        None
    };
    let predecessor = invocation
        .payload
        .get("predecessorWorkerId")
        .and_then(Value::as_str);
    let outcome = deps.runtime.upsert(bundle, predecessor).await?;
    if let Some(session_id) = invocation.causal_context.session_id.as_deref() {
        crate::domains::agent::r#loop::primitive_surface::promote_worker_for_session(
            session_id,
            &outcome.worker.worker_id,
        );
    }
    let mut response = serde_json::to_value(outcome).map_err(|error| error.to_string())?;
    if let (Some(response), Some((file_count, bytes))) = (response.as_object_mut(), source_import) {
        response.insert(
            "sourceImport".to_owned(),
            json!({"fileCount":file_count,"bytes":bytes}),
        );
    }
    Ok(response)
}

/// Import a staged UTF-8 source tree into a candidate without making the model
/// echo every file through JSON. Explicit inline bundle files win on duplicate
/// relative paths. Symlinks and special files are rejected so the immutable
/// version always contains exactly the tree the caller selected.
fn import_source_directory(
    source_directory: &Path,
    bundle: &mut WorkerBundle,
) -> Result<(usize, u64), String> {
    let root_metadata = std::fs::symlink_metadata(source_directory).map_err(|error| {
        format!(
            "inspect worker source directory {}: {error}",
            source_directory.display()
        )
    })?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(format!(
            "worker source directory must be a real directory, not a symlink or file: {}",
            source_directory.display()
        ));
    }

    let mut file_count = 0usize;
    let mut total_bytes = 0u64;
    for entry in walkdir::WalkDir::new(source_directory)
        .follow_links(false)
        .sort_by_file_name()
    {
        let entry = entry.map_err(|error| format!("walk worker source directory: {error}"))?;
        if entry.depth() == 0 {
            continue;
        }
        if entry.file_type().is_symlink() {
            return Err(format!(
                "worker source directory cannot contain symlinks: {}",
                entry.path().display()
            ));
        }
        if entry.file_type().is_dir() {
            continue;
        }
        if !entry.file_type().is_file() {
            return Err(format!(
                "worker source directory contains a non-file entry: {}",
                entry.path().display()
            ));
        }
        file_count = file_count
            .checked_add(1)
            .ok_or_else(|| "worker source file count overflow".to_owned())?;
        if file_count > MAX_WORKER_SOURCE_FILES {
            return Err(format!(
                "worker source directory exceeds the {MAX_WORKER_SOURCE_FILES}-file reliability ceiling"
            ));
        }
        let bytes = std::fs::read(entry.path())
            .map_err(|error| format!("read worker source {}: {error}", entry.path().display()))?;
        total_bytes = total_bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| "worker source byte count overflow".to_owned())?;
        if total_bytes > MAX_WORKER_SOURCE_BYTES {
            return Err(format!(
                "worker source directory exceeds the {MAX_WORKER_SOURCE_BYTES}-byte reliability ceiling"
            ));
        }
        let content = String::from_utf8(bytes).map_err(|_| {
            format!(
                "worker source files must be UTF-8 text: {}",
                entry.path().display()
            )
        })?;
        let relative = entry
            .path()
            .strip_prefix(source_directory)
            .map_err(|error| {
                format!(
                    "derive relative worker source path for {}: {error}",
                    entry.path().display()
                )
            })?;
        let relative = relative
            .components()
            .map(|component| {
                component
                    .as_os_str()
                    .to_str()
                    .ok_or_else(|| {
                        format!(
                            "worker source path is not UTF-8: {}",
                            entry.path().display()
                        )
                    })
                    .map(ToOwned::to_owned)
            })
            .collect::<Result<Vec<_>, _>>()?
            .join("/");
        bundle.files.entry(relative).or_insert(content);
    }
    Ok((file_count, total_bytes))
}

async fn discover(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let query = required_string(&invocation.payload, "query")?.to_ascii_lowercase();
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(12)
        .min(50) as usize;
    let query_terms = terms(&query);
    let mut workers = deps
        .runtime
        .store()
        .list(false)?
        .into_iter()
        .filter(|worker| worker.enabled)
        .filter_map(|worker| {
            let active = deps.runtime.store().load_active(&worker.worker_id).ok()?;
            let evidence = deps
                .runtime
                .store()
                .success_evidence(&worker.worker_id)
                .ok()?;
            let text = format!(
                "{} {} {} {}",
                worker.name,
                worker.description,
                serde_json::to_string(&active.bundle.routing).unwrap_or_default(),
                serde_json::to_string(&active.bundle.provenance).unwrap_or_default(),
            )
            .to_ascii_lowercase();
            let score = query_terms
                .iter()
                .filter(|term| text.contains(term.as_str()))
                .count();
            let successes = evidence
                .get("completedRuns")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            Some((score, successes, worker, active.bundle, evidence))
        })
        .filter(|(score, _, _, _, _)| *score > 0 || query_terms.is_empty())
        .collect::<Vec<_>>();
    workers.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| right.1.cmp(&left.1))
            .then_with(|| right.2.updated_at.cmp(&left.2.updated_at))
    });
    workers.truncate(limit);
    if let Some(session_id) = invocation.causal_context.session_id.as_deref() {
        for (_, _, worker, _, _) in &workers {
            crate::domains::agent::r#loop::primitive_surface::promote_worker_for_session(
                session_id,
                &worker.worker_id,
            );
        }
    }
    Ok(json!({
        "query": query,
        "workers": workers.into_iter().map(|(score, _, worker, bundle, evidence)| json!({
            "score":score,
            "worker":worker,
            "inputSchema":bundle.input_schema,
            "outputSchema":bundle.output_schema,
            "routing":bundle.routing,
            "provenance":bundle.provenance,
            "successEvidence":evidence,
        })).collect::<Vec<_>>()
    }))
}

async fn list(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let include_retired = invocation
        .payload
        .get("includeRetired")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(json!({
        "workers": deps.runtime.store().list(include_retired)?,
        "stopAll": deps.runtime.store().stop_all()?,
    }))
}

async fn inspect(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .store()
        .inspect(&required_string(&invocation.payload, "workerId")?)
}

async fn invoke_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let worker_id = required_string(&invocation.payload, "workerId")?;
    let input = invocation
        .payload
        .get("input")
        .cloned()
        .ok_or_else(|| "worker_invoke requires input".to_owned())?;
    let key = invocation
        .payload
        .get("idempotencyKey")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| invocation.causal_context.idempotency_key.clone())
        .unwrap_or_else(|| format!("manual:{}", invocation.id));
    serde_json::to_value(
        deps.runtime
            .invoke(InvokeRequest {
                worker_id,
                input,
                idempotency_key: key,
                trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
                causal_depth: invocation
                    .causal_context
                    .runtime_metadata
                    .get("workerCausalDepth")
                    .and_then(|value| value.parse::<u32>().ok())
                    .unwrap_or(0),
                trigger_kind: "manual".to_owned(),
            })
            .await?,
    )
    .map_err(|error| error.to_string())
}

async fn set_enabled(invocation: &Invocation, deps: &Deps, enabled: bool) -> Result<Value, String> {
    deps.runtime
        .set_enabled(&required_string(&invocation.payload, "workerId")?, enabled)
        .await
}

async fn rollback(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .rollback(
            &required_string(&invocation.payload, "workerId")?,
            &required_string(&invocation.payload, "version")?,
        )
        .await
}

async fn retire(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .retire(&required_string(&invocation.payload, "workerId")?)
        .await
}

async fn purge(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let worker_id = required_string(&invocation.payload, "workerId")?;
    Ok(json!({"workerId":worker_id,"purged":deps.runtime.purge(&worker_id).await?}))
}

async fn inbox(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(100)
        .min(500) as u32;
    let worker_id = invocation.payload.get("workerId").and_then(Value::as_str);
    Ok(json!({"items":deps.runtime.store().inbox(worker_id, limit)?}))
}

async fn inbox_attach(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(8)
        .min(32) as u32;
    Ok(json!({
        "items": deps.runtime.store().take_notable_unseen(
            invocation.payload.get("relevanceQuery").and_then(Value::as_str),
            limit,
        )?
    }))
}

async fn runs(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let worker_id = invocation.payload.get("workerId").and_then(Value::as_str);
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(100)
        .min(500) as u32;
    let runs = deps.runtime.store().runs(worker_id, limit)?;
    let mut attempts = serde_json::Map::new();
    let mut traces = serde_json::Map::new();
    for run in &runs {
        let _ = attempts.insert(
            run.invocation_id.clone(),
            Value::Array(deps.runtime.store().attempts(&run.invocation_id)?),
        );
        if !traces.contains_key(&run.trace_id)
            && let Some(trace) = deps.runtime.store().trace(&run.trace_id)?
        {
            let _ = traces.insert(run.trace_id.clone(), trace);
        }
    }
    Ok(json!({"runs":runs,"attempts":attempts,"traces":traces}))
}

async fn rotate_webhook(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    serde_json::to_value(deps.runtime.store().rotate_webhook(
        &required_string(&invocation.payload, "workerId")?,
        &required_string(&invocation.payload, "triggerId")?,
    )?)
    .map_err(|error| error.to_string())
}

async fn stop_all(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let stopped = invocation
        .payload
        .get("stopped")
        .and_then(Value::as_bool)
        .ok_or_else(|| "worker_stop_all requires stopped".to_owned())?;
    deps.runtime.set_stop_all(stopped).await?;
    Ok(json!({"stopped":stopped}))
}

async fn webhook(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let worker_id = required_string(&invocation.payload, "workerId")?;
    let trigger_id = required_string(&invocation.payload, "triggerId")?;
    let token = required_string(&invocation.payload, "token")?;
    let configured = deps
        .runtime
        .store()
        .verify_webhook(&worker_id, &trigger_id, &token)?;
    let body = invocation
        .payload
        .get("input")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let input = materialize_webhook_input(configured, body);
    serde_json::to_value(deps.runtime.enqueue(InvokeRequest {
        worker_id,
        input,
        idempotency_key: format!(
            "webhook:{trigger_id}:{}",
            required_string(&invocation.payload, "idempotencyKey")?
        ),
        trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
        causal_depth: 0,
        trigger_kind: "webhook".to_owned(),
    })?)
    .map_err(|error| error.to_string())
}

/// Treat a webhook body as the worker's typed input. Object-valued trigger
/// configuration provides defaults and request fields override them. This
/// keeps HTTP invocation identical to manual/direct invocation instead of
/// forcing every worker schema to declare an engine-specific `webhook` wrapper.
fn materialize_webhook_input(configured: Value, body: Value) -> Value {
    match (configured, body) {
        (Value::Object(mut defaults), Value::Object(request)) => {
            defaults.extend(request);
            Value::Object(defaults)
        }
        (_, body) => body,
    }
}

fn response(
    invocation: &Invocation,
    result: Result<Value, String>,
) -> Result<Value, CapabilityError> {
    let _ = invocation;
    result.map_err(|message| CapabilityError::Internal { message })
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

fn terms(value: &str) -> Vec<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|term| term.len() > 2)
        .map(str::to_owned)
        .collect()
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
    fn source_directory_imports_nested_utf8_files_and_inline_content_wins() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("lib")).unwrap();
        std::fs::write(root.path().join("main.py"), "print('staged')\n").unwrap();
        std::fs::write(root.path().join("lib/helper.py"), "VALUE = 1\n").unwrap();
        let mut bundle = test_worker_bundle();
        bundle
            .files
            .insert("main.py".to_owned(), "print('inline')\n".to_owned());

        let summary = import_source_directory(root.path(), &mut bundle).unwrap();

        assert_eq!(summary.0, 2);
        assert_eq!(bundle.files["main.py"], "print('inline')\n");
        assert_eq!(bundle.files["lib/helper.py"], "VALUE = 1\n");
    }

    #[test]
    fn source_directory_rejects_binary_files_and_symlinks() {
        let binary_root = tempfile::tempdir().unwrap();
        std::fs::write(binary_root.path().join("binary"), [0xff, 0xfe]).unwrap();
        assert!(
            import_source_directory(binary_root.path(), &mut test_worker_bundle())
                .unwrap_err()
                .contains("UTF-8")
        );

        let linked_root = tempfile::tempdir().unwrap();
        std::fs::write(linked_root.path().join("target.txt"), "target").unwrap();
        std::os::unix::fs::symlink(
            linked_root.path().join("target.txt"),
            linked_root.path().join("link.txt"),
        )
        .unwrap();
        assert!(
            import_source_directory(linked_root.path(), &mut test_worker_bundle())
                .unwrap_err()
                .contains("symlinks")
        );
    }

    #[test]
    fn webhook_body_is_direct_typed_input_with_configured_defaults() {
        let input = materialize_webhook_input(
            json!({"mode":"research","days":30}),
            json!({"topic":"persistent agents","days":7}),
        );

        assert_eq!(
            input,
            json!({"mode":"research","days":7,"topic":"persistent agents"})
        );
        assert!(input.get("webhook").is_none());
    }

    fn test_worker_bundle() -> WorkerBundle {
        serde_json::from_value(json!({
            "schemaVersion":"tron.worker_bundle.v1",
            "name":"Source Import",
            "description":"Test source directory import",
            "inputSchema":{"type":"object"},
            "outputSchema":{"type":"object"},
            "runner":{"kind":"command","command":["python3","main.py"]},
            "provenance":[{"source":"test:source-directory"}]
        }))
        .unwrap()
    }
}
