//! Agent-facing filesystem toolbox.
//!
//! All paths resolve against trusted runtime working-directory metadata. The
//! module never falls back to process cwd, never follows symlink escapes, and
//! keeps file bodies bounded before returning them to the model/runtime.

use std::fs;

use serde_json::{Value, json};
use walkdir::WalkDir;

use crate::engine::{
    CreateResource, EngineHostHandle, EngineResource, EngineResourceLocation,
    EngineResourceVersion, Invocation, PublishStreamEvent, UpdateResource, VisibilityScope,
    WorkerId,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

use super::agent_support::*;
use super::{FILESYSTEM_LIFECYCLE_TOPIC, WORKER, WRITE_SCOPE};

pub(crate) async fn read_value(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation = invocation.clone();
    run_blocking_task("filesystem::read", move || {
        let path = resolve_payload_path(&invocation, &request, false)?;
        let max_bytes = optional_usize(&request, "maxBytes")?
            .unwrap_or(DEFAULT_READ_BYTES)
            .min(MAX_READ_BYTES);
        let snapshot = read_snapshot(&path.canonical, max_bytes)?;
        if !snapshot.exists {
            return Err(not_found(&path.canonical));
        }
        Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "status": "ok",
            "operation": "read",
            "path": path_value(&path),
            "file": snapshot_value(&snapshot, true),
        }))
    })
    .await
}

pub(crate) async fn list_value(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation = invocation.clone();
    run_blocking_task("filesystem::list", move || {
        let path = resolve_path(
            &working_root(&invocation)?,
            optional_str(&request, "path")?.unwrap_or("."),
            false,
        )?;
        let max_results = optional_usize(&request, "maxResults")?
            .unwrap_or(500)
            .min(2_000);
        let show_hidden = optional_bool(&request, "showHidden")?.unwrap_or(false);
        let metadata = fs::symlink_metadata(&path.canonical)
            .map_err(|error| map_io_error(error, &path.canonical))?;
        if !metadata.is_dir() {
            return Err(invalid(format!(
                "path is not a directory: {}",
                path.relative
            )));
        }
        let mut entries = Vec::new();
        for entry in fs::read_dir(&path.canonical).map_err(|e| map_io_error(e, &path.canonical))? {
            let entry = entry.map_err(|e| map_io_error(e, &path.canonical))?;
            let name = entry.file_name().to_string_lossy().to_string();
            if !show_hidden && name.starts_with('.') {
                continue;
            }
            entries.push(entry_value(&path.root, &entry.path()));
        }
        entries.sort_by(|a, b| {
            let ad = a["isDirectory"].as_bool().unwrap_or(false);
            let bd = b["isDirectory"].as_bool().unwrap_or(false);
            bd.cmp(&ad).then_with(|| {
                a["relativePath"]
                    .as_str()
                    .unwrap_or_default()
                    .cmp(b["relativePath"].as_str().unwrap_or_default())
            })
        });
        let total = entries.len();
        entries.truncate(max_results);
        Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "status": "ok",
            "operation": "list",
            "path": path_value(&path),
            "entries": entries,
            "truncated": total > max_results,
            "limit": max_results
        }))
    })
    .await
}

