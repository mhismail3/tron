use super::*;

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
        .create_resource(crate::engine::CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: TOOL_SOURCE_PROPOSAL_KIND.to_owned(),
            schema_id: Some(TOOL_SOURCE_PROPOSAL_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("proposed".to_owned()),
            policy: json!({
                "owner": crate::domains::tool_sources::WORKER,
                "authority": crate::domains::tool_sources::PROPOSE_SCOPE,
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
        .create_resource(crate::engine::CreateResource {
            resource_id: Some(report_id.clone()),
            kind: TOOL_SOURCE_CONFORMANCE_REPORT_KIND.to_owned(),
            schema_id: Some(TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(status.clone()),
            policy: json!({
                "owner": crate::domains::tool_sources::WORKER,
                "authority": crate::domains::tool_sources::PROPOSE_SCOPE,
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
        .link_resources(crate::engine::LinkResources {
            source_resource_id: resource.resource_id.clone(),
            target_resource_id: proposal.resource.resource_id.clone(),
            relation: "proposal".to_owned(),
            metadata: json!({"source": crate::domains::tool_sources::WORKER, "kind": "conformance_report"}),
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

async fn ensure_internal_write_authority(
    deps: &Deps,
    invocation: &Invocation,
    label: &str,
    resource_kind: &str,
) -> Result<(), CapabilityError> {
    if !matches!(
        invocation.causal_context.actor_kind,
        crate::engine::ActorKind::System | crate::engine::ActorKind::Admin
    ) {
        return Err(policy(format!(
            "{label} requires trusted internal system/admin authority"
        )));
    }
    if !invocation
        .causal_context
        .has_scope(crate::domains::tool_sources::PROPOSE_SCOPE)
        || !invocation.causal_context.has_scope(RESOURCE_WRITE_SCOPE)
    {
        return Err(policy(format!(
            "{label} requires {} and {RESOURCE_WRITE_SCOPE}",
            crate::domains::tool_sources::PROPOSE_SCOPE
        )));
    }
    if crate::engine::is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id)
    {
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
    require_explicit_grant_item(
        &grant.allowed_authority_scopes,
        crate::domains::tool_sources::PROPOSE_SCOPE,
        label,
    )?;
    require_explicit_grant_item(&grant.allowed_authority_scopes, RESOURCE_WRITE_SCOPE, label)?;
    require_explicit_grant_item(&grant.allowed_resource_kinds, resource_kind, label)?;
    if grant.network_policy != "none" {
        return Err(policy(format!("{label} requires networkPolicy none")));
    }
    Ok(())
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
    use sha2::{Digest, Sha256};

    let mut hasher = Sha256::new();
    hasher.update(serde_json::to_vec(value).unwrap_or_default());
    hex::encode(hasher.finalize())
}

fn worker_id() -> Result<crate::engine::WorkerId, CapabilityError> {
    crate::engine::WorkerId::new(crate::domains::tool_sources::WORKER).map_err(engine_error)
}

async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_kind: &str,
    resource: &EngineResource,
    details: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: crate::domains::tool_sources::TOOL_SOURCE_TOPIC.to_owned(),
            payload: json!({
                "event": event_kind,
                "resource": resource_ref(resource, "subject"),
                "details": details,
                "activation": {"performed": false, "catalogRegistration": false, "execution": false}
            }),
            visibility: crate::engine::VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: crate::domains::tool_sources::WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
}
