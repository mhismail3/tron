use chrono::Utc;
use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineHostHandle, EngineResourceInspection, EngineResourceScope, Invocation,
    ListResources, UpdateResource, WorkerId,
};
use crate::shared::protocol::memory::{
    MEMORY_SCHEMA_VERSION, MemoryEngineDescriptor, MemoryMode, MemoryPolicyRecord, MemoryRecord,
    RESOURCE_BACKED_MEMORY_ENGINE_ID,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
pub(crate) use super::migration::{migrate_export_value, migrate_import_value};
pub(crate) use super::prompt_trace::{load_prompt_memory_context, record_prompt_trace_value};
use super::support::*;
use super::{
    MEMORY_ENGINE_KIND, MEMORY_ENGINE_SCHEMA_ID, MEMORY_POLICY_KIND, MEMORY_POLICY_SCHEMA_ID,
    MEMORY_RECORD_KIND, MEMORY_RECORD_SCHEMA_ID, WORKER,
};

pub(super) struct ResolvedPolicy {
    pub(super) scope: EngineResourceScope,
    pub(super) resource_id: Option<String>,
    pub(super) version_id: Option<String>,
    pub(super) record: MemoryPolicyRecord,
    pub(super) implicit: bool,
    pub(super) parse_error: Option<String>,
}

/// Return memory status with explicit disabled default when no policy exists.
pub(crate) async fn status_memory_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    _payload: &Value,
) -> Result<Value, CapabilityError> {
    let policy = resolve_policy(engine_host, &resource_scope(invocation), false).await?;
    let engine = policy.record.active_engine_id.as_deref().map(
        |engine_id| json!({"engineId": engine_id, "resourceId": engine_resource_id(engine_id)}),
    );
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "mode": policy.record.mode.as_str(),
        "activeEngine": engine,
        "compareEngineIds": policy.record.compare_engine_ids,
        "policy": {
            "resourceId": policy.resource_id,
            "versionId": policy.version_id,
            "implicit": policy.implicit,
            "scope": policy.scope,
            "parseError": policy.parse_error,
            "inclusion": policy.record.inclusion,
            "retention": policy.record.retention,
            "privacy": policy.record.privacy,
            "migration": policy.record.migration,
            "revision": policy.record.revision
        },
        "promptInclusion": prompt_inclusion_summary(&policy.record),
        "contract": {
            "resourceBacked": true,
            "semanticRetrieval": false,
            "embeddings": false,
            "ranking": false,
            "summarization": false,
            "hiddenPromptMemory": false
        }
    }))
}

