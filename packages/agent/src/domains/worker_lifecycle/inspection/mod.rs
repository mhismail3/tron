//! Read-only worker package lifecycle inspection.
//!
//! These projections are the provider-visible foundation for inspecting
//! host-owned worker lifecycle resources through `capability::execute`. They
//! intentionally do not install, enable, launch, stop, register, or execute
//! packages.

use serde_json::{Value, json};

use crate::engine::{
    ActorKind, EngineGrant, EngineHostHandle, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::{
    CONFORMANCE_KIND, INSTALLATION_KIND, LAUNCH_KIND, PACKAGE_KIND, PACKAGE_SCHEMA_VERSION,
    PROPOSAL_KIND,
};

mod projection;

use projection::{detail_projection, summary_projection};

const READ_SCOPE: &str = "worker.lifecycle.read";
const RESOURCE_READ_SCOPE: &str = "resource.read";
const LIST_LIMIT_DEFAULT: usize = 25;
const LIST_LIMIT_MAX: usize = 100;
const INSPECT_ARRAY_ITEMS_DEFAULT: usize = 25;
const INSPECT_ARRAY_ITEMS_MAX: usize = 100;
pub(super) const STRING_PREVIEW_BYTES: usize = 512;

const PACKAGE_SCHEMA_ID: &str = "tron.resource.worker_package.v1";
const INSTALLATION_SCHEMA_ID: &str = "tron.resource.worker_package_installation.v1";
const PROPOSAL_SCHEMA_ID: &str = "tron.resource.worker_package_proposal.v1";
const CONFORMANCE_SCHEMA_ID: &str = "tron.resource.worker_package_conformance_report.v1";
const LAUNCH_SCHEMA_ID: &str = "tron.resource.worker_launch_attempt.v1";

const SUPPORTED_KINDS: &[&str] = &[
    PACKAGE_KIND,
    INSTALLATION_KIND,
    PROPOSAL_KIND,
    CONFORMANCE_KIND,
    LAUNCH_KIND,
];

pub(crate) async fn list_worker_packages_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_session(invocation, "worker_package_list")?;
    let resource_kind =
        optional_string(payload, "workerPackageKind")?.unwrap_or_else(|| PACKAGE_KIND.to_owned());
    ensure_supported_kind(&resource_kind, "worker_package_list")?;
    let grant = inspect_read_grant(host, invocation, "worker_package_list").await?;
    require_read_kind_selector(&grant, &resource_kind, "worker_package_list")?;
    let lifecycle = optional_string(payload, "lifecycle")?;
    if let Some(lifecycle) = &lifecycle {
        validate_token(lifecycle, "lifecycle")?;
        if lifecycle == "archived" {
            return Err(invalid(
                "worker_package_list does not expose archived worker lifecycle resources",
            ));
        }
    }
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let scopes = readable_scopes(invocation);
    let mut resources = Vec::new();
    for scope in &scopes {
        let mut scoped = host
            .list_resources(ListResources {
                kind: Some(resource_kind.clone()),
                scope: Some(scope.clone()),
                lifecycle: lifecycle.clone(),
                limit: limit.saturating_add(1),
            })
            .await
            .map_err(engine_error)?;
        resources.append(&mut scoped);
        if resources.len() > limit {
            break;
        }
    }
    let truncated = resources.len() > limit;
    let mut records = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_worker_lifecycle_resource(&inspection, &resource_kind, "worker_package_list")?;
        ensure_readable_scope(&inspection, invocation, "worker_package_list")?;
        if is_archived_resource(&inspection) {
            continue;
        }
        let (version, current) = current_payload(&inspection, "worker_package_list")?;
        records.push(summary_projection(
            &inspection.resource,
            version,
            current,
            &resource_kind,
        ));
    }

    Ok(json!({
        "schemaVersion": PACKAGE_SCHEMA_VERSION,
        "operation": "worker_package_list",
        "scope": scope_projection(invocation),
        "resourceKind": resource_kind,
        "lifecycle": lifecycle,
        "records": records,
        "limits": {
            "requestedLimit": limit,
            "returned": records.len(),
            "truncated": truncated,
            "supportedKinds": SUPPORTED_KINDS
        },
        "activation": {
            "performed": false,
            "install": false,
            "enable": false,
            "launch": false,
            "stop": false,
            "registration": false,
            "execution": false
        },
        "network": {"performed": false, "requiredPolicy": "none"}
    }))
}

