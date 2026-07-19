use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{ActorKind, EngineResource, PublishStreamEvent, WorkerId};
use crate::engine::{
    EngineGrant, EngineResourceInspection, EngineResourceScope, EngineResourceVersion, Invocation,
};
use crate::shared::server::errors::CapabilityError;

use super::contract::{
    DEVICE_LIFECYCLE_TOPIC, RESOURCE_WRITE_SCOPE, SCHEMA_VERSION, WORKER, WRITE_SCOPE,
};
use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE};
use super::validation::*;
use super::{DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, Deps};
use crate::domains::notifications::contract::EVENT_FAMILIES;

pub(super) struct RegistrationRecordInput<'a> {
    pub(super) state: &'a str,
    pub(super) device_id: &'a str,
    pub(super) platform: &'a str,
    pub(super) label: Option<&'a str>,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) environment: &'a str,
    pub(super) bundle_id: &'a str,
    pub(super) token_hash: &'a str,
    pub(super) transport_enabled: bool,
    pub(super) push_opt_in: bool,
    pub(super) push_enabled: bool,
    pub(super) event_families: Vec<String>,
    pub(super) retention: Value,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
    pub(super) revision: u64,
}

pub(super) fn registration_record(input: RegistrationRecordInput<'_>) -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "state": input.state,
        "deviceId": input.device_id,
        "platform": input.platform,
        "label": input.label,
        "scope": scope_ref(input.scope),
        "apns": {
            "environment": input.environment,
            "bundleId": input.bundle_id,
            "tokenHash": input.token_hash,
            "tokenStorage": "private_transport_store",
            "liveApnsEnabled": input.transport_enabled,
            "registeredAt": input.updated_at
        },
        "notificationPolicy": {
            "optIn": input.push_opt_in,
            "pushEnabled": input.push_enabled,
            "defaultPushEnabled": false,
            "liveApnsEnabled": input.transport_enabled,
            "eventFamilies": input.event_families,
            "badgePolicy": {
                "mode": "unread_count",
                "scope": "current_resource_scope",
                "readClears": true
            }
        },
        "retention": input.retention,
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "unregistered": Value::Null,
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(input.invocation),
        "idempotency": {
            "key": input.idempotency_key,
            "invocationId": input.invocation.id.as_str(),
            "functionId": input.invocation.function_id.as_str()
        },
        "revision": input.revision
    })
}

pub(super) fn event_families(payload: &Value) -> Result<Vec<String>, CapabilityError> {
    let values = optional_string_array(payload, "eventFamilies", EVENT_FAMILIES.len())?
        .unwrap_or_else(|| {
            EVENT_FAMILIES
                .iter()
                .map(|value| (*value).to_owned())
                .collect()
        });
    let mut families = Vec::with_capacity(values.len());
    for value in values {
        let family = bounded_token("eventFamilies", &value, 64)?;
        if !EVENT_FAMILIES.iter().any(|allowed| *allowed == family) {
            return Err(invalid(format!(
                "unsupported notification event family {family}"
            )));
        }
        if !families.contains(&family) {
            families.push(family);
        }
    }
    if families.is_empty() {
        return Err(invalid("eventFamilies must not be empty"));
    }
    Ok(families)
}

pub(super) fn retention_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .unwrap_or(DEFAULT_RETENTION_DAYS)
        .clamp(1, MAX_RETENTION_DAYS);
    let max_inbox_records = optional_u64(payload, "maxInboxRecords")?
        .unwrap_or(DEFAULT_MAX_INBOX_RECORDS)
        .clamp(1, MAX_INBOX_RECORDS);
    Ok(json!({
        "privacyClass": "user_visible_notification_metadata",
        "tokenCustody": "private_transport_store_with_hash_only_resource_evidence",
        "maxAgeDays": max_age_days,
        "maxInboxRecords": max_inbox_records
    }))
}

