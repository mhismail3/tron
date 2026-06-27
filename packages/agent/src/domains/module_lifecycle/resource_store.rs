use serde_json::{Value, json};

use crate::engine::{
    EngineResource, EngineResourceInspection, EngineResourceScope, EngineResourceVersion,
    Invocation, PublishStreamEvent, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::contract::{MODULE_LIFECYCLE_TOPIC, WORKER};
use super::projection::module_lifecycle_summary;
use super::records::resource_ref;
use super::validation::invalid;
use super::{Deps, MODULE_LIFECYCLE_STATE_KIND, MODULE_LIFECYCLE_STATE_SCHEMA_ID};

pub(super) async fn inspect_resource_required(
    deps: &Deps,
    resource_id: &str,
    label: &str,
) -> Result<EngineResourceInspection, CapabilityError> {
    deps.engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing {label} {resource_id}")))
}

pub(super) async fn module_lifecycle_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "module lifecycle state").await?;
    let (version, payload) = current_payload(&inspection, "module_lifecycle projection")?;
    Ok(module_lifecycle_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

pub(super) fn ensure_module_lifecycle_state(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != MODULE_LIFECYCLE_STATE_KIND {
        return Err(invalid(format!(
            "{operation} expected {MODULE_LIFECYCLE_STATE_KIND}"
        )));
    }
    if inspection.resource.schema_id != MODULE_LIFECYCLE_STATE_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {MODULE_LIFECYCLE_STATE_SCHEMA_ID}"
        )));
    }
    Ok(())
}

pub(super) fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot access module lifecycle records outside the current scope"
        )));
    }
    Ok(())
}

pub(super) fn current_payload<'a>(
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

pub(super) async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    resource: &EngineResource,
    payload: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: MODULE_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "moduleLifecycleBoundary": {
                    "metadataOnly": true,
                    "installPerformed": false,
                    "activationPerformed": false,
                    "executionPerformed": false,
                    "rollbackExecuted": false,
                    "dependencyRestorePerformed": false,
                    "packageManagerUsed": false,
                    "networkPolicy": "none",
                    "networkAccessPerformed": false,
                    "physicalWorkspaceDirectoryCreated": false,
                    "repoManagedSkillsTouched": false,
                    "approvalEvidenceIsAuthority": false,
                    "derivedAuthorityRequired": true
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

pub(super) fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

pub(super) fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
