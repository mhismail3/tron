#![allow(dead_code)]

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    ActorKind, CreateResource, EngineGrant, EngineResource, EngineResourceInspection,
    EngineResourceScope, EngineResourceVersion, Invocation, LinkResources, ListResources,
    PublishStreamEvent, TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
    TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID, TOOL_SOURCE_PROPOSAL_KIND,
    TOOL_SOURCE_PROPOSAL_SCHEMA_ID, WorkerId, is_bootstrap_authority_grant_id,
};
use crate::shared::server::errors::CapabilityError;

use super::validation::*;
use super::{Deps, PROPOSE_SCOPE, READ_SCOPE, SCHEMA_VERSION, TOOL_SOURCE_TOPIC, WORKER};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";

/// Create an inert external tool-source proposal as trusted internal evidence.
pub(crate) async fn create_proposal_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_internal_write_authority(
        deps,
        invocation,
        "tool source proposal",
        TOOL_SOURCE_PROPOSAL_KIND,
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let source_kind = required_string(payload, "sourceKind")?;
    validate_source_kind(&source_kind)?;
    let source_identity = required_object(payload, "sourceIdentity")?;
    let provenance = required_object(payload, "provenance")?;
    let sandbox_policy = required_object(payload, "sandboxPolicy")?;
    let declared_tools = optional_array(payload, "declaredTools")?.unwrap_or_default();
    let declared_schemas = optional_array(payload, "declaredSchemas")?.unwrap_or_default();
    let expected_linkage = optional_object(payload, "expectedLinkage")?.unwrap_or_default();
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    let trace_refs =
        optional_array(payload, "traceRefs")?.unwrap_or_else(|| trace_refs(invocation));
    let replay_refs =
        optional_array(payload, "replayRefs")?.unwrap_or_else(|| replay_refs(invocation));
    let summary = optional_string(payload, "summary")?.unwrap_or_else(|| source_kind.clone());

    validate_bounded_array("declaredTools", &declared_tools, MAX_DECLARED_TOOLS)?;
    validate_bounded_array("declaredSchemas", &declared_schemas, MAX_DECLARED_SCHEMAS)?;
    validate_bounded_array("evidenceRefs", &evidence_refs, MAX_REFS)?;
    validate_bounded_array("traceRefs", &trace_refs, MAX_REFS)?;
    validate_bounded_array("replayRefs", &replay_refs, MAX_REFS)?;

    let mut candidate = json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": "proposed",
        "sourceKind": source_kind,
        "sourceIdentity": source_identity,
        "provenance": provenance,
        "sandboxPolicy": sandbox_policy,
        "declaredTools": declared_tools,
        "declaredSchemas": declared_schemas,
        "expectedLinkage": expected_linkage,
        "summary": summary,
        "authority": authority_record(invocation),
        "traceRefs": trace_refs,
        "replayRefs": replay_refs,
        "evidenceRefs": evidence_refs,
        "redaction": {"policy": "inline secrets rejected before persistence"},
        "limits": {
            "maxStringBytes": MAX_STRING_BYTES,
            "maxSchemaBytes": MAX_SCHEMA_BYTES,
            "maxTotalPayloadBytes": MAX_TOTAL_PAYLOAD_BYTES,
            "maxDeclaredTools": MAX_DECLARED_TOOLS,
            "maxDeclaredSchemas": MAX_DECLARED_SCHEMAS,
            "maxRefs": MAX_REFS
        },
        "idempotency": {"key": idempotency_key},
        "revision": 1
    });
    validate_proposal_payload(&candidate)?;

    let scope = resource_scope(invocation);
    let resource_id = proposal_resource_id(&scope, &candidate, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_scope(&existing, &scope, "tool_source_proposal replay")?;
        let resource_ref = current_resource_ref(&existing, "proposal")?;
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "tool_source_propose",
            "status": "ok",
            "idempotentReplay": true,
            "toolSourceProposalResourceId": resource_id,
            "resourceRefs": [resource_ref],
            "activation": {"performed": false, "catalogRegistration": false, "execution": false}
        }));
    }

    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: TOOL_SOURCE_PROPOSAL_KIND.to_owned(),
            schema_id: Some(TOOL_SOURCE_PROPOSAL_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("proposed".to_owned()),
            policy: json!({
                "owner": WORKER,
                "authority": PROPOSE_SCOPE,
                "activation": "forbidden"
            }),
            initial_payload: Some(candidate.take()),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_lifecycle_event(
        deps,
        invocation,
        "tool_source_proposal_created",
        &resource,
        json!({"state": "proposed"}),
    )
    .await?;

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "tool_source_propose",
        "status": "ok",
        "idempotentReplay": false,
        "toolSourceProposalResourceId": resource.resource_id,
        "resourceRefs": [resource_ref(&resource, "proposal")],
        "activation": {"performed": false, "catalogRegistration": false, "execution": false}
    }))
}

