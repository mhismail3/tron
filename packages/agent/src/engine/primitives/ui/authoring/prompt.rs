//! Generated UI prompt authoring.

use super::*;

pub(super) fn prompt_snippet_collection_row(
    inspection: &EngineResourceInspection,
    payload: &Value,
    request: &SurfaceAuthoringRequest,
) -> Option<Value> {
    let id = payload
        .get("id")
        .and_then(Value::as_str)
        .or_else(|| {
            inspection
                .resource
                .resource_id
                .strip_prefix(PROMPT_SNIPPET_RESOURCE_PREFIX)
        })?
        .to_owned();
    let name = bounded_prompt_preview(
        payload
            .get("name")
            .or_else(|| payload.get("title"))
            .and_then(Value::as_str)
            .unwrap_or("Untitled snippet"),
        request,
    );
    let text = bounded_prompt_preview(
        payload
            .get("text")
            .or_else(|| payload.get("body"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        request,
    );
    Some(json!({
        "id": id,
        "resourceId": inspection.resource.resource_id,
        "versionId": inspection.resource.current_version_id,
        "kind": inspection.resource.kind,
        "lifecycle": inspection.resource.lifecycle,
        "name": name,
        "text": text,
        "updatedAt": payload.get("updatedAt").cloned().unwrap_or(Value::Null),
        "sortKey": payload
            .get("updatedAt")
            .and_then(Value::as_str)
            .or_else(|| payload.get("createdAt").and_then(Value::as_str))
            .unwrap_or_default(),
    }))
}

pub(super) fn prompt_history_collection_row(
    inspection: &EngineResourceInspection,
    payload: &Value,
    request: &SurfaceAuthoringRequest,
) -> Option<Value> {
    let id = payload
        .get("id")
        .and_then(Value::as_str)
        .or_else(|| {
            inspection
                .resource
                .resource_id
                .strip_prefix(PROMPT_HISTORY_RESOURCE_PREFIX)
        })?
        .to_owned();
    let text = bounded_prompt_preview(
        payload
            .get("text")
            .or_else(|| payload.get("body"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        request,
    );
    Some(json!({
        "id": id,
        "resourceId": inspection.resource.resource_id,
        "versionId": inspection.resource.current_version_id,
        "kind": inspection.resource.kind,
        "lifecycle": inspection.resource.lifecycle,
        "text": text,
        "lastUsedAt": payload.get("lastUsedAt").cloned().unwrap_or(Value::Null),
        "useCount": payload.get("useCount").cloned().unwrap_or_else(|| json!(1)),
        "sortKey": payload
            .get("lastUsedAt")
            .and_then(Value::as_str)
            .or_else(|| payload.get("firstUsedAt").and_then(Value::as_str))
            .unwrap_or_default(),
    }))
}

fn bounded_prompt_preview(text: &str, request: &SurfaceAuthoringRequest) -> String {
    bounded_text_preview(text, request.max_preview_bytes)
}

pub(super) fn prompt_snippet_collection_layout(
    projection: &TargetProjection,
    rows: &[Value],
) -> Value {
    let mut children = vec![json!({
        "type": "Disclosure",
        "props": {"title": "Create snippet", "open": rows.is_empty()},
        "children": [
            {"type": "TextField", "props": {"name": "name", "label": "Name", "required": true}},
            {"type": "TextArea", "props": {"name": "text", "label": "Text", "required": true}},
            {"type": "Button", "props": {"label": "Create", "actionId": "create-snippet"}}
        ]
    })];
    if rows.is_empty() {
        children.push(json!({
            "type": "EmptyState",
            "props": {
                "title": "No snippets",
                "message": "Create a snippet to make it available in the picker."
            }
        }));
    } else {
        for row in rows {
            let Some(resource_id) = row.get("resourceId").and_then(Value::as_str) else {
                continue;
            };
            let row_key = collection_row_key(resource_id);
            children.push(json!({
                "type": "Disclosure",
                "props": {
                    "title": row.get("name").and_then(Value::as_str).unwrap_or("Snippet"),
                    "open": false
                },
                "children": [
                    {"type": "ResourceRef", "props": {
                        "resourceId": resource_id,
                        "versionId": row.get("versionId").cloned().unwrap_or(Value::Null),
                        "kind": "artifact",
                        "label": "Snippet resource"
                    }},
                    {"type": "TextField", "props": {
                        "name": format!("name_{row_key}"),
                        "label": "Name",
                        "value": row.get("name").cloned().unwrap_or(Value::Null),
                        "required": true
                    }},
                    {"type": "TextArea", "props": {
                        "name": format!("text_{row_key}"),
                        "label": "Text",
                        "value": row.get("text").cloned().unwrap_or(Value::Null),
                        "required": true
                    }},
                    {"type": "Button", "props": {
                        "label": "Update",
                        "actionId": format!("update-snippet-{row_key}")
                    }},
                    {"type": "Confirmation", "props": {
                        "title": "Delete snippet",
                        "message": "Discard this prompt snippet artifact.",
                        "confirmActionId": format!("delete-snippet-{row_key}")
                    }}
                ]
            }));
        }
    }
    json!({"type": "Section", "props": {"title": projection.title}, "children": children})
}

pub(super) fn prompt_history_collection_layout(
    projection: &TargetProjection,
    rows: &[Value],
) -> Value {
    let mut children = Vec::new();
    if !rows.is_empty() {
        children.push(json!({
            "type": "Confirmation",
            "props": {
                "title": "Clear history",
                "message": "Discard all prompt history artifacts.",
                "confirmActionId": "clear-history"
            }
        }));
    }
    if rows.is_empty() {
        children.push(json!({
            "type": "EmptyState",
            "props": {
                "title": "No history",
                "message": "Prompt history artifacts will appear here."
            }
        }));
    } else {
        for row in rows {
            let Some(resource_id) = row.get("resourceId").and_then(Value::as_str) else {
                continue;
            };
            let row_key = collection_row_key(resource_id);
            children.push(json!({
                "type": "Disclosure",
                "props": {
                    "title": row.get("text").and_then(Value::as_str).unwrap_or("Prompt"),
                    "open": false
                },
                "children": [
                    {"type": "ResourceRef", "props": {
                        "resourceId": resource_id,
                        "versionId": row.get("versionId").cloned().unwrap_or(Value::Null),
                        "kind": "artifact",
                        "label": "History resource"
                    }},
                    {"type": "Text", "props": {
                        "text": row.get("text").cloned().unwrap_or(Value::Null)
                    }},
                    {"type": "Metric", "props": {
                        "label": "Uses",
                        "value": row.get("useCount").cloned().unwrap_or_else(|| json!(1))
                    }},
                    {"type": "Confirmation", "props": {
                        "title": "Delete entry",
                        "message": "Discard this prompt history artifact.",
                        "confirmActionId": format!("delete-history-{row_key}")
                    }}
                ]
            }));
        }
    }
    json!({"type": "Section", "props": {"title": projection.title}, "children": children})
}

pub(super) fn prompt_snippet_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let mut actions = Vec::new();
    actions.push(prompt_collection_action(
        invocation,
        functions,
        "create-snippet",
        "Create Snippet",
        "prompt_library::snippet_create",
        json!({
            "type": "object",
            "required": ["name", "text"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "text": {"type": "string"}
            }
        }),
        json!({
            "name": "${input.name}",
            "text": "${input.text}"
        }),
    )?);

    for row in prompt_collection_rows(host, PROMPT_SNIPPET_RESOURCE_PREFIX)? {
        let resource_id = row["resourceId"].as_str().unwrap_or_default();
        let row_key = collection_row_key(resource_id);
        let id = row["id"].as_str().unwrap_or_default();
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("update-snippet-{row_key}"),
            "Update Snippet",
            "prompt_library::snippet_update",
            json!({
                "type": "object",
                "required": [format!("name_{row_key}"), format!("text_{row_key}")],
                "additionalProperties": false,
                "properties": {
                    format!("name_{row_key}"): {"type": "string"},
                    format!("text_{row_key}"): {"type": "string"}
                }
            }),
            json!({
                "id": id,
                "name": format!("${{input.name_{row_key}}}"),
                "text": format!("${{input.text_{row_key}}}")
            }),
        )?);
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("delete-snippet-{row_key}"),
            "Delete Snippet",
            "prompt_library::snippet_delete",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({"id": id}),
        )?);
    }
    Ok(actions)
}

