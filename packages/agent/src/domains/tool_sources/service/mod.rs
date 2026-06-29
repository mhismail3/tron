use serde_json::{Value, json};

use crate::engine::{
    EngineGrant, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources, TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
    TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID, TOOL_SOURCE_PROPOSAL_KIND,
    TOOL_SOURCE_PROPOSAL_SCHEMA_ID,
};
use crate::shared::server::errors::CapabilityError;

use super::validation::*;
use super::{Deps, READ_SCOPE, SCHEMA_VERSION};

#[cfg(test)]
mod write_fixtures;
#[cfg(test)]
pub(crate) use write_fixtures::{create_conformance_report_value, create_proposal_value};

const RESOURCE_READ_SCOPE: &str = "resource.read";

pub(crate) async fn list_tool_sources_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "tool_source_list").await?;
    require_read_kind_selector(&grant, TOOL_SOURCE_PROPOSAL_KIND, "tool_source_list")?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let scope = resource_scope(invocation);
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(TOOL_SOURCE_PROPOSAL_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: if include_archived {
                None
            } else {
                Some("proposed".to_owned())
            },
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut proposals = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_tool_source_proposal(&inspection, "tool_source_list")?;
        ensure_scope(&inspection, &scope, "tool_source_list")?;
        let (version, payload) = current_payload(&inspection, "tool_source_list")?;
        proposals.push(proposal_summary(&inspection.resource, version, payload));
    }
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "tool_source_list",
        "scope": scope_ref(&scope),
        "proposals": proposals,
        "limits": {"requestedLimit": limit, "returned": proposals.len(), "truncated": truncated, "includeArchived": include_archived},
        "activation": {"performed": false, "catalogRegistration": false, "execution": false},
        "network": {"performed": false, "requiredPolicy": "none"}
    }))
}

pub(crate) async fn inspect_tool_source_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "tool_source_inspect").await?;
    let resource_id = required_string(payload, "toolSourceResourceId")?;
    let resource_kind = if resource_id.starts_with(&format!("{TOOL_SOURCE_PROPOSAL_KIND}:")) {
        TOOL_SOURCE_PROPOSAL_KIND
    } else if resource_id.starts_with(&format!("{TOOL_SOURCE_CONFORMANCE_REPORT_KIND}:")) {
        TOOL_SOURCE_CONFORMANCE_REPORT_KIND
    } else {
        return Err(invalid(
            "toolSourceResourceId has unsupported tool source resource kind",
        ));
    };
    require_read_kind_selector(&grant, resource_kind, "tool_source_inspect")?;
    if resource_kind == TOOL_SOURCE_CONFORMANCE_REPORT_KIND
        && !allows_explicit_selector(
            &grant.resource_selectors,
            TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
        )
    {
        return Err(invalid(
            "tool_source_inspect requires an explicit kind:tool_source_conformance_report selector",
        ));
    }
    let max_schema_bytes = optional_u64(payload, "maxSchemaBytes")?
        .map(|value| value as usize)
        .unwrap_or(INSPECT_SCHEMA_PREVIEW_DEFAULT)
        .clamp(1, INSPECT_SCHEMA_PREVIEW_MAX);
    let scope = resource_scope(invocation);
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing tool source resource {resource_id}")))?;
    ensure_tool_source_resource(&inspection, resource_kind, "tool_source_inspect")?;
    ensure_scope(&inspection, &scope, "tool_source_inspect")?;
    let (version, payload) = current_payload(&inspection, "tool_source_inspect")?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "tool_source_inspect",
        "scope": scope_ref(&scope),
        "resource": inspected_resource(&inspection.resource, version, payload, max_schema_bytes),
        "limits": {"maxSchemaBytes": max_schema_bytes},
        "activation": {"performed": false, "catalogRegistration": false, "execution": false},
        "network": {"performed": false, "requiredPolicy": "none"}
    }))
}

