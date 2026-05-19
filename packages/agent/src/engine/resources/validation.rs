//! Generic resource request, lifecycle, relation, and payload validation.

use serde_json::Value;

use super::types::{
    CreateResource, EngineResourceLocation, EngineResourceTypeDefinition, LinkResources,
    ListResources, RegisterResourceType, UI_SURFACE_KIND, UpdateResource,
};
use super::ui_surface::validate_ui_surface_payload;
use crate::engine::errors::{EngineError, Result};
use crate::engine::ids::FunctionId;
use crate::engine::schema;

pub(crate) fn validate_type_request(request: &RegisterResourceType) -> Result<()> {
    validate_token("resource kind", &request.kind)?;
    validate_token("schema id", &request.schema_id)?;
    if request.lifecycle_states.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "resource kind {} must declare lifecycle states",
            request.kind
        )));
    }
    for state in &request.lifecycle_states {
        validate_token("lifecycle state", state)?;
    }
    for relation in &request.allowed_link_relations {
        validate_token("link relation", relation)?;
    }
    schema::validate_schema_definition(&resource_function_id(), "resource", &request.schema)?;
    Ok(())
}

pub(crate) fn validate_create_request(request: &CreateResource) -> Result<()> {
    validate_token("resource kind", &request.kind)?;
    if let Some(resource_id) = &request.resource_id {
        validate_token("resource id", resource_id)?;
    }
    if let Some(schema_id) = &request.schema_id {
        validate_token("schema id", schema_id)?;
    }
    if let Some(lifecycle) = &request.lifecycle {
        validate_token("lifecycle state", lifecycle)?;
    }
    validate_locations(&request.locations)
}

pub(crate) fn validate_update_request(request: &UpdateResource) -> Result<()> {
    validate_token("resource id", &request.resource_id)?;
    if let Some(version_id) = &request.expected_current_version_id {
        validate_token("version id", version_id)?;
    }
    if let Some(lifecycle) = &request.lifecycle {
        validate_token("lifecycle state", lifecycle)?;
    }
    validate_locations(&request.locations)
}

pub(crate) fn validate_link_request(request: &LinkResources) -> Result<()> {
    validate_token("source resource id", &request.source_resource_id)?;
    validate_token("target resource id", &request.target_resource_id)?;
    validate_token("link relation", &request.relation)
}

pub(crate) fn validate_list_filter(filter: &ListResources) -> Result<()> {
    if filter.limit == 0 {
        return Err(EngineError::PolicyViolation(
            "resource list limit must be greater than zero".to_owned(),
        ));
    }
    if let Some(kind) = &filter.kind {
        validate_token("resource kind", kind)?;
    }
    if let Some(lifecycle) = &filter.lifecycle {
        validate_token("lifecycle state", lifecycle)?;
    }
    Ok(())
}

fn validate_locations(locations: &[EngineResourceLocation]) -> Result<()> {
    for location in locations {
        validate_token("location kind", &location.kind)?;
        if location.uri.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "resource location uri must not be empty".to_owned(),
            ));
        }
    }
    Ok(())
}

pub(crate) fn validate_token(label: &str, value: &str) -> Result<()> {
    if value.trim().is_empty()
        || value.len() > 256
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | ':' | '.' | '/'))
    {
        return Err(EngineError::PolicyViolation(format!(
            "invalid {label} {value:?}"
        )));
    }
    Ok(())
}

pub(crate) fn ensure_lifecycle(
    definition: &EngineResourceTypeDefinition,
    lifecycle: &str,
) -> Result<()> {
    if definition
        .lifecycle_states
        .iter()
        .any(|state| state == lifecycle)
    {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource kind {} does not allow lifecycle {lifecycle}",
            definition.kind
        )))
    }
}

pub(crate) fn ensure_relation(
    definition: &EngineResourceTypeDefinition,
    relation: &str,
) -> Result<()> {
    if definition
        .allowed_link_relations
        .iter()
        .any(|allowed| allowed == "*" || allowed == relation)
    {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource kind {} does not allow relation {relation}",
            definition.kind
        )))
    }
}

pub(crate) fn validate_resource_payload(
    definition: &EngineResourceTypeDefinition,
    payload: &Value,
) -> Result<()> {
    schema::validate_payload(
        &resource_function_id(),
        "resource_payload",
        &definition.schema,
        payload,
    )?;
    if definition.kind == UI_SURFACE_KIND {
        validate_ui_surface_payload(payload)?;
    }
    Ok(())
}

fn resource_function_id() -> FunctionId {
    FunctionId::new("resource::payload").expect("valid static resource function id")
}
