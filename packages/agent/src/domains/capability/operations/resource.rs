//! Resource primitive execute operations.

use serde_json::{Map, Value, json};

use super::{
    Deps, compact_json, internal, invalid, ok_result, optional_str, optional_u64, required_str,
};
use crate::engine::{CausalContext, FunctionId, Invocation};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

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
    payload.insert(
        "kind".to_owned(),
        json!(required_str(&invocation.payload, "kind")?),
    );
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
    let mut payload = Map::new();
    payload.insert(
        "resourceId".to_owned(),
        json!(required_str(&invocation.payload, "resourceId")?),
    );
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
    let value = invoke_engine_value(
        deps,
        "resource::inspect",
        json!({"resourceId": required_str(&invocation.payload, "resourceId")?}),
        invocation.causal_context.clone(),
    )
    .await?;
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
    insert_optional_string(&mut payload, &invocation.payload, "kind")?;
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
