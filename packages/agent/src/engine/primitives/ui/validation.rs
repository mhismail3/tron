//! Stored generated-UI validation and action-submission checks.
//!
//! This module owns the boundary between durable `ui_surface` resources and
//! executable canonical capability invocations. The parent UI primitive remains
//! responsible for registration, dispatch, and surface authoring.

use super::*;

pub(super) fn validate_surface(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let surface_resource_id = required_str(&invocation.payload, "surfaceResourceId")?;
    let inspection = host.inspect_resource(surface_resource_id)?;
    let validation = surface_validation_state(host, invocation, &inspection);
    Ok(json!({
        "surfaceResourceId": surface_resource_id,
        "validationState": validation.state,
        "diagnostics": validation.diagnostics,
    }))
}

/// Validate one stored UI action and create the target invocation.
pub(in crate::engine) fn action_child_invocation(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<crate::engine::Invocation> {
    let surface_resource_id = required_str(&invocation.payload, "surfaceResourceId")?;
    let surface_version_id = required_str(&invocation.payload, "surfaceVersionId")?;
    let action_id = required_str(&invocation.payload, "actionId")?;
    let idempotency_key = required_str(&invocation.payload, "idempotencyKey")?;
    if idempotency_key.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "ui action submission requires idempotencyKey".to_owned(),
        ));
    }
    let inspection =
        host.inspect_resource(surface_resource_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: surface_resource_id.to_owned(),
            })?;
    ensure_ui_surface(&inspection)?;
    ensure_surface_active(&inspection)?;
    let current_version_id = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "ui_surface {surface_resource_id} has no current version"
            ))
        })?;
    if current_version_id != surface_version_id {
        return Err(EngineError::PolicyViolation(format!(
            "stale ui_surface version: expected {surface_version_id}, current {current_version_id}"
        )));
    }
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == surface_version_id)
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource_version",
            id: surface_version_id.to_owned(),
        })?;
    if version.state != EngineResourceVersionState::Available {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface version {surface_version_id} is not available"
        )));
    }
    let surface = &version.payload;
    ensure_not_expired(
        surface.get("expiresAt").and_then(Value::as_str),
        "ui_surface",
    )?;
    let action = surface_action(surface, action_id)?;
    ensure_not_expired(action.get("expiresAt").and_then(Value::as_str), "ui action")?;
    let target = validate_action_target(host, invocation, action)?;
    validate_required_grant(action, invocation)?;
    let input = invocation
        .payload
        .get("userInput")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let input_schema = action
        .get("inputSchema")
        .ok_or_else(|| EngineError::PolicyViolation("ui action requires inputSchema".to_owned()))?;
    schema::validate_payload(&target.id, "ui_action_input", input_schema, &input)?;
    let target_payload = render_payload_template(
        action.get("payloadTemplate").ok_or_else(|| {
            EngineError::PolicyViolation("ui action requires payloadTemplate".to_owned())
        })?,
        &input,
        surface_resource_id,
        surface_version_id,
        action_id,
        idempotency_key,
    )?;
    let child_context = invocation
        .causal_context
        .clone()
        .with_parent_invocation(invocation.id.clone())
        .with_idempotency_key(idempotency_key.to_owned())
        .with_runtime_metadata("ui.surfaceResourceId", surface_resource_id.to_owned())
        .with_runtime_metadata("ui.surfaceVersionId", surface_version_id.to_owned())
        .with_runtime_metadata("ui.actionId", action_id.to_owned());
    let mut child =
        crate::engine::Invocation::new_sync(target.id.clone(), target_payload, child_context);
    child.expected_function_revision = Some(target.revision);
    Ok(child)
}

pub(super) fn validate_surface_targets(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    surface: &Value,
) -> Result<()> {
    let actions = surface
        .get("actions")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            EngineError::PolicyViolation("ui_surface actions must be an array".to_owned())
        })?;
    for action in actions {
        let _ = validate_action_target(host, invocation, action)?;
    }
    Ok(())
}

