use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceLocation,
    EngineResourceScope, EngineResourceVersion, Invocation, PublishStreamEvent, UpdateResource,
};
use crate::shared::server::errors::CapabilityError;

use super::contract::{CONTEXT_CONTROL_TOPIC, WORKER};
use super::records::{resource_policy, resource_ref};
use super::validation::{engine_error, id_error, invalid};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_ACTION_SCHEMA_ID, CONTEXT_CONTROL_EPOCH_KIND,
    CONTEXT_CONTROL_EPOCH_SCHEMA_ID, CONTEXT_CONTROL_SNAPSHOT_KIND,
    CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID, CONTEXT_EXCLUSION_KIND, CONTEXT_EXCLUSION_SCHEMA_ID,
    CONTEXT_POLICY_SNAPSHOT_KIND, CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID, CONTEXT_SURVIVOR_KIND,
    CONTEXT_SURVIVOR_SCHEMA_ID, Deps,
};

pub(super) async fn create_action_resource(
    deps: &Deps,
    invocation: &Invocation,
    resource_id: &str,
    lifecycle: &str,
    record: Value,
    uri: &str,
) -> Result<(EngineResource, EngineResourceVersion, Value), CapabilityError> {
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: CONTEXT_CONTROL_ACTION_KIND.to_owned(),
            schema_id: Some(CONTEXT_CONTROL_ACTION_SCHEMA_ID.to_owned()),
            scope: resource_scope_from_payload(&record)?,
            owner_worker_id: crate::engine::WorkerId::new(WORKER).map_err(id_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(lifecycle.to_owned()),
            policy: resource_policy(CONTEXT_CONTROL_ACTION_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "context_control_action".to_owned(),
                uri: uri.to_owned(),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "context control action").await?;
    let (version, payload) = current_payload(&inspection, "context_control_action created")?;
    Ok((resource, version.clone(), payload.clone()))
}

pub(super) async fn update_action_resource(
    deps: &Deps,
    invocation: &Invocation,
    resource_id: &str,
    expected_current_version_id: String,
    lifecycle: &str,
    record: Value,
) -> Result<(EngineResource, EngineResourceVersion, Value), CapabilityError> {
    deps.engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.to_owned(),
            expected_current_version_id: Some(expected_current_version_id),
            lifecycle: Some(lifecycle.to_owned()),
            payload: record,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let inspection = inspect_resource_required(deps, resource_id, "context control action").await?;
    let (version, payload) = current_payload(&inspection, "context_control_action updated")?;
    Ok((
        inspection.resource.clone(),
        version.clone(),
        payload.clone(),
    ))
}

pub(super) async fn create_epoch_resource(
    deps: &Deps,
    invocation: &Invocation,
    resource_id: &str,
    record: Value,
    epoch_id: &str,
) -> Result<(EngineResource, EngineResourceVersion, Value), CapabilityError> {
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: CONTEXT_CONTROL_EPOCH_KIND.to_owned(),
            schema_id: Some(CONTEXT_CONTROL_EPOCH_SCHEMA_ID.to_owned()),
            scope: resource_scope_from_payload(&record)?,
            owner_worker_id: crate::engine::WorkerId::new(WORKER).map_err(id_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(CONTEXT_CONTROL_EPOCH_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "context_control_epoch".to_owned(),
                uri: format!("context-control-epoch:{epoch_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "context control epoch").await?;
    let (version, payload) = current_payload(&inspection, "context_control_epoch created")?;
    Ok((resource, version.clone(), payload.clone()))
}

pub(super) async fn create_policy_resource(
    deps: &Deps,
    invocation: &Invocation,
    resource_id: &str,
    kind: &str,
    schema_id: &str,
    lifecycle: &str,
    record: Value,
    uri: &str,
) -> Result<(EngineResource, EngineResourceVersion, Value), CapabilityError> {
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: kind.to_owned(),
            schema_id: Some(schema_id.to_owned()),
            scope: resource_scope_from_payload(&record)?,
            owner_worker_id: crate::engine::WorkerId::new(WORKER).map_err(id_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(lifecycle.to_owned()),
            policy: resource_policy(kind),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: kind.to_owned(),
                uri: uri.to_owned(),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "context policy").await?;
    let (version, payload) = current_payload(&inspection, "context policy created")?;
    Ok((resource, version.clone(), payload.clone()))
}

pub(super) async fn update_policy_resource(
    deps: &Deps,
    invocation: &Invocation,
    resource_id: &str,
    expected_current_version_id: String,
    record: Value,
) -> Result<EngineResourceVersion, CapabilityError> {
    deps.engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.to_owned(),
            expected_current_version_id: Some(expected_current_version_id),
            lifecycle: Some("disabled".to_owned()),
            payload: record,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

fn resource_scope_from_payload(payload: &Value) -> Result<EngineResourceScope, CapabilityError> {
    let kind = payload
        .pointer("/scope/kind")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("context control payload missing scope kind"))?;
    let value = payload
        .pointer("/scope/value")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("context control payload missing scope value"))?;
    match kind {
        "session" => Ok(EngineResourceScope::Session(value.to_owned())),
        "workspace" => Ok(EngineResourceScope::Workspace(value.to_owned())),
        "system" if value == "system" => Ok(EngineResourceScope::System),
        _ => Err(invalid("context control payload has invalid scope")),
    }
}

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

pub(super) fn ensure_context_snapshot(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        CONTEXT_CONTROL_SNAPSHOT_KIND,
        CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID,
    )
}

pub(super) fn ensure_context_action(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        CONTEXT_CONTROL_ACTION_KIND,
        CONTEXT_CONTROL_ACTION_SCHEMA_ID,
    )
}

pub(super) fn ensure_context_survivor(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        CONTEXT_SURVIVOR_KIND,
        CONTEXT_SURVIVOR_SCHEMA_ID,
    )
}

pub(super) fn ensure_context_exclusion(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        CONTEXT_EXCLUSION_KIND,
        CONTEXT_EXCLUSION_SCHEMA_ID,
    )
}

pub(super) fn ensure_context_policy_snapshot(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_kind_schema(
        inspection,
        operation,
        CONTEXT_POLICY_SNAPSHOT_KIND,
        CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID,
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
            "{operation} cannot access context-control records outside the current session"
        )));
    }
    Ok(())
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
            topic: CONTEXT_CONTROL_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "contextControlBoundary": {
                    "metadataOnly": true,
                    "providerSafe": true,
                    "networkPolicy": "none",
                    "agentStateTouched": false,
                    "stateInheritanceUsed": false,
                    "rawPromptBodiesStored": false,
                    "rawLogsStored": false,
                    "rawCommandsStored": false,
                    "secretsExposed": false,
                    "localPathsExposed": false
                }
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: match &resource.scope {
                EngineResourceScope::Session(session_id) => Some(session_id.clone()),
                _ => invocation.causal_context.session_id.clone(),
            },
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
}
