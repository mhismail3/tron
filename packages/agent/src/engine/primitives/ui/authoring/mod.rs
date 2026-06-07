//! Server-owned generated UI authoring for engine substrate surfaces.

use super::*;

pub(in crate::engine::primitives::ui::authoring) use actions::generated_actions;

mod actions;

#[derive(Clone, Debug)]
pub(in crate::engine::primitives::ui) struct SurfaceAuthoringRequest {
    pub(super) target_type: String,
    pub(super) target_id: String,
    pub(super) purpose: String,
    pub(super) layout_profile: String,
    pub(super) expected_target_revision: Option<u64>,
    pub(super) existing_surface_resource_id: Option<String>,
    pub(super) expected_current_version_id: Option<String>,
    pub(super) resource_id: Option<String>,
    pub(super) max_preview_bytes: usize,
    pub(super) expires_at: String,
    pub(super) refresh_policy: Value,
    pub(super) links: Vec<Value>,
    pub(super) context_session_id: Option<String>,
}

pub(super) struct AuthoredSurface {
    pub(super) surface: Value,
}

impl SurfaceAuthoringRequest {
    pub(in crate::engine::primitives::ui) fn from_invocation(
        invocation: &crate::engine::Invocation,
    ) -> Result<Self> {
        let target_type = required_string_owned(&invocation.payload, "targetType")?;
        ensure_supported_target_type(&target_type)?;
        let target_id = required_string_owned(&invocation.payload, "targetId")?;
        let purpose = optional_string(invocation.payload.get("purpose"))?
            .unwrap_or_else(|| format!("Inspect {target_type} {target_id}"));
        let layout_profile = optional_string(invocation.payload.get("layoutProfile"))?
            .unwrap_or_else(|| "compact".to_owned());
        let max_preview_bytes = optional_u64(invocation.payload.get("maxPreviewBytes"))?
            .unwrap_or(1024)
            .min(16 * 1024) as usize;
        let expires_at = optional_string(invocation.payload.get("expiresAt"))?
            .unwrap_or_else(default_expires_at);
        ensure_not_expired(Some(&expires_at), "ui_surface")?;
        Ok(Self {
            target_type,
            target_id,
            purpose,
            layout_profile,
            expected_target_revision: optional_u64(
                invocation.payload.get("expectedTargetRevision"),
            )?,
            existing_surface_resource_id: optional_string(
                invocation.payload.get("existingSurfaceResourceId"),
            )?,
            expected_current_version_id: optional_string(
                invocation.payload.get("expectedCurrentVersionId"),
            )?,
            resource_id: optional_string(invocation.payload.get("resourceId"))?,
            max_preview_bytes,
            expires_at,
            refresh_policy: invocation
                .payload
                .get("refreshPolicy")
                .cloned()
                .unwrap_or_else(|| json!({"mode": "manual"})),
            links: invocation
                .payload
                .get("links")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
            context_session_id: invocation.causal_context.session_id.clone(),
        })
    }

    pub(in crate::engine::primitives::ui) fn from_authoring_payload(
        payload: &Value,
    ) -> Result<Self> {
        let authoring = payload
            .get("authoring")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "ui::refresh_surface requires generated authoring metadata".to_owned(),
                )
            })?;
        if authoring.get("mode").and_then(Value::as_str) != Some(GENERATED_AUTHORING_MODE) {
            return Err(EngineError::PolicyViolation(
                "ui::refresh_surface requires generated authoring metadata".to_owned(),
            ));
        }
        let target_type = authoring
            .get("targetType")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                EngineError::PolicyViolation("generated authoring requires targetType".to_owned())
            })?
            .to_owned();
        ensure_supported_target_type(&target_type)?;
        let target_id = authoring
            .get("targetId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                EngineError::PolicyViolation("generated authoring requires targetId".to_owned())
            })?
            .to_owned();
        Ok(Self {
            target_type,
            target_id,
            purpose: authoring
                .get("purpose")
                .and_then(Value::as_str)
                .unwrap_or("Refresh generated surface")
                .to_owned(),
            layout_profile: authoring
                .get("layoutProfile")
                .and_then(Value::as_str)
                .unwrap_or("compact")
                .to_owned(),
            expected_target_revision: authoring.get("targetRevision").and_then(Value::as_u64),
            existing_surface_resource_id: None,
            expected_current_version_id: None,
            resource_id: None,
            max_preview_bytes: authoring
                .get("maxPreviewBytes")
                .and_then(Value::as_u64)
                .unwrap_or(1024)
                .min(16 * 1024) as usize,
            expires_at: payload
                .get("expiresAt")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .unwrap_or_else(default_expires_at),
            refresh_policy: payload
                .get("refreshPolicy")
                .cloned()
                .unwrap_or_else(|| json!({"mode": "manual"})),
            links: payload
                .get("bindings")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
            context_session_id: authoring
                .get("contextSessionId")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        })
    }
}