pub(super) async fn ensure_internal_write_authority(
    _deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<(), CapabilityError> {
    if !matches!(
        invocation.causal_context.actor_kind,
        ActorKind::Client | ActorKind::System | ActorKind::Admin
    ) {
        return Err(policy(format!(
            "{operation} requires trusted engine-client authority"
        )));
    }
    let expected_function = format!("device::{}", operation.trim_start_matches("device_"));
    if invocation.function_id.as_str() != expected_function {
        return Err(policy(format!(
            "{operation} is available only through {expected_function}"
        )));
    }
    if !invocation.causal_context.has_scope(WRITE_SCOPE) {
        return Err(policy(format!("{operation} requires {WRITE_SCOPE}")));
    }
    Ok(())
}

pub(super) async fn inspect_read_grant(
    deps: &Deps,
    invocation: &Invocation,
    operation: &str,
) -> Result<EngineGrant, CapabilityError> {
    let grant = deps
        .engine_host
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

pub(super) fn require_kind_selector(
    grant: &EngineGrant,
    operation: &str,
) -> Result<(), CapabilityError> {
    require_explicit_grant_item(
        &grant.allowed_resource_kinds,
        DEVICE_REGISTRATION_KIND,
        operation,
    )?;
    if let Some(selector) = grant
        .resource_selectors
        .iter()
        .find(|selector| is_broad_selector(selector))
    {
        return Err(invalid(format!(
            "{operation} rejects broad resource selector {selector}"
        )));
    }
    let expected = format!("kind:{DEVICE_REGISTRATION_KIND}");
    if !grant
        .resource_selectors
        .iter()
        .any(|selector| selector == &expected)
    {
        return Err(invalid(format!(
            "{operation} requires explicit {expected} selector"
        )));
    }
    Ok(())
}

fn require_explicit_grant_item(
    values: &[String],
    required: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if values.iter().any(|value| value == "*") {
        return Err(invalid(format!("{operation} rejects wildcard grants")));
    }
    if !values.iter().any(|value| value == required) {
        return Err(invalid(format!(
            "{operation} requires explicit {required} grant"
        )));
    }
    Ok(())
}

fn is_broad_selector(selector: &str) -> bool {
    let trimmed = selector.trim();
    trimmed == "*"
        || trimmed == "kind:*"
        || trimmed == "resource:*"
        || trimmed == "kind:"
        || trimmed == "resource:"
        || trimmed.ends_with(":*")
}

pub(super) fn ensure_device_registration(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != DEVICE_REGISTRATION_KIND {
        return Err(invalid(format!(
            "{operation} expected {DEVICE_REGISTRATION_KIND}"
        )));
    }
    if inspection.resource.schema_id != DEVICE_REGISTRATION_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {DEVICE_REGISTRATION_SCHEMA_ID}"
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
            "{operation} cannot access a device outside the current scope"
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
    Ok((version, &version.payload))
}

pub(super) fn validate_device_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{DEVICE_REGISTRATION_KIND}:")) {
        return Err(invalid(
            "deviceRegistrationResourceId has unsupported resource kind",
        ));
    }
    bounded_token("deviceRegistrationResourceId", value, 256).map(|_| ())
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
            topic: DEVICE_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "tokenRedaction": {
                    "rawTokenReturned": false,
                    "fullTokenHashReturned": false
                }
            }),
            visibility: crate::engine::VisibilityScope::System,
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

pub(super) fn resource_policy() -> Value {
    json!({
        "owner": WORKER,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "tokenCustody": "private_transport_store_with_hash_only_resource_evidence",
        "liveApnsTransport": "runtime_configured"
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [WRITE_SCOPE, READ_SCOPE, RESOURCE_WRITE_SCOPE, RESOURCE_READ_SCOPE],
        "resourceKind": DEVICE_REGISTRATION_KIND,
        "wildcardGrantsAllowed": false
    })
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

pub(super) fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role
    })
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    role: &str,
) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": version.version_id,
        "contentHash": version.content_hash,
        "role": role
    })
}

pub(super) fn device_resource_id(
    scope: &EngineResourceScope,
    platform: &str,
    environment: &str,
    bundle_id: &str,
    device_id: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(platform.as_bytes());
    hasher.update(b":");
    hasher.update(environment.as_bytes());
    hasher.update(b":");
    hasher.update(bundle_id.as_bytes());
    hasher.update(b":");
    hasher.update(device_id.as_bytes());
    format!(
        "{DEVICE_REGISTRATION_KIND}:{}",
        hex::encode(hasher.finalize())
    )
}

pub(super) fn assert_no_raw_token(payload: &Value, raw_token: &str) -> Result<(), CapabilityError> {
    let serialized = serde_json::to_string(payload)
        .map_err(|error| invalid(format!("serialize device record: {error}")))?;
    if serialized.contains(raw_token) {
        return Err(invalid("raw APNs token leaked into device registration"));
    }
    Ok(())
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

pub(super) fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}

pub(super) fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

fn policy(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Custom {
        code: "DEVICE_POLICY_DENIED".to_owned(),
        message: message.into(),
        details: None,
    }
}