fn validate_action_target(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    action: &Value,
) -> Result<FunctionDefinition> {
    let target_id = action
        .get("targetFunctionId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation("ui action requires targetFunctionId".to_owned())
        })?;
    if target_id == SUBMIT_ACTION_FUNCTION {
        return Err(EngineError::PolicyViolation(
            "ui actions cannot target ui::submit_action".to_owned(),
        ));
    }
    let target_id = FunctionId::new(target_id.to_owned())?;
    let target = host
        .discover_functions(&FunctionQuery {
            actor: Some(actor_context(invocation)),
            include_internal: true,
            ..FunctionQuery::default()
        })
        .into_iter()
        .find(|function| function.id == target_id)
        .ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: target_id.to_string(),
        })?;
    let expected_revision = action
        .get("targetRevision")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            EngineError::PolicyViolation("ui action requires targetRevision".to_owned())
        })?;
    if target.revision.0 != expected_revision {
        return Err(EngineError::StaleFunctionRevision {
            function_id: target.id.to_string(),
            expected: expected_revision,
            actual: target.revision.0,
        });
    }
    if target.effect_class.requires_idempotency() && target.idempotency.is_none() {
        return Err(EngineError::PolicyViolation(format!(
            "ui action target {} is mutating without idempotency",
            target.id
        )));
    }
    let declared_risk = action
        .get("requiredRisk")
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::PolicyViolation("ui action requires requiredRisk".to_owned()))
        .and_then(parse_risk)?;
    if target.risk_level > declared_risk {
        return Err(EngineError::PolicyViolation(format!(
            "ui action declared risk {:?} below target {} risk {:?}",
            declared_risk, target.id, target.risk_level
        )));
    }
    validate_action_payload_template_against_target_schema(action, &target)?;
    Ok(target)
}

fn validate_action_payload_template_against_target_schema(
    action: &Value,
    target: &FunctionDefinition,
) -> Result<()> {
    let Some(schema) = &target.request_schema else {
        return Ok(());
    };
    let template = action.get("payloadTemplate").ok_or_else(|| {
        EngineError::PolicyViolation("ui action requires payloadTemplate".to_owned())
    })?;
    validate_template_node(&target.id, schema, template, "$")
}

fn validate_template_node(
    target_id: &FunctionId,
    schema: &Value,
    template: &Value,
    path: &str,
) -> Result<()> {
    let schema_object = schema
        .as_object()
        .ok_or_else(|| EngineError::InvalidSchema {
            function_id: target_id.to_string(),
            direction: "ui_action_target_request",
            message: format!("{path} must be an object"),
        })?;
    if template
        .as_str()
        .is_some_and(|text| text.starts_with("${") && text.ends_with('}'))
    {
        return Ok(());
    }
    if schema_object
        .get("type")
        .is_some_and(|schema_type| schema_type == "object")
    {
        let template_object = template.as_object().ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "ui action payloadTemplate {path} must be an object for target {target_id}"
            ))
        })?;
        let properties = schema_object
            .get("properties")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        if schema_object
            .get("additionalProperties")
            .and_then(Value::as_bool)
            == Some(false)
        {
            for key in template_object.keys() {
                if !properties.contains_key(key) {
                    return Err(EngineError::PolicyViolation(format!(
                        "ui action payloadTemplate {path}.{key} is not accepted by target {target_id}"
                    )));
                }
            }
        }
        if let Some(required) = schema_object.get("required").and_then(Value::as_array) {
            for field in required {
                let field = field.as_str().ok_or_else(|| EngineError::InvalidSchema {
                    function_id: target_id.to_string(),
                    direction: "ui_action_target_request",
                    message: format!("{path}.required entries must be strings"),
                })?;
                if !template_object.contains_key(field) {
                    return Err(EngineError::PolicyViolation(format!(
                        "ui action payloadTemplate missing required target field {field}"
                    )));
                }
            }
        }
        for (key, child_schema) in properties {
            if let Some(child_template) = template_object.get(&key) {
                validate_template_node(
                    target_id,
                    &child_schema,
                    child_template,
                    &format!("{path}.{key}"),
                )?;
            }
        }
        return Ok(());
    }
    if !template_contains_placeholder(template) {
        schema::validate_payload(target_id, "ui_action_target_request", schema, template)?;
    }
    Ok(())
}

fn template_contains_placeholder(value: &Value) -> bool {
    match value {
        Value::String(text) => text.starts_with("${") && text.ends_with('}'),
        Value::Array(items) => items.iter().any(template_contains_placeholder),
        Value::Object(object) => object.values().any(template_contains_placeholder),
        _ => false,
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported ui action risk {value}"
        ))),
    }
}

