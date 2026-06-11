//! Resource primitive execute operations.

use serde_json::{Map, Value, json};

use super::{
    Deps, compact_json, internal, invalid, ok_result, optional_str, optional_u64, required_str,
};
use crate::engine::{CausalContext, FunctionId, Invocation};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

const EXECUTE_RESOURCE_KINDS: &[&str] = &[
    "agent_memory",
    "agent_result",
    "agent_rule",
    "artifact",
    "capability_definition",
    "claim",
    "decision",
    "evidence",
    "execution_output",
    "goal",
    "materialized_file",
    "patch_proposal",
    "ui_surface",
];

pub(super) async fn resource_create(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let mut payload = scoped_resource_payload(invocation)?;
    insert_optional_string(&mut payload, &invocation.payload, "resourceId")?;
    insert_optional_string(&mut payload, &invocation.payload, "schemaId")?;
    insert_optional_string(&mut payload, &invocation.payload, "lifecycle")?;
    insert_optional_value(&mut payload, &invocation.payload, "policy")?;
    insert_optional_value(&mut payload, &invocation.payload, "locations")?;
    let kind = required_allowed_kind(&invocation.payload, "kind")?;
    payload.insert("kind".to_owned(), json!(kind));
    payload.insert(
        "payload".to_owned(),
        invocation
            .payload
            .get("resourcePayload")
            .cloned()
            .ok_or_else(|| invalid("resource_create requires resourcePayload"))?,
    );
    let value = invoke_engine_value(
        deps,
        "resource::create",
        Value::Object(payload),
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("Resource created: {}", compact_json(&value["resource"])),
        json!({
            "primitiveOperation": "resource_create",
            "status": "ok",
            "resource": value
        }),
    ))
}

pub(super) async fn resource_update(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let resource_id = required_str(&invocation.payload, "resourceId")?;
    ensure_resource_accessible(deps, &invocation.causal_context, resource_id).await?;
    let mut payload = Map::new();
    payload.insert("resourceId".to_owned(), json!(resource_id));
    insert_optional_string(
        &mut payload,
        &invocation.payload,
        "expectedCurrentVersionId",
    )?;
    insert_optional_string(&mut payload, &invocation.payload, "lifecycle")?;
    insert_optional_value(&mut payload, &invocation.payload, "locations")?;
    payload.insert(
        "payload".to_owned(),
        invocation
            .payload
            .get("resourcePayload")
            .cloned()
            .ok_or_else(|| invalid("resource_update requires resourcePayload"))?,
    );
    let value = invoke_engine_value(
        deps,
        "resource::update",
        Value::Object(payload),
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("Resource updated: {}", compact_json(&value["version"])),
        json!({
            "primitiveOperation": "resource_update",
            "status": "ok",
            "resource": value
        }),
    ))
}

pub(super) async fn resource_link(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let mut payload = Map::new();
    for field in ["sourceResourceId", "targetResourceId", "relation"] {
        payload.insert(
            field.to_owned(),
            json!(required_str(&invocation.payload, field)?),
        );
    }
    ensure_resource_accessible(
        deps,
        &invocation.causal_context,
        required_str(&invocation.payload, "sourceResourceId")?,
    )
    .await?;
    ensure_resource_accessible(
        deps,
        &invocation.causal_context,
        required_str(&invocation.payload, "targetResourceId")?,
    )
    .await?;
    insert_optional_value(&mut payload, &invocation.payload, "metadata")?;
    let value = invoke_engine_value(
        deps,
        "resource::link",
        Value::Object(payload),
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("Resource linked: {}", compact_json(&value["link"])),
        json!({
            "primitiveOperation": "resource_link",
            "status": "ok",
            "resource": value
        }),
    ))
}

pub(super) async fn resource_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = inspect_resource_value(
        deps,
        &invocation.causal_context,
        required_str(&invocation.payload, "resourceId")?,
    )
    .await?;
    if !value["inspection"].is_null() {
        ensure_inspection_allowed(&value["inspection"], &invocation.causal_context)?;
    }
    Ok(ok_result(
        format!(
            "Resource inspection: {}",
            compact_json(&value["inspection"])
        ),
        json!({
            "primitiveOperation": "resource_inspect",
            "status": "ok",
            "resource": value
        }),
    ))
}

pub(super) async fn resource_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let mut payload = scoped_resource_payload(invocation)?;
    let kind = required_allowed_kind(&invocation.payload, "kind")?;
    payload.insert("kind".to_owned(), json!(kind));
    insert_optional_string(&mut payload, &invocation.payload, "lifecycle")?;
    if let Some(limit) = optional_u64(&invocation.payload, "limit")? {
        payload.insert("limit".to_owned(), json!(limit.clamp(1, 500)));
    }
    let value = invoke_engine_value(
        deps,
        "resource::list",
        Value::Object(payload),
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("Resources: {}", compact_json(&value["resources"])),
        json!({
            "primitiveOperation": "resource_list",
            "status": "ok",
            "resource": value
        }),
    ))
}