pub(crate) async fn find_value(
    invocation: &Invocation,
    payload: &Value,
    glob_only: bool,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation = invocation.clone();
    run_blocking_task("filesystem::find", move || {
        let root = working_root(&invocation)?;
        let base = resolve_path(&root, optional_str(&request, "path")?.unwrap_or("."), false)?;
        let query = optional_str(&request, "query")?.map(str::to_lowercase);
        let glob = optional_str(&request, "glob")?.map(str::to_owned);
        if glob_only && glob.is_none() {
            return Err(invalid("glob is required"));
        }
        if query.is_none() && glob.is_none() {
            return Err(invalid("query or glob is required"));
        }
        let show_hidden = optional_bool(&request, "showHidden")?.unwrap_or(false);
        let max_results = optional_usize(&request, "maxResults")?
            .unwrap_or(DEFAULT_RESULTS)
            .min(MAX_RESULTS);
        let mut visited = 0usize;
        let mut matches = Vec::new();
        for entry in WalkDir::new(&base.canonical).follow_links(false) {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            visited += 1;
            if visited > MAX_WALK_ENTRIES || matches.len() >= max_results {
                break;
            }
            let rel = relative_to(&root, entry.path());
            if rel.is_empty() || (!show_hidden && path_has_hidden_component(&rel)) {
                continue;
            }
            let rel_lower = rel.to_lowercase();
            let query_match = query.as_ref().is_some_and(|q| rel_lower.contains(q));
            let glob_match = glob.as_ref().is_some_and(|g| wildcard_match(g, &rel));
            if query_match || glob_match {
                matches.push(entry_value(&root, entry.path()));
            }
        }
        Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "status": "ok",
            "operation": if glob_only { "glob" } else { "find" },
            "path": path_value(&base),
            "matches": matches,
            "truncated": visited > MAX_WALK_ENTRIES,
            "limit": max_results
        }))
    })
    .await
}

pub(crate) async fn search_text_value(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation = invocation.clone();
    run_blocking_task("filesystem::search_text", move || {
        let root = working_root(&invocation)?;
        let base = resolve_path(&root, optional_str(&request, "path")?.unwrap_or("."), false)?;
        let query = required_str(&request, "query")?.to_owned();
        let query_lower = query.to_lowercase();
        let glob = optional_str(&request, "glob")?.map(str::to_owned);
        let show_hidden = optional_bool(&request, "showHidden")?.unwrap_or(false);
        let max_results = optional_usize(&request, "maxResults")?
            .unwrap_or(DEFAULT_RESULTS)
            .min(MAX_RESULTS);
        let max_file_bytes = optional_usize(&request, "maxFileBytes")?
            .unwrap_or(DEFAULT_READ_BYTES)
            .min(MAX_READ_BYTES);
        let mut visited = 0usize;
        let mut results = Vec::new();
        let mut skipped_binary = 0usize;
        for entry in WalkDir::new(&base.canonical).follow_links(false) {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            visited += 1;
            if visited > MAX_WALK_ENTRIES || results.len() >= max_results {
                break;
            }
            if !entry.file_type().is_file() {
                continue;
            }
            let rel = relative_to(&root, entry.path());
            if !show_hidden && path_has_hidden_component(&rel) {
                continue;
            }
            if glob.as_ref().is_some_and(|g| !wildcard_match(g, &rel)) {
                continue;
            }
            let snapshot = read_snapshot(entry.path(), max_file_bytes)?;
            if snapshot.is_binary {
                skipped_binary += 1;
                continue;
            }
            let Some(text) = snapshot.text.as_deref() else {
                continue;
            };
            for (index, line) in text.lines().enumerate() {
                if line.to_lowercase().contains(&query_lower) {
                    results.push(json!({
                        "relativePath": rel,
                        "lineNumber": index + 1,
                        "preview": truncate_chars(line, MAX_LINE_PREVIEW),
                        "contentHash": snapshot.content_hash,
                    }));
                    if results.len() >= max_results {
                        break;
                    }
                }
            }
        }
        Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "status": "ok",
            "operation": "search_text",
            "query": query,
            "path": path_value(&base),
            "matches": results,
            "skippedBinaryFiles": skipped_binary,
            "truncated": visited > MAX_WALK_ENTRIES,
            "limit": max_results
        }))
    })
    .await
}

pub(crate) async fn diff_value(
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation = invocation.clone();
    run_blocking_task("filesystem::diff", move || {
        let plan = full_write_plan(&invocation, &request, false)?;
        Ok(plan_result_value(&plan, Vec::new(), None))
    })
    .await
}

