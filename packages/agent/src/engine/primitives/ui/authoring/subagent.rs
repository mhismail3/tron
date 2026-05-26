//! Generated UI subagent authoring.

use super::*;

pub(super) fn subagent_collection_projection(
    host: &dyn PrimitiveRuntimeHost,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    if request.layout_profile != SUBAGENT_LINEAGE_LAYOUT_PROFILE {
        return Err(EngineError::PolicyViolation(format!(
            "resource_collection target {} requires layoutProfile {SUBAGENT_LINEAGE_LAYOUT_PROFILE}",
            request.target_id
        )));
    }
    let mut rows = subagent_resource_rows(host, request)?;
    append_subagent_invocation_rows(host, &mut rows, request);
    sort_subagent_rows(&mut rows);
    let truncated = rows.len() > SUBAGENT_COLLECTION_LIMIT;
    rows.truncate(SUBAGENT_COLLECTION_LIMIT);
    Ok(TargetProjection {
        title: "Subagent Lineage".to_owned(),
        summary: format!(
            "{} child agent runs{}",
            rows.len(),
            if truncated { " shown" } else { "" }
        ),
        revision: host.catalog_revision().0,
        graph: json!({
            "collection": {
                "targetId": request.target_id,
                "layoutProfile": request.layout_profile,
                "resourceKind": "agent_result",
                "rowKind": "subagent_lineage",
                "rows": rows,
                "truncated": truncated,
                "limit": SUBAGENT_COLLECTION_LIMIT,
            }
        }),
    })
}