pub(super) fn author_surface_for_target(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    refreshed_from_version_id: Option<&str>,
) -> Result<AuthoredSurface> {
    let projection = target_projection(host, invocation, request)?;
    if let Some(expected) = request.expected_target_revision
        && projection.revision != expected
    {
        return Err(EngineError::StaleFunctionRevision {
            function_id: format!("{}:{}", request.target_type, request.target_id),
            expected,
            actual: projection.revision,
        });
    }
    let projection_hash = hash_json(&projection.graph)?;
    let mut bindings = vec![json!({
        "targetType": request.target_type,
        "targetId": request.target_id,
        "role": "target",
        "layoutProfile": request.layout_profile,
        "label": projection.title,
    })];
    for link in &request.links {
        if !bindings.iter().any(|binding| binding == link) {
            bindings.push(link.clone());
        }
    }
    let surface_id = format!(
        "generated.{}.{}",
        request.target_type,
        slug(&request.target_id)
    );
    let actions = generated_actions(host, invocation, request)?;
    let mut surface = json!({
        "surfaceId": surface_id,
        "title": projection.title,
        "purpose": request.purpose,
        "catalog": {"id": "tron.ui.catalog.core.v1", "revision": UI_CATALOG_REVISION},
        "layout": layout_for_projection(request, &projection, &actions),
        "bindings": bindings,
        "actions": actions,
        "redactionPolicy": {"mode": "redacted"},
        "expiresAt": request.expires_at,
        "refreshPolicy": request.refresh_policy,
        "authoring": {
            "mode": GENERATED_AUTHORING_MODE,
            "targetType": request.target_type,
            "targetId": request.target_id,
            "purpose": request.purpose,
            "layoutProfile": request.layout_profile,
            "targetRevision": projection.revision,
            "catalogRevision": host.catalog_revision().0,
            "projectionHash": projection_hash,
            "maxPreviewBytes": request.max_preview_bytes,
            "createdByInvocationId": invocation.id.as_str(),
        }
    });
    if let Some(session_id) = &request.context_session_id {
        surface["authoring"]["contextSessionId"] = json!(session_id);
    }
    if let Some(version_id) = refreshed_from_version_id {
        surface["authoring"]["refreshedFromVersionId"] = json!(version_id);
    }
    validate_surface_targets(host, invocation, &surface)?;
    validate_ui_surface_payload(&surface)?;
    Ok(AuthoredSurface { surface })
}

pub(in crate::engine::primitives::ui) struct TargetProjection {
    pub(in crate::engine::primitives::ui) title: String,
    pub(in crate::engine::primitives::ui) summary: String,
    pub(in crate::engine::primitives::ui) revision: u64,
    pub(in crate::engine::primitives::ui) graph: Value,
}