pub(crate) async fn write_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation_clone = invocation.clone();
    let mut plan = run_blocking_task("filesystem::write", move || {
        full_write_plan(&invocation_clone, &request, true)
    })
    .await?;
    persist_plan(engine_host, invocation, &mut plan, "write").await
}

pub(crate) async fn edit_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let request = payload.clone();
    let invocation_clone = invocation.clone();
    let mut plan = run_blocking_task("filesystem::edit", move || {
        exact_replace_plan(&invocation_clone, &request, true)
    })
    .await?;
    persist_plan(engine_host, invocation, &mut plan, "apply_patch").await
}

fn full_write_plan(
    invocation: &Invocation,
    payload: &Value,
    allow_commit: bool,
) -> Result<MutationPlan, CapabilityError> {
    let content = required_str(payload, "content")?.to_owned();
    if content.len() > MAX_WRITE_BYTES {
        return Err(invalid(format!(
            "content exceeds {MAX_WRITE_BYTES} byte filesystem write limit"
        )));
    }
    let path = resolve_payload_path(invocation, payload, true)?;
    let commit = optional_bool(payload, "commit")?.unwrap_or(false) && allow_commit;
    mutation_plan(path, payload, content, commit)
}

fn exact_replace_plan(
    invocation: &Invocation,
    payload: &Value,
    allow_commit: bool,
) -> Result<MutationPlan, CapabilityError> {
    let path = resolve_payload_path(invocation, payload, false)?;
    let before = read_snapshot(&path.canonical, MAX_READ_BYTES)?;
    if !before.exists {
        return Err(not_found(&path.canonical));
    }
    if before.truncated {
        return Err(invalid(
            "exact text patch refuses files larger than the bounded preview limit",
        ));
    }
    if before.is_binary {
        return Err(invalid("exact text patch refuses binary files"));
    }
    let old_text = required_str(payload, "oldText")?;
    if old_text.is_empty() {
        return Err(invalid("oldText must not be empty"));
    }
    let current = before.text.as_deref().unwrap_or_default();
    let count = current.match_indices(old_text).count();
    if count != 1 {
        return Err(invalid(format!(
            "oldText must match exactly once; found {count} matches"
        )));
    }
    let new_content = current.replacen(old_text, required_str(payload, "newText")?, 1);
    if new_content.len() > MAX_WRITE_BYTES {
        return Err(invalid(format!(
            "patched content exceeds {MAX_WRITE_BYTES} byte filesystem write limit"
        )));
    }
    let commit = optional_bool(payload, "commit")?.unwrap_or(false) && allow_commit;
    mutation_plan_with_before(path, payload, before, new_content, commit)
}

fn mutation_plan(
    path: ResolvedPath,
    payload: &Value,
    after_content: String,
    commit: bool,
) -> Result<MutationPlan, CapabilityError> {
    let before = read_snapshot(&path.canonical, MAX_READ_BYTES).or_else(|error| match error {
        CapabilityError::NotFound { .. } => Ok(FileSnapshot {
            exists: false,
            is_binary: false,
            size_bytes: 0,
            content_hash: None,
            text: Some(String::new()),
            truncated: false,
        }),
        other => Err(other),
    })?;
    mutation_plan_with_before(path, payload, before, after_content, commit)
}

fn mutation_plan_with_before(
    path: ResolvedPath,
    payload: &Value,
    before: FileSnapshot,
    after_content: String,
    commit: bool,
) -> Result<MutationPlan, CapabilityError> {
    if let Some(expected) = optional_str(payload, "expectedHash")? {
        let Some(actual) = before.content_hash.as_deref() else {
            return Err(invalid(format!(
                "cannot verify expectedHash for {} because the current file hash is unavailable",
                path.relative
            )));
        };
        if expected != actual {
            return Err(invalid(format!(
                "expectedHash mismatch for {}: expected {expected}, actual {actual}",
                path.relative
            )));
        }
    } else if commit && before.exists {
        return Err(invalid(
            "commit=true for an existing file requires expectedHash",
        ));
    }
    let after_hash = sha256_hex(after_content.as_bytes());
    let max_diff = optional_usize(payload, "maxDiffBytes")?
        .unwrap_or(DEFAULT_DIFF_BYTES)
        .min(MAX_DIFF_BYTES);
    let (diff, diff_truncated) = unified_diff(
        &path.relative,
        before.text.as_deref(),
        &after_content,
        before.is_binary,
        max_diff,
    );
    Ok(MutationPlan {
        path,
        commit,
        reason: optional_str(payload, "reason")?.map(str::to_owned),
        before,
        after_content,
        after_hash,
        diff,
        diff_truncated,
    })
}

