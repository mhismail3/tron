use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources, PublishStreamEvent, UpdateResource, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{ensure_write_authority, inspect_read_grant, require_kind_selectors};
use super::contract::{
    NOTIFICATION_LIFECYCLE_TOPIC, NOTIFICATION_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE,
    RESOURCE_WRITE_SCOPE, WORKER, WRITE_SCOPE,
};
use super::delivery::{create_delivery_evidence, delivery_summaries_for_notification};
use super::projection::{inspected_notification, notification_summary};
use super::validation::*;
use super::{Deps, NOTIFICATION_DELIVERY_KIND, NOTIFICATION_KIND, NOTIFICATION_SCHEMA_ID};

pub(crate) async fn send_notification_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let push_requested = optional_bool(payload, "pushRequested")?.unwrap_or(false);
    ensure_write_authority(deps, invocation, "notification_send", push_requested).await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let notification_id = optional_string(payload, "notificationId")?
        .map(|value| bounded_token("notificationId", &value, NOTIFICATION_ID_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let family = parse_event_family(optional_string(payload, "family")?)?;
    let severity = parse_severity(optional_string(payload, "severity")?)?;
    let title = bounded_text(
        "title",
        &required_string(payload, "title")?,
        TITLE_MAX_BYTES,
    )?;
    let body = bounded_text("body", &required_string(payload, "body")?, BODY_MAX_BYTES)?;
    let source_refs = optional_array(payload, "sourceRefs")?.unwrap_or_default();
    let evidence_refs = optional_array(payload, "evidenceRefs")?.unwrap_or_default();
    validate_refs("sourceRefs", &source_refs)?;
    validate_refs("evidenceRefs", &evidence_refs)?;
    let retention = retention_policy(payload)?;
    let now = Utc::now().to_rfc3339();
    let resource_id = notification_resource_id(&scope, &family, &notification_id, &idempotency_key);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_notification(&existing, "notification_send replay")?;
        ensure_scope(&existing, &scope, "notification_send replay")?;
        let (version, _) = current_payload(&existing, "notification_send replay")?;
        let badge_count = unread_badge_count(deps, &scope).await?;
        return Ok(json!({
            "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
            "operation": "notification_send",
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "notificationResourceId": resource_id,
            "notificationVersionId": version.version_id,
            "badgeCount": badge_count,
            "delivery": {"idempotentReplay": true},
            "resourceRefs": [version_ref(&existing.resource, version, "notification")]
        }));
    }

    let badge_count = unread_badge_count(deps, &scope).await?.saturating_add(1);
    let record = notification_record(NotificationRecordInput {
        state: "unread",
        notification_id: &notification_id,
        family: &family,
        severity: &severity,
        title: &title,
        body: &body,
        scope: &scope,
        push_requested,
        retention,
        source_refs,
        evidence_refs,
        badge_count,
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: NOTIFICATION_KIND.to_owned(),
            schema_id: Some(NOTIFICATION_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("unread".to_owned()),
            policy: resource_policy("notification"),
            initial_payload: Some(record),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let notification_version_id = resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid("notification resource was created without a current version"))?;
    let deliveries = create_delivery_evidence(
        deps,
        invocation,
        &scope,
        &resource,
        &notification_version_id,
        &family,
        push_requested,
        badge_count,
    )
    .await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "notification.created",
        &resource,
        json!({
            "state": "unread",
            "family": family,
            "badgeCount": badge_count,
            "pushRequested": push_requested,
            "deliveryCount": deliveries.len()
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
        "operation": "notification_send",
        "status": "unread",
        "idempotentReplay": false,
        "notificationResourceId": resource.resource_id,
        "notificationVersionId": resource.current_version_id,
        "badgeCount": badge_count,
        "delivery": {
            "records": deliveries,
            "liveApnsAttempted": false,
            "deliveryEvidenceOnly": true
        },
        "resourceRefs": [resource_ref(&resource, "notification")]
    }))
}

pub(crate) async fn list_notifications_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "notification_list").await?;
    require_kind_selectors(&grant, "notification_list", &[NOTIFICATION_KIND])?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_read = optional_bool(payload, "includeRead")?.unwrap_or(false);
    let state = optional_string(payload, "state")?;
    if let Some(state) = state.as_deref()
        && !matches!(state, "unread" | "read" | "archived")
    {
        return Err(invalid("state must be unread, read, or archived"));
    }
    let lifecycle = match (include_read, state) {
        (_, Some(state)) => Some(state),
        (false, None) => Some("unread".to_owned()),
        (true, None) => None,
    };
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(NOTIFICATION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle,
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut notifications = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_notification(&inspection, "notification_list")?;
        ensure_scope(&inspection, &scope, "notification_list")?;
        let (version, payload) = current_payload(&inspection, "notification_list")?;
        notifications.push(notification_summary(&inspection.resource, version, payload));
    }
    Ok(json!({
        "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
        "operation": "notification_list",
        "scope": scope_ref(&scope),
        "notifications": notifications,
        "badgeCount": unread_badge_count(deps, &scope).await?,
        "limits": {
            "requestedLimit": limit,
            "returned": notifications.len(),
            "truncated": truncated,
            "includeRead": include_read
        }
    }))
}

