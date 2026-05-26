//! Generated UI source-control authoring.

use super::*;

pub(super) fn source_control_projection(
    host: &dyn PrimitiveRuntimeHost,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    if request.layout_profile != SOURCE_CONTROL_SESSION_LAYOUT_PROFILE {
        return Err(EngineError::PolicyViolation(format!(
            "source_control target requires layoutProfile {SOURCE_CONTROL_SESSION_LAYOUT_PROFILE}"
        )));
    }
    let session_id = request.target_id.as_str();
    let recent = source_control_invocation_rows(host, session_id, request);
    let latest_status = latest_source_control_result(host, session_id, "worktree::get_status")
        .unwrap_or_else(|| json!({}));
    let latest_conflicts =
        latest_source_control_result(host, session_id, "worktree::list_conflicts")
            .unwrap_or_else(|| json!({"conflicts": []}));
    let changed_files = source_control_file_rows(&latest_status, request);
    let branch = bounded_text_preview(
        latest_status
            .get("branch")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        request.max_preview_bytes,
    );
    let dirty = latest_status
        .get("isDirty")
        .or_else(|| latest_status.get("dirty"))
        .cloned()
        .unwrap_or_else(|| json!(false));
    let conflict_state = latest_status
        .get("conflictState")
        .or_else(|| latest_status.get("conflictsState"))
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            if latest_conflicts
                .get("conflicts")
                .and_then(Value::as_array)
                .is_some_and(|conflicts| !conflicts.is_empty())
            {
                "conflicted"
            } else {
                "none"
            }
        })
        .to_owned();
    let warnings = if recent.is_empty() {
        vec![json!(
            "No source-control invocations have been recorded for this session."
        )]
    } else {
        Vec::new()
    };
    Ok(TargetProjection {
        title: "Source Control Review".to_owned(),
        summary: format!(
            "{branch} / {conflict_state} / {} changed files",
            changed_files.len()
        ),
        revision: host.catalog_revision().0,
        graph: json!({
            "sourceControl": {
                "sessionId": session_id,
                "branch": branch,
                "dirty": dirty,
                "conflictState": conflict_state,
                "changedFiles": changed_files,
                "recentInvocations": recent,
                "latestStatus": bounded_json(latest_status, request.max_preview_bytes),
                "latestConflicts": bounded_json(latest_conflicts, request.max_preview_bytes),
                "warnings": warnings,
                "limit": SOURCE_CONTROL_INVOCATION_LIMIT,
            }
        }),
    })
}

pub(super) fn source_control_invocation_rows(
    host: &dyn PrimitiveRuntimeHost,
    session_id: &str,
    request: &SurfaceAuthoringRequest,
) -> Vec<Value> {
    let mut records = host
        .invocations()
        .into_iter()
        .filter(|record| {
            record.session_id.as_deref() == Some(session_id)
                && is_source_control_function(record.function_id.as_str())
        })
        .collect::<Vec<_>>();
    records.sort_by(|left, right| right.timestamp.cmp(&left.timestamp));
    records
        .into_iter()
        .take(SOURCE_CONTROL_INVOCATION_LIMIT)
        .map(|record| {
            json!({
                "invocationId": record.invocation_id.as_str(),
                "functionId": record.function_id.as_str(),
                "status": if record.succeeded { "completed" } else { "failed" },
                "timestamp": record.timestamp.to_rfc3339(),
                "catalogRevision": record.catalog_revision.0,
                "functionRevision": record.function_revision.0,
                "resourceRefs": record.produced_resource_refs,
                "summary": invocation_result_summary(&record, request),
            })
        })
        .collect()
}

fn latest_source_control_result(
    host: &dyn PrimitiveRuntimeHost,
    session_id: &str,
    function_id: &str,
) -> Option<Value> {
    let mut records = host
        .invocations()
        .into_iter()
        .filter(|record| {
            record.session_id.as_deref() == Some(session_id)
                && record.function_id.as_str() == function_id
                && record.succeeded
        })
        .collect::<Vec<_>>();
    records.sort_by(|left, right| right.timestamp.cmp(&left.timestamp));
    records.into_iter().find_map(|record| record.result_value)
}

