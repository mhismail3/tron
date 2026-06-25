//! Resource-backed procedural state list and inspect behavior.

use serde_json::{Value, json};

use crate::engine::{
    ActorKind, EngineGrant, EngineHostHandle, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::{PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID, READ_SCOPE, SCHEMA_VERSION};
use crate::domains::procedural::projection::{
    STRING_PREVIEW_BYTES, detail_projection, summary_projection,
};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const LIST_LIMIT_DEFAULT: usize = 25;
const LIST_LIMIT_MAX: usize = 100;
const INSPECT_ARRAY_ITEMS_DEFAULT: usize = 25;
const INSPECT_ARRAY_ITEMS_MAX: usize = 100;
const SUPPORTED_PROCEDURAL_KINDS: &[&str] = &["skill", "rule", "hook", "procedure"];
const READABLE_LIFECYCLES: &[&str] = &["draft", "candidate", "validated"];

pub(crate) async fn list_procedural_state_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_scope(invocation, "procedural_state_list")?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_read_grant(host, invocation, "procedural_state_list").await?;
    require_read_selectors(&grant, &procedural_kind, "procedural_state_list")?;
    let lifecycle = optional_string(payload, "lifecycle")?;
    if let Some(lifecycle) = &lifecycle {
        validate_token(lifecycle, "lifecycle")?;
        ensure_readable_lifecycle(lifecycle, "procedural_state_list")?;
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
                kind: Some(PROCEDURAL_RECORD_KIND.to_owned()),
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
    for resource in resources {
        if records.len() >= limit {
            break;
        }
        let Some(inspection) = host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            return Err(invalid(format!(
                "procedural_state_list missing listed resource {}",
                resource.resource_id
            )));
        };
        ensure_procedural_record(&inspection, "procedural_state_list")?;
        ensure_readable_scope(&inspection, invocation, "procedural_state_list")?;
        let (version, current) = current_payload(&inspection, "procedural_state_list")?;
        if let Some(stored_kind) = current.get("proceduralKind").and_then(Value::as_str)
            && SUPPORTED_PROCEDURAL_KINDS
                .iter()
                .any(|supported| supported == &stored_kind)
            && stored_kind != procedural_kind
        {
            continue;
        }
        validate_record_payload(current, &procedural_kind, "procedural_state_list")?;
        ensure_readable_lifecycle(&inspection.resource.lifecycle, "procedural_state_list")?;
        records.push(summary_projection(&inspection.resource, version, current));
    }

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "procedural_state_list",
        "scope": scope_projection(invocation),
        "proceduralKind": procedural_kind,
        "records": records,
        "limits": {
            "requestedLimit": limit,
            "returned": records.len(),
            "truncated": truncated,
            "supportedProceduralKinds": SUPPORTED_PROCEDURAL_KINDS
        },
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
    }))
}

pub(crate) async fn inspect_procedural_state_value(
    host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_trusted_current_scope(invocation, "procedural_state_inspect")?;
    let resource_id = required_string(payload, "proceduralRecordResourceId")?;
    let procedural_kind = required_procedural_kind(payload)?;
    let grant = inspect_read_grant(host, invocation, "procedural_state_inspect").await?;
    require_read_selectors(&grant, &procedural_kind, "procedural_state_inspect")?;
    let max_items = optional_u64(payload, "maxEvidenceItems")?
        .map(|value| value as usize)
        .unwrap_or(INSPECT_ARRAY_ITEMS_DEFAULT)
        .clamp(1, INSPECT_ARRAY_ITEMS_MAX);
    let inspection = host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing procedural record {resource_id}")))?;
    ensure_procedural_record(&inspection, "procedural_state_inspect")?;
    ensure_readable_scope(&inspection, invocation, "procedural_state_inspect")?;
    ensure_readable_lifecycle(&inspection.resource.lifecycle, "procedural_state_inspect")?;
    let (version, current) = current_payload(&inspection, "procedural_state_inspect")?;
    validate_record_payload(current, &procedural_kind, "procedural_state_inspect")?;

    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "procedural_state_inspect",
        "scope": scope_projection(invocation),
        "resource": detail_projection(&inspection.resource, version, current, max_items),
        "limits": {"maxEvidenceItems": max_items, "stringPreviewBytes": STRING_PREVIEW_BYTES},
        "activation": activation_proof(),
        "network": {"performed": false, "requiredPolicy": "none"},
        "redacted": true
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
    require_explicit_grant_item(
        &grant.allowed_resource_kinds,
        PROCEDURAL_RECORD_KIND,
        operation,
    )?;
    if grant.network_policy != "none" {
        return Err(invalid(format!("{operation} requires networkPolicy none")));
    }
    Ok(grant)
}

