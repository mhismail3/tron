use serde_json::Value;

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::{
    EngineResource, EngineResourceInspection, EngineResourceScope, EngineResourceVersion,
    Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::Deps;
use super::projection::{ModuleActivityItem, ModuleActivityProjection};

const DEFAULT_LIMIT: usize = 40;
const MAX_LIMIT: usize = 100;
const MODULE_RESOURCE_KINDS: &[&str] = &[
    crate::engine::MODULE_MANIFEST_KIND,
    crate::engine::MODULE_PROPOSAL_KIND,
    crate::engine::MODULE_VALIDATION_REPORT_KIND,
    crate::engine::MODULE_INSTALL_REQUEST_KIND,
    crate::engine::MODULE_INSTALL_DECISION_KIND,
    crate::engine::MODULE_DEPENDENCY_REQUEST_KIND,
    crate::engine::MODULE_DEPENDENCY_DECISION_KIND,
    crate::engine::MODULE_DEPENDENCY_POLICY_KIND,
    crate::engine::MODULE_LIFECYCLE_STATE_KIND,
    crate::engine::MODULE_RUNTIME_STATE_KIND,
];

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "overview" => |invocation, deps| {
            overview_value(deps, invocation).await
        },
    ];
}

pub(crate) async fn overview_value(
    deps: &Deps,
    invocation: &Invocation,
) -> Result<Value, CapabilityError> {
    let scopes = readable_scopes(invocation);
    if scopes.is_empty() {
        return Err(invalid(
            "module_activity_overview requires trusted session or workspace context",
        ));
    }
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, MAX_LIMIT);
    let mut items = Vec::new();
    for kind in MODULE_RESOURCE_KINDS {
        for scope in &scopes {
            let resources = deps
                .engine_host
                .list_resources(ListResources {
                    kind: Some((*kind).to_owned()),
                    scope: Some(scope.clone()),
                    lifecycle: None,
                    limit: limit.saturating_add(1),
                })
                .await
                .map_err(engine_error)?;
            for resource in resources {
                if let Some((inspection, version, payload)) =
                    inspect_current_payload(deps, invocation, &resource).await?
                {
                    items.push(ModuleActivityItem::from_resource(
                        &inspection.resource,
                        &version,
                        &payload,
                    ));
                }
            }
        }
    }
    Ok(ModuleActivityProjection::from_items(items, limit).into_value())
}

async fn inspect_current_payload(
    deps: &Deps,
    invocation: &Invocation,
    resource: &EngineResource,
) -> Result<Option<(EngineResourceInspection, EngineResourceVersion, Value)>, CapabilityError> {
    let Some(inspection) = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
    else {
        return Ok(None);
    };
    if !MODULE_RESOURCE_KINDS.contains(&inspection.resource.kind.as_str()) {
        return Ok(None);
    }
    ensure_readable_scope(&inspection, invocation)?;
    let Some(version_id) = inspection.resource.current_version_id.as_deref() else {
        return Ok(None);
    };
    let Some(version) = inspection
        .versions
        .iter()
        .find(|version| version.version_id == version_id)
    else {
        return Ok(None);
    };
    if !version.state.may_be_current() {
        return Ok(None);
    }
    Ok(Some((
        inspection.clone(),
        version.clone(),
        version.payload.clone(),
    )))
}

fn readable_scopes(invocation: &Invocation) -> Vec<EngineResourceScope> {
    let mut scopes = Vec::new();
    if let Some(session) = &invocation.causal_context.session_id {
        scopes.push(EngineResourceScope::Session(session.clone()));
    }
    if let Some(workspace) = &invocation.causal_context.workspace_id {
        scopes.push(EngineResourceScope::Workspace(workspace.clone()));
    }
    scopes
}

fn ensure_readable_scope(
    inspection: &EngineResourceInspection,
    invocation: &Invocation,
) -> Result<(), CapabilityError> {
    match &inspection.resource.scope {
        EngineResourceScope::Session(session)
            if invocation.causal_context.session_id.as_ref() == Some(session) =>
        {
            Ok(())
        }
        EngineResourceScope::Workspace(workspace)
            if invocation.causal_context.workspace_id.as_ref() == Some(workspace) =>
        {
            Ok(())
        }
        _ => Err(invalid(
            "module_activity_overview cannot inspect module resources outside the current session/workspace scope",
        )),
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
