use serde_json::{Value, json};

use crate::engine::{
    EngineResource, EngineResourceInspection, EngineResourceScope, EngineResourceVersion,
    Invocation, PublishStreamEvent, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::contract::{MODULE_DEPENDENCY_LIFECYCLE_TOPIC, WORKER};
use super::projection::{
    module_dependency_decision_summary, module_dependency_policy_summary,
    module_dependency_request_summary,
};
use super::records::resource_ref;
use super::validation::invalid;
use super::{
    Deps, MODULE_DEPENDENCY_DECISION_KIND, MODULE_DEPENDENCY_DECISION_SCHEMA_ID,
    MODULE_DEPENDENCY_POLICY_KIND, MODULE_DEPENDENCY_POLICY_SCHEMA_ID,
    MODULE_DEPENDENCY_REQUEST_KIND, MODULE_DEPENDENCY_REQUEST_SCHEMA_ID,
};

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

pub(super) async fn module_dependency_request_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "module dependency request").await?;
    let (version, payload) =
        current_payload(&inspection, "module_dependency_request_record projection")?;
    Ok(module_dependency_request_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

pub(super) async fn module_dependency_decision_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "module dependency decision")
            .await?;
    let (version, payload) =
        current_payload(&inspection, "module_dependency_decision_record projection")?;
    Ok(module_dependency_decision_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

pub(super) async fn module_dependency_policy_summary_for_resource(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Value, CapabilityError> {
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "module dependency policy").await?;
    let (version, payload) =
        current_payload(&inspection, "module_dependency_policy_activate projection")?;
    Ok(module_dependency_policy_summary(
        &inspection.resource,
        version,
        payload,
    ))
}

pub(super) fn ensure_module_dependency_request(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        MODULE_DEPENDENCY_REQUEST_KIND,
        MODULE_DEPENDENCY_REQUEST_SCHEMA_ID,
    )
}

pub(super) fn ensure_module_dependency_decision(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        MODULE_DEPENDENCY_DECISION_KIND,
        MODULE_DEPENDENCY_DECISION_SCHEMA_ID,
    )
}

pub(super) fn ensure_module_dependency_policy(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        MODULE_DEPENDENCY_POLICY_KIND,
        MODULE_DEPENDENCY_POLICY_SCHEMA_ID,
    )
}

fn ensure_kind_schema(
    inspection: &EngineResourceInspection,
    operation: &str,
    kind: &str,
    schema_id: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != kind {
        return Err(invalid(format!("{operation} expected {kind}")));
    }
    if inspection.resource.schema_id != schema_id {
        return Err(invalid(format!("{operation} expected schema {schema_id}")));
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
            "{operation} cannot access module dependency records outside the current scope"
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
            topic: MODULE_DEPENDENCY_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "moduleDependencyBoundary": {
                    "metadataOnly": true,
                    "dependencyRestorePerformed": false,
                    "packageManagerUsed": false,
                    "manifestMutated": false,
                    "lockfileMutated": false,
                    "activationPerformed": false,
                    "executionPerformed": false,
                    "networkPolicy": "none",
                    "networkAccessPerformed": false,
                    "physicalWorkspaceDirectoryCreated": false,
                    "repoManagedSkillsTouched": false,
                    "rawDependencyArtifactsStored": false,
                    "packageManagerOutputStored": false
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
