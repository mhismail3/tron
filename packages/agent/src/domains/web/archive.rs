//! Web source archive lifecycle updates.

use chrono::Utc;
use serde_json::{Value, json};

use crate::engine::{
    EngineGrant, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, PublishStreamEvent, UpdateResource, VisibilityScope,
    WEB_SOURCE_KIND, WEB_SOURCE_SCHEMA_ID,
};
use crate::shared::server::errors::CapabilityError;

use super::{
    Deps, READ_SCOPE, WEB_LIFECYCLE_TOPIC, WEB_SOURCE_SCHEMA_VERSION, WORKER, WRITE_SCOPE,
};

const RESOURCE_READ_SCOPE: &str = "resource.read";
const RESOURCE_WRITE_SCOPE: &str = "resource.write";
const WEB_SOURCE_ID_PREFIX: &str = "web_source:";
const MAX_REASON_BYTES: usize = 512;

pub(crate) async fn web_source_archive_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_archive_grant(deps, invocation).await?;
    let request = ArchiveRequest::parse(payload)?;
    let scope = session_resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&request.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("web_source_archive webSourceResourceId was not found"))?;
    ensure_web_source(&inspection, "web_source_archive")?;
    ensure_scope(&inspection, &scope, "web_source_archive")?;
    let current = current_version(&inspection, "web_source_archive")?;
    if let Some(value) =
        idempotent_archive_replay(&inspection, current, &request, "web_source_archive")?
    {
        return Ok(value);
    }
    if !inspection
        .versions
        .iter()
        .any(|version| version.version_id == request.expected_version_id)
    {
        return Err(invalid(
            "web_source_archive expectedWebSourceVersionId was not found for this resource",
        ));
    }
    if current.version_id != request.expected_version_id {
        return Err(invalid(
            "web_source_archive expectedWebSourceVersionId is stale; inspect the current version",
        ));
    }
    if !current.state.may_be_current() {
        return Err(invalid(
            "web_source_archive current version is not available",
        ));
    }
    if current.payload.get("state").and_then(Value::as_str) == Some("archived")
        || inspection.resource.lifecycle == "archived"
    {
        return Err(invalid("web_source_archive source is already archived"));
    }

    let archived_at = Utc::now().to_rfc3339();
    let mut archived_payload = current.payload.clone();
    let Some(object) = archived_payload.as_object_mut() else {
        return Err(invalid(
            "web_source_archive web_source payload must be an object",
        ));
    };
    object.insert("state".to_owned(), json!("archived"));
    object.insert(
        "revision".to_owned(),
        json!(
            current
                .payload
                .get("revision")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .saturating_add(1)
        ),
    );
    object.insert(
        "archive".to_owned(),
        archive_metadata(&request, invocation, &grant, &archived_at),
    );

    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: request.resource_id.clone(),
            expected_current_version_id: Some(request.expected_version_id.clone()),
            lifecycle: Some("archived".to_owned()),
            payload: archived_payload,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let updated = deps
        .engine_host
        .inspect_resource(&request.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| internal("web_source_archive updated resource disappeared"))?;
    let cursor = publish_archive_event(deps, invocation, &updated.resource, &version).await?;
    Ok(archive_result(
        &updated.resource,
        &version,
        &request,
        cursor.0,
        false,
    ))
}

struct ArchiveRequest {
    resource_id: String,
    expected_version_id: String,
    reason: String,
    idempotency_key: String,
}

impl ArchiveRequest {
    fn parse(payload: &Value) -> Result<Self, CapabilityError> {
        let resource_id = required_string(payload, "webSourceResourceId")?;
        validate_web_source_id(&resource_id)?;
        let expected_version_id = required_string(payload, "expectedWebSourceVersionId")?;
        validate_version_id("expectedWebSourceVersionId", &expected_version_id)?;
        let reason = required_bounded_string(payload, "reason", MAX_REASON_BYTES)?;
        let idempotency_key = required_string(payload, "idempotencyKey")?;
        validate_version_id("idempotencyKey", &idempotency_key)?;
        Ok(Self {
            resource_id,
            expected_version_id,
            reason,
            idempotency_key,
        })
    }
}

