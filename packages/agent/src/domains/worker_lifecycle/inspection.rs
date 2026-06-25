//! Read-only worker package lifecycle inspection.
//!
//! These projections are the provider-visible foundation for inspecting
//! host-owned worker lifecycle resources through `capability::execute`. They
//! intentionally do not install, enable, launch, stop, register, or execute
//! packages.

use serde_json::{Value, json};

use crate::engine::{
    ActorKind, EngineGrant, EngineHostHandle, EngineResource, EngineResourceInspection,
    EngineResourceScope, EngineResourceVersion, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::{
    CONFORMANCE_KIND, INSTALLATION_KIND, LAUNCH_KIND, PACKAGE_KIND, PACKAGE_SCHEMA_VERSION,
    PROPOSAL_KIND,
};

const READ_SCOPE: &str = "worker.lifecycle.read";
const RESOURCE_READ_SCOPE: &str = "resource.read";
const LIST_LIMIT_DEFAULT: usize = 25;
const LIST_LIMIT_MAX: usize = 100;
const INSPECT_ARRAY_ITEMS_DEFAULT: usize = 25;
const INSPECT_ARRAY_ITEMS_MAX: usize = 100;
const STRING_PREVIEW_BYTES: usize = 512;
const METADATA_MAX_DEPTH: usize = 4;
const METADATA_MAX_OBJECT_FIELDS: usize = 32;

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

fn summary_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    kind: &str,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageVersion": payload.get("packageVersion").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
        "state": payload.get("status").cloned().unwrap_or(Value::Null),
        "summary": summary_for_kind(payload, kind),
        "resourceRefs": [version_ref(resource, version, "worker_lifecycle")]
    })
}

fn detail_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    kind: &str,
    max_items: usize,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "identity": identity_projection(payload),
        "state": state_projection(payload),
        "provenance": safe_metadata(payload.get("provenance"), max_items),
        "source": source_projection(payload),
        "namespaceClaims": array_preview(payload.get("namespaceClaims"), max_items),
        "expectedFunctions": array_preview(payload.get("expectedFunctions"), max_items),
        "expectedTriggers": array_preview(payload.get("expectedTriggers"), max_items),
        "requestedGrants": requested_grants_projection(payload.get("requestedGrants")),
        "conformance": conformance_projection(payload, max_items),
        "launch": launch_projection(payload),
        "proposal": proposal_projection(payload),
        "installation": installation_projection(payload),
        "traceRefs": safe_metadata(payload.get("traceRefs"), max_items),
        "replayRefs": safe_metadata(payload.get("replayRefs"), max_items),
        "resourceRefs": [version_ref(resource, version, "worker_lifecycle")],
        "redaction": {
            "rawManifest": kind == PACKAGE_KIND || kind == PROPOSAL_KIND,
            "launchToken": true,
            "envValues": true,
            "localPaths": true,
            "endpoint": true,
            "tokenGrantId": true
        }
    })
}

fn identity_projection(payload: &Value) -> Value {
    json!({
        "packageId": payload.get("packageId").cloned().unwrap_or(Value::Null),
        "packageVersion": payload.get("packageVersion").cloned().unwrap_or(Value::Null),
        "packageDigest": payload.get("packageDigest").cloned().unwrap_or(Value::Null),
        "workerId": payload.get("workerId").cloned().unwrap_or(Value::Null),
        "packageResourceId": payload.get("packageResourceId").cloned().unwrap_or(Value::Null),
        "launchAttemptResourceId": payload.get("launchAttemptResourceId").cloned().unwrap_or(Value::Null),
        "conformanceReportResourceId": payload.get("conformanceReportResourceId").cloned().unwrap_or(Value::Null)
    })
}

fn state_projection(payload: &Value) -> Value {
    json!({
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "reason": string_preview(payload.get("reason")),
        "failure": safe_metadata(payload.get("failure"), INSPECT_ARRAY_ITEMS_DEFAULT),
        "ownershipLost": payload.get("ownershipLost").cloned().unwrap_or(Value::Null),
        "stopped": payload.get("stopped").cloned().unwrap_or(Value::Null)
    })
}

