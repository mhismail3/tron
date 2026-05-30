//! Module resource mutation, lookup, and projection helpers.
//!
//! Package, configuration, activation, decision, and evidence records are all
//! resource-backed. This submodule owns module resource ids, upserts, version
//! guards, payload lookup, resource refs, trust summaries, and relation links so
//! lifecycle and trust operations compose the engine resource substrate through
//! one helper boundary.

use super::*;

pub(super) struct UpsertResource {
    pub(super) resource_id: String,
    pub(super) kind: &'static str,
    pub(super) lifecycle: &'static str,
    pub(super) scope: EngineResourceScope,
    pub(super) payload: Value,
    pub(super) expected_current_version_id: Option<String>,
    pub(super) trace_id: crate::engine::TraceId,
    pub(super) invocation_id: Option<crate::engine::InvocationId>,
    pub(super) actor_id: ActorId,
}

pub(super) fn upsert_resource(
    host: &ModulePrimitiveHandler,
    request: UpsertResource,
) -> Result<(EngineResource, EngineResourceVersion, &'static str)> {
    if let Some(existing) = host.inspect_resource(&request.resource_id)? {
        let version = host.update_resource(UpdateResource {
            resource_id: request.resource_id,
            expected_current_version_id: request
                .expected_current_version_id
                .or(existing.resource.current_version_id.clone()),
            lifecycle: Some(request.lifecycle.to_owned()),
            payload: request.payload,
            state: None,
            locations: Vec::new(),
            trace_id: request.trace_id,
            invocation_id: request.invocation_id,
        })?;
        let resource = host
            .inspect_resource(&version.resource_id)?
            .expect("updated resource must exist")
            .resource;
        Ok((resource, version, "updated"))
    } else {
        let resource = host.create_resource(CreateResource {
            resource_id: Some(request.resource_id),
            kind: request.kind.to_owned(),
            schema_id: None,
            scope: request.scope,
            owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
            owner_actor_id: request.actor_id,
            lifecycle: Some(request.lifecycle.to_owned()),
            policy: json!({"managedBy": "module"}),
            initial_payload: Some(request.payload),
            locations: Vec::new(),
            trace_id: request.trace_id,
            invocation_id: request.invocation_id,
        })?;
        let inspection = host
            .inspect_resource(&resource.resource_id)?
            .expect("created resource must be inspectable");
        let version =
            current_version(&inspection)
                .cloned()
                .ok_or_else(|| EngineError::LedgerFailure {
                    operation: "module.upsert",
                    message: "created resource missing initial version".to_owned(),
                })?;
        Ok((resource, version, "created"))
    }
}

pub(super) fn ensure_expected_current_version(
    inspection: &EngineResourceInspection,
    expected: &str,
) -> Result<()> {
    if inspection.resource.current_version_id.as_deref() == Some(expected) {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "expectedCurrentVersionId {expected} does not match current version {:?}",
            inspection.resource.current_version_id
        )))
    }
}

pub(super) fn ensure_version_is_current(
    inspection: &EngineResourceInspection,
    version_id: &str,
) -> Result<()> {
    if inspection.resource.current_version_id.as_deref() == Some(version_id) {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "versionId {version_id} is not current version {:?}",
            inspection.resource.current_version_id
        )))
    }
}

pub(super) fn resource_scope_and_token(
    invocation: &Invocation,
) -> Result<(EngineResourceScope, String)> {
    match optional_string(invocation.payload.get("scope"))?
        .unwrap_or_else(|| "workspace".to_owned())
        .as_str()
    {
        "system" => Ok((EngineResourceScope::System, "system".to_owned())),
        "workspace" => {
            let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                .or(invocation.causal_context.workspace_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace-scoped module resource requires workspaceId".to_owned(),
                    )
                })?;
            if workspace_id.trim().is_empty() {
                return Err(EngineError::PolicyViolation(
                    "workspaceId must not be empty".to_owned(),
                ));
            }
            Ok((
                EngineResourceScope::Workspace(workspace_id.clone()),
                workspace_id,
            ))
        }
        "session" => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session-scoped module resource requires sessionId".to_owned(),
                    )
                })?;
            if session_id.trim().is_empty() {
                return Err(EngineError::PolicyViolation(
                    "sessionId must not be empty".to_owned(),
                ));
            }
            Ok((EngineResourceScope::Session(session_id.clone()), session_id))
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported module resource scope {other}"
        ))),
    }
}

pub(super) fn next_config_revision(
    host: &ModulePrimitiveHandler,
    resource_id: &str,
) -> Result<u64> {
    Ok(host
        .inspect_resource(resource_id)?
        .and_then(|inspection| current_payload(&inspection))
        .and_then(|payload| payload.get("configRevision").and_then(Value::as_u64))
        .unwrap_or(0)
        .saturating_add(1))
}

pub(super) fn package_resource_id_from_payload(payload: &Value) -> Result<String> {
    if let Some(resource_id) = optional_string(payload.get("packageResourceId"))? {
        return Ok(resource_id);
    }
    let package_id = required_str(payload, "packageId")?;
    Ok(package_resource_id(package_id))
}

pub(super) fn package_resource_id(package_id: &str) -> String {
    format!("worker-package:{package_id}")
}

pub(super) fn config_resource_id(scope: &str, package_id: &str) -> String {
    format!("module-config:{scope}:{package_id}")
}

pub(super) fn activation_resource_id(scope: &str, package_id: &str) -> String {
    format!("activation:{scope}:{package_id}")
}

