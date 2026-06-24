use super::common::{
    create_wrapper_resource, ensure_resource_kind, optional_resource_scope_filter,
    resource_ref_from_resource, resource_ref_from_version,
};
use super::input::{locations, string_array};
use super::*;

pub(super) fn artifact_split_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let source_id = required_string_owned(&invocation.payload, "resourceId")?;
    let source = store
        .inspect(&source_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: source_id.clone(),
        })?;
    ensure_resource_kind(&source, "artifact")?;
    let parts = invocation
        .payload
        .get("parts")
        .and_then(Value::as_array)
        .ok_or_else(|| EngineError::PolicyViolation("artifact::split requires parts".to_owned()))?;
    if parts.is_empty() {
        return Err(EngineError::PolicyViolation(
            "artifact::split requires at least one part".to_owned(),
        ));
    }
    let mut created = Vec::new();
    let mut links = Vec::new();
    let mut refs = Vec::new();
    for part in parts {
        let payload = part.get("payload").cloned().unwrap_or_else(|| part.clone());
        let mut child_invocation = invocation.clone();
        let mut child_payload = merge_payload_base(invocation, payload);
        if let Some(resource_id) = part.get("resourceId")
            && let Some(object) = child_payload.as_object_mut()
        {
            object.insert("resourceId".to_owned(), resource_id.clone());
        }
        child_invocation.payload = child_payload;
        let artifact = create_wrapper_resource(store, &child_invocation, "artifact", None)?;
        let link = store.link(LinkResources {
            source_resource_id: artifact.resource_id.clone(),
            target_resource_id: source_id.clone(),
            relation: "derived_from".to_owned(),
            metadata: json!({"operation": "artifact::split"}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        refs.push(resource_ref_from_resource(&artifact, "split_part"));
        created.push(artifact);
        links.push(link);
    }
    Ok(json!({
        "source": source.resource,
        "parts": created,
        "links": links,
        "resourceRefs": refs,
    }))
}

pub(super) fn artifact_compose_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let input_ids = string_array(&invocation.payload, "inputResourceIds")?;
    if input_ids.is_empty() {
        return Err(EngineError::PolicyViolation(
            "artifact::compose requires inputResourceIds".to_owned(),
        ));
    }
    for resource_id in &input_ids {
        let inspection = store
            .inspect(resource_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: resource_id.clone(),
            })?;
        ensure_resource_kind(&inspection, "artifact")?;
    }
    let artifact = create_wrapper_resource(store, invocation, "artifact", None)?;
    let mut links = Vec::new();
    for resource_id in input_ids {
        links.push(store.link(LinkResources {
            source_resource_id: artifact.resource_id.clone(),
            target_resource_id: resource_id,
            relation: "derived_from".to_owned(),
            metadata: json!({"operation": "artifact::compose"}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?);
    }
    Ok(json!({
        "artifact": artifact,
        "links": links,
        "resourceRefs": [resource_ref_from_resource(&artifact, "composed")],
    }))
}

pub(super) fn artifact_merge_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let target_id = required_string_owned(&invocation.payload, "targetResourceId")?;
    let source_ids = string_array(&invocation.payload, "sourceResourceIds")?;
    let target = store
        .inspect(&target_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: target_id.clone(),
        })?;
    ensure_resource_kind(&target, "artifact")?;
    for resource_id in &source_ids {
        let inspection = store
            .inspect(resource_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: resource_id.clone(),
            })?;
        ensure_resource_kind(&inspection, "artifact")?;
    }
    let version = store.update(UpdateResource {
        resource_id: target_id.clone(),
        expected_current_version_id: optional_string(
            invocation.payload.get("expectedCurrentVersionId"),
        )?,
        lifecycle: optional_string(invocation.payload.get("lifecycle"))?,
        payload: invocation.payload.get("payload").cloned().ok_or_else(|| {
            EngineError::PolicyViolation("artifact::merge requires payload".to_owned())
        })?,
        state: None,
        locations: locations(&invocation.payload)?,
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    let mut links = Vec::new();
    for resource_id in source_ids {
        links.push(store.link(LinkResources {
            source_resource_id: target_id.clone(),
            target_resource_id: resource_id,
            relation: "supersedes".to_owned(),
            metadata: json!({"operation": "artifact::merge"}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?);
    }
    Ok(json!({
        "version": version,
        "links": links,
        "resourceRefs": [resource_ref_from_version(&version, "artifact", "merged")],
    }))
}

pub(super) fn artifact_search_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let query = required_str(&invocation.payload, "query")?.to_lowercase();
    let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(25) as usize;
    let artifacts = store.list(ListResources {
        kind: Some("artifact".to_owned()),
        scope: optional_resource_scope_filter(invocation)?,
        lifecycle: None,
        limit: limit.saturating_mul(4).max(limit).min(500),
    })?;
    let mut matches = Vec::new();
    let mut refs = Vec::new();
    for artifact in artifacts {
        let Some(inspection) = store.inspect(&artifact.resource_id)? else {
            continue;
        };
        let preview = resource_preview(&inspection, 512);
        if preview.to_lowercase().contains(&query)
            || artifact.resource_id.to_lowercase().contains(&query)
        {
            refs.push(resource_ref_from_resource(&artifact, "match"));
            matches.push(json!({
                "resource": artifact,
                "preview": preview,
            }));
        }
        if matches.len() >= limit {
            break;
        }
    }
    Ok(json!({
        "matches": matches,
        "resourceRefs": refs,
    }))
}

pub(super) fn goal_working_set_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let goal_id = required_str(&invocation.payload, "goalResourceId")?;
    let preview_bytes =
        optional_u64(invocation.payload.get("previewBytes"))?.unwrap_or(1024) as usize;
    let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
    let goal = store
        .inspect(goal_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: goal_id.to_owned(),
        })?;
    ensure_resource_kind(&goal, "goal")?;
    let mut resource_ids = std::collections::BTreeSet::new();
    for link in goal.outgoing_links.iter().chain(goal.incoming_links.iter()) {
        resource_ids.insert(link.source_resource_id.clone());
        resource_ids.insert(link.target_resource_id.clone());
    }
    resource_ids.remove(goal_id);
    let mut resources = Vec::new();
    let mut unresolved_claims = Vec::new();
    let mut candidate_outputs = Vec::new();
    let mut promoted_outputs = Vec::new();
    for resource_id in resource_ids.into_iter().take(limit) {
        let Some(inspection) = store.inspect(&resource_id)? else {
            continue;
        };
        let projected = json!({
            "resource": inspection.resource,
            "preview": resource_preview(&inspection, preview_bytes),
            "outgoingLinks": inspection.outgoing_links,
            "incomingLinks": inspection.incoming_links,
        });
        if projected
            .pointer("/resource/kind")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind == "claim")
            && projected
                .pointer("/resource/lifecycle")
                .and_then(Value::as_str)
                .is_some_and(|lifecycle| lifecycle == "draft")
        {
            unresolved_claims.push(projected.clone());
        }
        if linked_by_relation(&goal, &resource_id, "candidate_output") {
            candidate_outputs.push(projected.clone());
        }
        if linked_by_relation(&goal, &resource_id, "promoted_output") {
            promoted_outputs.push(projected.clone());
        }
        resources.push(projected);
    }
    let links = goal
        .outgoing_links
        .iter()
        .chain(goal.incoming_links.iter())
        .cloned()
        .collect::<Vec<_>>();
    Ok(json!({
        "goal": goal.resource,
        "resources": resources,
        "links": links,
        "unresolvedClaims": unresolved_claims,
        "candidateOutputs": candidate_outputs,
        "promotedOutputs": promoted_outputs,
    }))
}

pub(super) fn merge_payload_base(invocation: &Invocation, payload: Value) -> Value {
    let mut object = serde_json::Map::new();
    if let Some(resource_id) = payload.get("resourceId") {
        object.insert("resourceId".to_owned(), resource_id.clone());
    }
    for field in ["scope", "sessionId", "workspaceId", "lifecycle", "policy"] {
        if let Some(value) = invocation.payload.get(field) {
            object.insert(field.to_owned(), value.clone());
        }
    }
    object.insert("payload".to_owned(), payload);
    Value::Object(object)
}

pub(super) fn resource_preview(inspection: &EngineResourceInspection, limit: usize) -> String {
    let payload = inspection
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
        .unwrap_or(Value::Null);
    let text = payload
        .get("summary")
        .or_else(|| payload.get("title"))
        .or_else(|| payload.get("body"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| payload.to_string());
    text.chars().take(limit).collect()
}

pub(super) fn linked_by_relation(
    goal: &EngineResourceInspection,
    resource_id: &str,
    relation: &str,
) -> bool {
    goal.outgoing_links
        .iter()
        .any(|link| link.target_resource_id == resource_id && link.relation == relation)
        || goal
            .incoming_links
            .iter()
            .any(|link| link.source_resource_id == resource_id && link.relation == relation)
}
