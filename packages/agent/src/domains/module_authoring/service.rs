use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceLocation,
    EngineResourceScope, EngineResourceVersion, Invocation, ListResources, PublishStreamEvent,
    WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{
    ensure_write_authority, inspect_read_grant, require_exact_resource_selector,
};
use super::contract::{
    MODULE_AUTHORING_LIFECYCLE_TOPIC, MODULE_PROPOSAL_SCHEMA_VERSION, READ_SCOPE,
    RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::projection::{inspected_module_proposal, module_proposal_summary};
use super::validation::*;
use super::{Deps, MODULE_PROPOSAL_KIND, MODULE_PROPOSAL_SCHEMA_ID};

const IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str = "sha256:tron.module_proposal.idempotency.v1";
const IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.module_proposal.idempotency.v1\0";

pub(crate) async fn record_module_proposal_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    ensure_write_authority(deps, invocation, "module_proposal_record").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let proposal_id_input = optional_string(payload, "proposalId")?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let proposal_id =
        bounded_provider_visible_token("proposalId", &proposal_id_input, PROPOSAL_ID_MAX_BYTES)?;
    let state = lifecycle_state(payload)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let summary = bounded_text(
        "summary",
        &required_string(payload, "summary")?,
        SUMMARY_MAX_BYTES,
    )?;
    let intended_module_refs = validate_ref_array(
        "intendedModuleRefs",
        &optional_array(payload, "intendedModuleRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let source_refs = validate_ref_array(
        "sourceRefs",
        &optional_array(payload, "sourceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let doc_refs = validate_ref_array(
        "docRefs",
        &optional_array(payload, "docRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let test_refs = validate_ref_array(
        "testRefs",
        &optional_array(payload, "testRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let trace_refs = validate_ref_array(
        "traceRefs",
        &optional_array(payload, "traceRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let replay_refs = validate_ref_array(
        "replayRefs",
        &optional_array(payload, "replayRefs")?.unwrap_or_default(),
        MAX_REFS,
    )?;
    let validation = validation_placeholder(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = module_proposal_resource_id(&scope, &proposal_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_module_proposal(&existing, "module_proposal_record replay")?;
        ensure_scope(&existing, &scope, "module_proposal_record replay")?;
        let (version, payload) = current_payload(&existing, "module_proposal_record replay")?;
        return Ok(json!({
            "schemaVersion": MODULE_PROPOSAL_SCHEMA_VERSION,
            "operation": "module_proposal_record",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "moduleProposalResourceId": resource_id,
            "moduleProposalVersionId": version.version_id,
            "proposal": module_proposal_summary(&existing.resource, version, payload),
            "resourceRefs": [version_ref(&existing.resource, version, "module_proposal")]
        }));
    }

    let record = module_proposal_record(ModuleProposalRecordInput {
        proposal_id: &proposal_id,
        state: &state,
        scope: &scope,
        title: &title,
        summary: &summary,
        intended_module_refs,
        source_refs,
        doc_refs,
        test_refs,
        trace_refs,
        replay_refs,
        validation,
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: MODULE_PROPOSAL_KIND.to_owned(),
            schema_id: Some(MODULE_PROPOSAL_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.clone()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "module_proposal".to_owned(),
                uri: format!("module-proposal:{proposal_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let version_id = resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid("module proposal resource was created without a current version"))?;
    publish_lifecycle_event(
        deps,
        invocation,
        "module_proposal.recorded",
        &resource,
        json!({
            "proposalState": state,
            "metadataOnly": true,
            "noInstall": true,
            "noExecution": true,
            "networkPolicy": "none",
            "physicalWorkspaceDirectoryCreated": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MODULE_PROPOSAL_SCHEMA_VERSION,
        "operation": "module_proposal_record",
        "status": resource.lifecycle,
        "idempotentReplay": false,
        "moduleProposalResourceId": resource.resource_id,
        "moduleProposalVersionId": version_id,
        "proposal": module_proposal_summary_for_resource(deps, &resource).await?,
        "resourceRefs": [resource_ref(&resource, "module_proposal")]
    }))
}

pub(crate) async fn list_module_proposal_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let _grant = inspect_read_grant(deps, invocation, "module_proposal_list").await?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_archived = optional_bool(payload, "includeArchived")?.unwrap_or(false);
    let lifecycle = optional_string(payload, "lifecycle")?
        .map(|value| bounded_token("lifecycle", &value, TOKEN_MAX_BYTES))
        .transpose()?;
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(MODULE_PROPOSAL_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: lifecycle.or_else(|| {
                if include_archived {
                    None
                } else {
                    Some("draft".to_owned())
                }
            }),
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
        ensure_module_proposal(&inspection, "module_proposal_list")?;
        ensure_scope(&inspection, &scope, "module_proposal_list")?;
        let (version, payload) = current_payload(&inspection, "module_proposal_list")?;
        proposals.push(module_proposal_summary(
            &inspection.resource,
            version,
            payload,
        ));
    }
    Ok(json!({
        "schemaVersion": MODULE_PROPOSAL_SCHEMA_VERSION,
        "operation": "module_proposal_list",
        "scope": scope_ref(&scope),
        "proposals": proposals,
        "limits": {
            "requestedLimit": limit,
            "returned": proposals.len(),
            "truncated": truncated,
            "includeArchived": include_archived
        },
        "sideEffects": side_effect_proof()
    }))
}

pub(crate) async fn inspect_module_proposal_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    reject_unsafe_payload(payload)?;
    let grant = inspect_read_grant(deps, invocation, "module_proposal_inspect").await?;
    let resource_id = required_string(payload, "moduleProposalResourceId")?;
    validate_module_proposal_resource_id(&resource_id)?;
    require_exact_resource_selector(&grant, &resource_id, "module_proposal_inspect")?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing module proposal {resource_id}")))?;
    ensure_module_proposal(&inspection, "module_proposal_inspect")?;
    ensure_scope(&inspection, &scope, "module_proposal_inspect")?;
    let (version, payload) = current_payload(&inspection, "module_proposal_inspect")?;
    Ok(json!({
        "schemaVersion": MODULE_PROPOSAL_SCHEMA_VERSION,
        "operation": "module_proposal_inspect",
        "scope": scope_ref(&scope),
        "proposal": inspected_module_proposal(&inspection.resource, version, payload),
        "sideEffects": side_effect_proof()
    }))
}

struct ModuleProposalRecordInput<'a> {
    proposal_id: &'a str,
    state: &'a str,
    scope: &'a EngineResourceScope,
    title: &'a str,
    summary: &'a str,
    intended_module_refs: Vec<Value>,
    source_refs: Vec<Value>,
    doc_refs: Vec<Value>,
    test_refs: Vec<Value>,
    trace_refs: Vec<Value>,
    replay_refs: Vec<Value>,
    validation: Value,
    created_at: &'a str,
    updated_at: &'a str,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn module_proposal_record(input: ModuleProposalRecordInput<'_>) -> Value {
    json!({
        "schemaVersion": MODULE_PROPOSAL_SCHEMA_VERSION,
        "state": input.state,
        "proposalId": input.proposal_id,
        "scope": scope_ref(input.scope),
        "identity": {
            "title": input.title,
            "summary": input.summary
        },
        "intendedModuleRefs": input.intended_module_refs,
        "refs": {
            "source": input.source_refs,
            "docs": input.doc_refs,
            "tests": input.test_refs,
            "trace": input.trace_refs,
            "replay": input.replay_refs
        },
        "validation": input.validation,
        "lifecycle": {
            "state": input.state,
            "install": "forbidden",
            "activation": "forbidden",
            "execution": "forbidden",
            "dependencyRestore": "forbidden",
            "networkPolicy": "none"
        },
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(input.idempotency_key),
        "safetyProof": safety_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": input.revision
    })
}

async fn module_proposal_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created module proposal resource missing during projection"))?;
    let (version, payload) = current_payload(&inspection, "module_proposal_record projection")?;
    Ok(module_proposal_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

fn ensure_module_proposal(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != MODULE_PROPOSAL_KIND {
        return Err(invalid(format!(
            "{operation} expected {MODULE_PROPOSAL_KIND}"
        )));
    }
    if inspection.resource.schema_id != MODULE_PROPOSAL_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {MODULE_PROPOSAL_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot access module proposals outside the current scope"
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
    if !version.state.may_be_current() {
        return Err(invalid(format!(
            "{operation} current version is not available"
        )));
    }
    Ok((version, &version.payload))
}

fn validate_module_proposal_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{MODULE_PROPOSAL_KIND}:")) {
        return Err(invalid(
            "moduleProposalResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleProposalResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
}

async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    resource: &EngineResource,
    payload: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: MODULE_AUTHORING_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "moduleAuthoringBoundary": {
                    "metadataOnly": true,
                    "noInstall": true,
                    "noExecution": true,
                    "dependencyRestorePerformed": false,
                    "networkPolicy": "none",
                    "physicalWorkspaceDirectoryCreated": false,
                    "repoManagedSkillsTouched": false
                }
            }),
            visibility: crate::engine::VisibilityScope::Session,
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

fn module_proposal_resource_id(
    scope: &EngineResourceScope,
    proposal_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(proposal_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{MODULE_PROPOSAL_KIND}:{}", hex::encode(hasher.finalize()))
}

fn idempotency_evidence(idempotency_key: &str) -> Value {
    json!({
        "fingerprint": idempotency_fingerprint(idempotency_key),
        "fingerprintAlgorithm": IDEMPOTENCY_FINGERPRINT_ALGORITHM,
        "keyRedacted": true,
        "rawKeyStored": false
    })
}

fn idempotency_fingerprint(idempotency_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(IDEMPOTENCY_FINGERPRINT_DOMAIN);
    hasher.update(idempotency_key.as_bytes());
    hex::encode(hasher.finalize())
}

fn resource_policy() -> Value {
    json!({
        "owner": WORKER,
        "kind": MODULE_PROPOSAL_KIND,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "metadataOnly": true,
        "install": "forbidden",
        "execution": "forbidden",
        "networkPolicy": "none"
    })
}

fn authority_record() -> Value {
    json!({
        "grantRedacted": true,
        "rawAuthorityIdsStored": false,
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [MODULE_PROPOSAL_KIND],
        "wildcardGrantsAllowed": false
    })
}

fn safety_proof() -> Value {
    json!({
        "noInstall": true,
        "noExecution": true,
        "dependencyRestorePerformed": false,
        "packageManagerUsed": false,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "repoManagedSkillsTouched": false,
        "rawProposalBodyStored": false,
        "rawPromptStored": false,
        "commandsStored": false,
        "fileContentsStored": false,
        "absolutePathsStored": false
    })
}

fn side_effect_proof() -> Value {
    json!({
        "install": false,
        "activation": false,
        "execution": false,
        "dependencyResolution": false,
        "packageManager": false,
        "network": {"performed": false, "requiredPolicy": "none"},
        "repoManagedSkillsTouched": false,
        "physicalWorkspaceDirectoryCreated": false
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_trace",
        "id": runtime_ref_fingerprint("trace", invocation.causal_context.trace_id.as_str()),
        "role": "record_trace"
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_invocation",
        "id": runtime_ref_fingerprint("invocation", invocation.id.as_str()),
        "role": "record_invocation"
    })]
}

fn runtime_ref_fingerprint(kind: &str, value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"tron.module_proposal.runtime_ref.v1\0");
    hasher.update(kind.as_bytes());
    hasher.update(b":");
    hasher.update(value.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

fn version_ref(resource: &EngineResource, version: &EngineResourceVersion, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": version.version_id,
        "role": role
    })
}

fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "role": role
    })
}

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(|error| invalid(format!("worker id: {error}")))
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