pub(in crate::engine::primitives::ui) fn target_projection(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    match request.target_type.as_str() {
        "worker" => {
            let worker_id = WorkerId::new(request.target_id.clone())?;
            let worker = host.inspect_worker(&worker_id)?;
            let functions = host
                .discover_functions(&FunctionQuery {
                    include_internal: true,
                    ..FunctionQuery::default()
                })
                .into_iter()
                .filter(|function| function.owner_worker == worker_id)
                .collect::<Vec<_>>();
            Ok(TargetProjection {
                title: format!("Worker {}", worker.id.as_str()),
                summary: format!("{} capabilities", functions.len()),
                revision: host.catalog_revision().0,
                graph: bounded_json(
                    json!({"worker": worker, "capabilities": functions}),
                    request.max_preview_bytes,
                ),
            })
        }
        "capability" => {
            let function = host
                .discover_functions(&FunctionQuery {
                    actor: Some(actor_context(invocation)),
                    include_internal: true,
                    ..FunctionQuery::default()
                })
                .into_iter()
                .find(|function| function.id.as_str() == request.target_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "function",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Capability {}", function.id.as_str()),
                summary: function.description.clone(),
                revision: function.revision.0,
                graph: bounded_json(json!({"capability": function}), request.max_preview_bytes),
            })
        }
        "goal" | "resource" => {
            let inspection = host.inspect_resource(&request.target_id)?.ok_or_else(|| {
                EngineError::NotFound {
                    kind: "resource",
                    id: request.target_id.clone(),
                }
            })?;
            let summary = format!(
                "{} / {}",
                inspection.resource.kind, inspection.resource.lifecycle
            );
            Ok(TargetProjection {
                title: format!("Resource {}", inspection.resource.resource_id),
                summary,
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"resource": inspection}), request.max_preview_bytes),
            })
        }
        RESOURCE_COLLECTION_TARGET => resource_collection_projection(host, request),
        "decision" => {
            let inspection = host.inspect_resource(&request.target_id)?.ok_or_else(|| {
                EngineError::NotFound {
                    kind: "resource",
                    id: request.target_id.clone(),
                }
            })?;
            if inspection.resource.kind != "decision" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {} is {}, expected decision",
                    request.target_id, inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Decision {}", request.target_id),
                summary: inspection.resource.lifecycle.clone(),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"decision": inspection}), request.max_preview_bytes),
            })
        }
        "invocation" => {
            let record = host
                .invocations()
                .into_iter()
                .find(|record| record.invocation_id.as_str() == request.target_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "invocation",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Invocation {}", record.function_id.as_str()),
                summary: record
                    .error
                    .as_ref()
                    .map_or_else(|| "completed".to_owned(), |_| "failed".to_owned()),
                revision: record.function_revision.0,
                graph: bounded_json(
                    json!({"invocation": invocation_record_value(&record, false)}),
                    request.max_preview_bytes,
                ),
            })
        }
        "grant" => {
            let grant_id = crate::engine::ids::AuthorityGrantId::new(request.target_id.clone())?;
            let grant = host
                .inspect_grant(&grant_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "grant",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Grant {}", grant.grant_id.as_str()),
                summary: format!("{:?} / max {:?}", grant.lifecycle, grant.max_risk),
                revision: grant.revision,
                graph: bounded_json(json!({"grant": grant}), request.max_preview_bytes),
            })
        }
        "queue" => {
            let item = host
                .queue_items("engine", 500)?
                .into_iter()
                .find(|item| {
                    item.receipt_id == request.target_id || item.queue == request.target_id
                })
                .ok_or_else(|| EngineError::NotFound {
                    kind: "queue_item",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Queue {}", item.receipt_id),
                summary: format!("{:?} {}", item.status, item.function_id.as_str()),
                revision: item
                    .target_revision
                    .map_or(host.catalog_revision().0, |revision| revision.0),
                graph: bounded_json(json!({"queue": item}), request.max_preview_bytes),
            })
        }
        "lease" => {
            let lease =
                host.resource_lease(&request.target_id)?
                    .ok_or_else(|| EngineError::NotFound {
                        kind: "lease",
                        id: request.target_id.clone(),
                    })?;
            Ok(TargetProjection {
                title: format!("Lease {}", lease.lease_id),
                summary: format!(
                    "{:?} {}:{}",
                    lease.status, lease.resource_kind, lease.resource_id
                ),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"lease": lease}), request.max_preview_bytes),
            })
        }
        "storage" => {
            let storage = host.storage_stats().ok().map(|stats| json!(stats));
            Ok(TargetProjection {
                title: "Storage".to_owned(),
                summary: storage
                    .as_ref()
                    .and_then(|value| value.get("databaseBytes").and_then(Value::as_u64))
                    .map_or_else(
                        || "storage stats unavailable".to_owned(),
                        |bytes| format!("{bytes} database bytes"),
                    ),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"storage": storage}), request.max_preview_bytes),
            })
        }
        "integrity" => {
            let damaged = host.list_resources(crate::engine::resources::ListResources {
                kind: None,
                scope: None,
                lifecycle: Some("damaged".to_owned()),
                limit: 50,
            })?;
            Ok(TargetProjection {
                title: "Integrity".to_owned(),
                summary: format!("{} damaged resources", damaged.len()),
                revision: host.catalog_revision().0,
                graph: bounded_json(
                    json!({"damagedResources": damaged}),
                    request.max_preview_bytes,
                ),
            })
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported ui target type {other}"
        ))),
    }
}