pub(crate) async fn inspect_notification_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "notification_inspect").await?;
    require_kind_selectors(
        &grant,
        "notification_inspect",
        &[NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND],
    )?;
    let resource_id = required_string(payload, "notificationResourceId")?;
    validate_notification_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing notification {resource_id}")))?;
    ensure_notification(&inspection, "notification_inspect")?;
    ensure_scope(&inspection, &scope, "notification_inspect")?;
    let (version, payload) = current_payload(&inspection, "notification_inspect")?;
    let deliveries = delivery_summaries_for_notification(deps, &inspection, 25).await?;
    Ok(json!({
        "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
        "operation": "notification_inspect",
        "scope": scope_ref(&scope),
        "notification": inspected_notification(&inspection.resource, version, payload, deliveries),
        "badgeCount": unread_badge_count(deps, &scope).await?
    }))
}

pub(crate) async fn mark_notification_read_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_write_authority(deps, invocation, "notification_mark_read", false).await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let resource_id = required_string(payload, "notificationResourceId")?;
    validate_notification_resource_id(&resource_id)?;
    let reason = optional_string(payload, "reason")?
        .map(|value| bounded_text("reason", &value, REASON_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| "mark_read".to_owned());
    let scope = resource_scope(invocation)?;
    let mut inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing notification {resource_id}")))?;
    ensure_notification(&inspection, "notification_mark_read")?;
    ensure_scope(&inspection, &scope, "notification_mark_read")?;
    let (current_version, current) = current_payload(&inspection, "notification_mark_read")?;
    if optional_string(payload, "expectedNotificationVersionId")?
        .is_some_and(|expected| expected != current_version.version_id)
    {
        return Err(invalid("notification version is stale"));
    }
    if inspection.resource.lifecycle == "read" {
        return Ok(json!({
            "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
            "operation": "notification_mark_read",
            "status": "already_read",
            "idempotentReplay": true,
            "notificationResourceId": resource_id,
            "notificationVersionId": current_version.version_id,
            "badgeCount": unread_badge_count(deps, &scope).await?,
            "resourceRefs": [version_ref(&inspection.resource, current_version, "notification")]
        }));
    }
    let now = Utc::now().to_rfc3339();
    let mut record = current.clone();
    record["state"] = json!("read");
    record["updatedAt"] = json!(now);
    record["readState"] = json!({
        "isRead": true,
        "readAt": record["updatedAt"],
        "readByActorId": invocation.causal_context.actor_id.as_str(),
        "reason": reason,
        "idempotency": {
            "key": idempotency_key,
            "invocationId": invocation.id.as_str()
        }
    });
    record["revision"] = json!(record["revision"].as_u64().unwrap_or(1).saturating_add(1));
    record["badge"]["count"] = json!(unread_badge_count(deps, &scope).await?.saturating_sub(1));
    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(current_version.version_id.clone()),
            lifecycle: Some("read".to_owned()),
            payload: record,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = "read".to_owned();
    inspection.resource.current_version_id = Some(version.version_id.clone());
    let badge_count = unread_badge_count(deps, &scope).await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "notification.read",
        &inspection.resource,
        json!({"state": "read", "badgeCount": badge_count}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
        "operation": "notification_mark_read",
        "status": "read",
        "idempotentReplay": false,
        "notificationResourceId": resource_id,
        "notificationVersionId": version.version_id,
        "badgeCount": badge_count,
        "resourceRefs": [version_ref(&inspection.resource, &version, "notification")]
    }))
}

