//! Stored runtime-surface validation and generic action submissions.

use super::*;
use crate::engine::kernel::ids::FunctionId;
use crate::engine::kernel::schema;

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

pub(super) fn submit_action(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
) -> Result<Value> {
    let surface_resource_id = required_str(&invocation.payload, "surfaceResourceId")?;
    let surface_version_id = required_str(&invocation.payload, "surfaceVersionId")?;
    let action_id = required_str(&invocation.payload, "actionId")?;
    let idempotency_key = required_str(&invocation.payload, "idempotencyKey")?;
    if idempotency_key.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "ui action submission requires idempotencyKey".to_owned(),
        ));
    }
    let user_input = invocation
        .payload
        .get("userInput")
        .cloned()
        .unwrap_or_else(|| json!({}));
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
    let input_schema = action
        .get("inputSchema")
        .ok_or_else(|| EngineError::PolicyViolation("ui action requires inputSchema".to_owned()))?;
    let function_id = FunctionId::new(SUBMIT_ACTION_FUNCTION.to_owned())?;
    schema::validate_payload(&function_id, "ui_action_input", input_schema, &user_input)?;
    Ok(json!({
        "surfaceResourceId": surface_resource_id,
        "surfaceVersionId": surface_version_id,
        "actionId": action_id,
        "accepted": true,
        "userInput": user_input,
    }))
}

pub(super) struct SurfaceValidation {
    pub(super) state: &'static str,
    diagnostics: Vec<Value>,
}

pub(super) fn surface_validation_state(
    _host: &dyn PrimitiveRuntimeHost,
    _invocation: &crate::engine::Invocation,
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

pub(super) fn current_version_hash(inspection: &EngineResourceInspection) -> Option<String> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .map(|version| version.content_hash.clone())
}