fn source_projection(payload: &Value) -> Value {
    let source = payload.get("source").cloned().unwrap_or(Value::Null);
    json!({
        "kind": source.get("kind").cloned().unwrap_or(Value::Null),
        "pathRedacted": source.get("path").is_some(),
        "metadata": source_without_paths(&source),
        "sourceRootRedacted": payload.get("sourceRoot").is_some(),
        "workingDirectoryRedacted": payload.get("workingDirectory").is_some(),
        "launchCommandRedacted": payload.get("launchCommand").is_some() || payload.get("argv").is_some(),
        "envAllowlistCount": payload.get("envAllowlist").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len())),
        "envKeyCount": payload.get("envKeys").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len()))
    })
}

fn source_without_paths(source: &Value) -> Value {
    let mut source = source.clone();
    if let Some(object) = source.as_object_mut() {
        object.retain(|key, _| {
            let lower = key.to_ascii_lowercase();
            !lower.contains("path") && !lower.contains("root") && lower != "workingdirectory"
        });
    }
    source
}

fn requested_grants_projection(value: Option<&Value>) -> Value {
    let Some(value) = value else {
        return Value::Null;
    };
    json!({
        "authorityScopes": array_preview(value.get("authorityScopes"), INSPECT_ARRAY_ITEMS_DEFAULT),
        "resourceKinds": array_preview(value.get("resourceKinds"), INSPECT_ARRAY_ITEMS_DEFAULT),
        "fileRootCount": value.get("fileRoots").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len())),
        "fileRootsRedacted": value.get("fileRoots").is_some(),
        "networkPolicy": value.get("networkPolicy").cloned().unwrap_or(Value::Null),
        "maxRisk": value.get("maxRisk").cloned().unwrap_or(Value::Null),
        "budget": value.get("budget").cloned().unwrap_or(Value::Null)
    })
}

fn conformance_projection(payload: &Value, max_items: usize) -> Value {
    json!({
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "checks": safe_array_preview(payload.get("checks"), max_items),
        "policy": safe_metadata(payload.get("conformancePolicy"), max_items),
        "catalogRevision": payload.get("catalogRevision").cloned().unwrap_or(Value::Null),
        "launchAttemptResourceId": payload.get("launchAttemptResourceId").cloned().unwrap_or(Value::Null)
    })
}

fn launch_projection(payload: &Value) -> Value {
    json!({
        "status": payload.get("status").cloned().unwrap_or(Value::Null),
        "processId": payload.get("processId").cloned().unwrap_or(Value::Null),
        "argvRedacted": payload.get("argv").is_some(),
        "workingDirectoryRedacted": payload.get("workingDirectory").is_some(),
        "endpointRedacted": payload.get("endpoint").is_some(),
        "tokenGrantIdRedacted": payload.get("tokenGrantId").is_some(),
        "envKeyCount": payload.get("envKeys").and_then(Value::as_array).map_or(Value::Null, |items| json!(items.len()))
    })
}

fn proposal_projection(payload: &Value) -> Value {
    json!({
        "summary": string_preview(payload.get("summary")),
        "proposedBy": string_preview(payload.get("proposedBy")),
        "manifestRedacted": payload.get("manifest").is_some()
    })
}

fn installation_projection(payload: &Value) -> Value {
    json!({
        "packageResourceId": payload.get("packageResourceId").cloned().unwrap_or(Value::Null),
        "rollbackRef": payload.get("rollbackRef").cloned().unwrap_or(Value::Null),
        "authorityGrantId": payload.get("authorityGrantId").cloned().unwrap_or(Value::Null)
    })
}

fn summary_for_kind(payload: &Value, kind: &str) -> Value {
    match kind {
        PROPOSAL_KIND => string_preview(payload.get("summary")),
        CONFORMANCE_KIND => json!({
            "status": payload.get("status").cloned().unwrap_or(Value::Null),
            "checkCount": payload.get("checks").and_then(Value::as_array).map_or(0, Vec::len)
        }),
        LAUNCH_KIND => json!({
            "status": payload.get("status").cloned().unwrap_or(Value::Null),
            "processId": payload.get("processId").cloned().unwrap_or(Value::Null)
        }),
        _ => Value::Null,
    }
}