pub(super) fn require_inspection(
    host: &ModulePrimitiveHandler,
    resource_id: &str,
    expected_kind: &str,
) -> Result<EngineResourceInspection> {
    let inspection = host
        .inspect_resource(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    if inspection.resource.kind != expected_kind {
        return Err(EngineError::PolicyViolation(format!(
            "resource {resource_id} is {}, expected {expected_kind}",
            inspection.resource.kind
        )));
    }
    Ok(inspection)
}

pub(super) fn current_payload(inspection: &EngineResourceInspection) -> Option<Value> {
    current_version(inspection).map(|version| version.payload.clone())
}

pub(super) fn current_payload_from_json_inspection(inspection: &Value) -> Option<&Value> {
    let current = inspection
        .get("resource")?
        .get("currentVersionId")?
        .as_str()?;
    inspection
        .get("versions")?
        .as_array()?
        .iter()
        .find(|version| version.get("versionId").and_then(Value::as_str) == Some(current))?
        .get("payload")
}

pub(super) fn current_version(
    inspection: &EngineResourceInspection,
) -> Option<&EngineResourceVersion> {
    let current = inspection.resource.current_version_id.as_ref()?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
}

pub(super) fn version_payload(
    inspection: &EngineResourceInspection,
    version_id: &str,
) -> Result<Value> {
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == version_id)
        .map(|version| version.payload.clone())
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource_version",
            id: version_id.to_owned(),
        })
}

pub(super) fn resource_ref_from_resource(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role,
        "contentHash": Value::Null,
    })
}

pub(super) fn resource_ref_from_version(
    version: &EngineResourceVersion,
    kind: &str,
    role: &str,
) -> Value {
    json!({
        "resourceId": version.resource_id,
        "kind": kind,
        "versionId": version.version_id,
        "role": role,
        "contentHash": version.content_hash,
    })
}

pub(super) fn filter_resources_by_package(
    host: &ModulePrimitiveHandler,
    resources: Vec<EngineResource>,
    package_id: Option<&str>,
) -> Result<Vec<Value>> {
    let Some(package_id) = package_id else {
        return Ok(Vec::new());
    };
    let mut filtered = Vec::new();
    for resource in resources {
        let Some(inspection) = host.inspect_resource(&resource.resource_id)? else {
            continue;
        };
        let Some(payload) = current_payload(&inspection) else {
            continue;
        };
        if payload.get("packageId").and_then(Value::as_str) == Some(package_id)
            || payload
                .get("packageResourceId")
                .and_then(Value::as_str)
                .is_some_and(|id| id == package_resource_id(package_id))
        {
            filtered.push(json!(inspection));
        }
    }
    Ok(filtered)
}

pub(super) fn trust_decision_metadata<'a>(
    payload: &'a Value,
    expected_type: &str,
) -> Result<&'a serde_json::Map<String, Value>> {
    let metadata = payload
        .get("metadata")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!("{expected_type} decision is missing metadata"))
        })?;
    if metadata.get("decisionType").and_then(Value::as_str) != Some(expected_type) {
        return Err(EngineError::PolicyViolation(format!(
            "expected decisionType {expected_type}"
        )));
    }
    Ok(metadata)
}

pub(super) fn package_trust_summary(inspection: &EngineResourceInspection) -> Result<Value> {
    let payload = current_payload(inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "package {} has no current payload",
            inspection.resource.resource_id
        ))
    })?;
    Ok(json!({
        "packageResourceId": inspection.resource.resource_id,
        "packageVersionId": inspection.resource.current_version_id,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "sourceTrustStatus": payload.get("sourceTrustStatus").cloned().unwrap_or(Value::Null),
        "signatureKeyRef": payload.get("signatureKeyRef").cloned().unwrap_or(Value::Null),
    }))
}

pub(super) fn activation_trust_summary(inspection: &EngineResourceInspection) -> Result<Value> {
    let payload = current_payload(inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "activation {} has no current payload",
            inspection.resource.resource_id
        ))
    })?;
    Ok(json!({
        "activationResourceId": inspection.resource.resource_id,
        "activationVersionId": inspection.resource.current_version_id,
        "lifecycle": inspection.resource.lifecycle,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageResourceId": payload.get("packageResourceId").cloned().unwrap_or(Value::Null),
        "activationStatus": payload.get("activationStatus").cloned().unwrap_or(Value::Null),
        "derivedGrantId": payload.get("derivedGrantId").cloned().unwrap_or(Value::Null),
        "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
    }))
}

pub(super) fn decision_summary(inspection: &EngineResourceInspection) -> Result<Value> {
    let payload = current_payload(inspection).ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "decision {} has no current payload",
            inspection.resource.resource_id
        ))
    })?;
    Ok(json!({
        "resourceId": inspection.resource.resource_id,
        "versionId": inspection.resource.current_version_id,
        "lifecycle": inspection.resource.lifecycle,
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "decisionType": payload
            .get("metadata")
            .and_then(|metadata| metadata.get("decisionType"))
            .cloned()
            .unwrap_or(Value::Null),
    }))
}

pub(super) fn trust_target_status(payload: &Value) -> &'static str {
    match payload.get("status").and_then(Value::as_str) {
        Some("active") | Some("approved") => "active",
        Some("expired") | Some("revoked") => "stale",
        Some("rejected") => "denied",
        _ => "inspectable",
    }
}

pub(super) fn trust_warnings_for_status(status: &str) -> Vec<Value> {
    if matches!(status, "stale" | "denied") {
        vec![json!({
            "code": "trust_not_current",
            "message": "target trust decision is not active"
        })]
    } else {
        Vec::new()
    }
}

pub(super) fn link_if_possible(
    host: &ModulePrimitiveHandler,
    source: &str,
    target: &str,
    relation: &str,
    invocation: &Invocation,
) {
    let _ = host.link_resources(LinkResources {
        source_resource_id: source.to_owned(),
        target_resource_id: target.to_owned(),
        relation: relation.to_owned(),
        metadata: json!({"source": "module"}),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    });
}