fn validate_required_grant(action: &Value, invocation: &crate::engine::Invocation) -> Result<()> {
    let required = action
        .get("requiredGrant")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if required == invocation.causal_context.authority_grant_id.as_str() {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "ui action requires grant {required}"
        )))
    }
}

fn render_payload_template(
    template: &Value,
    input: &Value,
    surface_resource_id: &str,
    surface_version_id: &str,
    action_id: &str,
    idempotency_key: &str,
) -> Result<Value> {
    match template {
        Value::String(text) => match text.as_str() {
            "${surface.resourceId}" => Ok(json!(surface_resource_id)),
            "${surface.versionId}" => Ok(json!(surface_version_id)),
            "${action.id}" => Ok(json!(action_id)),
            "${submission.idempotencyKey}" => Ok(json!(idempotency_key)),
            value if value.starts_with("${input.") && value.ends_with('}') => {
                let path = &value["${input.".len()..value.len() - 1];
                input.get(path).cloned().ok_or_else(|| {
                    EngineError::PolicyViolation(format!(
                        "ui action input template references missing field {path}"
                    ))
                })
            }
            value if value.starts_with("${") && value.ends_with('}') => {
                Err(EngineError::PolicyViolation(format!(
                    "unsupported ui action payloadTemplate placeholder {value}"
                )))
            }
            _ => Ok(template.clone()),
        },
        Value::Array(items) => items
            .iter()
            .map(|item| {
                render_payload_template(
                    item,
                    input,
                    surface_resource_id,
                    surface_version_id,
                    action_id,
                    idempotency_key,
                )
            })
            .collect::<Result<Vec<_>>>()
            .map(Value::Array),
        Value::Object(object) => {
            let mut rendered = serde_json::Map::new();
            for (key, value) in object {
                rendered.insert(
                    key.clone(),
                    render_payload_template(
                        value,
                        input,
                        surface_resource_id,
                        surface_version_id,
                        action_id,
                        idempotency_key,
                    )?,
                );
            }
            Ok(Value::Object(rendered))
        }
        _ => Ok(template.clone()),
    }
}

pub(super) struct SurfaceValidation {
    pub(super) state: &'static str,
    diagnostics: Vec<Value>,
}