pub(crate) async fn inspect_worker_package_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_session(invocation, "worker_package_inspect")?;
    let resource_id = required_string(payload, "workerPackageResourceId")?;
    let expected_kind = kind_from_resource_id(&resource_id)?;
    let grant = inspect_read_grant(host, invocation, "worker_package_inspect").await?;
    require_read_kind_selector(&grant, expected_kind, "worker_package_inspect")?;
    let max_items = optional_u64(payload, "maxLifecycleItems")?
        .map(|value| value as usize)
        .unwrap_or(INSPECT_ARRAY_ITEMS_DEFAULT)
        .clamp(1, INSPECT_ARRAY_ITEMS_MAX);
    let inspection = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing worker lifecycle resource {resource_id}")))?;
    ensure_worker_lifecycle_resource(&inspection, expected_kind, "worker_package_inspect")?;
    ensure_readable_scope(&inspection, invocation, "worker_package_inspect")?;
    ensure_not_archived_resource(&inspection, "worker_package_inspect")?;
    let (version, current) = current_payload(&inspection, "worker_package_inspect")?;

    Ok(json!({
        "schemaVersion": PACKAGE_SCHEMA_VERSION,
        "operation": "worker_package_inspect",
        "scope": scope_projection(invocation),
        "resource": detail_projection(&inspection.resource, version, current, expected_kind, max_items),
        "limits": {"maxLifecycleItems": max_items, "stringPreviewBytes": STRING_PREVIEW_BYTES},
        "activation": {
            "performed": false,
            "install": false,
            "enable": false,
            "launch": false,
            "stop": false,
            "registration": false,
            "execution": false
        },
        "network": {"performed": false, "requiredPolicy": "none"}
    }))
}

async fn inspect_read_grant(
    host: &EngineHostHandle,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = host
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
    if grant
        .resource_selectors
        .iter()
        .any(|selector| selector == "*")
    {
        return Err(invalid(format!(
            "{operation} requires explicit resource selectors; wildcard grants are not accepted"
        )));
    }
    if !grant
        .resource_selectors
        .iter()
        .any(|selector| selector == &format!("kind:{resource_kind}"))
    {
        return Err(invalid(format!(
            "{operation} requires an explicit kind:{resource_kind} selector"
        )));
    }
    Ok(())
}

fn ensure_not_archived_resource(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if is_archived_resource(inspection) {
        return Err(invalid(format!(
            "{operation} does not expose archived worker lifecycle resources"
        )));
    }
    Ok(())
}

fn is_archived_resource(inspection: &EngineResourceInspection) -> bool {
    inspection.resource.lifecycle == "archived"
}

fn require_explicit_grant_item(
    items: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if items.iter().any(|item| item == "*") {
        return Err(invalid(format!(
            "{operation} requires explicit authority; wildcard grants are not accepted"
        )));
    }
    if items.iter().any(|item| item == required) {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} requires {required} authority"
        )))
    }
}

fn ensure_trusted_current_session(
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    let session_id = invocation
        .causal_context
        .session_id
        .as_deref()
        .ok_or_else(|| {
            invalid(format!(
                "{operation} requires trusted current session context"
            ))
        })?;
    match invocation.causal_context.actor_kind {
        ActorKind::Agent => {
            let expected = format!("agent:{session_id}");
            if invocation.causal_context.actor_id.as_str() != expected {
                return Err(invalid(format!(
                    "{operation} agent actor must match the current session"
                )));
            }
        }
        ActorKind::System => {}
        _ => {
            return Err(invalid(format!(
                "{operation} requires trusted agent or system context"
            )));
        }
    }
    Ok(())
}

fn ensure_worker_lifecycle_resource(
    inspection: &EngineResourceInspection,
    expected_kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    ensure_supported_kind(expected_kind, operation)?;
    let expected_schema = schema_id_for_kind(expected_kind)?;
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

fn ensure_readable_scope(
    inspection: &EngineResourceInspection,
    invocation: &Invocation,
    operation: &str,
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
        _ => Err(invalid(format!(
            "{operation} cannot inspect worker lifecycle resources outside the current session/workspace scope"
        ))),
    }
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

fn scope_projection(invocation: &Invocation) -> Value {
    json!({
        "session": invocation.causal_context.session_id,
        "workspace": invocation.causal_context.workspace_id
    })
}

fn kind_from_resource_id(resource_id: &str) -> Result<&'static str, CapabilityError> {
    for kind in SUPPORTED_KINDS {
        if resource_id.starts_with(&format!("{kind}:")) {
            return Ok(*kind);
        }
    }
    Err(invalid(
        "workerPackageResourceId has unsupported worker lifecycle resource kind",
    ))
}

fn ensure_supported_kind(kind: &str, operation: &str) -> Result<(), CapabilityError> {
    if SUPPORTED_KINDS.iter().any(|supported| supported == &kind) {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} supports only worker lifecycle resource kinds"
        )))
    }
}

fn schema_id_for_kind(kind: &str) -> Result<&'static str, CapabilityError> {
    match kind {
        PACKAGE_KIND => Ok(PACKAGE_SCHEMA_ID),
        INSTALLATION_KIND => Ok(INSTALLATION_SCHEMA_ID),
        PROPOSAL_KIND => Ok(PROPOSAL_SCHEMA_ID),
        CONFORMANCE_KIND => Ok(CONFORMANCE_SCHEMA_ID),
        LAUNCH_KIND => Ok(LAUNCH_SCHEMA_ID),
        _ => Err(invalid("unsupported worker lifecycle resource kind")),
    }
}

fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?
        .ok_or_else(|| invalid(format!("missing required field {field}")))
}

fn optional_string(payload: &Value, field: &str) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a non-negative integer"))),
        Some(_) => Err(invalid(format!("{field} must be a non-negative integer"))),
    }
}

fn validate_token(value: &str, label: &str) -> Result<(), CapabilityError> {
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        Ok(())
    } else {
        Err(invalid(format!("{label} is malformed")))
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Custom {
        code: "WORKER_PACKAGE_INSPECTION_ENGINE_ERROR".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
