//! Generated UI notifications authoring.

use super::*;

pub(super) fn notification_collection_projection(
    host: &dyn PrimitiveRuntimeHost,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    if request.layout_profile != NOTIFICATION_INBOX_LAYOUT_PROFILE {
        return Err(EngineError::PolicyViolation(format!(
            "resource_collection target notification requires layoutProfile {NOTIFICATION_INBOX_LAYOUT_PROFILE}"
        )));
    }
    let read_decisions = notification_read_decisions(host)?;
    let resources = host.list_resources(ListResources {
        kind: Some("notification".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 10_000,
    })?;
    let mut rows = Vec::new();
    for resource in resources.into_iter().filter(|resource| {
        resource
            .resource_id
            .starts_with(NOTIFICATION_RESOURCE_PREFIX)
            && !matches!(resource.lifecycle.as_str(), "discarded" | "archived")
            && resource.current_version_id.is_some()
    }) {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        if let Some(row) = notification_collection_row(&inspection, &payload, &read_decisions) {
            rows.push(row);
        }
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
    let truncated = rows.len() > NOTIFICATION_COLLECTION_LIMIT;
    rows.truncate(NOTIFICATION_COLLECTION_LIMIT);
    let unread = rows
        .iter()
        .filter(|row| row.get("isRead").and_then(Value::as_bool) == Some(false))
        .count();
    Ok(TargetProjection {
        title: "Notifications".to_owned(),
        summary: format!(
            "{} notifications{} / {unread} unread",
            rows.len(),
            if truncated { " shown" } else { "" }
        ),
        revision: host.catalog_revision().0,
        graph: json!({
            "collection": {
                "targetId": request.target_id,
                "layoutProfile": request.layout_profile,
                "resourceKind": "notification",
                "rowKind": "notification",
                "rows": rows,
                "truncated": truncated,
                "limit": NOTIFICATION_COLLECTION_LIMIT,
                "unreadCount": unread,
            }
        }),
    })
}

fn notification_collection_row(
    inspection: &EngineResourceInspection,
    payload: &Value,
    decisions: &[NotificationReadDecision],
) -> Option<Value> {
    let resource_id = &inspection.resource.resource_id;
    let title = bounded_text_preview(
        payload
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("Notification"),
        512,
    );
    let body = bounded_text_preview(
        payload
            .get("body")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        512,
    );
    let read_decision = decisions
        .iter()
        .filter(|decision| decision.affects(resource_id))
        .max_by(|left, right| left.read_at.cmp(&right.read_at));
    Some(json!({
        "resourceId": resource_id,
        "versionId": inspection.resource.current_version_id,
        "kind": inspection.resource.kind,
        "lifecycle": inspection.resource.lifecycle,
        "title": title,
        "body": body,
        "priority": payload.get("priority").cloned().unwrap_or_else(|| json!("normal")),
        "createdAt": payload.get("createdAt").cloned().unwrap_or(Value::Null),
        "deliveryStatus": payload.pointer("/delivery/status").cloned().unwrap_or(Value::Null),
        "deliveryWarning": payload.pointer("/delivery/warning").cloned().unwrap_or(Value::Null),
        "isRead": read_decision.is_some(),
        "readAt": read_decision
            .map(|decision| json!(decision.read_at.clone()))
            .unwrap_or(Value::Null),
        "sortKey": payload
            .get("createdAt")
            .and_then(Value::as_str)
            .or_else(|| payload.get("updatedAt").and_then(Value::as_str))
        .unwrap_or_default(),
    }))
}

#[derive(Debug, Clone)]
struct NotificationReadDecision {
    decision_type: String,
    notification_resource_id: Option<String>,
    affected_notification_ids: Vec<String>,
    read_at: String,
}

impl NotificationReadDecision {
    fn affects(&self, resource_id: &str) -> bool {
        match self.decision_type.as_str() {
            "notification_read" => self.notification_resource_id.as_deref() == Some(resource_id),
            "notification_mark_all_read" => self
                .affected_notification_ids
                .iter()
                .any(|affected| affected == resource_id),
            _ => false,
        }
    }
}

fn notification_read_decisions(
    host: &dyn PrimitiveRuntimeHost,
) -> Result<Vec<NotificationReadDecision>> {
    let decisions = host.list_resources(ListResources {
        kind: Some("decision".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 10_000,
    })?;
    let mut out = Vec::new();
    for decision in decisions {
        if matches!(decision.lifecycle.as_str(), "archived" | "discarded") {
            continue;
        }
        let Some(inspection) = host.inspect_resource(&decision.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        let Some(metadata) = payload.get("metadata") else {
            continue;
        };
        let Some(decision_type) = metadata.get("decisionType").and_then(Value::as_str) else {
            continue;
        };
        if !matches!(
            decision_type,
            "notification_read" | "notification_mark_all_read"
        ) {
            continue;
        }
        out.push(NotificationReadDecision {
            decision_type: decision_type.to_owned(),
            notification_resource_id: metadata
                .get("notificationResourceId")
                .and_then(Value::as_str)
                .map(str::to_owned),
            affected_notification_ids: metadata
                .get("affectedNotificationIds")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter_map(|value| value.as_str().map(str::to_owned))
                .collect(),
            read_at: metadata
                .get("readAt")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
        });
    }
    Ok(out)
}

pub(super) fn notification_collection_layout(
    projection: &TargetProjection,
    rows: &[Value],
) -> Value {
    let unread = projection
        .graph
        .pointer("/collection/unreadCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let mut children = Vec::new();
    if unread > 0 {
        children.push(json!({
            "type": "Button",
            "props": {"label": "Mark all read", "actionId": "mark-all-read"}
        }));
    }
    if rows.is_empty() {
        children.push(json!({
            "type": "EmptyState",
            "props": {
                "title": "No notifications",
                "message": "Operator notifications will appear here."
            }
        }));
    } else {
        for row in rows {
            let Some(resource_id) = row.get("resourceId").and_then(Value::as_str) else {
                continue;
            };
            let row_key = collection_row_key(resource_id);
            let is_read = row.get("isRead").and_then(Value::as_bool).unwrap_or(false);
            let mut row_children = vec![
                json!({"type": "ResourceRef", "props": {
                    "resourceId": resource_id,
                    "versionId": row.get("versionId").cloned().unwrap_or(Value::Null),
                    "kind": "notification",
                    "label": "Notification resource"
                }}),
                json!({"type": "Text", "props": {
                    "text": row.get("body").cloned().unwrap_or(Value::Null)
                }}),
                json!({"type": "Metric", "props": {
                    "label": "Priority",
                    "value": row.get("priority").cloned().unwrap_or_else(|| json!("normal"))
                }}),
                json!({"type": "Metric", "props": {
                    "label": "Delivery",
                    "value": row.get("deliveryStatus").cloned().unwrap_or_else(|| json!("unknown"))
                }}),
                json!({"type": "Metric", "props": {
                    "label": "Read",
                    "value": if is_read { json!("yes") } else { json!("no") }
                }}),
            ];
            if !is_read {
                row_children.push(json!({"type": "Button", "props": {
                    "label": "Mark read",
                    "actionId": format!("mark-read-{row_key}")
                }}));
            }
            children.push(json!({
                "type": "Disclosure",
                "props": {
                    "title": row.get("title").and_then(Value::as_str).unwrap_or("Notification"),
                    "subtitle": row.get("createdAt").cloned().unwrap_or(Value::Null),
                    "open": !is_read
                },
                "children": row_children
            }));
        }
    }
    json!({"type": "Section", "props": {"title": projection.title}, "children": children})
}

pub(super) fn notification_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let rows = notification_collection_rows(host)?;
    let mut actions = Vec::new();
    if rows
        .iter()
        .any(|row| row.get("isRead").and_then(Value::as_bool) == Some(false))
    {
        actions.push(prompt_collection_action(
            invocation,
            functions,
            "mark-all-read",
            "Mark All Read",
            "notifications::mark_all_read",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({}),
        )?);
    }
    for row in rows {
        if row.get("isRead").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let resource_id = row["resourceId"].as_str().unwrap_or_default();
        let row_key = collection_row_key(resource_id);
        actions.push(prompt_collection_action(
            invocation,
            functions,
            &format!("mark-read-{row_key}"),
            "Mark Read",
            "notifications::mark_read",
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({"eventId": resource_id}),
        )?);
    }
    Ok(actions)
}

fn notification_collection_rows(host: &dyn PrimitiveRuntimeHost) -> Result<Vec<Value>> {
    let decisions = notification_read_decisions(host)?;
    let resources = host.list_resources(ListResources {
        kind: Some("notification".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 10_000,
    })?;
    let mut rows = Vec::new();
    for resource in resources.into_iter().filter(|resource| {
        resource
            .resource_id
            .starts_with(NOTIFICATION_RESOURCE_PREFIX)
            && !matches!(resource.lifecycle.as_str(), "discarded" | "archived")
            && resource.current_version_id.is_some()
    }) {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        if let Some(row) = notification_collection_row(&inspection, &payload, &decisions) {
            rows.push(row);
        }
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
    rows.truncate(NOTIFICATION_COLLECTION_LIMIT);
    Ok(rows)
}