async fn inspect_archive_grant(
    deps: &Deps,
    invocation: &Invocation,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(|error| {
            internal(format!(
                "inspect web source archive authority grant: {error}"
            ))
        })?
        .ok_or_else(|| invalid("web_source_archive authority grant was not found"))?;
    if grant.network_policy != "none" {
        return Err(invalid(
            "web_source_archive requires an authority grant with networkPolicy none",
        ));
    }
    for (items, required, label) in [
        (
            &grant.allowed_authority_scopes,
            READ_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_authority_scopes,
            WRITE_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_authority_scopes,
            RESOURCE_READ_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_authority_scopes,
            RESOURCE_WRITE_SCOPE,
            "authority scope",
        ),
        (
            &grant.allowed_resource_kinds,
            WEB_SOURCE_KIND,
            "resource kind",
        ),
    ] {
        require_grant_item(items, required, label, "web_source_archive")?;
    }
    if !allows_item(&grant.resource_selectors, "*")
        && !allows_item(
            &grant.resource_selectors,
            &format!("kind:{WEB_SOURCE_KIND}"),
        )
    {
        return Err(invalid(format!(
            "web_source_archive requires a grant selector for kind:{WEB_SOURCE_KIND}"
        )));
    }
    Ok(grant)
}

fn idempotent_archive_replay(
    inspection: &EngineResourceInspection,
    current: &EngineResourceVersion,
    request: &ArchiveRequest,
    operation: &str,
) -> Result<Option<Value>, CapabilityError> {
    let archive = current.payload.get("archive");
    let matches_replay = inspection.resource.lifecycle == "archived"
        && current.payload.get("state").and_then(Value::as_str) == Some("archived")
        && archive
            .and_then(|value| value.pointer("/idempotency/key"))
            .and_then(Value::as_str)
            == Some(request.idempotency_key.as_str())
        && archive
            .and_then(|value| value.get("previousVersionId"))
            .and_then(Value::as_str)
            == Some(request.expected_version_id.as_str());
    if matches_replay {
        return Ok(Some(archive_result(
            &inspection.resource,
            current,
            request,
            0,
            true,
        )));
    }
    if inspection.resource.lifecycle == "archived" {
        return Err(invalid(format!(
            "{operation} source is already archived with a different idempotency key or expected version"
        )));
    }
    Ok(None)
}

fn archive_metadata(
    request: &ArchiveRequest,
    invocation: &Invocation,
    grant: &EngineGrant,
    archived_at: &str,
) -> Value {
    json!({
        "archivedAt": archived_at,
        "reason": request.reason,
        "previousVersionId": request.expected_version_id,
        "archivedBy": {
            "actorId": invocation.causal_context.actor_id.as_str(),
            "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
            "grantId": grant.grant_id.as_str(),
            "networkPolicy": grant.network_policy,
            "authorityScopes": invocation.causal_context.authority_scopes,
            "resourceKind": WEB_SOURCE_KIND
        },
        "retentionPolicy": {
            "state": "archived",
            "deletesSourceEvidence": false,
            "prunesCachedBytes": false,
            "automaticTtlCleanup": false
        },
        "idempotency": {
            "key": request.idempotency_key,
            "invocationId": invocation.id.as_str(),
            "functionId": invocation.function_id.as_str()
        },
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "revision": 1
    })
}