/// Configure a scope-local memory policy resource.
pub(crate) async fn configure_policy_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let mode = mode_from_payload(payload)?;
    let scope = resource_scope(invocation);
    let active_engine_id = optional_string(payload, "activeEngineId")?.or_else(|| {
        (mode != MemoryMode::Disabled).then(|| RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned())
    });
    let compare_engine_ids = optional_array(payload, "compareEngineIds")?
        .into_iter()
        .map(|value| {
            value
                .as_str()
                .filter(|value| !value.trim().is_empty())
                .map(str::to_owned)
                .ok_or_else(|| invalid_params("compareEngineIds must contain strings"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if mode == MemoryMode::Compare && compare_engine_ids.is_empty() {
        return Err(invalid_params(
            "compare mode requires at least one compareEngineIds entry",
        ));
    }
    if mode != MemoryMode::Disabled
        && let Some(engine_id) = active_engine_id.as_deref()
    {
        ensure_engine_resource(engine_host, invocation, engine_id).await?;
    }

    let existing = engine_host
        .inspect_resource(&policy_resource_id(&scope))
        .await
        .map_err(engine_error)?;
    let (expected_version, prior_revision) = existing
        .as_ref()
        .and_then(current_payload)
        .map(|(version, payload)| {
            let revision = serde_json::from_value::<MemoryPolicyRecord>(payload)
                .map(|policy| policy.revision)
                .unwrap_or(0);
            (Some(version), revision)
        })
        .unwrap_or((None, 0));
    let record = MemoryPolicyRecord {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        mode: mode.clone(),
        active_engine_id,
        compare_engine_ids,
        inclusion: optional_object(payload, "inclusion")?.unwrap_or_else(|| {
            json!({
                "promptInclusion": if mode == MemoryMode::Active { "eligible_by_contract" } else { "disabled" },
                "reason": format!("memory_mode_{}", mode.as_str())
            })
        }),
        retention: optional_object(payload, "retention")?
            .unwrap_or_else(|| json!({"defaultRetention": "explicit"})),
        privacy: optional_object(payload, "privacy")?
            .unwrap_or_else(|| json!({"defaultSensitivity": "private"})),
        migration: optional_object(payload, "migration")?
            .unwrap_or_else(|| json!({"exportImport": "enabled"})),
        provenance: optional_object(payload, "provenance")?.unwrap_or_else(|| {
            json!({
                "source": "memory.configure_policy",
                "actorId": invocation.causal_context.actor_id.as_str()
            })
        }),
        revision: prior_revision.saturating_add(1),
    };
    let record_payload = to_value(&record, "memory policy")?;
    let resource = if let Some(existing) = existing {
        let policy_resource_id = existing.resource.resource_id.clone();
        let version = engine_host
            .update_resource(UpdateResource {
                resource_id: policy_resource_id.clone(),
                expected_current_version_id: expected_version,
                lifecycle: Some(record.mode.as_str().to_owned()),
                payload: record_payload,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        let _ = publish_lifecycle_event(
            engine_host,
            invocation,
            "memory.policy_configured",
            json!({
                "policyResourceId": policy_resource_id,
                "policyVersionId": version.version_id.clone(),
                "mode": record.mode.as_str(),
                "activeEngineId": record.active_engine_id.clone()
            }),
        )
        .await?;
        return Ok(json!({
            "schemaVersion": MEMORY_SCHEMA_VERSION,
            "status": "configured",
            "policyResourceId": existing.resource.resource_id.clone(),
            "policyVersionId": version.version_id.clone(),
            "mode": record.mode.as_str(),
            "resourceRefs": [version_ref(&existing.resource, &version, "memory_policy")]
        }));
    } else {
        engine_host
            .create_resource(CreateResource {
                resource_id: Some(policy_resource_id(&scope)),
                kind: MEMORY_POLICY_KIND.to_owned(),
                schema_id: Some(MEMORY_POLICY_SCHEMA_ID.to_owned()),
                scope,
                owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
                owner_actor_id: invocation.causal_context.actor_id.clone(),
                lifecycle: Some(record.mode.as_str().to_owned()),
                policy: memory_policy("policy"),
                initial_payload: Some(record_payload),
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?
    };
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.policy_configured",
        json!({
            "policyResourceId": resource.resource_id.clone(),
            "policyVersionId": resource.current_version_id.clone(),
            "mode": record.mode.as_str(),
            "activeEngineId": record.active_engine_id.clone()
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "configured",
        "policyResourceId": resource.resource_id.clone(),
        "policyVersionId": resource.current_version_id.clone(),
        "mode": record.mode.as_str(),
        "resourceRefs": [resource_ref(&resource, "memory_policy")]
    }))
}

/// Retain a memory record through the deterministic resource-backed engine.
pub(crate) async fn retain_memory_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let policy = require_writable_policy(engine_host, invocation).await?;
    let body_ref = required_object(payload, "bodyRef")?;
    ensure_body_ref_is_pointer(&body_ref)?;
    let now = Utc::now();
    let record = MemoryRecord {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        subject: required_string(payload, "subject")?,
        scope: required_object(payload, "scope")?,
        preview: required_string(payload, "preview")?,
        body_ref,
        provenance: required_object(payload, "provenance")?,
        confidence: required_object(payload, "confidence")?,
        sensitivity: required_string(payload, "sensitivity")?,
        retention: required_object(payload, "retention")?,
        expires_at: optional_datetime(payload, "expiresAt")?,
        source_refs: optional_array(payload, "sourceRefs")?,
        trace_refs: merge_trace_refs(optional_array(payload, "traceRefs")?, invocation),
        replay_refs: merge_replay_refs(optional_array(payload, "replayRefs")?, invocation),
        lifecycle: json!({"state": "retained", "retainedAt": now}),
        migration: optional_object(payload, "migration")?
            .unwrap_or_else(|| json!({"portable": true, "lineage": []})),
        revision: 1,
    };
    let resource_id = optional_string(payload, "recordId")?
        .unwrap_or_else(|| format!("memory_record:{}", invocation.id.as_str()));
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: MEMORY_RECORD_KIND.to_owned(),
            schema_id: Some(MEMORY_RECORD_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("retained".to_owned()),
            policy: memory_policy("record"),
            initial_payload: Some(to_value(&record, "memory record")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.record_retained",
        json!({
            "recordResourceId": resource.resource_id.clone(),
            "recordVersionId": resource.current_version_id.clone(),
            "policyResourceId": policy.resource_id.clone(),
            "mode": policy.record.mode.as_str(),
            "sensitivity": record.sensitivity.clone(),
            "traceRefs": record.trace_refs.clone(),
            "replayRefs": record.replay_refs.clone()
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "retained",
        "recordResourceId": resource.resource_id.clone(),
        "recordVersionId": resource.current_version_id.clone(),
        "resourceRefs": [resource_ref(&resource, "memory_record")]
    }))
}

/// Version a memory record with explicit replacement metadata.
pub(crate) async fn edit_memory_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _policy = require_writable_policy(engine_host, invocation).await?;
    let resource_id = required_string(payload, "recordResourceId")?;
    let expected = required_string(payload, "expectedCurrentVersionId")?;
    let inspection = require_memory_record(engine_host, &resource_id).await?;
    let (current_version_id, current_payload) = current_payload(&inspection)
        .ok_or_else(|| invalid_params("memory record has no current payload"))?;
    if current_version_id != expected {
        return Err(invalid_params(format!(
            "memory record revision conflict: expected {expected}, actual {current_version_id}"
        )));
    }
    let mut record: MemoryRecord = serde_json::from_value(current_payload)
        .map_err(|err| invalid_params(format!("malformed memory record payload: {err}")))?;
    if let Some(subject) = optional_string(payload, "subject")? {
        record.subject = subject;
    }
    if let Some(preview) = optional_string(payload, "preview")? {
        record.preview = preview;
    }
    if let Some(body_ref) = optional_object(payload, "bodyRef")? {
        ensure_body_ref_is_pointer(&body_ref)?;
        record.body_ref = body_ref;
    }
    if let Some(scope) = optional_object(payload, "scope")? {
        record.scope = scope;
    }
    if let Some(confidence) = optional_object(payload, "confidence")? {
        record.confidence = confidence;
    }
    if let Some(retention) = optional_object(payload, "retention")? {
        record.retention = retention;
    }
    if let Some(sensitivity) = optional_string(payload, "sensitivity")? {
        record.sensitivity = sensitivity;
    }
    record.expires_at = optional_datetime(payload, "expiresAt")?.or(record.expires_at);
    record.revision = record.revision.saturating_add(1);
    record.lifecycle = json!({
        "state": "edited",
        "editedAt": Utc::now(),
        "parentVersionId": expected,
        "reason": optional_string(payload, "reason")?
    });
    record.trace_refs = merge_trace_refs(record.trace_refs, invocation);
    record.replay_refs = merge_replay_refs(record.replay_refs, invocation);
    let version = engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(expected),
            lifecycle: Some("edited".to_owned()),
            payload: to_value(&record, "memory record edit")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.record_edited",
        json!({"recordResourceId": resource_id.clone(), "recordVersionId": version.version_id.clone()}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "edited",
        "recordResourceId": resource_id,
        "recordVersionId": version.version_id.clone(),
        "resourceRefs": [version_ref(&inspection.resource, &version, "memory_record")]
    }))
}

/// Tombstone a memory record without erasing audit history.
pub(crate) async fn tombstone_memory_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _policy = require_writable_policy(engine_host, invocation).await?;
    let resource_id = required_string(payload, "recordResourceId")?;
    let expected = required_string(payload, "expectedCurrentVersionId")?;
    let inspection = require_memory_record(engine_host, &resource_id).await?;
    let (current_version_id, current_payload) = current_payload(&inspection)
        .ok_or_else(|| invalid_params("memory record has no current payload"))?;
    if current_version_id != expected {
        return Err(invalid_params(format!(
            "memory record revision conflict: expected {expected}, actual {current_version_id}"
        )));
    }
    let mut record: MemoryRecord = serde_json::from_value(current_payload)
        .map_err(|err| invalid_params(format!("malformed memory record payload: {err}")))?;
    record.revision = record.revision.saturating_add(1);
    record.lifecycle = json!({
        "state": "tombstoned",
        "tombstonedAt": Utc::now(),
        "parentVersionId": expected,
        "reason": optional_string(payload, "reason")?.unwrap_or_else(|| "explicit_tombstone".to_owned())
    });
    record.trace_refs = merge_trace_refs(record.trace_refs, invocation);
    record.replay_refs = merge_replay_refs(record.replay_refs, invocation);
    let version = engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(expected),
            lifecycle: Some("tombstoned".to_owned()),
            payload: to_value(&record, "memory record tombstone")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.record_tombstoned",
        json!({"recordResourceId": resource_id.clone(), "recordVersionId": version.version_id.clone()}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "tombstoned",
        "recordResourceId": resource_id,
        "recordVersionId": version.version_id.clone(),
        "resourceRefs": [version_ref(&inspection.resource, &version, "memory_record")]
    }))
}