fn scoped_resource_payload(invocation: &Invocation) -> Result<Map<String, Value>, CapabilityError> {
    let mut payload = Map::new();
    match optional_str(&invocation.payload, "scope")?.unwrap_or("session") {
        "session" => {
            let session_id = invocation
                .causal_context
                .session_id
                .as_deref()
                .ok_or_else(|| {
                    invalid("resource operation requires trusted current session context")
                })?;
            payload.insert("scope".to_owned(), json!("session"));
            payload.insert("sessionId".to_owned(), json!(session_id));
        }
        "workspace" => {
            let workspace_id = invocation
                .causal_context
                .workspace_id
                .as_deref()
                .ok_or_else(|| invalid("workspace resource requires trusted workspace context"))?;
            payload.insert("scope".to_owned(), json!("workspace"));
            payload.insert("workspaceId".to_owned(), json!(workspace_id));
        }
        "system" => {
            return Err(invalid(
                "capability::execute cannot read or write system-scoped resources",
            ));
        }
        other => {
            return Err(invalid(format!(
                "unsupported execute resource scope {other}"
            )));
        }
    }
    Ok(payload)
}

async fn ensure_resource_accessible(
    deps: &Deps,
    context: &CausalContext,
    resource_id: &str,
) -> Result<(), CapabilityError> {
    let value = inspect_resource_value(deps, context, resource_id).await?;
    if value["inspection"].is_null() {
        return Err(invalid("resource operation target is not accessible"));
    }
    ensure_inspection_allowed(&value["inspection"], context)
}

async fn inspect_resource_value(
    deps: &Deps,
    context: &CausalContext,
    resource_id: &str,
) -> Result<Value, CapabilityError> {
    invoke_engine_value(
        deps,
        "resource::inspect",
        json!({"resourceId": resource_id}),
        context.clone(),
    )
    .await
}

fn ensure_inspection_allowed(
    inspection: &Value,
    context: &CausalContext,
) -> Result<(), CapabilityError> {
    let kind = inspection
        .pointer("/resource/kind")
        .and_then(Value::as_str)
        .ok_or_else(|| internal("resource inspection omitted kind"))?;
    ensure_allowed_kind(kind)?;
    let scope = inspection
        .pointer("/resource/scope")
        .ok_or_else(|| internal("resource inspection omitted scope"))?;
    match scope {
        Value::Object(object) => {
            if let Some(session_id) = object.get("session").and_then(Value::as_str) {
                if context.session_id.as_deref() == Some(session_id) {
                    return Ok(());
                }
            }
            if let Some(workspace_id) = object.get("workspace").and_then(Value::as_str) {
                if context.workspace_id.as_deref() == Some(workspace_id) {
                    return Ok(());
                }
            }
            Err(invalid("resource operation target is not accessible"))
        }
        Value::String(scope) if scope == "system" => Err(invalid(
            "capability::execute cannot read or write system-scoped resources",
        )),
        _ => Err(internal(
            "resource inspection has unsupported scope encoding",
        )),
    }
}

fn required_allowed_kind<'a>(payload: &'a Value, field: &str) -> Result<&'a str, CapabilityError> {
    let kind = required_str(payload, field)?;
    ensure_allowed_kind(kind)?;
    Ok(kind)
}

fn ensure_allowed_kind(kind: &str) -> Result<(), CapabilityError> {
    if EXECUTE_RESOURCE_KINDS
        .iter()
        .any(|allowed| allowed == &kind)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "capability::execute cannot operate on resource kind {kind}"
        )))
    }
}

fn insert_optional_string(
    target: &mut Map<String, Value>,
    source: &Value,
    field: &str,
) -> Result<(), CapabilityError> {
    if let Some(value) = optional_str(source, field)? {
        target.insert(field.to_owned(), json!(value));
    }
    Ok(())
}

fn insert_optional_value(
    target: &mut Map<String, Value>,
    source: &Value,
    field: &str,
) -> Result<(), CapabilityError> {
    if let Some(value) = source.get(field) {
        target.insert(field.to_owned(), value.clone());
    }
    Ok(())
}

async fn invoke_engine_value(
    deps: &Deps,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> Result<Value, CapabilityError> {
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(|error| internal(error.to_string()))?,
            payload,
            causal_context,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(internal(format!("{function_id} failed: {error}")));
    }
    result
        .value
        .ok_or_else(|| internal(format!("{function_id} returned no value")))
}