pub(super) fn prompt_history_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let mut actions = Vec::new();
    let rows = prompt_collection_rows(host, PROMPT_HISTORY_RESOURCE_PREFIX)?;
    if !rows.is_empty() {
        actions.push(prompt_collection_action(
            invocation,
            functions,
            "clear-history",
            "Clear History",
            "prompt_library::history_clear",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({}),
        )?);
    }
    for row in rows {
        let resource_id = row["resourceId"].as_str().unwrap_or_default();
        let row_key = collection_row_key(resource_id);
        let id = row["id"].as_str().unwrap_or_default();
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("delete-history-{row_key}"),
            "Delete History",
            "prompt_library::history_delete",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({"id": id}),
        )?);
    }
    Ok(actions)
}

fn prompt_collection_rows(host: &dyn PrimitiveRuntimeHost, prefix: &str) -> Result<Vec<Value>> {
    let mut rows = Vec::new();
    for projection in current_resource_payloads_by_prefix(host, "artifact", prefix, &["discarded"])?
    {
        let id = projection
            .payload
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| {
                projection
                    .inspection
                    .resource
                    .resource_id
                    .strip_prefix(prefix)
            })
            .unwrap_or_default()
            .to_owned();
        rows.push(json!({
            "id": id,
            "resourceId": projection.inspection.resource.resource_id,
            "sortKey": projection.payload
                .get("updatedAt")
                .and_then(Value::as_str)
                .or_else(|| projection.payload.get("lastUsedAt").and_then(Value::as_str))
                .or_else(|| projection.payload.get("createdAt").and_then(Value::as_str))
                .unwrap_or_default(),
        }));
    }
    rows.sort_by(|left, right| {
        right
            .get("sortKey")
            .and_then(Value::as_str)
            .cmp(&left.get("sortKey").and_then(Value::as_str))
            .then_with(|| {
                left.get("resourceId")
                    .and_then(Value::as_str)
                    .cmp(&right.get("resourceId").and_then(Value::as_str))
            })
    });
    rows.truncate(PROMPT_COLLECTION_LIMIT);
    Ok(rows)
}
