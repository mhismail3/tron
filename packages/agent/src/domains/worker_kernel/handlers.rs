use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;
use crate::engine::RUNTIME_METADATA_TRIGGER_DEPTH;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

use super::host;
use super::runtime::WorkerRuntime;
use super::types::{InvokeRequest, WorkerBundle};

const MAX_WORKER_SOURCE_FILES: usize = 1_024;
const MAX_WORKER_SOURCE_BYTES: u64 = 16 * 1_048_576;

#[derive(Clone)]
pub(super) struct Deps {
    pub(super) runtime: Arc<WorkerRuntime>,
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "filesystem_read" => |invocation, deps| { response(invocation, host::filesystem_read(invocation, &deps.runtime).await) },
        "filesystem_list" => |invocation, deps| { response(invocation, host::filesystem_list(invocation, &deps.runtime).await) },
        "filesystem_search_text" => |invocation, deps| { response(invocation, host::filesystem_search_text(invocation, &deps.runtime).await) },
        "filesystem_write" => |invocation, deps| { response(invocation, host::filesystem_write(invocation, &deps.runtime).await) },
        "filesystem_edit" => |invocation, deps| { response(invocation, host::filesystem_edit(invocation, &deps.runtime).await) },
        "process_run" => |invocation, deps| { response(invocation, host::process_run(invocation, &deps.runtime).await) },
        "web_fetch" => |invocation, deps| { response(invocation, host::web_fetch(invocation, &deps.runtime).await) },
        "core_proposal_create" => |invocation, deps| { response(invocation, core_proposal_create(invocation, deps).await) },
        "core_proposal_list" => |invocation, deps| { response(invocation, core_proposal_list(invocation, deps).await) },
        "core_proposal_inspect" => |invocation, deps| { response(invocation, core_proposal_inspect(invocation, deps).await) },
        "core_proposal_apply" => |invocation, deps| { response(invocation, core_proposal_apply(invocation, deps).await) },
        "upsert" => |invocation, deps| { response(invocation, upsert(invocation, deps).await) },
        "discover" => |invocation, deps| { response(invocation, discover(invocation, deps).await) },
        "list" => |invocation, deps| { response(invocation, list(invocation, deps).await) },
        "inspect" => |invocation, deps| { response(invocation, inspect(invocation, deps).await) },
        "invoke" => |invocation, deps| { response(invocation, invoke_worker(invocation, deps).await) },
        "await" => |invocation, deps| { response(invocation, await_worker(invocation, deps).await) },
        "stop" => |invocation, deps| { response(invocation, stop_worker(invocation, deps).await) },
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
        "surface_snapshot" => |invocation, deps| { response(invocation, engine_surface_snapshot(invocation, deps).await) },
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
                required_content(&invocation.payload, "patch")?,
                test_command,
            )
            .await?,
    )
    .map_err(|error| error.to_string())
}