fn source_control_file_rows(status: &Value, request: &SurfaceAuthoringRequest) -> Vec<Value> {
    let Some(files) = status
        .get("files")
        .or_else(|| status.get("changes"))
        .or_else(|| status.get("changedFiles"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    files
        .iter()
        .take(SOURCE_CONTROL_FILE_LIMIT)
        .filter_map(|file| {
            let path = file
                .get("path")
                .or_else(|| file.get("file"))
                .and_then(Value::as_str)?;
            if unsafe_prompt_preview_text(path) {
                return None;
            }
            Some(json!({
                "path": bounded_text_preview(path, request.max_preview_bytes),
                "status": file
                    .get("status")
                    .or_else(|| file.get("state"))
                    .cloned()
                    .unwrap_or_else(|| json!("modified")),
                "additions": file.get("additions").cloned().unwrap_or(Value::Null),
                "deletions": file.get("deletions").cloned().unwrap_or(Value::Null),
            }))
        })
        .collect()
}

fn is_source_control_function(function_id: &str) -> bool {
    function_id.starts_with("worktree::") || function_id.starts_with("git::")
}

fn invocation_result_summary(
    record: &crate::engine::invocation::InvocationRecord,
    request: &SurfaceAuthoringRequest,
) -> String {
    if let Some(error) = &record.error {
        return bounded_text_preview(&error.to_string(), request.max_preview_bytes);
    }
    let Some(value) = &record.result_value else {
        return "No result payload".to_owned();
    };
    let text = bounded_json(value.clone(), request.max_preview_bytes).to_string();
    bounded_text_preview(&text, request.max_preview_bytes)
}

pub(super) fn source_control_session_layout(projection: &TargetProjection) -> Value {
    let source = projection
        .graph
        .get("sourceControl")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let files = source
        .get("changedFiles")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let recent = source
        .get("recentInvocations")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut children = vec![
        json!({"type": "Metric", "props": {
            "label": "Session",
            "value": source
                .get("sessionId")
                .and_then(Value::as_str)
                .map(display_identifier)
                .map(Value::String)
                .unwrap_or(Value::Null)
        }}),
        json!({"type": "Metric", "props": {
            "label": "Branch",
            "value": source.get("branch").cloned().unwrap_or_else(|| json!("unknown"))
        }}),
        json!({"type": "Metric", "props": {
            "label": "Changed files",
            "value": files.len()
        }}),
        json!({"type": "Metric", "props": {
            "label": "Conflict state",
            "value": source.get("conflictState").cloned().unwrap_or_else(|| json!("unknown"))
        }}),
    ];
    children.push(json!({
        "type": "Disclosure",
        "props": {"title": "Changed Files", "open": !files.is_empty()},
        "children": if files.is_empty() {
            vec![json!({"type": "EmptyState", "props": {
                "title": "No changed files",
                "message": "Run worktree status to refresh source-control state."
            }})]
        } else {
            vec![json!({"type": "Table", "props": {
                "columns": ["path", "status", "additions", "deletions"],
                "rows": files
            }})]
        }
    }));
    let mut invocation_children = Vec::new();
    for row in recent {
        if let Some(invocation_id) = row.get("invocationId").and_then(Value::as_str) {
            invocation_children.push(json!({"type": "InvocationRef", "props": {
                "invocationId": invocation_id,
                "label": row.get("functionId").and_then(Value::as_str).unwrap_or("Source-control invocation")
            }}));
        }
        invocation_children.push(json!({"type": "Metric", "props": {
            "label": "Status",
            "value": row.get("status").cloned().unwrap_or_else(|| json!("unknown"))
        }}));
        invocation_children.push(json!({"type": "Text", "props": {
            "text": row.get("summary").cloned().unwrap_or(Value::Null)
        }}));
    }
    if invocation_children.is_empty() {
        invocation_children.push(json!({"type": "EmptyState", "props": {
            "title": "No source-control history",
            "message": "Source-control capability invocations will appear here."
        }}));
    }
    children.push(json!({
        "type": "Disclosure",
        "props": {"title": "Recent Source-Control Invocations", "open": false},
        "children": invocation_children
    }));
    children.push(json!({
        "type": "Disclosure",
        "props": {"title": "Review Actions", "open": true},
        "children": [
            {"type": "Button", "props": {"label": "Refresh status", "actionId": "refresh-worktree-status"}},
            {"type": "TextField", "props": {"name": "file", "label": "File path for diff", "required": true}},
            {"type": "Button", "props": {"label": "Inspect diff", "actionId": "inspect-worktree-diff"}},
            {"type": "Button", "props": {"label": "List conflicts", "actionId": "list-conflicts"}},
            {"type": "TextField", "props": {"name": "message", "label": "Commit message", "required": true}},
            {"type": "Toggle", "props": {"name": "stageAll", "label": "Stage all changes", "value": true}},
            {"type": "Confirmation", "props": {
                "title": "Commit worktree",
                "message": "Create a git commit through the canonical worktree capability.",
                "confirmActionId": "commit-worktree"
            }},
            {"type": "Confirmation", "props": {
                "title": "Finalize session",
                "message": "Publish or merge the session worktree using server policy.",
                "confirmActionId": "finalize-session"
            }},
            {"type": "Confirmation", "props": {
                "title": "Push branch",
                "message": "Push through the canonical git capability with approval and policy checks.",
                "confirmActionId": "push-branch"
            }},
            {"type": "Confirmation", "props": {
                "title": "Sync main",
                "message": "Run a dry-run main-branch sync through the canonical git capability.",
                "confirmActionId": "sync-main"
            }}
        ]
    }));
    json!({"type": "Section", "props": {"title": projection.title}, "children": children})
}

pub(super) fn source_control_actions(
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let session_id = request.target_id.as_str();
    let mut actions = Vec::new();
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "refresh-worktree-status",
        "Refresh Status",
        "worktree::get_status",
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({"sessionId": session_id}),
    )?;
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "inspect-worktree-diff",
        "Inspect Diff",
        "worktree::get_diff",
        json!({
            "type": "object",
            "required": ["file"],
            "additionalProperties": false,
            "properties": {"file": {"type": "string"}}
        }),
        json!({"sessionId": session_id, "file": "${input.file}"}),
    )?;
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "list-conflicts",
        "List Conflicts",
        "worktree::list_conflicts",
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({"sessionId": session_id}),
    )?;
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "commit-worktree",
        "Commit Worktree",
        "worktree::commit",
        json!({
            "type": "object",
            "required": ["message", "stageAll"],
            "additionalProperties": false,
            "properties": {
                "message": {"type": "string"},
                "stageAll": {"type": "boolean"}
            }
        }),
        json!({
            "sessionId": session_id,
            "message": "${input.message}",
            "stageAll": "${input.stageAll}"
        }),
    )?;
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "finalize-session",
        "Finalize Session",
        "worktree::finalize_session",
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({"sessionId": session_id}),
    )?;
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "push-branch",
        "Push Branch",
        "git::push",
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({"sessionId": session_id}),
    )?;
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "sync-main",
        "Sync Main",
        "git::sync_main",
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({"sessionId": session_id, "dryRun": true}),
    )?;
    Ok(actions)
}