fn archive_result(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    request: &ArchiveRequest,
    stream_cursor: u64,
    replayed: bool,
) -> Value {
    json!({
        "schemaVersion": WEB_SOURCE_SCHEMA_VERSION,
        "status": "archived",
        "operation": "web_source_archive",
        "webSourceResourceId": resource.resource_id,
        "webSourceVersionId": version.version_id,
        "previousWebSourceVersionId": request.expected_version_id,
        "reason": request.reason,
        "streamCursor": stream_cursor,
        "cache": {
            "hit": replayed,
            "resourceId": resource.resource_id
        },
        "resourceRefs": [{
            "role": "source_archive",
            "kind": resource.kind,
            "resourceId": resource.resource_id,
            "versionId": version.version_id,
            "schemaId": resource.schema_id,
            "lifecycle": resource.lifecycle,
            "contentHash": version.content_hash
        }],
        "network": {"performed": false, "requiredPolicy": "none"}
    })
}

async fn publish_archive_event(
    deps: &Deps,
    invocation: &Invocation,
    resource: &EngineResource,
    version: &EngineResourceVersion,
) -> Result<crate::engine::StreamCursor, CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: WEB_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": "web.archived",
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
                "actorId": invocation.causal_context.actor_id.as_str(),
                "payload": {
                    "webSourceResourceId": resource.resource_id,
                    "webSourceVersionId": version.version_id,
                    "previousWebSourceVersionId": version.parent_version_id,
                    "resourceRefs": [{
                        "role": "source_archive",
                        "kind": resource.kind,
                        "resourceId": resource.resource_id,
                        "versionId": version.version_id,
                        "schemaId": resource.schema_id,
                        "lifecycle": resource.lifecycle,
                        "contentHash": version.content_hash
                    }]
                }
            }),
            visibility: VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

fn ensure_web_source(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != WEB_SOURCE_KIND {
        return Err(invalid(format!(
            "{operation} resource kind mismatch: expected {WEB_SOURCE_KIND}"
        )));
    }
    if inspection.resource.schema_id != WEB_SOURCE_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} resource schema mismatch: expected {WEB_SOURCE_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope == expected {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} cannot archive a web_source outside the current session scope"
        )))
    }
}

fn current_version<'a>(
    inspection: &'a EngineResourceInspection,
    operation: &str,
) -> Result<&'a EngineResourceVersion, CapabilityError> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid(format!("{operation} web_source has no current version")))?;
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid(format!("{operation} current version is missing")))
}

fn session_resource_scope(invocation: &Invocation) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .ok_or_else(|| invalid("web_source_archive requires trusted current session context"))
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "functionId": invocation.function_id.as_str()
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "engine_invocation",
        "invocationId": invocation.id.as_str(),
        "traceId": invocation.causal_context.trace_id.as_str()
    })]
}

fn require_grant_item(
    items: &[String],
    required: &str,
    label: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if allows_item(items, required) {
        Ok(())
    } else {
        Err(invalid(format!("{operation} requires {label} {required}")))
    }
}

fn allows_item(items: &[String], required: &str) -> bool {
    items.iter().any(|item| item == "*" || item == required)
}

fn validate_web_source_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(WEB_SOURCE_ID_PREFIX) {
        return Err(invalid(format!(
            "webSourceResourceId must start with {WEB_SOURCE_ID_PREFIX}"
        )));
    }
    validate_token("webSourceResourceId", value, 180)
}

fn validate_version_id(field: &str, value: &str) -> Result<(), CapabilityError> {
    validate_token(field, value, 180)
}

fn validate_token(field: &str, value: &str, max_len: usize) -> Result<(), CapabilityError> {
    if value.is_empty()
        || value.len() > max_len
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid(format!("{field} is malformed")));
    }
    Ok(())
}

fn required_bounded_string(
    payload: &Value,
    field: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let value = required_string(payload, field)?;
    if value.len() > max_bytes {
        return Err(invalid(format!("{field} exceeds {max_bytes} bytes")));
    }
    Ok(value)
}

fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    match payload.get(field) {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(value.trim().to_owned()),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
        None => Err(invalid(format!("{field} is required"))),
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