fn require_read_selectors(
    grant: &EngineGrant,
    procedural_kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if grant
        .resource_selectors
        .iter()
        .any(|selector| selector == "*")
    {
        return Err(invalid(format!(
            "{operation} requires explicit resource selectors; wildcard grants are not accepted"
        )));
    }
    for required in [
        format!("kind:{PROCEDURAL_RECORD_KIND}"),
        format!("proceduralKind:{procedural_kind}"),
    ] {
        if !grant
            .resource_selectors
            .iter()
            .any(|selector| selector == &required)
        {
            return Err(invalid(format!(
                "{operation} requires an explicit {required} selector"
            )));
        }
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

fn ensure_trusted_current_scope(
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
    if invocation.causal_context.workspace_id.is_none() {
        return Err(invalid(format!(
            "{operation} requires trusted current workspace context"
        )));
    }
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

fn ensure_procedural_record(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != PROCEDURAL_RECORD_KIND {
        return Err(invalid(format!(
            "{operation} expected {PROCEDURAL_RECORD_KIND}"
        )));
    }
    if inspection.resource.schema_id.as_str() != PROCEDURAL_RECORD_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {PROCEDURAL_RECORD_SCHEMA_ID}"
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
            "{operation} cannot inspect procedural records outside the current session/workspace scope"
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

fn validate_record_payload(
    payload: &Value,
    expected_kind: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    let object = payload
        .as_object()
        .ok_or_else(|| invalid(format!("{operation} procedural payload must be an object")))?;
    for required in [
        "schemaVersion",
        "proceduralKind",
        "identity",
        "summary",
        "status",
        "provenance",
        "eval",
        "activation",
        "sourceRefs",
        "traceRefs",
        "replayRefs",
        "revision",
    ] {
        if !object.contains_key(required) {
            return Err(invalid(format!(
                "{operation} malformed procedural payload missing {required}"
            )));
        }
    }
    if payload.get("schemaVersion").and_then(Value::as_str) != Some(SCHEMA_VERSION) {
        return Err(invalid(format!(
            "{operation} expected payload schemaVersion {SCHEMA_VERSION}"
        )));
    }
    if payload.get("proceduralKind").and_then(Value::as_str) != Some(expected_kind) {
        return Err(invalid(format!(
            "{operation} procedural kind mismatch for {expected_kind}"
        )));
    }
    if !matches!(payload.get("identity"), Some(Value::Object(_))) {
        return Err(invalid(format!(
            "{operation} procedural identity must be an object"
        )));
    }
    for field in ["provenance", "eval", "activation"] {
        if !matches!(payload.get(field), Some(Value::Object(_))) {
            return Err(invalid(format!(
                "{operation} procedural {field} must be an object"
            )));
        }
    }
    for field in ["sourceRefs", "traceRefs", "replayRefs"] {
        if !matches!(payload.get(field), Some(Value::Array(_))) {
            return Err(invalid(format!(
                "{operation} procedural {field} must be an array"
            )));
        }
    }
    let status = payload
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{operation} procedural status must be a string")))?;
    ensure_readable_lifecycle(status, operation)?;
    Ok(())
}

fn ensure_readable_lifecycle(lifecycle: &str, operation: &str) -> Result<(), CapabilityError> {
    if READABLE_LIFECYCLES.iter().any(|state| state == &lifecycle) {
        Ok(())
    } else if matches!(lifecycle, "disabled" | "stale" | "archived") {
        Err(invalid(format!(
            "{operation} does not expose {lifecycle} procedural records"
        )))
    } else {
        Err(invalid(format!(
            "{operation} unsupported procedural lifecycle {lifecycle}"
        )))
    }
}

fn scope_projection(invocation: &Invocation) -> Value {
    json!({
        "session": invocation.causal_context.session_id,
        "workspace": invocation.causal_context.workspace_id
    })
}

fn activation_proof() -> Value {
    json!({
        "performed": false,
        "skillActivated": false,
        "ruleApplied": false,
        "hookFired": false,
        "procedureExecuted": false,
        "triggerRegistered": false,
        "promptInjected": false,
        "learnedBehavior": false,
        "autonomousExecution": false,
        "toolExecution": false,
        "workerStarted": false,
        "jobStarted": false,
        "processStarted": false,
        "networkStarted": false,
        "packageInstalled": false,
        "catalogRegistered": false
    })
}

fn required_procedural_kind(payload: &Value) -> Result<String, CapabilityError> {
    let kind = required_string(payload, "proceduralKind")?;
    if SUPPORTED_PROCEDURAL_KINDS
        .iter()
        .any(|supported| supported == &kind)
    {
        Ok(kind)
    } else {
        Err(invalid(
            "proceduralKind must be skill, rule, hook, or procedure",
        ))
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
        code: "PROCEDURAL_INSPECTION_ENGINE_ERROR".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use serde_json::{Value, json};

    pub(crate) fn procedural_payload(procedural_kind: &str, summary: &str, status: &str) -> Value {
        json!({
            "schemaVersion": super::SCHEMA_VERSION,
            "proceduralKind": procedural_kind,
            "identity": {
                "id": format!("{procedural_kind}.demo"),
                "name": format!("Demo {procedural_kind}"),
                "version": "1.0.0",
                "namespace": "procedural.demo"
            },
            "summary": summary,
            "status": status,
            "provenance": {
                "source": "test",
                "authorityGrantId": "grant-procedural-secret-123",
                "sourcePath": "/Users/example/private/procedure.md",
                "nested": {
                    "credential": "secret-token",
                    "grant_id": "grant-procedural-nested-123",
                    "note": "reviewed"
                }
            },
            "eval": {
                "status": "passed",
                "profile": "schema-only",
                "lastRunAt": "2026-06-25T00:00:00Z",
                "failure": {"message": "failed with grant-procedural-failure at /private/path"}
            },
            "activation": {
                "available": false,
                "reason": "inspection_only"
            },
            "sourceRefs": [{"resourceId": "evidence:one", "path": "/private/path"}],
            "traceRefs": [{"traceId": "trace-procedural", "grantId": "grant-procedural-trace"}],
            "replayRefs": [{"replayId": "replay-procedural", "authority_grant_id": "grant-procedural-replay"}],
            "revision": 1,
            "body": "raw secret procedure body",
            "manifest": {"raw": "raw manifest"},
            "implementation": {"command": "run dangerous thing"},
            "contentRef": {"uri": "/private/procedural/body.md"},
            "contentHash": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        })
    }
}