fn resource_collection_projection(
    host: &dyn PrimitiveRuntimeHost,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    if request.layout_profile != "compact" {
        return Err(EngineError::PolicyViolation(format!(
            "resource_collection target {} requires layoutProfile compact",
            request.target_id
        )));
    }
    let kind = match request.target_id.as_str() {
        "*" | "all" => None,
        kind => Some(kind.to_owned()),
    };
    let resources = host.list_resources(ListResources {
        kind: kind.clone(),
        scope: None,
        lifecycle: None,
        limit: RESOURCE_COLLECTION_SCAN_LIMIT,
    })?;
    let mut rows = resources
        .into_iter()
        .map(|resource| {
            json!({
                "resourceId": resource.resource_id,
                "kind": resource.kind,
                "scope": resource.scope.kind(),
                "scopeValue": resource.scope.value(),
                "lifecycle": resource.lifecycle,
                "currentVersionId": resource.current_version_id,
                "createdAt": resource.created_at.to_rfc3339(),
                "updatedAt": resource.updated_at.to_rfc3339(),
            })
        })
        .collect::<Vec<_>>();
    rows.sort_by(|left, right| {
        right
            .get("updatedAt")
            .and_then(Value::as_str)
            .cmp(&left.get("updatedAt").and_then(Value::as_str))
            .then_with(|| {
                left.get("resourceId")
                    .and_then(Value::as_str)
                    .cmp(&right.get("resourceId").and_then(Value::as_str))
            })
    });
    let truncated = rows.len() > RESOURCE_COLLECTION_LIMIT;
    rows.truncate(RESOURCE_COLLECTION_LIMIT);
    let title = kind.as_deref().map_or_else(
        || "Resources".to_owned(),
        |kind| format!("{kind} resources"),
    );
    let summary = format!(
        "{} resources{}",
        rows.len(),
        if truncated { " shown" } else { "" }
    );
    Ok(TargetProjection {
        title,
        summary,
        revision: host.catalog_revision().0,
        graph: json!({
            "collection": {
                "targetId": request.target_id,
                "layoutProfile": request.layout_profile,
                "resourceKind": kind,
                "rows": rows,
                "truncated": truncated,
                "limit": RESOURCE_COLLECTION_LIMIT,
            }
        }),
    })
}

pub(super) fn display_identifier(value: &str) -> String {
    let char_count = value.chars().count();
    if char_count <= 24 {
        return value.to_owned();
    }
    let prefix = value.chars().take(10).collect::<String>();
    let suffix = value
        .chars()
        .rev()
        .take(8)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    format!("{prefix}...{suffix}")
}

fn layout_for_projection(
    request: &SurfaceAuthoringRequest,
    projection: &TargetProjection,
    actions: &[Value],
) -> Value {
    if request.target_type == RESOURCE_COLLECTION_TARGET {
        return resource_collection_layout(projection);
    }
    if request.target_type == "capability" {
        return capability_layout(projection, actions);
    }
    if request.target_type == "decision" {
        return operator_action_layout(projection, actions);
    }
    json!({
        "type": "Section",
        "props": {"title": projection.title},
        "children": [
            {"type": "Heading", "props": {"text": projection.title}},
            {"type": "Text", "props": {"text": projection.summary}},
            {"type": "Monospace", "props": {"text": projection.graph.to_string()}},
            {"type": "Button", "props": {"label": "Refresh", "actionId": "refresh-surface"}}
        ]
    })
}