async fn engine_surface_snapshot(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .engine_surface_snapshot(
            invocation.causal_context.session_id.as_deref(),
            invocation.causal_context.workspace_id.as_deref(),
            invocation
                .payload
                .get("relevanceQuery")
                .and_then(Value::as_str),
        )
        .await
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

fn require_autonomous(deps: &Deps) -> Result<(), String> {
    if deps.runtime.autonomous_enabled() {
        Ok(())
    } else {
        Err(
            "autonomous workers are disabled for this engine; set autonomousWorkers=true"
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
        let source_directory = host::resolve_path(
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
        crate::domains::worker_kernel::promote_worker_for_session(
            deps.runtime.host(),
            session_id,
            &outcome.worker.worker_id,
            &outcome.worker.active_version,
        )
        .await?;
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
    let query = required_string(&invocation.payload, "query")?;
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(12)
        .min(50) as usize;
    let promoted = match invocation.causal_context.session_id.as_deref() {
        Some(session_id) => {
            super::surface::session_worker_promotions(deps.runtime.host(), session_id).await?
        }
        None => std::collections::BTreeSet::new(),
    };
    let mut payloads = std::collections::BTreeMap::new();
    let mut documents = Vec::new();
    for worker in deps
        .runtime
        .store()
        .list(false)?
        .into_iter()
        .filter(|worker| worker.enabled)
    {
        let Ok(active) = deps.runtime.store().load_active(&worker.worker_id) else {
            continue;
        };
        let Ok(evidence) = deps.runtime.store().success_evidence(&worker.worker_id) else {
            continue;
        };
        documents.push(super::retrieval::WorkerRetrievalDocument {
            key: worker.worker_id.clone(),
            worker_id: worker.worker_id.clone(),
            name: worker.name.clone(),
            description: worker.description.clone(),
            intents: active.bundle.routing.intents.clone(),
            examples: active.bundle.routing.examples.clone(),
            provenance: active
                .bundle
                .provenance
                .iter()
                .map(|source| {
                    source.revision.as_ref().map_or_else(
                        || source.source.clone(),
                        |revision| format!("{}@{revision}", source.source),
                    )
                })
                .collect(),
            completed_runs: evidence
                .get("completedRuns")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            updated_at: worker.updated_at.clone(),
        });
        let _ = payloads.insert(worker.worker_id.clone(), (worker, active.bundle, evidence));
    }
    let include_unmatched = super::retrieval::query_is_empty(Some(&query));
    let ranked = super::retrieval::rank_workers(documents, Some(&query), &promoted)
        .into_iter()
        .filter(|rank| include_unmatched || rank.relevance_score > 0)
        .take(limit)
        .collect::<Vec<_>>();
    if let Some(session_id) = invocation.causal_context.session_id.as_deref() {
        for rank in &ranked {
            let Some((worker, _, _)) = payloads.get(&rank.worker_id) else {
                continue;
            };
            super::surface::promote_worker_for_session(
                deps.runtime.host(),
                session_id,
                &rank.worker_id,
                &worker.active_version,
            )
            .await?;
        }
    }
    Ok(json!({
        "query": query,
        "workers": ranked.into_iter().filter_map(|rank| {
            let (worker, bundle, evidence) = payloads.remove(&rank.worker_id)?;
            Some(json!({
                "score":rank.relevance_score,
                "promoted":rank.promoted,
                "worker":worker,
                "inputSchema":bundle.input_schema,
                "outputSchema":bundle.output_schema,
                "routing":bundle.routing,
                "provenance":bundle.provenance,
                "successEvidence":evidence,
            }))
        }).collect::<Vec<_>>()
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
    let request = InvokeRequest {
        worker_id,
        input,
        idempotency_key: key,
        trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
        causal_depth: invocation
            .causal_context
            .runtime_metadata
            .get(RUNTIME_METADATA_TRIGGER_DEPTH)
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(0),
        trigger_kind: "manual".to_owned(),
    };
    let record = match invocation
        .payload
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("wait")
    {
        "enqueue" => deps.runtime.enqueue_and_dispatch(request)?,
        "wait" => deps.runtime.invoke(request).await?,
        mode => return Err(format!("unsupported worker invocation mode '{mode}'")),
    };
    serde_json::to_value(record).map_err(|error| error.to_string())
}

async fn await_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    require_autonomous(deps)?;
    let timeout = std::time::Duration::from_secs(
        invocation
            .payload
            .get("timeoutSeconds")
            .and_then(Value::as_u64)
            .unwrap_or(30)
            .min(7_200),
    );
    let (record, timed_out) = deps
        .runtime
        .await_invocation(
            &required_string(&invocation.payload, "invocationId")?,
            timeout,
        )
        .await?;
    Ok(json!({"invocation":record,"timedOut":timed_out}))
}

async fn set_enabled(invocation: &Invocation, deps: &Deps, enabled: bool) -> Result<Value, String> {
    deps.runtime
        .set_enabled(&required_string(&invocation.payload, "workerId")?, enabled)
        .await
}

async fn stop_worker(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .stop_worker(&required_string(&invocation.payload, "workerId")?)
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

/// Read exact textual content while still rejecting absent or blank values.
/// Unified diffs require their terminal newline, so the identifier-oriented
/// `required_string` normalization must never be used for patch bytes.
fn required_content(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|content| !content.trim().is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("{field} is required"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_patch_content_preserves_the_terminal_newline() {
        let patch = "diff --git a/file b/file\n-old\n+new\n";
        assert_eq!(
            required_content(&json!({"patch":patch}), "patch"),
            Ok(patch.to_owned())
        );
        assert!(required_content(&json!({"patch":"  \n"}), "patch").is_err());
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
