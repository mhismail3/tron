use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, EngineResource,
    EngineResourceInspection, EngineResourceScope, EngineResourceVersion, Invocation,
    LinkResources, ListResources, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::contract::{
    DELIVERY_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WORKER,
    WRITE_SCOPE,
};
use super::projection::delivery_summary;
use super::validation::DEVICE_DELIVERY_LIMIT;
use super::{Deps, NOTIFICATION_DELIVERY_KIND, NOTIFICATION_DELIVERY_SCHEMA_ID, NOTIFICATION_KIND};

const DELIVERY_RELATION: &str = "delivery_evidence";

pub(super) async fn create_delivery_evidence(
    deps: &Deps,
    invocation: &Invocation,
    scope: &EngineResourceScope,
    notification: &EngineResource,
    notification_version_id: &str,
    family: &str,
    push_requested: bool,
    badge_count: u64,
    operation_at: &DateTime<Utc>,
) -> Result<Vec<Value>, CapabilityError> {
    if !push_requested {
        let record = create_delivery_resource(
            deps,
            invocation,
            scope,
            notification,
            notification_version_id,
            None,
            family,
            "inbox_only",
            "push_not_requested",
            false,
            badge_count,
            0,
            operation_at,
        )
        .await?;
        return Ok(vec![record]);
    }

    let devices = active_devices(deps, scope).await?;
    if devices.is_empty() {
        let record = create_delivery_resource(
            deps,
            invocation,
            scope,
            notification,
            notification_version_id,
            None,
            family,
            "skipped_no_device",
            "no_active_device_registration",
            true,
            badge_count,
            0,
            operation_at,
        )
        .await?;
        return Ok(vec![record]);
    }

    let mut records = Vec::new();
    for (index, device) in devices.iter().enumerate() {
        let (_, payload) = current_payload(device, "notification_delivery device")?;
        let (state, reason) = delivery_state_for_device(payload, family);
        records.push(
            create_delivery_resource(
                deps,
                invocation,
                scope,
                notification,
                notification_version_id,
                Some(device),
                family,
                state,
                reason,
                true,
                badge_count,
                index,
                operation_at,
            )
            .await?,
        );
    }
    Ok(records)
}

pub(super) async fn delivery_summaries_for_notification(
    deps: &Deps,
    notification: &EngineResourceInspection,
    limit: usize,
) -> Result<Vec<Value>, CapabilityError> {
    let mut deliveries = Vec::new();
    for link in notification
        .outgoing_links
        .iter()
        .filter(|link| link.relation == DELIVERY_RELATION)
        .take(limit)
    {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&link.target_resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_delivery(&inspection, "notification_inspect delivery")?;
        let (version, payload) = current_payload(&inspection, "notification_inspect delivery")?;
        deliveries.push(delivery_summary(&inspection.resource, version, payload));
    }
    Ok(deliveries)
}