/// Create bounded preflight/conformance evidence for an existing proposal.
pub(crate) async fn create_conformance_report_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_internal_write_authority(
        deps,
        invocation,
        "tool source conformance report",
        TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let proposal_id = required_string(payload, "toolSourceProposalResourceId")?;
    validate_resource_id_prefix(&proposal_id, TOOL_SOURCE_PROPOSAL_KIND)?;
    let status = optional_string(payload, "status")?.unwrap_or_else(|| "failed".to_owned());
    validate_report_status(&status)?;
    let checks = optional_array(payload, "checks")?.unwrap_or_default();
    validate_bounded_array("checks", &checks, 50)?;
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    validate_bounded_array("evidenceRefs", &evidence_refs, MAX_REFS)?;

    let scope = resource_scope(invocation);
    let proposal = deps
        .engine_host
        .inspect_resource(&proposal_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing tool source proposal {proposal_id}")))?;
    ensure_tool_source_proposal(&proposal, "tool_source_conformance")?;
    ensure_scope(&proposal, &scope, "tool_source_conformance")?;
    let (proposal_version, _) = current_payload(&proposal, "tool_source_conformance")?;

    let report_id = report_resource_id(&scope, &proposal_id, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&report_id)
        .await
        .map_err(engine_error)?
    {
        ensure_scope(&existing, &scope, "tool_source_conformance replay")?;
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "tool_source_conformance_report",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "toolSourceConformanceReportResourceId": report_id,
            "resourceRefs": [current_resource_ref(&existing, "conformance_report")?],
            "activation": {"performed": false, "catalogRegistration": false, "execution": false}
        }));
    }

    let report = json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": status,
        "toolSourceProposalResourceId": proposal_id,
        "proposalVersionId": proposal_version.version_id,
        "status": status,
        "checks": checks,
        "summary": report_summary(payload),
        "authority": authority_record(invocation),
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "evidenceRefs": evidence_refs,
        "idempotency": {"key": idempotency_key},
        "revision": 1,
        "activation": {"performed": false, "catalogRegistration": false, "execution": false}
    });
    validate_no_forbidden_material(&report)?;
    validate_total_size(&report)?;

    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(report_id.clone()),
            kind: TOOL_SOURCE_CONFORMANCE_REPORT_KIND.to_owned(),
            schema_id: Some(TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(status.clone()),
            policy: json!({
                "owner": WORKER,
                "authority": PROPOSE_SCOPE,
                "activation": "forbidden"
            }),
            initial_payload: Some(report),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    deps.engine_host
        .link_resources(LinkResources {
            source_resource_id: resource.resource_id.clone(),
            target_resource_id: proposal.resource.resource_id.clone(),
            relation: "proposal".to_owned(),
            metadata: json!({"source": WORKER, "kind": "conformance_report"}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_lifecycle_event(
        deps,
        invocation,
        "tool_source_conformance_report_created",
        &resource,
        json!({"status": status}),
    )
    .await?;

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "tool_source_conformance_report",
        "status": status,
        "idempotentReplay": false,
        "toolSourceConformanceReportResourceId": resource.resource_id,
        "resourceRefs": [resource_ref(&resource, "conformance_report")],
        "activation": {"performed": false, "catalogRegistration": false, "execution": false}
    }))
}

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

async fn ensure_internal_write_authority(
    deps: &Deps,
    invocation: &Invocation,
    label: &str,
    resource_kind: &str,
) -> Result<(), CapabilityError> {
    if !matches!(
        invocation.causal_context.actor_kind,
        ActorKind::System | ActorKind::Admin
    ) {
        return Err(policy(format!(
            "{label} requires trusted internal system/admin authority"
        )));
    }
    if !invocation.causal_context.has_scope(PROPOSE_SCOPE)
        || !invocation.causal_context.has_scope(RESOURCE_WRITE_SCOPE)
    {
        return Err(policy(format!(
            "{label} requires {PROPOSE_SCOPE} and {RESOURCE_WRITE_SCOPE}"
        )));
    }
    if is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id) {
        return Err(policy(format!(
            "{label} requires a derived non-bootstrap grant"
        )));
    }
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| policy("unknown proposal authority grant"))?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, PROPOSE_SCOPE, label)?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, RESOURCE_WRITE_SCOPE, label)?;
    require_explicit_grant_item(&grant.allowed_resource_kinds, resource_kind, label)?;
    if grant.network_policy != "none" {
        return Err(policy(format!("{label} requires networkPolicy none")));
    }
    Ok(())
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

fn current_resource_ref(
    inspection: &EngineResourceInspection,
    role: &str,
) -> Result<Value, CapabilityError> {
    let (version, _) = current_payload(inspection, "resource_ref")?;
    Ok(version_ref(&inspection.resource, version, role))
}

fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role
    })
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

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_invocation",
        "invocationId": invocation.id.as_str(),
        "traceId": invocation.causal_context.trace_id.as_str()
    })]
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "actorKind": format!("{:?}", invocation.causal_context.actor_kind),
        "actorId": invocation.causal_context.actor_id.as_str(),
        "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
        "networkPolicy": "none",
        "activation": "forbidden"
    })
}

fn report_summary(payload: &Value) -> Value {
    payload
        .get("summary")
        .cloned()
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({"source": "bounded_preflight"}))
}

fn proposal_resource_id(scope: &EngineResourceScope, payload: &Value, key: &str) -> String {
    let identity = json!({
        "scope": scope_ref(scope),
        "sourceKind": payload["sourceKind"],
        "sourceIdentity": payload["sourceIdentity"],
        "idempotencyKey": key
    });
    format!("{TOOL_SOURCE_PROPOSAL_KIND}:{}", digest_value(&identity))
}

fn report_resource_id(scope: &EngineResourceScope, proposal_id: &str, key: &str) -> String {
    let identity = json!({
        "scope": scope_ref(scope),
        "proposal": proposal_id,
        "idempotencyKey": key
    });
    format!(
        "{TOOL_SOURCE_CONFORMANCE_REPORT_KIND}:{}",
        digest_value(&identity)
    )
}

fn digest_value(value: &Value) -> String {
    let mut hasher = Sha256::new();
    hasher.update(serde_json::to_vec(value).unwrap_or_default());
    hex::encode(hasher.finalize())
}

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}

async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_kind: &str,
    resource: &EngineResource,
    details: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: TOOL_SOURCE_TOPIC.to_owned(),
            payload: json!({
                "event": event_kind,
                "resource": resource_ref(resource, "subject"),
                "details": details,
                "activation": {"performed": false, "catalogRegistration": false, "execution": false}
            }),
            visibility: crate::engine::VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
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
