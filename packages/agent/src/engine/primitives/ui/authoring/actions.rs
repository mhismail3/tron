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

pub(in crate::engine::primitives::ui::authoring) fn push_optional_action(
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

pub(in crate::engine::primitives::ui::authoring) fn prompt_collection_action(
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
        "authorityPolicy": {"requiredScopes": target.required_authority.scopes.clone()},
        "targetRevision": target.revision.0,
        "expiresAt": default_expires_at()
    }))
}