async fn persist_plan(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    plan: &mut MutationPlan,
    operation: &str,
) -> Result<Value, CapabilityError> {
    if plan.commit {
        write_committed_content(plan)?;
    }
    let patch_resource = create_patch_resource(engine_host, invocation, plan, operation).await?;
    let mut refs = vec![resource_ref(&patch_resource, "patch_proposal")];
    let materialized = if plan.commit {
        let (resource, version) =
            upsert_materialized_file_resource(engine_host, invocation, plan).await?;
        refs.push(version_ref(&resource, &version, "materialized_file"));
        Some(json!({
            "resourceId": resource.resource_id,
            "versionId": version.version_id,
            "contentHash": plan.after_hash
        }))
    } else {
        None
    };
    publish_lifecycle(
        engine_host,
        invocation,
        operation,
        plan,
        &patch_resource,
        materialized.clone(),
    )
    .await?;
    Ok(plan_result_value(plan, refs, materialized))
}

fn write_committed_content(plan: &MutationPlan) -> Result<(), CapabilityError> {
    if let Some(parent) = plan.path.canonical.parent() {
        fs::create_dir_all(parent).map_err(|error| map_io_error(error, parent))?;
    }
    fs::write(&plan.path.canonical, plan.after_content.as_bytes())
        .map_err(|error| map_io_error(error, &plan.path.canonical))
}

async fn create_patch_resource(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    plan: &MutationPlan,
    operation: &str,
) -> Result<EngineResource, CapabilityError> {
    engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!(
                "{PATCH_PROPOSAL_KIND}:{}",
                invocation.id.as_str()
            )),
            kind: PATCH_PROPOSAL_KIND.to_owned(),
            schema_id: Some(PATCH_PROPOSAL_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error_to_capability_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(if plan.commit { "applied" } else { "proposed" }.to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": WRITE_SCOPE,
                "networkPolicy": "none",
                "approvalPolicy": "explicit commit and idempotency required; package-wide approval trigger deferred"
            }),
            initial_payload: Some(json!({
                "targetPath": plan.path.relative,
                "baseContentHash": plan.before.content_hash,
                "diff": plan.diff,
                "status": if plan.commit { "applied" } else { "proposed" },
                "result": result_metadata(plan, operation)
            })),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error_to_capability_error)
}