fn operator_action_layout(projection: &TargetProjection, actions: &[Value]) -> Value {
    let mut children = vec![
        json!({"type": "Heading", "props": {"text": projection.title}}),
        json!({"type": "Text", "props": {"text": projection.summary}}),
        json!({"type": "Monospace", "props": {"text": projection.graph.to_string()}}),
    ];
    children.extend(operator_input_components(actions));
    let action_ids = actions
        .iter()
        .filter_map(|action| {
            action
                .get("actionId")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .collect::<Vec<_>>();
    if !action_ids.is_empty() {
        children.push(json!({
            "type": "ButtonGroup",
            "props": {"actions": action_ids}
        }));
    }
    json!({
        "type": "Section",
        "props": {"title": projection.title},
        "children": children
    })
}

fn operator_input_components(actions: &[Value]) -> Vec<Value> {
    let mut components = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for action in actions {
        let schema = action.get("inputSchema").unwrap_or(&Value::Null);
        let properties = schema
            .get("properties")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let required = schema
            .get("required")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str);
        for name in required {
            if !seen.insert(name.to_owned()) {
                continue;
            }
            if let Some(property) = properties.get(name) {
                components.push(component_for_capability_field(name, property));
            }
        }
    }
    components
}

fn capability_layout(projection: &TargetProjection, actions: &[Value]) -> Value {
    let mut children = vec![
        json!({"type": "Heading", "props": {"text": projection.title}}),
        json!({"type": "Text", "props": {"text": projection.summary}}),
        json!({"type": "Monospace", "props": {"text": projection.graph.to_string()}}),
    ];
    if let Some(invoke) = actions
        .iter()
        .find(|action| action.get("actionId").and_then(Value::as_str) == Some("invoke-capability"))
    {
        children.extend(capability_input_components(invoke));
        children.push(json!({
            "type": "Button",
            "props": {"label": "Invoke", "actionId": "invoke-capability"}
        }));
    }
    children.push(
        json!({"type": "Button", "props": {"label": "Refresh", "actionId": "refresh-surface"}}),
    );
    json!({
        "type": "Section",
        "props": {"title": projection.title},
        "children": children
    })
}

fn capability_input_components(action: &Value) -> Vec<Value> {
    let schema = action.get("inputSchema").unwrap_or(&Value::Null);
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    required
        .filter_map(|name| {
            let property = properties.get(name)?;
            Some(component_for_capability_field(name, property))
        })
        .collect()
}

fn component_for_capability_field(name: &str, schema: &Value) -> Value {
    let label = schema
        .get("title")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| display_identifier(name));
    if let Some(options) = schema.get("enum").and_then(Value::as_array) {
        let options = options
            .iter()
            .filter_map(Value::as_str)
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
        return json!({"type": "Select", "props": {"name": name, "label": label, "required": true, "options": options}});
    }
    match schema.get("type").and_then(Value::as_str) {
        Some("boolean") => {
            json!({"type": "Toggle", "props": {"name": name, "label": label}})
        }
        Some("integer") => {
            json!({"type": "Stepper", "props": {"name": name, "label": label}})
        }
        _ if name.contains("text") || name.contains("body") || name.contains("message") => {
            json!({"type": "TextArea", "props": {"name": name, "label": label, "required": true}})
        }
        _ => {
            json!({"type": "TextField", "props": {"name": name, "label": label, "required": true}})
        }
    }
}

fn resource_collection_layout(projection: &TargetProjection) -> Value {
    let rows = projection
        .graph
        .pointer("/collection/rows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut children = vec![
        json!({"type": "Heading", "props": {"text": projection.title}}),
        json!({"type": "Text", "props": {"text": projection.summary}}),
    ];
    for row in rows {
        let title = row
            .get("resourceId")
            .and_then(Value::as_str)
            .unwrap_or("resource");
        let detail = json!({
            "kind": row.get("kind").cloned().unwrap_or(Value::Null),
            "scope": row.get("scope").cloned().unwrap_or(Value::Null),
            "lifecycle": row.get("lifecycle").cloned().unwrap_or(Value::Null),
            "currentVersionId": row.get("currentVersionId").cloned().unwrap_or(Value::Null),
        });
        children.push(json!({
            "type": "ResourceRow",
            "props": {
                "title": title,
                "subtitle": detail.to_string()
            }
        }));
    }
    children.push(
        json!({"type": "Button", "props": {"label": "Refresh", "actionId": "refresh-surface"}}),
    );
    json!({
        "type": "Section",
        "props": {"title": projection.title},
        "children": children
    })
}

pub(in crate::engine::primitives::ui) fn actor_context(
    invocation: &crate::engine::Invocation,
) -> ActorContext {
    ActorContext {
        actor_id: invocation.causal_context.actor_id.clone(),
        actor_kind: invocation.causal_context.actor_kind.clone(),
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        authority_scopes: invocation.causal_context.authority_scopes.clone(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
    }
}