pub(super) fn surface_validation_state(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    inspection: &Option<EngineResourceInspection>,
) -> SurfaceValidation {
    let Some(inspection) = inspection else {
        return SurfaceValidation {
            state: "invalid",
            diagnostics: vec![
                json!({"code": "missing_surface", "message": "ui_surface resource does not exist"}),
            ],
        };
    };
    if let Err(error) = ensure_ui_surface(inspection) {
        return validation_error("invalid", "wrong_kind", error);
    }
    match inspection.resource.lifecycle.as_str() {
        "expired" => {
            return SurfaceValidation {
                state: "expired",
                diagnostics: vec![
                    json!({"code": "expired_lifecycle", "message": "ui_surface lifecycle is expired"}),
                ],
            };
        }
        "damaged" | "discarded" => {
            return SurfaceValidation {
                state: "damaged",
                diagnostics: vec![
                    json!({"code": "unavailable_lifecycle", "message": format!("ui_surface lifecycle is {}", inspection.resource.lifecycle)}),
                ],
            };
        }
        _ => {}
    }
    let Some(current_version_id) = inspection.resource.current_version_id.as_deref() else {
        return SurfaceValidation {
            state: "invalid",
            diagnostics: vec![
                json!({"code": "missing_current_version", "message": "ui_surface has no current version"}),
            ],
        };
    };
    let Some(version) = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current_version_id)
    else {
        return SurfaceValidation {
            state: "damaged",
            diagnostics: vec![
                json!({"code": "missing_current_version_record", "message": "current ui_surface version is missing"}),
            ],
        };
    };
    if version.state != EngineResourceVersionState::Available {
        return SurfaceValidation {
            state: "damaged",
            diagnostics: vec![
                json!({"code": "unavailable_version", "message": format!("current ui_surface version is {:?}", version.state)}),
            ],
        };
    }
    let payload = &version.payload;
    if let Err(error) = validate_ui_surface_payload(payload) {
        return validation_error("invalid", "invalid_payload", error);
    }
    if DateTime::parse_from_rfc3339(
        payload
            .get("expiresAt")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )
    .map(|expires_at| expires_at.with_timezone(&Utc) <= Utc::now())
    .unwrap_or(true)
    {
        return SurfaceValidation {
            state: "expired",
            diagnostics: vec![
                json!({"code": "expired_surface", "message": "ui_surface expiresAt is expired or invalid"}),
            ],
        };
    }
    if let Some(actions) = payload.get("actions").and_then(Value::as_array) {
        for action in actions {
            if DateTime::parse_from_rfc3339(
                action
                    .get("expiresAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
            .map(|expires_at| expires_at.with_timezone(&Utc) <= Utc::now())
            .unwrap_or(true)
            {
                return SurfaceValidation {
                    state: "expired",
                    diagnostics: vec![
                        json!({"code": "expired_action", "message": "ui_surface action is expired or invalid"}),
                    ],
                };
            }
            if action
                .get("requiredGrant")
                .and_then(Value::as_str)
                .is_some_and(|required| {
                    required != invocation.causal_context.authority_grant_id.as_str()
                })
            {
                return SurfaceValidation {
                    state: "unauthorized",
                    diagnostics: vec![
                        json!({"code": "grant_mismatch", "message": "ui_surface action requires a different grant"}),
                    ],
                };
            }
            if let Err(error) = validate_action_target(host, invocation, action) {
                return match error {
                    EngineError::StaleFunctionRevision { .. } => {
                        validation_error("stale", "stale_action_target", error)
                    }
                    EngineError::NotFound { .. } => {
                        validation_error("invalid", "missing_action_target", error)
                    }
                    other => validation_error("invalid", "invalid_action_target", other),
                };
            }
        }
    }
    if let Some(authoring) = payload.get("authoring").and_then(Value::as_object)
        && authoring.get("mode").and_then(Value::as_str) == Some(GENERATED_AUTHORING_MODE)
    {
        match SurfaceAuthoringRequest::from_authoring_payload(payload).and_then(|request| {
            target_projection(host, invocation, &request).map(|target| (request, target))
        }) {
            Ok((_, target)) => {
                if authoring
                    .get("targetRevision")
                    .and_then(Value::as_u64)
                    .is_some_and(|revision| revision != target.revision)
                {
                    return SurfaceValidation {
                        state: "stale",
                        diagnostics: vec![
                            json!({"code": "stale_target_revision", "message": "generated ui_surface target revision drifted"}),
                        ],
                    };
                }
            }
            Err(error) => return validation_error("invalid", "invalid_authoring_target", error),
        }
    }
    if let Some(bindings) = payload.get("bindings").and_then(Value::as_array) {
        for binding in bindings {
            if let Err(error) = validate_binding_target(host, invocation, binding) {
                return validation_error("invalid", "dangling_binding", error);
            }
        }
    }
    SurfaceValidation {
        state: "valid",
        diagnostics: Vec::new(),
    }
}

fn validation_error(
    state: &'static str,
    code: &'static str,
    error: EngineError,
) -> SurfaceValidation {
    SurfaceValidation {
        state,
        diagnostics: vec![json!({"code": code, "message": error.to_string()})],
    }
}

fn validate_binding_target(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    binding: &Value,
) -> Result<()> {
    let Some(target_type) = binding.get("targetType").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(target_id) = binding.get("targetId").and_then(Value::as_str) else {
        return Ok(());
    };
    let request = SurfaceAuthoringRequest {
        target_type: target_type.to_owned(),
        target_id: target_id.to_owned(),
        purpose: "validate binding".to_owned(),
        layout_profile: "compact".to_owned(),
        expected_target_revision: None,
        existing_surface_resource_id: None,
        expected_current_version_id: None,
        resource_id: None,
        max_preview_bytes: 256,
        expires_at: default_expires_at(),
        refresh_policy: json!({"mode": "manual"}),
        links: Vec::new(),
    };
    target_projection(host, invocation, &request).map(|_| ())
}

pub(super) fn current_version_hash(inspection: &EngineResourceInspection) -> Option<String> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| version.content_hash.clone())
}