pub(crate) async fn mark_all_notifications_read_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    ensure_write_authority(deps, invocation, "notification_mark_all_read", false).await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let reason = optional_string(payload, "reason")?
        .map(|value| bounded_text("reason", &value, REASON_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| "mark_all_read".to_owned());
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(MARK_ALL_LIMIT_MAX)
        .clamp(1, MARK_ALL_LIMIT_MAX);
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(NOTIFICATION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some("unread".to_owned()),
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut updated = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(mut inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_notification(&inspection, "notification_mark_all_read")?;
        ensure_scope(&inspection, &scope, "notification_mark_all_read")?;
        let (current_version, current) =
            current_payload(&inspection, "notification_mark_all_read")?;
        let now = Utc::now().to_rfc3339();
        let mut record = current.clone();
        record["state"] = json!("read");
        record["updatedAt"] = json!(now);
        record["readState"] = json!({
            "isRead": true,
            "readAt": record["updatedAt"],
            "readByActorId": invocation.causal_context.actor_id.as_str(),
            "reason": reason,
            "idempotency": {
                "key": idempotency_key,
                "invocationId": invocation.id.as_str()
            }
        });
        record["revision"] = json!(record["revision"].as_u64().unwrap_or(1).saturating_add(1));
        record["badge"]["count"] = json!(0);
        let version = deps
            .engine_host
            .update_resource(UpdateResource {
                resource_id: inspection.resource.resource_id.clone(),
                expected_current_version_id: Some(current_version.version_id.clone()),
                lifecycle: Some("read".to_owned()),
                payload: record,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        inspection.resource.lifecycle = "read".to_owned();
        inspection.resource.current_version_id = Some(version.version_id.clone());
        updated.push(version_ref(&inspection.resource, &version, "notification"));
    }
    let badge_count = unread_badge_count(deps, &scope).await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "notification.all_read",
        &EngineResource {
            resource_id: format!("notification_batch:{}", invocation.id.as_str()),
            kind: NOTIFICATION_KIND.to_owned(),
            schema_id: NOTIFICATION_SCHEMA_ID.to_owned(),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: "read".to_owned(),
            policy: resource_policy("notification_batch"),
            current_version_id: None,
            trace_id: invocation.causal_context.trace_id.clone(),
            created_by_invocation_id: Some(invocation.id.clone()),
            created_at: Utc::now(),
            updated_at: Utc::now(),
        },
        json!({"state": "read", "updatedCount": updated.len(), "badgeCount": badge_count}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
        "operation": "notification_mark_all_read",
        "status": "read",
        "updatedCount": updated.len(),
        "badgeCount": badge_count,
        "truncated": truncated,
        "resourceRefs": updated
    }))
}

struct NotificationRecordInput<'a> {
    state: &'a str,
    notification_id: &'a str,
    family: &'a str,
    severity: &'a str,
    title: &'a str,
    body: &'a str,
    scope: &'a EngineResourceScope,
    push_requested: bool,
    retention: Value,
    source_refs: Vec<Value>,
    evidence_refs: Vec<Value>,
    badge_count: u64,
    created_at: &'a str,
    updated_at: &'a str,
    invocation: &'a Invocation,
    idempotency_key: &'a str,
    revision: u64,
}

