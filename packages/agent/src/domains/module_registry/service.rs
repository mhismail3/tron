use serde_json::{Value, json};

use crate::engine::{
    EngineGrant, EngineHostHandle, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::manifest::{
    INSPECT_ITEMS_DEFAULT, INSPECT_ITEMS_MAX, LIST_LIMIT_DEFAULT, LIST_LIMIT_MAX,
    validate_manifest_payload,
};
use super::projection::{detail_projection, side_effect_proof, summary_projection};
use super::{MODULE_MANIFEST_KIND, MODULE_MANIFEST_SCHEMA_ID, READ_SCOPE, SCHEMA_VERSION};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const READABLE_LIFECYCLES: &[&str] = &["candidate", "validated", "stale"];

pub(crate) async fn list_modules_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(host, invocation, "module_list").await?;
    require_read_kind_selector(&grant, "module_list")?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let lifecycle = optional_string(payload, "lifecycle")?;
    if let Some(lifecycle) = &lifecycle {
        ensure_known_lifecycle(lifecycle, "module_list")?;
    }
    let resources = host
        .list_resources(ListResources {
            kind: Some(MODULE_MANIFEST_KIND.to_owned()),
            scope: Some(EngineResourceScope::System),
            lifecycle,
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut modules = Vec::new();
    for resource in resources {
        if modules.len() >= limit {
            break;
        }
        if !include_archived && resource.lifecycle == "archived" {
            continue;
        }
        let Some(inspection) = host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            return Err(invalid(format!(
                "module_list missing listed module manifest {}",
                resource.resource_id
            )));
        };
        ensure_module_manifest_resource(&inspection, "module_list")?;
        ensure_system_scope(&inspection, "module_list")?;
        if !include_archived {
            ensure_readable_lifecycle(&inspection.resource.lifecycle, "module_list")?;
        }
        let (version, current) = current_payload(&inspection, "module_list")?;
        validate_manifest_payload(current, "module_list")?;
        modules.push(summary_projection(&inspection.resource, version, current));
    }

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "module_list",
        "scope": scope_ref(),
        "modules": modules,
        "limits": {
            "requestedLimit": limit,
            "returned": modules.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": side_effect_proof(),
        "redacted": true
    }))
}

pub(crate) async fn inspect_module_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(host, invocation, "module_inspect").await?;
    require_read_kind_selector(&grant, "module_inspect")?;
    let resource_id = required_string(payload, "moduleManifestResourceId")?;
    if !resource_id.starts_with(&format!("{MODULE_MANIFEST_KIND}:")) {
        return Err(invalid(
            "moduleManifestResourceId has unsupported module manifest resource kind",
        ));
    }
    let max_items = optional_u64(payload, "maxItems")?
        .map(|value| value as usize)
        .unwrap_or(INSPECT_ITEMS_DEFAULT)
        .clamp(1, INSPECT_ITEMS_MAX);
    let inspection = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing module manifest {resource_id}")))?;
    ensure_module_manifest_resource(&inspection, "module_inspect")?;
    ensure_system_scope(&inspection, "module_inspect")?;
    ensure_readable_lifecycle(&inspection.resource.lifecycle, "module_inspect")?;
    let (version, current) = current_payload(&inspection, "module_inspect")?;
    validate_manifest_payload(current, "module_inspect")?;

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "module_inspect",
        "scope": scope_ref(),
        "resource": detail_projection(&inspection.resource, version, current, max_items),
        "limits": {"maxItems": max_items},
        "sideEffects": side_effect_proof(),
        "redacted": true
    }))
}

async fn inspect_read_grant(
    host: &EngineHostHandle,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("{operation} authority grant was not found")))?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, READ_SCOPE, operation)?;
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        RESOURCE_READ_SCOPE,
        operation,
    )?;
    require_explicit_grant_item(
        &grant.allowed_resource_kinds,
        MODULE_MANIFEST_KIND,
        operation,
    )?;
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

fn require_read_kind_selector(grant: &EngineGrant, operation: &str) -> Result<(), CapabilityError> {
    if grant
        .resource_selectors
        .iter()
        .any(|selector| selector == "*")
    {
        return Err(invalid(format!(
            "{operation} requires explicit resource selectors; wildcard grants are not accepted"
        )));
    }
    if grant
        .resource_selectors
        .iter()
        .any(|selector| selector == &format!("kind:{MODULE_MANIFEST_KIND}"))
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires an explicit kind:{MODULE_MANIFEST_KIND} selector"
        )))
    }
}

fn require_explicit_grant_item(
    items: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if items.iter().any(|item| item == "*") {
        return Err(invalid(format!(
            "{operation} requires explicit authority; wildcard grants are not accepted"
        )));
    }
    if items.iter().any(|item| item == required) {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires {required} authority"
        )))
    }
}

fn ensure_module_manifest_resource(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != MODULE_MANIFEST_KIND {
        return Err(invalid(format!(
            "{operation} expected {MODULE_MANIFEST_KIND}"
        )));
    }
    if inspection.resource.schema_id.as_str() != MODULE_MANIFEST_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {MODULE_MANIFEST_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn ensure_system_scope(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.scope == EngineResourceScope::System {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} cannot inspect module manifests outside system scope"
        )))
    }
}

fn ensure_readable_lifecycle(lifecycle: &str, operation: &str) -> Result<(), CapabilityError> {
    if READABLE_LIFECYCLES
        .iter()
        .any(|readable| readable == &lifecycle)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} cannot inspect module manifest lifecycle {lifecycle}"
        )))
    }
}

fn ensure_known_lifecycle(lifecycle: &str, operation: &str) -> Result<(), CapabilityError> {
    if READABLE_LIFECYCLES
        .iter()
        .copied()
        .chain(["archived"])
        .any(|known| known == lifecycle)
    {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} unsupported module manifest lifecycle {lifecycle}"
        )))
    }
}

fn current_payload<'a>(
    inspection: &'a EngineResourceInspection,
    operation: &str,
) -> Result<(&'a EngineResourceVersion, &'a Value), CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid(format!("{operation} resource has no current version")))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid(format!("{operation} current version is missing")))?;
    if !version.state.may_be_current() {
        return Err(invalid(format!(
            "{operation} current version is not available"
        )));
    }
    Ok((version, &version.payload))
}

fn scope_ref() -> Value {
    json!({"kind": "system", "value": "system"})
}

fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?
        .ok_or_else(|| invalid(format!("missing required field {field}")))
}

fn optional_string(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Custom {
        code: "MODULE_REGISTRY_ENGINE_ERROR".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