fn array_preview(value: Option<&Value>, max_items: usize) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"items": [], "total": 0, "truncated": false, "maxItems": max_items});
    };
    json!({
        "items": items.iter().take(max_items).cloned().collect::<Vec<_>>(),
        "total": items.len(),
        "truncated": items.len() > max_items,
        "maxItems": max_items
    })
}

fn safe_array_preview(value: Option<&Value>, max_items: usize) -> Value {
    let Some(Value::Array(items)) = value else {
        return json!({"items": [], "total": 0, "truncated": false, "maxItems": max_items});
    };
    json!({
        "items": items
            .iter()
            .take(max_items)
            .map(|item| safe_metadata_value(item, max_items, 0))
            .collect::<Vec<_>>(),
        "total": items.len(),
        "truncated": items.len() > max_items,
        "maxItems": max_items
    })
}

fn safe_metadata(value: Option<&Value>, max_items: usize) -> Value {
    value
        .map(|value| safe_metadata_value(value, max_items, 0))
        .unwrap_or(Value::Null)
}

fn safe_metadata_value(value: &Value, max_items: usize, depth: usize) -> Value {
    if depth >= METADATA_MAX_DEPTH {
        return json!({"truncated": true, "reason": "maxDepth"});
    }
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => value.clone(),
        Value::String(text) => safe_string_preview(text),
        Value::Array(items) => json!({
            "items": items
                .iter()
                .take(max_items)
                .map(|item| safe_metadata_value(item, max_items, depth + 1))
                .collect::<Vec<_>>(),
            "total": items.len(),
            "truncated": items.len() > max_items,
            "maxItems": max_items
        }),
        Value::Object(object) => {
            let mut projected = serde_json::Map::new();
            for (key, value) in object.iter().take(METADATA_MAX_OBJECT_FIELDS) {
                if sensitive_metadata_key(key) {
                    projected.insert(key.clone(), json!({"redacted": true}));
                } else {
                    projected.insert(
                        key.clone(),
                        safe_metadata_value(value, max_items, depth + 1),
                    );
                }
            }
            if object.len() > METADATA_MAX_OBJECT_FIELDS {
                projected.insert(
                    "truncated".to_owned(),
                    json!({
                        "fieldCount": object.len(),
                        "maxFields": METADATA_MAX_OBJECT_FIELDS
                    }),
                );
            }
            Value::Object(projected)
        }
    }
}

fn safe_string_preview(text: &str) -> Value {
    let lower = text.to_ascii_lowercase();
    if lower.contains("secret")
        || lower.contains("token")
        || lower.contains("password")
        || lower.contains("credential")
        || lower.contains("apikey")
        || lower.contains("api_key")
        || lower.contains("/private/")
        || lower.contains("/users/")
    {
        return json!({"redacted": true, "bytes": text.len()});
    }
    let bounded = bounded_utf8(text, STRING_PREVIEW_BYTES);
    json!({
        "text": bounded.text,
        "bytes": text.len(),
        "truncated": bounded.truncated,
        "maxBytes": STRING_PREVIEW_BYTES
    })
}

fn sensitive_metadata_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    lower.contains("secret")
        || lower.contains("token")
        || lower.contains("password")
        || lower.contains("credential")
        || lower.contains("apikey")
        || lower.contains("api_key")
        || lower.contains("env")
        || lower.contains("path")
        || lower.contains("root")
        || lower.contains("endpoint")
        || lower == "argv"
        || lower.contains("command")
        || lower.contains("manifest")
}

fn string_preview(value: Option<&Value>) -> Value {
    let Some(Value::String(text)) = value else {
        return Value::Null;
    };
    let bounded = bounded_utf8(text, STRING_PREVIEW_BYTES);
    json!({
        "text": bounded.text,
        "bytes": text.len(),
        "truncated": bounded.truncated,
        "maxBytes": STRING_PREVIEW_BYTES
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