fn notification_record(input: NotificationRecordInput<'_>) -> Value {
    json!({
        "schemaVersion": NOTIFICATION_SCHEMA_VERSION,
        "state": input.state,
        "notificationId": input.notification_id,
        "family": input.family,
        "severity": input.severity,
        "title": input.title,
        "body": input.body,
        "scope": scope_ref(input.scope),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "readState": {
            "isRead": false,
            "readAt": Value::Null,
            "readByActorId": Value::Null
        },
        "badge": {
            "policy": "unread_count",
            "scope": "current_resource_scope",
            "count": input.badge_count,
            "includesRead": false
        },
        "deliveryPolicy": {
            "pushRequested": input.push_requested,
            "defaultPushEnabled": false,
            "liveApnsEnabled": false,
            "deliveryEvidenceOnly": true
        },
        "retention": input.retention,
        "refs": {
            "source": input.source_refs,
            "evidence": input.evidence_refs
        },
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

async fn unread_badge_count(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<u64, CapabilityError> {
    let unread = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(NOTIFICATION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some("unread".to_owned()),
            limit: DEFAULT_MAX_INBOX_RECORDS as usize,
        })
        .await
        .map_err(engine_error)?;
    Ok(unread.len() as u64)
}

fn ensure_notification(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != NOTIFICATION_KIND {
        return Err(invalid(format!("{operation} expected {NOTIFICATION_KIND}")));
    }
    if inspection.resource.schema_id != NOTIFICATION_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {NOTIFICATION_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn ensure_scope(
    inspection: &EngineResourceInspection,
    expected: &EngineResourceScope,
    operation: &str,
) -> Result<(), CapabilityError> {
    if &inspection.resource.scope != expected {
        return Err(invalid(format!(
            "{operation} cannot access a notification outside the current scope"
        )));
    }
    Ok(())
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
    Ok((version, &version.payload))
}

fn validate_notification_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with(&format!("{NOTIFICATION_KIND}:")) {
        return Err(invalid(
            "notificationResourceId has unsupported resource kind",
        ));
    }
    bounded_token("notificationResourceId", value, 256).map(|_| ())
}

fn validate_refs(label: &str, refs: &[Value]) -> Result<(), CapabilityError> {
    if refs.len() > 25 {
        return Err(invalid(format!("{label} may contain at most 25 items")));
    }
    for value in refs {
        let serialized = serde_json::to_string(value)
            .map_err(|error| invalid(format!("serialize {label}: {error}")))?;
        let lowered = serialized.to_ascii_lowercase();
        if lowered.contains("bearer ")
            || lowered.contains("password=")
            || lowered.contains("secret=")
            || lowered.contains("api_key=")
            || lowered.contains("\"token\"")
        {
            return Err(invalid(format!("{label} contains secret-like material")));
        }
    }
    Ok(())
}

fn retention_policy(payload: &Value) -> Result<Value, CapabilityError> {
    let max_age_days = optional_u64(payload, "maxAgeDays")?
        .unwrap_or(DEFAULT_RETENTION_DAYS)
        .clamp(1, MAX_RETENTION_DAYS);
    let max_inbox_records = optional_u64(payload, "maxInboxRecords")?
        .unwrap_or(DEFAULT_MAX_INBOX_RECORDS)
        .clamp(1, MAX_INBOX_RECORDS);
    Ok(json!({
        "privacyClass": "user_visible_notification_content",
        "policy": "bounded_content_with_redacted_delivery_evidence",
        "maxAgeDays": max_age_days,
        "maxInboxRecords": max_inbox_records
    }))
}

async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    resource: &EngineResource,
    payload: Value,
) -> Result<(), CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: NOTIFICATION_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "event": event_type,
                "resource": resource_ref(resource, "subject"),
                "details": payload,
                "push": {
                    "liveApnsAttempted": false,
                    "deliveryEvidenceOnly": true
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

fn notification_resource_id(
    scope: &EngineResourceScope,
    family: &str,
    notification_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(family.as_bytes());
    hasher.update(b":");
    hasher.update(notification_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{NOTIFICATION_KIND}:{}", hex::encode(hasher.finalize()))
}

fn resource_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "badgePolicy": "unread_count",
        "liveApnsTransport": "disabled"
    })
}

fn authority_record(invocation: &Invocation) -> Value {
    json!({
        "grantId": invocation.causal_context.authority_grant_id.as_str(),
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND],
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

fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({"kind": scope.kind(), "value": scope.value()})
}

fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "versionId": resource.current_version_id,
        "role": role
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

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