async fn upsert_materialized_file_resource(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    plan: &MutationPlan,
) -> Result<(EngineResource, EngineResourceVersion), CapabilityError> {
    let resource_id = materialized_file_resource_id(&plan.path.canonical);
    let payload = json!({
        "canonicalPath": plan.path.canonical.to_string_lossy(),
        "relativePath": plan.path.relative,
        "entryType": "file",
        "contentHash": plan.after_hash,
        "sizeBytes": u64::try_from(plan.after_content.len()).unwrap_or(u64::MAX),
        "mimeType": "text/plain",
        "metadata": {
            "schemaVersion": SCHEMA_VERSION,
            "previousHash": plan.before.content_hash,
            "rollbackPreview": plan.before.text.as_deref().map(|text| truncate_chars(text, DEFAULT_DIFF_BYTES)),
            "diffTruncated": plan.diff_truncated
        }
    });
    let locations = vec![
        EngineResourceLocation {
            kind: "file".to_owned(),
            uri: plan.path.canonical.to_string_lossy().into_owned(),
            mime_type: Some("text/plain".to_owned()),
            size_bytes: Some(u64::try_from(plan.after_content.len()).unwrap_or(u64::MAX)),
        },
        EngineResourceLocation {
            kind: "blob".to_owned(),
            uri: format!("sha256:{}", plan.after_hash),
            mime_type: Some("text/plain".to_owned()),
            size_bytes: Some(u64::try_from(plan.after_content.len()).unwrap_or(u64::MAX)),
        },
    ];
    if let Some(existing) = engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error_to_capability_error)?
    {
        let version = engine_host
            .update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id: existing.resource.current_version_id.clone(),
                lifecycle: Some("materialized".to_owned()),
                payload,
                state: None,
                locations,
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error_to_capability_error)?;
        let resource = engine_host
            .inspect_resource(&resource_id)
            .await
            .map_err(engine_error_to_capability_error)?
            .ok_or_else(|| internal("materialized file resource missing after update"))?
            .resource;
        Ok((resource, version))
    } else {
        let resource = engine_host
            .create_resource(CreateResource {
                resource_id: Some(resource_id),
                kind: MATERIALIZED_FILE_KIND.to_owned(),
                schema_id: Some(MATERIALIZED_FILE_SCHEMA_ID.to_owned()),
                scope: resource_scope(invocation),
                owner_worker_id: WorkerId::new(WORKER).map_err(engine_error_to_capability_error)?,
                owner_actor_id: invocation.causal_context.actor_id.clone(),
                lifecycle: Some("materialized".to_owned()),
                policy: json!({"owner": WORKER, "authority": WRITE_SCOPE}),
                initial_payload: Some(payload),
                locations,
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error_to_capability_error)?;
        let inspection = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error_to_capability_error)?
            .ok_or_else(|| internal("materialized file resource missing after create"))?;
        let version = current_version(&inspection.versions, &resource)?;
        Ok((resource, version))
    }
}

async fn publish_lifecycle(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    operation: &str,
    plan: &MutationPlan,
    patch_resource: &EngineResource,
    materialized: Option<Value>,
) -> Result<(), CapabilityError> {
    engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: FILESYSTEM_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": "filesystem.patch_recorded",
                "operation": operation,
                "committed": plan.commit,
                "path": plan.path.relative,
                "beforeHash": plan.before.content_hash,
                "afterHash": plan.after_hash,
                "patchResourceId": patch_resource.resource_id,
                "materialized": materialized,
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
            }),
            visibility: VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map(|_| ())
        .map_err(engine_error_to_capability_error)
}

fn plan_result_value(
    plan: &MutationPlan,
    resource_refs: Vec<Value>,
    materialized: Option<Value>,
) -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "status": if plan.commit { "committed" } else { "preview" },
        "path": path_value(&plan.path),
        "commit": plan.commit,
        "before": snapshot_value(&plan.before, false),
        "after": {
            "contentHash": plan.after_hash,
            "sizeBytes": plan.after_content.len(),
            "preview": truncate_chars(&plan.after_content, DEFAULT_READ_BYTES)
        },
        "diff": plan.diff,
        "diffTruncated": plan.diff_truncated,
        "rollback": {
            "strategy": "manual_write_previous_content",
            "previousHash": plan.before.content_hash,
            "previousPreview": plan.before.text.as_deref().map(|text| truncate_chars(text, DEFAULT_DIFF_BYTES))
        },
        "reason": plan.reason,
        "resourceRefs": resource_refs,
        "materialized": materialized
    })
}

fn result_metadata(plan: &MutationPlan, operation: &str) -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": operation,
        "committed": plan.commit,
        "beforeHash": plan.before.content_hash,
        "afterHash": plan.after_hash,
        "diffTruncated": plan.diff_truncated,
        "rollbackEvidence": "bounded previous preview and hash"
    })
}