async fn inspect_read_grant(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
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
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

fn require_read_kind_selector(
    grant: &EngineGrant,
    resource_kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    require_explicit_grant_item(&grant.allowed_resource_kinds, resource_kind, operation)?;
    if !allows_explicit_selector(&grant.resource_selectors, resource_kind) {
        return Err(invalid(format!(
            "{operation} requires an explicit kind:{resource_kind} selector"
        )));
    }
    Ok(())
}

fn proposal_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "sourceKind": payload.get("sourceKind").cloned().unwrap_or(Value::Null),
        "sourceIdentity": payload.get("sourceIdentity").cloned().unwrap_or(Value::Null),
        "state": payload.get("state").cloned().unwrap_or(Value::Null),
        "summary": payload.get("summary").cloned().unwrap_or(Value::Null),
        "sandboxPolicy": payload.get("sandboxPolicy").cloned().unwrap_or(Value::Null),
        "declaredToolCount": payload.get("declaredTools").and_then(Value::as_array).map_or(0, Vec::len),
        "declaredSchemaCount": payload.get("declaredSchemas").and_then(Value::as_array).map_or(0, Vec::len),
        "expectedLinkage": payload.get("expectedLinkage").cloned().unwrap_or(Value::Null),
        "traceRefs": payload.get("traceRefs").cloned().unwrap_or_else(|| json!([])),
        "replayRefs": payload.get("replayRefs").cloned().unwrap_or_else(|| json!([])),
        "resourceRefs": [version_ref(resource, version, "proposal")]
    })
}

fn inspected_resource(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    max_schema_bytes: usize,
) -> Value {
    let mut payload = payload.clone();
    if resource.kind == TOOL_SOURCE_PROPOSAL_KIND {
        if let Some(schemas) = payload.get_mut("declaredSchemas") {
            *schemas = bounded_schema_preview(schemas, max_schema_bytes);
        }
    }
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "payload": payload,
        "resourceRefs": [version_ref(resource, version, "inspected")]
    })
}

fn bounded_schema_preview(value: &Value, max_bytes: usize) -> Value {
    let serialized = serde_json::to_string(value).unwrap_or_default();
    let bounded = bounded_utf8(&serialized, max_bytes);
    json!({
        "serializedPreview": bounded.text,
        "bytes": serialized.len(),
        "truncated": bounded.truncated,
        "maxBytes": max_bytes
    })
}

struct BoundedText {
    text: String,
    truncated: bool,
}

fn bounded_utf8(value: &str, max_bytes: usize) -> BoundedText {
    if value.len() <= max_bytes {
        return BoundedText {
            text: value.to_owned(),
            truncated: false,
        };
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    BoundedText {
        text: value[..end].to_owned(),
        truncated: true,
    }
}

fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot inspect a tool source outside the current scope"
        )));
    }
    Ok(())
}

fn ensure_tool_source_proposal(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_tool_source_resource(inspection, TOOL_SOURCE_PROPOSAL_KIND, operation)
}

pub(super) fn ensure_tool_source_resource(
    inspection: &EngineResourceInspection,
    expected_kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    let expected_schema = match expected_kind {
        TOOL_SOURCE_PROPOSAL_KIND => TOOL_SOURCE_PROPOSAL_SCHEMA_ID,
        TOOL_SOURCE_CONFORMANCE_REPORT_KIND => TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID,
        _ => {
            return Err(invalid(format!(
                "{operation} expected supported tool source resource kind"
            )));
        }
    };
    if inspection.resource.kind != expected_kind {
        return Err(invalid(format!("{operation} expected {expected_kind}")));
    }
    if inspection.resource.schema_id.as_str() != expected_schema {
        return Err(invalid(format!(
            "{operation} expected schema {expected_schema}"
        )));
    }
    Ok(())
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
    Ok((version, &version.payload))
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": version.version_id,
        "contentHash": version.content_hash,
        "role": role
    })
}

fn require_explicit_grant_item(
    items: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if items.iter().any(|item| item == "*") {
        return Err(policy(format!(
            "{operation} requires explicit authority; wildcard grants are not accepted"
        )));
    }
    if items.iter().any(|item| item == required) {
        Ok(())
    } else {
        Err(policy(format!("{operation} requires {required} authority")))
    }
}

fn allows_explicit_selector(items: &[String], kind: &str) -> bool {
    items.iter().any(|item| item == &format!("kind:{kind}"))
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Custom {
        code: "TOOL_SOURCE_ENGINE_ERROR".to_owned(),
        message: error.to_string(),
        details: None,
    }
}
