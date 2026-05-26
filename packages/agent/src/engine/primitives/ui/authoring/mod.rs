//! Server-owned generated UI authoring for resource and lineage surfaces.

use super::*;

use agent_control::{
    agent_control_actions, agent_control_projection, agent_control_session_layout,
};
use notifications::{
    notification_collection_actions, notification_collection_layout,
    notification_collection_projection,
};
use prompt::{
    prompt_history_collection_actions, prompt_history_collection_layout,
    prompt_history_collection_row, prompt_snippet_collection_actions,
    prompt_snippet_collection_layout, prompt_snippet_collection_row,
};
use source_control::{
    source_control_actions, source_control_invocation_rows, source_control_projection,
    source_control_session_layout,
};
use subagent::{
    subagent_collection_actions, subagent_collection_layout, subagent_collection_projection,
};

mod agent_control;
mod notifications;
mod prompt;
mod source_control;
mod subagent;

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
    let mut surface = json!({
        "surfaceId": surface_id,
        "title": projection.title,
        "purpose": request.purpose,
        "catalog": {"id": "tron.ui.catalog.core.v1", "revision": UI_CATALOG_REVISION},
        "layout": layout_for_projection(request, &projection),
        "bindings": bindings,
        "actions": generated_actions(host, invocation, request)?,
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
        SOURCE_CONTROL_TARGET => source_control_projection(host, request),
        AGENT_CONTROL_TARGET => agent_control_projection(host, invocation, request),
        "package" => {
            let resource_id = if request.target_id.starts_with("worker-package:") {
                request.target_id.clone()
            } else {
                format!("worker-package:{}", request.target_id)
            };
            let inspection =
                host.inspect_resource(&resource_id)?
                    .ok_or_else(|| EngineError::NotFound {
                        kind: "resource",
                        id: resource_id.clone(),
                    })?;
            if inspection.resource.kind != "worker_package" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {resource_id} is {}, expected worker_package",
                    inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Package {}", request.target_id),
                summary: format!(
                    "{} / {}",
                    inspection.resource.kind, inspection.resource.lifecycle
                ),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"package": inspection}), request.max_preview_bytes),
            })
        }
        "module_config" => {
            let inspection = host.inspect_resource(&request.target_id)?.ok_or_else(|| {
                EngineError::NotFound {
                    kind: "resource",
                    id: request.target_id.clone(),
                }
            })?;
            if inspection.resource.kind != "module_config" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {} is {}, expected module_config",
                    request.target_id, inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Module Config {}", request.target_id),
                summary: inspection.resource.lifecycle.clone(),
                revision: host.catalog_revision().0,
                graph: bounded_json(
                    json!({"moduleConfig": inspection}),
                    request.max_preview_bytes,
                ),
            })
        }
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
        "activation" => {
            let resource_id = if request.target_id.starts_with("activation:") {
                request.target_id.clone()
            } else {
                format!("activation:{}", request.target_id)
            };
            let inspection =
                host.inspect_resource(&resource_id)?
                    .ok_or_else(|| EngineError::NotFound {
                        kind: "resource",
                        id: resource_id.clone(),
                    })?;
            if inspection.resource.kind != "activation_record" {
                return Err(EngineError::PolicyViolation(format!(
                    "resource {resource_id} is {}, expected activation_record",
                    inspection.resource.kind
                )));
            }
            Ok(TargetProjection {
                title: format!("Activation {}", request.target_id),
                summary: inspection.resource.lifecycle.clone(),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"activation": inspection}), request.max_preview_bytes),
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
        "approval" => {
            let record = host
                .approval_records(None, invocation.causal_context.session_id.as_deref(), 500)?
                .into_iter()
                .find(|record| record.approval_id == request.target_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "approval",
                    id: request.target_id.clone(),
                })?;
            Ok(TargetProjection {
                title: format!("Approval {}", record.approval_id),
                summary: format!("{:?} {}", record.status, record.function_id.as_str()),
                revision: host.catalog_revision().0,
                graph: bounded_json(json!({"approval": record}), request.max_preview_bytes),
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
    if request.target_id == NOTIFICATION_COLLECTION_TARGET {
        return notification_collection_projection(host, request);
    }
    if request.target_id == SUBAGENT_COLLECTION_TARGET {
        return subagent_collection_projection(host, request);
    }
    let (prefix, title, expected_profile, row_kind) = match request.target_id.as_str() {
        PROMPT_SNIPPET_COLLECTION_TARGET => (
            PROMPT_SNIPPET_RESOURCE_PREFIX,
            "Prompt Snippets",
            PROMPT_SNIPPET_LAYOUT_PROFILE,
            "snippet",
        ),
        PROMPT_HISTORY_COLLECTION_TARGET => (
            PROMPT_HISTORY_RESOURCE_PREFIX,
            "Prompt History",
            PROMPT_HISTORY_LAYOUT_PROFILE,
            "history",
        ),
        other => {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported resource_collection target {other}"
            )));
        }
    };
    if request.layout_profile != expected_profile {
        return Err(EngineError::PolicyViolation(format!(
            "resource_collection target {} requires layoutProfile {expected_profile}",
            request.target_id
        )));
    }

    let resources = host.list_resources(ListResources {
        kind: Some("artifact".to_owned()),
        scope: None,
        lifecycle: None,
        limit: 10_000,
    })?;
    let mut rows = Vec::new();
    for resource in resources.into_iter().filter(|resource| {
        resource.resource_id.starts_with(prefix)
            && resource.lifecycle != "discarded"
            && resource.current_version_id.is_some()
    }) {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        let row = match row_kind {
            "snippet" => prompt_snippet_collection_row(&inspection, &payload, request),
            "history" => prompt_history_collection_row(&inspection, &payload, request),
            _ => None,
        };
        if let Some(row) = row {
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
    let truncated = rows.len() > PROMPT_COLLECTION_LIMIT;
    rows.truncate(PROMPT_COLLECTION_LIMIT);
    let summary = format!(
        "{} {}{}",
        rows.len(),
        if row_kind == "snippet" {
            "snippets"
        } else {
            "history entries"
        },
        if truncated { " shown" } else { "" }
    );
    Ok(TargetProjection {
        title: title.to_owned(),
        summary,
        revision: host.catalog_revision().0,
        graph: json!({
            "collection": {
                "targetId": request.target_id,
                "layoutProfile": request.layout_profile,
                "resourceKind": "artifact",
                "rowKind": row_kind,
                "rows": rows,
                "truncated": truncated,
                "limit": PROMPT_COLLECTION_LIMIT,
            }
        }),
    })
}

pub(super) fn bounded_text_preview(text: &str, max_preview_bytes: usize) -> String {
    if unsafe_prompt_preview_text(text) {
        return "[redacted]".to_owned();
    }
    let max_chars = max_preview_bytes.clamp(64, 512);
    if text.chars().count() <= max_chars {
        text.to_owned()
    } else {
        let mut preview = text.chars().take(max_chars).collect::<String>();
        preview.push_str("...");
        preview
    }
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

pub(super) fn unsafe_prompt_preview_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("secret=")
        || lower.contains("api_key")
        || lower.contains("access_token")
        || lower.contains("private_key")
        || lower.contains("file://")
        || lower.contains("javascript:")
        || lower.contains("<script")
        || text.contains("sk-")
}

fn layout_for_projection(
    request: &SurfaceAuthoringRequest,
    projection: &TargetProjection,
) -> Value {
    if request.target_type == RESOURCE_COLLECTION_TARGET {
        return resource_collection_layout(request, projection);
    }
    if request.target_type == SOURCE_CONTROL_TARGET {
        return source_control_session_layout(projection);
    }
    if request.target_type == AGENT_CONTROL_TARGET {
        return agent_control_session_layout(projection);
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

fn resource_collection_layout(
    request: &SurfaceAuthoringRequest,
    projection: &TargetProjection,
) -> Value {
    let rows = projection
        .graph
        .pointer("/collection/rows")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if request.layout_profile == PROMPT_SNIPPET_LAYOUT_PROFILE {
        return prompt_snippet_collection_layout(projection, &rows);
    }
    if request.layout_profile == NOTIFICATION_INBOX_LAYOUT_PROFILE {
        return notification_collection_layout(projection, &rows);
    }
    if request.layout_profile == SUBAGENT_LINEAGE_LAYOUT_PROFILE {
        return subagent_collection_layout(projection, &rows);
    }
    prompt_history_collection_layout(projection, &rows)
}

fn generated_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
) -> Result<Vec<Value>> {
    let functions = host.discover_functions(&FunctionQuery {
        actor: Some(actor_context(invocation)),
        include_internal: true,
        ..FunctionQuery::default()
    });
    let refresh = functions
        .iter()
        .find(|function| function.id.as_str() == REFRESH_SURFACE_FUNCTION)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: REFRESH_SURFACE_FUNCTION.to_owned(),
        })?;
    let mut actions = vec![json!({
        "actionId": "refresh-surface",
        "label": "Refresh",
        "targetFunctionId": REFRESH_SURFACE_FUNCTION,
        "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
        "payloadTemplate": {
            "surfaceResourceId": "${surface.resourceId}",
            "expectedCurrentVersionId": "${surface.versionId}"
        },
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&refresh.risk_level),
        "approvalPolicy": {"required": refresh.required_authority.approval_required},
        "targetRevision": refresh.revision.0,
        "expiresAt": default_expires_at()
    })];
    if request.target_type == RESOURCE_COLLECTION_TARGET {
        actions.extend(resource_collection_actions(
            host, invocation, request, &functions,
        )?);
    }
    if request.target_type == SOURCE_CONTROL_TARGET {
        actions.extend(source_control_actions(invocation, request, &functions)?);
    }
    if request.target_type == AGENT_CONTROL_TARGET {
        actions.extend(agent_control_actions(invocation, request, &functions)?);
    }
    if request.target_type == "package" {
        if let Some(inspect_package) = functions
            .iter()
            .find(|function| function.id.as_str() == "module::inspect_package")
        {
            actions.push(json!({
                "actionId": "inspect-package",
                "label": "Inspect Package",
                "targetFunctionId": "module::inspect_package",
                "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                "payloadTemplate": {
                    "packageId": request.target_id.strip_prefix("worker-package:").unwrap_or(&request.target_id)
                },
                "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                "requiredRisk": risk_label(&inspect_package.risk_level),
                "approvalPolicy": {"required": inspect_package.required_authority.approval_required},
                "targetRevision": inspect_package.revision.0,
                "expiresAt": default_expires_at()
            }));
        }
        if let Some(verify_integrity) = functions
            .iter()
            .find(|function| function.id.as_str() == "module::verify_integrity")
        {
            let resource_id = if request.target_id.starts_with("worker-package:") {
                request.target_id.clone()
            } else {
                format!("worker-package:{}", request.target_id)
            };
            if let Some(inspection) = host.inspect_resource(&resource_id)?
                && let Some(version_id) = inspection.resource.current_version_id
            {
                actions.push(json!({
                    "actionId": "verify-package-integrity",
                    "label": "Verify Integrity",
                    "targetFunctionId": "module::verify_integrity",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "worker_package",
                        "resourceId": resource_id,
                        "resourceVersionId": version_id
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_integrity.risk_level),
                    "approvalPolicy": {"required": verify_integrity.required_authority.approval_required},
                    "targetRevision": verify_integrity.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
        let resource_id = if request.target_id.starts_with("worker-package:") {
            request.target_id.clone()
        } else {
            format!("worker-package:{}", request.target_id)
        };
        if let Some(inspection) = host.inspect_resource(&resource_id)?
            && let Some(version_id) = inspection.resource.current_version_id.clone()
        {
            let manifest = current_payload(&inspection).unwrap_or_else(|| json!({}));
            if let Some(verify_source) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::verify_source")
            {
                actions.push(json!({
                    "actionId": "verify-package-source",
                    "label": "Verify Source",
                    "targetFunctionId": "module::verify_source",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "mode": "on_demand"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_source.risk_level),
                    "approvalPolicy": {"required": verify_source.required_authority.approval_required},
                    "targetRevision": verify_source.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(register_source) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::register_source")
            {
                if manifest
                    .get("sourceProvenance")
                    .and_then(|source| source.get("kind"))
                    .and_then(Value::as_str)
                    == Some("local_digest_pinned")
                {
                    actions.push(json!({
                        "actionId": "register-local-package-source",
                        "label": "Register Source",
                        "targetFunctionId": "module::register_source",
                        "inputSchema": {
                            "type": "object",
                            "required": ["reason", "expiresAt"],
                            "additionalProperties": false,
                            "properties": {
                                "reason": {"type": "string"},
                                "expiresAt": {"type": "string"}
                            }
                        },
                        "payloadTemplate": {
                            "sourceKind": "local_digest_source",
                            "scope": "system",
                            "sourceDigest": manifest.get("packageDigest").cloned().unwrap_or(Value::Null),
                            "sourceRef": manifest.get("sourceRef").cloned().unwrap_or_else(|| json!({})),
                            "allowedPackageSelectors": [manifest.get("packageId").cloned().unwrap_or(Value::Null)],
                            "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                            "expiresAt": "${input.expiresAt}",
                            "reason": "${input.reason}"
                        },
                        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                        "requiredRisk": risk_label(&register_source.risk_level),
                        "approvalPolicy": {"required": register_source.required_authority.approval_required},
                        "targetRevision": register_source.revision.0,
                        "expiresAt": default_expires_at()
                    }));
                }
                if manifest
                    .get("signature")
                    .is_some_and(|value| !value.is_null())
                {
                    actions.push(json!({
                        "actionId": "register-ed25519-trust-root",
                        "label": "Register Trust Root",
                        "targetFunctionId": "module::register_source",
                        "inputSchema": {
                            "type": "object",
                            "required": ["publicKey", "keyId", "reason", "expiresAt"],
                            "additionalProperties": false,
                            "properties": {
                                "publicKey": {"type": "string"},
                                "keyId": {"type": "string"},
                                "reason": {"type": "string"},
                                "expiresAt": {"type": "string"}
                            }
                        },
                        "payloadTemplate": {
                            "sourceKind": "ed25519_trust_root",
                            "scope": "system",
                            "algorithm": "ed25519",
                            "publicKey": "${input.publicKey}",
                            "keyId": "${input.keyId}",
                            "allowedPackageSelectors": [manifest.get("packageId").cloned().unwrap_or(Value::Null)],
                            "trustTierCeiling": "signed_local",
                            "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                            "expiresAt": "${input.expiresAt}",
                            "reason": "${input.reason}"
                        },
                        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                        "requiredRisk": risk_label(&register_source.risk_level),
                        "approvalPolicy": {"required": register_source.required_authority.approval_required},
                        "targetRevision": register_source.revision.0,
                        "expiresAt": default_expires_at()
                    }));
                }
            }
            if manifest
                .get("signature")
                .is_some_and(|value| !value.is_null())
                && let Some(verify_signature) = functions
                    .iter()
                    .find(|function| function.id.as_str() == "module::verify_signature")
            {
                actions.push(json!({
                    "actionId": "verify-package-signature",
                    "label": "Verify Signature",
                    "targetFunctionId": "module::verify_signature",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&verify_signature.risk_level),
                    "approvalPolicy": {"required": verify_signature.required_authority.approval_required},
                    "targetRevision": verify_signature.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(audit_policy) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::audit_policy")
            {
                actions.push(json!({
                    "actionId": "audit-package-policy",
                    "label": "Audit Policy",
                    "targetFunctionId": "module::audit_policy",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&audit_policy.risk_level),
                    "approvalPolicy": {"required": audit_policy.required_authority.approval_required},
                    "targetRevision": audit_policy.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(record_policy_audit) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::record_policy_audit")
            {
                actions.push(json!({
                    "actionId": "record-package-policy-audit",
                    "label": "Record Audit",
                    "targetFunctionId": "module::record_policy_audit",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "scope": "system"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&record_policy_audit.risk_level),
                    "approvalPolicy": {"required": record_policy_audit.required_authority.approval_required},
                    "targetRevision": record_policy_audit.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(reconcile_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::reconcile_trust")
            {
                actions.push(json!({
                    "actionId": "reconcile-package-trust",
                    "label": "Reconcile Trust",
                    "targetFunctionId": "module::reconcile_trust",
                    "inputSchema": {
                        "type": "object",
                        "required": ["reason"],
                        "additionalProperties": false,
                        "properties": {"reason": {"type": "string"}}
                    },
                    "payloadTemplate": {
                        "scope": "system",
                        "packageResourceId": resource_id,
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&reconcile_trust.risk_level),
                    "approvalPolicy": {"required": reconcile_trust.required_authority.approval_required},
                    "targetRevision": reconcile_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(inspect_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::inspect_trust")
            {
                actions.push(json!({
                    "actionId": "inspect-package-trust",
                    "label": "Inspect Trust",
                    "targetFunctionId": "module::inspect_trust",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "includeEvidence": true,
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&inspect_trust.risk_level),
                    "approvalPolicy": {"required": inspect_trust.required_authority.approval_required},
                    "targetRevision": inspect_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(simulate_trust) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::simulate_trust_change")
            {
                actions.push(json!({
                    "actionId": "simulate-package-trust",
                    "label": "Simulate Trust",
                    "targetFunctionId": "module::simulate_trust_change",
                    "inputSchema": trust_review_operation_input_schema(false),
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "targetVersionId": version_id,
                        "operation": "${input.operation}",
                        "includeGeneratedUi": true,
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&simulate_trust.risk_level),
                    "approvalPolicy": {"required": simulate_trust.required_authority.approval_required},
                    "targetRevision": simulate_trust.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(record_review) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::record_trust_review")
            {
                actions.push(json!({
                    "actionId": "record-package-trust-review",
                    "label": "Record Review",
                    "targetFunctionId": "module::record_trust_review",
                    "inputSchema": trust_review_operation_input_schema(true),
                    "payloadTemplate": {
                        "targetType": "package",
                        "targetResourceId": resource_id,
                        "targetVersionId": version_id,
                        "operation": "${input.operation}",
                        "operatorNotes": "${input.operatorNotes}",
                        "limit": 50
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&record_review.risk_level),
                    "approvalPolicy": {"required": record_review.required_authority.approval_required},
                    "targetRevision": record_review.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(schedule_audit) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::schedule_trust_audit")
            {
                actions.push(json!({
                    "actionId": "schedule-package-trust-audit",
                    "label": "Schedule Audit",
                    "targetFunctionId": "module::schedule_trust_audit",
                    "inputSchema": {
                        "type": "object",
                        "required": ["scheduleId", "cadence", "timezone", "wallClockTime", "expiresAt", "reason"],
                        "additionalProperties": false,
                        "properties": {
                            "scheduleId": {"type": "string"},
                            "cadence": {"type": "string", "enum": ["daily", "weekly"]},
                            "timezone": {"type": "string"},
                            "wallClockTime": {"type": "string"},
                            "dayOfWeek": {"type": "string"},
                            "expiresAt": {"type": "string"},
                            "reason": {"type": "string"}
                        }
                    },
                    "payloadTemplate": {
                        "scheduleId": "${input.scheduleId}",
                        "scope": "system",
                        "selectors": [manifest.get("packageId").cloned().unwrap_or_else(|| json!(resource_id))],
                        "cadence": "${input.cadence}",
                        "timezone": "${input.timezone}",
                        "wallClockTime": "${input.wallClockTime}",
                        "dayOfWeek": "${input.dayOfWeek}",
                        "expiresAt": "${input.expiresAt}",
                        "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&schedule_audit.risk_level),
                    "approvalPolicy": {"required": schedule_audit.required_authority.approval_required},
                    "targetRevision": schedule_audit.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if let Some(run_conformance) = functions
                .iter()
                .find(|function| function.id.as_str() == "module::run_conformance")
            {
                actions.push(json!({
                    "actionId": "run-package-conformance",
                    "label": "Run Conformance",
                    "targetFunctionId": "module::run_conformance",
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": {
                        "targetType": "worker_package",
                        "resourceId": resource_id,
                        "resourceVersionId": version_id,
                        "expectedCurrentVersionId": version_id,
                        "mode": "static"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&run_conformance.risk_level),
                    "approvalPolicy": {"required": run_conformance.required_authority.approval_required},
                    "targetRevision": run_conformance.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
            if manifest
                .get("sourceProvenance")
                .and_then(|source| source.get("kind"))
                .and_then(Value::as_str)
                == Some("local_digest_pinned")
                && manifest.get("sourceTrustStatus").and_then(Value::as_str) == Some("verified")
                && let Some(approve_source) = functions
                    .iter()
                    .find(|function| function.id.as_str() == "module::approve_source")
            {
                actions.push(json!({
                    "actionId": "approve-package-source",
                    "label": "Approve Source",
                    "targetFunctionId": "module::approve_source",
                    "inputSchema": {
                        "type": "object",
                        "required": ["reason", "expiresAt"],
                        "additionalProperties": false,
                        "properties": {
                            "reason": {"type": "string"},
                            "expiresAt": {"type": "string"}
                        }
                    },
                    "payloadTemplate": {
                        "packageResourceId": resource_id,
                        "packageVersionId": version_id,
                        "packageDigest": manifest.get("packageDigest").cloned().unwrap_or(Value::Null),
                        "packageId": manifest.get("packageId").cloned().unwrap_or(Value::Null),
                        "scope": "system",
                        "trustTierCeiling": "local_digest_pinned",
                        "grantCeiling": manifest.get("requiredGrants").cloned().unwrap_or_else(|| json!({})),
                        "expiresAt": "${input.expiresAt}",
                        "reason": "${input.reason}"
                    },
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&approve_source.risk_level),
                    "approvalPolicy": {"required": approve_source.required_authority.approval_required},
                    "targetRevision": approve_source.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    if request.target_type == "decision" {
        let resource_id = request.target_id.clone();
        let inspection =
            host.inspect_resource(&resource_id)?
                .ok_or_else(|| EngineError::NotFound {
                    kind: "resource",
                    id: resource_id.clone(),
                })?;
        let version_id = inspection
            .resource
            .current_version_id
            .clone()
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: resource_id.clone(),
            })?;
        let decision_payload = current_payload(&inspection).unwrap_or_else(|| json!({}));
        let decision_metadata = decision_payload.get("metadata").and_then(Value::as_object);
        let is_trust_root = decision_metadata
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            == Some("module_trust_root");
        let is_trust_audit_schedule = decision_metadata
            .and_then(|metadata| metadata.get("decisionType"))
            .and_then(Value::as_str)
            == Some("module_trust_audit_schedule");
        for (action_id, label, target_function, input_schema, payload) in [
            (
                "inspect-trust-decision",
                "Inspect Trust",
                "module::inspect_trust",
                json!({"type": "object", "additionalProperties": false, "properties": {}}),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "includeEvidence": true,
                    "limit": 50
                }),
            ),
            (
                "simulate-trust-decision",
                "Simulate",
                "module::simulate_trust_change",
                trust_review_operation_input_schema(false),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "operation": "${input.operation}",
                    "includeGeneratedUi": true,
                    "limit": 50
                }),
            ),
            (
                "record-trust-review",
                "Record Review",
                "module::record_trust_review",
                trust_review_operation_input_schema(true),
                json!({
                    "targetType": "decision",
                    "targetResourceId": resource_id,
                    "targetVersionId": version_id,
                    "operation": "${input.operation}",
                    "operatorNotes": "${input.operatorNotes}",
                    "limit": 50
                }),
            ),
            (
                "trust-audit-status",
                "Audit Status",
                "module::trust_audit_status",
                json!({"type": "object", "additionalProperties": false, "properties": {}}),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "includeEvidence": true,
                    "includeQueue": true,
                    "limit": 50
                }),
            ),
            (
                "renew-trust-root",
                "Renew",
                "module::renew_trust_root",
                json!({
                    "type": "object",
                    "required": ["expiresAt", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "expiresAt": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "trustRootDecisionResourceId": resource_id,
                    "trustRootDecisionVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "expiresAt": "${input.expiresAt}",
                    "allowedPackageSelectors": decision_metadata
                        .and_then(|metadata| metadata.get("allowedPackageSelectors"))
                        .cloned()
                        .unwrap_or_else(|| json!([])),
                    "grantCeiling": decision_metadata
                        .and_then(|metadata| metadata.get("grantCeiling"))
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    "trustTierCeiling": "signed_local",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "rotate-signature-key",
                "Rotate",
                "module::rotate_signature_key",
                json!({
                    "type": "object",
                    "required": ["newTrustRootDecisionResourceId", "newTrustRootDecisionVersionId", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "newTrustRootDecisionResourceId": {"type": "string"},
                        "newTrustRootDecisionVersionId": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "oldTrustRootDecisionResourceId": resource_id,
                    "oldTrustRootDecisionVersionId": version_id,
                    "newTrustRootDecisionResourceId": "${input.newTrustRootDecisionResourceId}",
                    "newTrustRootDecisionVersionId": "${input.newTrustRootDecisionVersionId}",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "expire-trust-decision",
                "Expire",
                "module::expire_trust_decision",
                json!({
                    "type": "object",
                    "required": ["reason"],
                    "additionalProperties": false,
                    "properties": {"reason": {"type": "string"}}
                }),
                json!({
                    "decisionResourceId": resource_id,
                    "decisionVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "reason": "${input.reason}"
                }),
            ),
            (
                "enforce-revocation",
                "Enforce",
                "module::enforce_revocation",
                json!({
                    "type": "object",
                    "required": ["mode", "activationResourceIds", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "mode": {"type": "string", "enum": ["disable", "quarantine"]},
                        "activationResourceIds": {"type": "array", "items": {"type": "string"}},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "trustDecisionResourceId": resource_id,
                    "expectedDecisionVersionId": version_id,
                    "mode": "${input.mode}",
                    "activationResourceIds": "${input.activationResourceIds}",
                    "reason": "${input.reason}"
                }),
            ),
            (
                "run-scheduled-trust-audit",
                "Run Audit",
                "module::run_scheduled_trust_audit",
                json!({
                    "type": "object",
                    "required": ["dueBucket"],
                    "additionalProperties": false,
                    "properties": {"dueBucket": {"type": "string"}}
                }),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "dueBucket": "${input.dueBucket}"
                }),
            ),
            (
                "record-trust-audit-retention",
                "Review Retention",
                "module::record_trust_audit_retention",
                json!({
                    "type": "object",
                    "required": ["olderThan", "reason"],
                    "additionalProperties": false,
                    "properties": {
                        "olderThan": {"type": "string"},
                        "reason": {"type": "string"}
                    }
                }),
                json!({
                    "scheduleDecisionResourceId": resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "olderThan": "${input.olderThan}",
                    "reason": "${input.reason}"
                }),
            ),
        ] {
            if matches!(
                target_function,
                "module::renew_trust_root"
                    | "module::rotate_signature_key"
                    | "module::enforce_revocation"
            ) && !is_trust_root
            {
                continue;
            }
            if matches!(
                target_function,
                "module::trust_audit_status"
                    | "module::run_scheduled_trust_audit"
                    | "module::record_trust_audit_retention"
            ) && !is_trust_audit_schedule
            {
                continue;
            }
            if let Some(function) = functions
                .iter()
                .find(|function| function.id.as_str() == target_function)
            {
                actions.push(json!({
                    "actionId": action_id,
                    "label": label,
                    "targetFunctionId": target_function,
                    "inputSchema": input_schema,
                    "payloadTemplate": payload,
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&function.risk_level),
                    "approvalPolicy": {"required": function.required_authority.approval_required},
                    "targetRevision": function.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    if request.target_type == "activation" {
        let resource_id = if request.target_id.starts_with("activation:") {
            request.target_id.clone()
        } else {
            format!("activation:{}", request.target_id)
        };
        let version_id = host
            .inspect_resource(&resource_id)?
            .and_then(|inspection| inspection.resource.current_version_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource_version",
                id: resource_id.clone(),
            })?;
        for (action_id, label, target_function, payload) in [
            (
                "check-activation-health",
                "Check Health",
                "module::check_health",
                json!({
                    "activationResourceId": resource_id,
                    "activationVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "mode": "on_demand"
                }),
            ),
            (
                "verify-activation-integrity",
                "Verify Integrity",
                "module::verify_integrity",
                json!({
                    "targetType": "activation_record",
                    "resourceId": resource_id,
                    "resourceVersionId": version_id,
                    "expectedCurrentVersionId": version_id
                }),
            ),
            (
                "recover-activation",
                "Recover",
                "module::recover_activation",
                json!({
                    "activationResourceId": resource_id,
                    "expectedCurrentVersionId": version_id,
                    "reason": "operator requested recovery from generated surface"
                }),
            ),
        ] {
            if let Some(target) = functions
                .iter()
                .find(|function| function.id.as_str() == target_function)
            {
                actions.push(json!({
                    "actionId": action_id,
                    "label": label,
                    "targetFunctionId": target_function,
                    "inputSchema": {"type": "object", "additionalProperties": false, "properties": {}},
                    "payloadTemplate": payload,
                    "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                    "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
                    "requiredRisk": risk_label(&target.risk_level),
                    "approvalPolicy": {"required": target.required_authority.approval_required},
                    "targetRevision": target.revision.0,
                    "expiresAt": default_expires_at()
                }));
            }
        }
    }
    Ok(actions
        .into_iter()
        .map(with_stored_action_consequence)
        .collect())
}

fn resource_collection_actions(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    match (request.target_id.as_str(), request.layout_profile.as_str()) {
        (PROMPT_SNIPPET_COLLECTION_TARGET, PROMPT_SNIPPET_LAYOUT_PROFILE) => {
            prompt_snippet_collection_actions(host, invocation, functions)
        }
        (PROMPT_HISTORY_COLLECTION_TARGET, PROMPT_HISTORY_LAYOUT_PROFILE) => {
            prompt_history_collection_actions(host, invocation, functions)
        }
        (NOTIFICATION_COLLECTION_TARGET, NOTIFICATION_INBOX_LAYOUT_PROFILE) => {
            notification_collection_actions(host, invocation, functions)
        }
        (SUBAGENT_COLLECTION_TARGET, SUBAGENT_LINEAGE_LAYOUT_PROFILE) => {
            subagent_collection_actions(host, invocation, request, functions)
        }
        _ => Ok(Vec::new()),
    }
}

pub(super) fn push_optional_action(
    actions: &mut Vec<Value>,
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
    action_id: &str,
    label: &str,
    target_function: &str,
    input_schema: Value,
    payload_template: Value,
) -> Result<()> {
    if functions
        .iter()
        .any(|function| function.id.as_str() == target_function)
    {
        actions.push(prompt_collection_action(
            invocation,
            functions,
            action_id,
            label,
            target_function,
            input_schema,
            payload_template,
        )?);
    }
    Ok(())
}

pub(super) fn prompt_collection_action(
    invocation: &crate::engine::Invocation,
    functions: &[FunctionDefinition],
    action_id: &str,
    label: &str,
    target_function: &str,
    input_schema: Value,
    payload_template: Value,
) -> Result<Value> {
    let target = functions
        .iter()
        .find(|function| function.id.as_str() == target_function)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: target_function.to_owned(),
        })?;
    Ok(json!({
        "actionId": action_id,
        "label": label,
        "targetFunctionId": target_function,
        "inputSchema": input_schema,
        "payloadTemplate": payload_template,
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&target.risk_level),
        "approvalPolicy": {"required": target.required_authority.approval_required},
        "targetRevision": target.revision.0,
        "expiresAt": default_expires_at()
    }))
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
