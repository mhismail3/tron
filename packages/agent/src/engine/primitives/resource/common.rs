use super::input::{locations, resource_scope_from_payload};
use super::*;

pub(super) fn optional_resource_scope_filter(
    invocation: &Invocation,
) -> Result<Option<EngineResourceScope>> {
    if invocation.payload.get("scope").is_none() {
        return Ok(None);
    }
    resource_scope_from_payload(invocation, false).map(Some)
}

pub(super) fn create_wrapper_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: Option<&str>,
) -> Result<EngineResource> {
    let payload = invocation.payload.get("payload").cloned().ok_or_else(|| {
        EngineError::PolicyViolation(format!("{} requires payload", invocation.function_id))
    })?;
    create_typed_resource(store, invocation, kind, lifecycle, Some(payload))
}

pub(super) fn create_typed_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: Option<&str>,
    payload: Option<Value>,
) -> Result<EngineResource> {
    store.create(CreateResource {
        resource_id: optional_string(invocation.payload.get("resourceId"))?,
        kind: kind.to_owned(),
        schema_id: None,
        scope: resource_scope_from_payload(invocation, false)?,
        owner_worker_id: WorkerId::new(RESOURCE_WORKER_ID).unwrap(),
        owner_actor_id: invocation.causal_context.actor_id.clone(),
        lifecycle: lifecycle
            .map(str::to_owned)
            .or(optional_string(invocation.payload.get("lifecycle"))?),
        policy: invocation
            .payload
            .get("policy")
            .cloned()
            .unwrap_or_else(|| json!({})),
        initial_payload: payload,
        locations: locations(&invocation.payload)?,
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })
}

pub(super) fn update_wrapper_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    lifecycle: Option<&str>,
) -> Result<EngineResourceVersion> {
    store.update(UpdateResource {
        resource_id: required_string_owned(&invocation.payload, "resourceId")?,
        expected_current_version_id: optional_string(
            invocation.payload.get("expectedCurrentVersionId"),
        )?,
        lifecycle: lifecycle.map(str::to_owned),
        payload: invocation.payload.get("payload").cloned().ok_or_else(|| {
            EngineError::PolicyViolation(format!("{} requires payload", invocation.function_id))
        })?,
        state: None,
        locations: locations(&invocation.payload)?,
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })
}

pub(super) fn lifecycle_wrapper_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: &str,
) -> Result<EngineResourceVersion> {
    let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
    lifecycle_resource_by_id(store, invocation, &resource_id, kind, lifecycle)
}

pub(super) fn lifecycle_resource_by_id(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    resource_id: &str,
    kind: &str,
    lifecycle: &str,
) -> Result<EngineResourceVersion> {
    let inspection = store
        .inspect(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    ensure_resource_kind(&inspection, kind)?;
    let caller_expected = optional_string(invocation.payload.get("expectedCurrentVersionId"))?;
    if caller_expected.is_some()
        && caller_expected.as_ref() != inspection.resource.current_version_id.as_ref()
    {
        return Err(EngineError::PolicyViolation(format!(
            "resource {resource_id} version conflict: expected {:?}, actual {:?}",
            caller_expected, inspection.resource.current_version_id
        )));
    }
    let payload = current_payload(&inspection)?;
    let expected_current_version_id = caller_expected.or(inspection.resource.current_version_id);
    store.update(UpdateResource {
        resource_id: resource_id.to_owned(),
        expected_current_version_id,
        lifecycle: Some(lifecycle.to_owned()),
        payload,
        state: None,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })
}

pub(super) fn create_and_attach_resource(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    default_relation: &str,
) -> Result<(EngineResource, crate::engine::EngineResourceLink)> {
    let resource = create_wrapper_resource(store, invocation, kind, None)?;
    let target_resource_id = required_string_owned(&invocation.payload, "targetResourceId")?;
    let relation = optional_string(invocation.payload.get("relation"))?
        .unwrap_or_else(|| default_relation.to_owned());
    let link = store.link(LinkResources {
        source_resource_id: resource.resource_id.clone(),
        target_resource_id,
        relation,
        metadata: invocation
            .payload
            .get("metadata")
            .cloned()
            .unwrap_or_else(|| json!({})),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    Ok((resource, link))
}

pub(super) fn ensure_inspected_kind(
    inspection: &Option<EngineResourceInspection>,
    expected: &str,
) -> Result<()> {
    if let Some(inspection) = inspection {
        ensure_resource_kind(inspection, expected)?;
    }
    Ok(())
}

pub(super) fn ensure_resource_kind(
    inspection: &EngineResourceInspection,
    expected: &str,
) -> Result<()> {
    if inspection.resource.kind == expected {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource {} is kind {}, expected {expected}",
            inspection.resource.resource_id, inspection.resource.kind
        )))
    }
}

pub(super) fn current_payload(inspection: &EngineResourceInspection) -> Result<Value> {
    inspection
        .resource
        .current_version_id
        .as_ref()
        .and_then(|current| {
            inspection
                .versions
                .iter()
                .find(|version| &version.version_id == current)
        })
        .map(|version| version.payload.clone())
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} has no current payload",
                inspection.resource.resource_id
            ))
        })
}

pub(super) fn wrapper_create_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    kind: &str,
    lifecycle: Option<&str>,
    role: &str,
) -> Result<Value> {
    let resource = create_wrapper_resource(store, invocation, kind, lifecycle)?;
    Ok(json!({
        "resource": resource,
        "resourceRefs": [resource_ref_from_resource(&resource, role)],
    }))
}

pub(super) fn wrapper_version_response(
    store: &mut super::ResourceStoreBackend,
    version: EngineResourceVersion,
    role: &str,
) -> Result<Value> {
    let kind = resource_kind_for_version(store, &version)?;
    let resource_ref = resource_ref_from_version(&version, &kind, role);
    Ok(json!({
        "version": version,
        "resourceRefs": [resource_ref],
    }))
}

pub(super) fn resource_kind_for_version(
    store: &super::ResourceStoreBackend,
    version: &EngineResourceVersion,
) -> Result<String> {
    store
        .inspect(&version.resource_id)?
        .map(|inspection| inspection.resource.kind)
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: version.resource_id.clone(),
        })
}

pub(super) fn resource_ref_from_resource(resource: &EngineResource, role: &str) -> Value {
    let mut value = json!({
        "resourceId": resource.resource_id.as_str(),
        "kind": resource.kind.as_str(),
        "role": role,
    });
    if let Some(version_id) = &resource.current_version_id {
        value["versionId"] = json!(version_id);
    }
    value
}

pub(super) fn resource_ref_from_version(
    version: &EngineResourceVersion,
    kind: &str,
    role: &str,
) -> Value {
    json!({
        "resourceId": version.resource_id.as_str(),
        "kind": kind,
        "versionId": version.version_id.as_str(),
        "role": role,
        "contentHash": version.content_hash.as_str(),
    })
}