/// List redacted memory records in the current scope.
pub(crate) async fn list_memory_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(50)
        .clamp(1, 500) as usize;
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(MEMORY_RECORD_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: optional_string(payload, "lifecycle")?,
            limit,
        })
        .await
        .map_err(engine_error)?;
    let mut records = Vec::new();
    for resource in resources {
        if let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
            && let Some((version_id, payload)) = current_payload(&inspection)
        {
            records.push(json!({
                "resource": inspection.resource,
                "currentVersionId": version_id,
                "record": redacted_record_payload(&payload)
            }));
        }
    }
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "records": records,
        "redacted": true
    }))
}

/// Inspect one redacted memory record.
pub(crate) async fn inspect_memory_value(
    engine_host: &EngineHostHandle,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let resource_id = required_string(payload, "recordResourceId")?;
    let inspection = require_memory_record(engine_host, &resource_id).await?;
    let redacted_versions = inspection
        .versions
        .iter()
        .map(|version| {
            json!({
                "versionId": version.version_id,
                "parentVersionId": version.parent_version_id,
                "contentHash": version.content_hash,
                "state": version.state,
                "createdAt": version.created_at,
                "record": redacted_record_payload(&version.payload)
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "resource": inspection.resource,
        "versions": redacted_versions,
        "events": inspection.events,
        "redacted": true
    }))
}

pub(super) async fn require_writable_policy(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
) -> Result<ResolvedPolicy, CapabilityError> {
    let policy = resolve_policy(engine_host, &resource_scope(invocation), true).await?;
    if policy.record.mode == MemoryMode::Disabled {
        return Err(invalid_params(
            "memory is disabled for this scope; configure active, shadow, or compare mode before writing records",
        ));
    }
    if policy.parse_error.is_some() {
        return Err(invalid_params("memory policy is malformed"));
    }
    Ok(policy)
}

pub(super) async fn resolve_policy(
    engine_host: &EngineHostHandle,
    scope: &EngineResourceScope,
    strict: bool,
) -> Result<ResolvedPolicy, CapabilityError> {
    let mut scopes = Vec::new();
    scopes.push(scope.clone());
    if let EngineResourceScope::Session(_) = scope {
        // Session policy falls back to workspace only through explicit caller
        // context; if none is known, system default still applies.
    }
    scopes.push(EngineResourceScope::System);
    for candidate in scopes {
        let resource_id = policy_resource_id(&candidate);
        if let Some(inspection) = engine_host
            .inspect_resource(&resource_id)
            .await
            .map_err(engine_error)?
        {
            let Some((version_id, payload)) = current_payload(&inspection) else {
                if strict {
                    return Err(invalid_params("memory policy has no current payload"));
                }
                return Ok(malformed_policy(
                    candidate,
                    Some(resource_id),
                    None,
                    "missing payload",
                ));
            };
            match serde_json::from_value::<MemoryPolicyRecord>(payload) {
                Ok(record) => {
                    return Ok(ResolvedPolicy {
                        scope: candidate,
                        resource_id: Some(resource_id),
                        version_id: Some(version_id),
                        record,
                        implicit: false,
                        parse_error: None,
                    });
                }
                Err(err) if strict => {
                    return Err(invalid_params(format!("malformed memory policy: {err}")));
                }
                Err(err) => {
                    return Ok(malformed_policy(
                        candidate,
                        Some(resource_id),
                        Some(version_id),
                        err.to_string(),
                    ));
                }
            }
        }
    }
    Ok(ResolvedPolicy {
        scope: scope.clone(),
        resource_id: None,
        version_id: None,
        record: MemoryPolicyRecord::disabled_default(),
        implicit: true,
        parse_error: None,
    })
}

fn malformed_policy(
    scope: EngineResourceScope,
    resource_id: Option<String>,
    version_id: Option<String>,
    message: impl Into<String>,
) -> ResolvedPolicy {
    let mut record = MemoryPolicyRecord::disabled_default();
    record.inclusion = json!({
        "promptInclusion": "disabled",
        "reason": "memory_policy_malformed_fail_closed"
    });
    ResolvedPolicy {
        scope,
        resource_id,
        version_id,
        record,
        implicit: false,
        parse_error: Some(message.into()),
    }
}

async fn ensure_engine_resource(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    engine_id: &str,
) -> Result<(), CapabilityError> {
    let resource_id = engine_resource_id(engine_id);
    if engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .is_some()
    {
        return Ok(());
    }
    let descriptor = MemoryEngineDescriptor {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        engine_id: engine_id.to_owned(),
        label: "Deterministic resource-backed memory".to_owned(),
        version: "1".to_owned(),
        package_provenance: json!({
            "kind": "built_in_contract_probe",
            "algorithm": "none",
            "embeddings": false,
            "ranking": false,
            "summarization": false
        }),
        supported_modes: vec![
            MemoryMode::Disabled,
            MemoryMode::Active,
            MemoryMode::Shadow,
            MemoryMode::Compare,
        ],
        supported_stores: vec!["engine_resources".to_owned()],
        privacy_features: json!({
            "bodyStorage": "resource_ref_only",
            "promptContent": "status_and_refs_only",
            "redactedAudit": true
        }),
        migration_support: json!({"export": true, "import": true, "indexMetadata": "none"}),
        eval_profile: json!({"requiredBeforeSemanticRetrieval": true, "currentEval": "schema_only"}),
        status: "available".to_owned(),
    };
    engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: MEMORY_ENGINE_KIND.to_owned(),
            schema_id: Some(MEMORY_ENGINE_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::System,
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("available".to_owned()),
            policy: memory_policy("engine"),
            initial_payload: Some(to_value(&descriptor, "memory engine descriptor")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
}

async fn require_memory_record(
    engine_host: &EngineHostHandle,
    resource_id: &str,
) -> Result<EngineResourceInspection, CapabilityError> {
    let inspection = engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("memory record {resource_id} missing")))?;
    if inspection.resource.kind != MEMORY_RECORD_KIND {
        return Err(invalid_params(format!(
            "resource {resource_id} is not a memory record"
        )));
    }
    Ok(inspection)
}

fn prompt_inclusion_summary(policy: &MemoryPolicyRecord) -> Value {
    json!({
        "mode": policy.mode.as_str(),
        "enabledForPrompt": false,
        "reason": if policy.mode == MemoryMode::Disabled {
            "memory_disabled"
        } else {
            "prompt_inclusion_requires_future_retrieval_policy"
        },
        "privateContentIncluded": false
    })
}

fn merge_trace_refs(mut refs: Vec<Value>, invocation: &Invocation) -> Vec<Value> {
    refs.extend(trace_refs(invocation));
    refs
}

fn merge_replay_refs(mut refs: Vec<Value>, invocation: &Invocation) -> Vec<Value> {
    refs.extend(replay_refs(invocation));
    refs
}
