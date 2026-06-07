//! Generated UI action authoring.

use super::*;

pub(in crate::engine::primitives::ui::authoring) fn generated_actions(
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
        "authorityPolicy": {"requiredScopes": refresh.required_authority.scopes.clone()},
        "targetRevision": refresh.revision.0,
        "expiresAt": default_expires_at()
    })];
    if request.target_type == "capability"
        && let Some(action) = capability_invocation_action(invocation, request, &functions)?
    {
        actions.push(action);
    }
    Ok(actions
        .into_iter()
        .map(with_stored_action_consequence)
        .collect())
}

fn capability_invocation_action(
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Option<Value>> {
    let Some(target) = functions
        .iter()
        .find(|function| function.id.as_str() == request.target_id)
    else {
        return Err(EngineError::NotFound {
            kind: "function",
            id: request.target_id.clone(),
        });
    };
    if target.id.as_str() == SUBMIT_ACTION_FUNCTION {
        return Ok(None);
    }
    let Some((input_schema, payload_template)) = capability_input_schema_and_template(target)
    else {
        return Ok(None);
    };
    Ok(Some(json!({
        "actionId": "invoke-capability",
        "label": "Invoke",
        "targetFunctionId": target.id.as_str(),
        "inputSchema": input_schema,
        "payloadTemplate": payload_template,
        "idempotencyKeyTemplate": "${submission.idempotencyKey}",
        "requiredGrant": invocation.causal_context.authority_grant_id.as_str(),
        "requiredRisk": risk_label(&target.risk_level),
        "authorityPolicy": {"requiredScopes": target.required_authority.scopes.clone()},
        "targetRevision": target.revision.0,
        "expiresAt": default_expires_at()
    })))
}

fn capability_input_schema_and_template(target: &FunctionDefinition) -> Option<(Value, Value)> {
    let Some(schema) = &target.request_schema else {
        return Some((
            json!({"type": "object", "additionalProperties": false, "properties": {}}),
            json!({}),
        ));
    };
    if !schema
        .get("type")
        .is_none_or(|schema_type| schema_type == "object")
    {
        return None;
    }
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|fields| {
            fields
                .iter()
                .map(|field| field.as_str().map(ToOwned::to_owned))
                .collect::<Option<Vec<_>>>()
        })
        .unwrap_or_else(|| Some(Vec::new()))?;
    let mut input_properties = serde_json::Map::new();
    let mut payload_template = serde_json::Map::new();
    for field in &required {
        let property = properties.get(field)?;
        if !capability_schema_field_is_renderable(property) {
            return None;
        }
        input_properties.insert(field.clone(), property.clone());
        payload_template.insert(field.clone(), json!(format!("${{input.{field}}}")));
    }
    Some((
        json!({
            "type": "object",
            "required": required,
            "additionalProperties": false,
            "properties": input_properties
        }),
        Value::Object(payload_template),
    ))
}

fn capability_schema_field_is_renderable(schema: &Value) -> bool {
    let Some(kind) = schema.get("type").and_then(Value::as_str) else {
        return schema.get("enum").and_then(Value::as_array).is_some();
    };
    matches!(kind, "string" | "boolean" | "integer")
}