pub(super) fn subagent_resource_rows(
    host: &dyn PrimitiveRuntimeHost,
    request: &SurfaceAuthoringRequest,
) -> Result<Vec<Value>> {
    let resources = host.list_resources(ListResources {
        kind: Some("agent_result".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 10_000,
    })?;
    let mut rows = Vec::new();
    for resource in resources.into_iter().filter(|resource| {
        resource
            .resource_id
            .starts_with(SUBAGENT_RESULT_RESOURCE_PREFIX)
            && !matches!(resource.lifecycle.as_str(), "discarded" | "archived")
            && resource.current_version_id.is_some()
    }) {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        if let Some(row) = subagent_resource_row(&inspection, &payload, request) {
            rows.push(row);
        }
    }
    Ok(rows)
}

fn subagent_resource_row(
    inspection: &EngineResourceInspection,
    payload: &Value,
    request: &SurfaceAuthoringRequest,
) -> Option<Value> {
    let metadata = payload.get("metadata")?;
    let expected_subagent_session_id = inspection
        .resource
        .resource_id
        .strip_prefix(SUBAGENT_RESULT_RESOURCE_PREFIX)?;
    let subagent_session_id = metadata.get("subagentSessionId").and_then(Value::as_str)?;
    let parent_session_id = metadata.get("parentSessionId").and_then(Value::as_str)?;
    if subagent_session_id != expected_subagent_session_id
        || parent_session_id.trim().is_empty()
        || request
            .context_session_id
            .as_deref()
            .is_some_and(|session_id| session_id != parent_session_id)
        || !matches!(
            &inspection.resource.scope,
            EngineResourceScope::Session(scope) if scope == parent_session_id
        )
    {
        return None;
    }
    let task = bounded_text_preview(
        metadata
            .get("task")
            .and_then(Value::as_str)
            .unwrap_or("Subagent run"),
        request.max_preview_bytes,
    );
    let message = bounded_text_preview(
        payload
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        request.max_preview_bytes,
    );
    let status = subagent_status_from_payload(payload, metadata);
    Some(json!({
        "subagentSessionId": subagent_session_id,
        "parentSessionId": parent_session_id,
        "task": task,
        "status": status,
        "success": metadata.get("success").cloned().unwrap_or(Value::Null),
        "turnsExecuted": metadata.get("turnsExecuted").cloned().unwrap_or(Value::Null),
        "durationMs": metadata.get("durationMs").cloned().unwrap_or(Value::Null),
        "spawnType": metadata.get("spawnType").cloned().unwrap_or(Value::Null),
        "message": message,
        "resourceId": inspection.resource.resource_id,
        "versionId": inspection.resource.current_version_id,
        "kind": inspection.resource.kind,
        "lifecycle": inspection.resource.lifecycle,
        "sortKey": inspection.resource.updated_at.to_rfc3339(),
        "source": "agent_result_resource",
    }))
}

pub(super) fn append_subagent_invocation_rows(
    host: &dyn PrimitiveRuntimeHost,
    rows: &mut Vec<Value>,
    request: &SurfaceAuthoringRequest,
) {
    for record in host
        .invocations()
        .into_iter()
        .filter(|record| record.function_id.as_str() == "agent::spawn_subagent")
    {
        let Some(result) = record.result_value.as_ref() else {
            continue;
        };
        let Some(subagent_session_id) = result
            .get("runId")
            .and_then(Value::as_str)
            .or_else(|| result.pointer("/handle/sessionId").and_then(Value::as_str))
        else {
            continue;
        };
        let Some(parent_session_id) = result
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
        else {
            continue;
        };
        if request
            .context_session_id
            .as_deref()
            .is_some_and(|session_id| session_id != parent_session_id)
        {
            continue;
        }
        if rows.iter().any(|row| {
            row.get("subagentSessionId").and_then(Value::as_str) == Some(subagent_session_id)
        }) {
            continue;
        }
        let task = bounded_text_preview(
            result
                .get("task")
                .and_then(Value::as_str)
                .unwrap_or("Subagent run"),
            request.max_preview_bytes,
        );
        rows.push(json!({
            "subagentSessionId": subagent_session_id,
            "parentSessionId": parent_session_id,
            "task": task,
            "status": result
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or(if record.succeeded { "running" } else { "failed" }),
            "success": result.pointer("/handle/success").cloned().unwrap_or(Value::Null),
            "turnsExecuted": result.pointer("/handle/turnsExecuted").cloned().unwrap_or(Value::Null),
            "durationMs": Value::Null,
            "spawnType": result.get("kind").cloned().unwrap_or_else(|| json!("agent")),
            "message": result.pointer("/handle/output")
                .and_then(Value::as_str)
                .map(|value| bounded_text_preview(value, request.max_preview_bytes))
                .unwrap_or_default(),
            "invocationId": record.invocation_id.as_str(),
            "resourceId": Value::Null,
            "versionId": Value::Null,
            "kind": "agent_result",
            "lifecycle": Value::Null,
            "sortKey": record.timestamp.to_rfc3339(),
            "source": "spawn_invocation",
        }));
    }
}

fn subagent_status_from_payload(payload: &Value, metadata: &Value) -> String {
    if let Some(stop_reason) = payload.get("stopReason").and_then(Value::as_str) {
        return stop_reason.to_owned();
    }
    match metadata.get("success").and_then(Value::as_bool) {
        Some(true) => "completed".to_owned(),
        Some(false) => "failed".to_owned(),
        None => "unknown".to_owned(),
    }
}

pub(super) fn sort_subagent_rows(rows: &mut [Value]) {
    rows.sort_by(|left, right| {
        right
            .get("sortKey")
            .and_then(Value::as_str)
            .cmp(&left.get("sortKey").and_then(Value::as_str))
            .then_with(|| {
                left.get("subagentSessionId")
                    .and_then(Value::as_str)
                    .cmp(&right.get("subagentSessionId").and_then(Value::as_str))
            })
    });
}

pub(super) fn subagent_collection_layout(projection: &TargetProjection, rows: &[Value]) -> Value {
    let mut children = Vec::new();
    if rows.is_empty() {
        children.push(json!({
            "type": "EmptyState",
            "props": {
                "title": "No subagent runs",
                "message": "Child agent lineage will appear here after agent::spawn_subagent runs."
            }
        }));
    } else {
        for row in rows {
            let Some(subagent_session_id) = row.get("subagentSessionId").and_then(Value::as_str)
            else {
                continue;
            };
            let row_key = collection_row_key(subagent_session_id);
            let mut row_children = Vec::new();
            if let Some(resource_id) = row.get("resourceId").and_then(Value::as_str) {
                row_children.push(json!({"type": "ResourceRef", "props": {
                    "resourceId": resource_id,
                    "versionId": row.get("versionId").cloned().unwrap_or(Value::Null),
                    "kind": "agent_result",
                    "label": "Result resource"
                }}));
            }
            if let Some(invocation_id) = row.get("invocationId").and_then(Value::as_str) {
                row_children.push(json!({"type": "InvocationRef", "props": {
                    "invocationId": invocation_id,
                    "label": "Spawn invocation"
                }}));
            }
            row_children.extend([
                json!({"type": "Metric", "props": {
                    "label": "Status",
                    "value": row.get("status").cloned().unwrap_or_else(|| json!("unknown"))
                }}),
                json!({"type": "Metric", "props": {
                    "label": "Subagent",
                    "value": subagent_session_id
                }}),
                json!({"type": "Metric", "props": {
                    "label": "Parent session",
                    "value": row.get("parentSessionId").cloned().unwrap_or(Value::Null)
                }}),
                json!({"type": "Metric", "props": {
                    "label": "Turns",
                    "value": row.get("turnsExecuted").cloned().unwrap_or(Value::Null)
                }}),
                json!({"type": "Metric", "props": {
                    "label": "Duration",
                    "value": row.get("durationMs").cloned().unwrap_or(Value::Null)
                }}),
                json!({"type": "Text", "props": {
                    "text": row.get("message").cloned().unwrap_or(Value::Null)
                }}),
                json!({"type": "Button", "props": {
                    "label": "Check status",
                    "actionId": format!("subagent-status-{row_key}")
                }}),
                json!({"type": "Button", "props": {
                    "label": "Open result",
                    "actionId": format!("subagent-result-{row_key}")
                }}),
            ]);
            if row
                .get("status")
                .and_then(Value::as_str)
                .is_some_and(|status| matches!(status, "running" | "pending"))
            {
                row_children.push(json!({"type": "Confirmation", "props": {
                    "title": "Cancel subagent",
                    "message": "Request cancellation for this child agent.",
                    "confirmActionId": format!("subagent-cancel-{row_key}")
                }}));
            }
            children.push(json!({
                "type": "Disclosure",
                "props": {
                    "title": row.get("task").and_then(Value::as_str).unwrap_or("Subagent run"),
                    "subtitle": row.get("status").cloned().unwrap_or_else(|| json!("unknown")),
                    "open": false
                },
                "children": row_children
            }));
        }
    }
    json!({"type": "Section", "props": {"title": projection.title}, "children": children})
}

pub(super) fn subagent_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let mut rows = subagent_resource_rows(host, request)?;
    append_subagent_invocation_rows(host, &mut rows, request);
    sort_subagent_rows(&mut rows);
    rows.truncate(SUBAGENT_COLLECTION_LIMIT);
    let mut actions = Vec::new();
    for row in rows {
        let Some(subagent_session_id) = row.get("subagentSessionId").and_then(Value::as_str) else {
            continue;
        };
        let parent_session_id = row
            .get("parentSessionId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let row_key = collection_row_key(subagent_session_id);
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("subagent-status-{row_key}"),
            "Check Status",
            "agent::subagent_status",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({
                "sessionId": parent_session_id,
                "subagentSessionId": subagent_session_id
            }),
        )?);
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("subagent-result-{row_key}"),
            "Open Result",
            "agent::subagent_result",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({
                "sessionId": parent_session_id,
                "subagentSessionId": subagent_session_id
            }),
        )?);
        if row
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| matches!(status, "running" | "pending"))
        {
            actions.push(prompt_collection_action(
                invocation,
                functions,
                &format!("subagent-cancel-{row_key}"),
                "Cancel Subagent",
                "agent::cancel_subagent",
                json!({"type": "object", "additionalProperties": false, "properties": {}}),
                json!({
                    "sessionId": parent_session_id,
                    "subagentSessionId": subagent_session_id
                }),
            )?);
        }
    }
    Ok(actions)
}