#[allow(clippy::too_many_arguments)]
async fn create_delivery_resource(
    deps: &Deps,
    invocation: &Invocation,
    scope: &EngineResourceScope,
    notification: &EngineResource,
    notification_version_id: &str,
    device: Option<&EngineResourceInspection>,
    family: &str,
    state: &str,
    reason: &str,
    push_requested: bool,
    badge_count: u64,
    index: usize,
    operation_at: &DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let now = operation_at.to_rfc3339();
    let (device_id, environment, token_hash) = if let Some(inspection) = device {
        let (_, payload) = current_payload(inspection, "notification_delivery device")?;
        (
            Some(inspection.resource.resource_id.clone()),
            payload
                .get("apns")
                .and_then(|apns| apns.get("environment"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            payload
                .get("apns")
                .and_then(|apns| apns.get("tokenHash"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        )
    } else {
        (None, None, None)
    };
    let delivery = json!({
        "schemaVersion": DELIVERY_SCHEMA_VERSION,
        "state": state,
        "notificationResourceId": notification.resource_id,
        "notificationVersionId": notification_version_id,
        "deviceRegistrationResourceId": device_id,
        "family": family,
        "apnsEnvironment": environment,
        "outcome": {
            "status": state,
            "reason": reason
        },
        "push": {
            "requested": push_requested,
            "liveApnsAttempted": false,
            "liveApnsEnabled": false,
            "tokenHash": token_hash,
            "tokenRedacted": token_hash.is_some()
        },
        "badge": {
            "policy": "unread_count",
            "scope": "current_resource_scope",
            "count": badge_count,
            "includesRead": false
        },
        "createdAt": now,
        "traceRefs": trace_refs(invocation),
        "replayRefs": replay_refs(invocation),
        "authority": authority_record(invocation),
        "idempotency": {
            "key": invocation.causal_context.idempotency_key,
            "invocationId": invocation.id.as_str()
        },
        "revision": 1
    });
    let resource_id = delivery_resource_id(
        &notification.resource_id,
        device_id.as_deref(),
        invocation,
        index,
    );
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: NOTIFICATION_DELIVERY_KIND.to_owned(),
            schema_id: Some(NOTIFICATION_DELIVERY_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(state.to_owned()),
            policy: resource_policy("notification_delivery"),
            initial_payload: Some(delivery),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = deps
        .engine_host
        .link_resources(LinkResources {
            source_resource_id: notification.resource_id.clone(),
            target_resource_id: resource.resource_id.clone(),
            relation: DELIVERY_RELATION.to_owned(),
            metadata: json!({"state": state, "reason": reason}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("created delivery resource disappeared"))?;
    let (version, payload) = current_payload(&inspection, "notification_delivery")?;
    Ok(delivery_summary(&inspection.resource, version, payload))
}

async fn active_devices(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<Vec<EngineResourceInspection>, CapabilityError> {
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(DEVICE_REGISTRATION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some("active".to_owned()),
            limit: DEVICE_DELIVERY_LIMIT,
        })
        .await
        .map_err(engine_error)?;
    let mut devices = Vec::new();
    for resource in resources {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        if inspection.resource.kind == DEVICE_REGISTRATION_KIND
            && inspection.resource.schema_id == DEVICE_REGISTRATION_SCHEMA_ID
        {
            devices.push(inspection);
        }
    }
    Ok(devices)
}

fn delivery_state_for_device(payload: &Value, family: &str) -> (&'static str, &'static str) {
    let Some(policy) = payload.get("notificationPolicy") else {
        return ("skipped_policy_disabled", "missing_notification_policy");
    };
    let opt_in = policy
        .get("optIn")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let push_enabled = policy
        .get("pushEnabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let family_enabled = policy
        .get("eventFamilies")
        .and_then(Value::as_array)
        .map(|families| {
            families
                .iter()
                .filter_map(Value::as_str)
                .any(|allowed| allowed == family)
        })
        .unwrap_or(false);
    if !opt_in || !push_enabled {
        ("skipped_policy_disabled", "device_push_not_opted_in")
    } else if !family_enabled {
        (
            "skipped_family_opt_out",
            "event_family_not_enabled_for_device",
        )
    } else {
        (
            "skipped_transport_disabled",
            "live_apns_transport_disabled_in_slice_13",
        )
    }
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

fn ensure_delivery(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != NOTIFICATION_DELIVERY_KIND {
        return Err(invalid(format!(
            "{operation} expected {NOTIFICATION_DELIVERY_KIND}"
        )));
    }
    if inspection.resource.schema_id != NOTIFICATION_DELIVERY_SCHEMA_ID {
        return Err(invalid(format!(
            "{operation} expected schema {NOTIFICATION_DELIVERY_SCHEMA_ID}"
        )));
    }
    Ok(())
}

fn delivery_resource_id(
    notification_resource_id: &str,
    device_resource_id: Option<&str>,
    invocation: &Invocation,
    index: usize,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(notification_resource_id.as_bytes());
    hasher.update(b":");
    hasher.update(device_resource_id.unwrap_or("none").as_bytes());
    hasher.update(b":");
    hasher.update(invocation.id.as_str().as_bytes());
    hasher.update(b":");
    hasher.update(index.to_string().as_bytes());
    format!(
        "{NOTIFICATION_DELIVERY_KIND}:{}",
        hex::encode(hasher.finalize())
    )
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

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
