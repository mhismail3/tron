use std::sync::Arc;
use std::{path::PathBuf, process::Stdio, time::Duration};

use serde_json::{Value, json};

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;
use crate::engine::RUNTIME_METADATA_WORKING_DIRECTORY;
use crate::shared::server::errors::CapabilityError;

use super::runtime::WorkerRuntime;
use super::types::{InvokeRequest, WorkerBundle};

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
    require_autonomous(deps)?;
    Ok(json!({"proposals":deps.runtime.list_core_proposals()?}))
}

async fn core_proposal_inspect(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
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
        .unwrap_or(200)
        .min(1_000) as usize;
    let mut matches = Vec::new();
    for entry in walkdir::WalkDir::new(&path).follow_links(false) {
        let Ok(entry) = entry else { continue };
        if !entry.file_type().is_file() {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if metadata.len() > 1_048_576 {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        for (index, line) in content.lines().enumerate() {
            if line.contains(&query) {
                matches.push(json!({"path":entry.path(),"line":index + 1,"text":line}));
                if matches.len() >= max {
                    return Ok(json!({"query":query,"matches":matches,"truncated":true}));
                }
            }
        }
    }
    Ok(json!({"query":query,"matches":matches,"truncated":false}))
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
    let bundle: WorkerBundle = serde_json::from_value(
        invocation
            .payload
            .get("bundle")
            .cloned()
            .ok_or_else(|| "worker_upsert requires bundle".to_owned())?,
    )
    .map_err(|error| format!("decode worker bundle: {error}"))?;
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
    serde_json::to_value(outcome).map_err(|error| error.to_string())
}

async fn discover(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
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
    require_autonomous(deps)?;
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
    require_autonomous(deps)?;
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
    require_autonomous(deps)?;
    deps.runtime
        .set_enabled(&required_string(&invocation.payload, "workerId")?, enabled)
        .await
}

async fn rollback(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    deps.runtime
        .rollback(
            &required_string(&invocation.payload, "workerId")?,
            &required_string(&invocation.payload, "version")?,
        )
        .await
}

async fn retire(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    deps.runtime
        .retire(&required_string(&invocation.payload, "workerId")?)
        .await
}

async fn purge(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let worker_id = required_string(&invocation.payload, "workerId")?;
    Ok(json!({"workerId":worker_id,"purged":deps.runtime.purge(&worker_id).await?}))
}

async fn inbox(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
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
    require_autonomous(deps)?;
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
    require_autonomous(deps)?;
    let worker_id = invocation.payload.get("workerId").and_then(Value::as_str);
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(100)
        .min(500) as u32;
    Ok(json!({"runs":deps.runtime.store().runs(worker_id, limit)?}))
}

async fn rotate_webhook(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    serde_json::to_value(deps.runtime.store().rotate_webhook(
        &required_string(&invocation.payload, "workerId")?,
        &required_string(&invocation.payload, "triggerId")?,
    )?)
    .map_err(|error| error.to_string())
}

async fn stop_all(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
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
    let mut input = configured;
    let body = invocation
        .payload
        .get("input")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if let Some(object) = input.as_object_mut() {
        let _ = object.insert("webhook".to_owned(), body);
    } else {
        input = body;
    }
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
