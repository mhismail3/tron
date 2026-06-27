use serde_json::{Value, json};

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::{
    EngineResource, EngineResourceInspection, EngineResourceVersion, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::projection::{ModuleActivityItem, ModuleActivityProjection};
use super::{Deps, contract};

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
            overview_value(deps, &invocation.payload).await
        },
    ];
}

pub(crate) async fn overview_value(deps: &Deps, payload: &Value) -> Result<Value, CapabilityError> {
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, MAX_LIMIT);
    let mut items = Vec::new();
    for kind in MODULE_RESOURCE_KINDS {
        let resources = deps
            .engine_host
            .list_resources(ListResources {
                kind: Some((*kind).to_owned()),
                scope: None,
                lifecycle: None,
                limit: limit.saturating_add(1),
            })
            .await
            .map_err(engine_error)?;
        for resource in resources {
            if let Some((inspection, version, payload)) =
                inspect_current_payload(deps, &resource).await?
            {
                items.push(ModuleActivityItem::from_resource(
                    &inspection.resource,
                    &version,
                    &payload,
                ));
            }
        }
    }
    Ok(ModuleActivityProjection::from_items(items, limit).into_value())
}

async fn inspect_current_payload(
    deps: &Deps,
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

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

#[allow(dead_code)]
fn _schema_marker() -> Value {
    json!({"schemaVersion": contract::SCHEMA_VERSION})
}
