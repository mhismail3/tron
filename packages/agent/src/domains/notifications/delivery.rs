use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, EngineResource,
    EngineResourceInspection, EngineResourceScope, EngineResourceVersion, Invocation,
    LinkResources, ListResources, WorkerId,
};
use crate::platform::apns::{ApnsBatch, ApnsNotification};
use crate::shared::server::errors::CapabilityError;

use super::contract::{
    DELIVERY_SCHEMA_VERSION, READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WORKER,
    WRITE_SCOPE,
};
use super::projection::delivery_summary;
use super::validation::DEVICE_DELIVERY_LIMIT;
use super::{Deps, NOTIFICATION_DELIVERY_KIND, NOTIFICATION_DELIVERY_SCHEMA_ID, NOTIFICATION_KIND};

const DELIVERY_RELATION: &str = "delivery_evidence";

struct DeliveryOutcome {
    state: &'static str,
    reason: String,
    live_attempted: bool,
    live_enabled: bool,
    status_code: Option<u16>,
    terminal_token_rejected: bool,
}

pub(super) async fn create_delivery_evidence(
    deps: &Deps,
    invocation: &Invocation,
    scope: &EngineResourceScope,
    notification: &EngineResource,
    notification_version_id: &str,
    family: &str,
    title: &str,
    body: &str,
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
            &DeliveryOutcome::inbox_only(),
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
            &DeliveryOutcome::skipped("skipped_no_device", "no_active_device_registration"),
            true,
            badge_count,
            0,
            operation_at,
        )
        .await?;
        return Ok(vec![record]);
    }

    let mut records = Vec::new();
    let notification_payload = ApnsNotification {
        title: title.to_owned(),
        body: body.to_owned(),
        data: notification_data(scope, notification, notification_version_id),
        priority: "high".to_owned(),
        sound: Some("default".to_owned()),
        badge: Some(u32::try_from(badge_count).unwrap_or(u32::MAX)),
        thread_id: invocation.causal_context.session_id.clone(),
    };
    for (index, device) in devices.iter().enumerate() {
        let (_, payload) = current_payload(device, "notification_delivery device")?;
        let outcome = delivery_outcome(deps, payload, family, &notification_payload).await?;
        records.push(
            create_delivery_resource(
                deps,
                invocation,
                scope,
                notification,
                notification_version_id,
                Some(device),
                family,
                &outcome,
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
    outcome: &DeliveryOutcome,
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
        "state": outcome.state,
        "notificationResourceId": notification.resource_id,
        "notificationVersionId": notification_version_id,
        "deviceRegistrationResourceId": device_id,
        "family": family,
        "apnsEnvironment": environment,
        "outcome": {
            "status": outcome.state,
            "reason": outcome.reason,
            "statusCode": outcome.status_code,
            "terminalTokenRejected": outcome.terminal_token_rejected
        },
        "push": {
            "requested": push_requested,
            "liveApnsAttempted": outcome.live_attempted,
            "liveApnsEnabled": outcome.live_enabled,
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
            lifecycle: Some(outcome.state.to_owned()),
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
            metadata: json!({"state": outcome.state, "reason": outcome.reason}),
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
    _scope: &EngineResourceScope,
) -> Result<Vec<EngineResourceInspection>, CapabilityError> {
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(DEVICE_REGISTRATION_KIND.to_owned()),
            scope: Some(EngineResourceScope::System),
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

impl DeliveryOutcome {
    fn inbox_only() -> Self {
        Self {
            state: "inbox_only",
            reason: "push_not_requested".to_owned(),
            live_attempted: false,
            live_enabled: false,
            status_code: None,
            terminal_token_rejected: false,
        }
    }

    fn skipped(state: &'static str, reason: &str) -> Self {
        Self {
            state,
            reason: reason.to_owned(),
            live_attempted: false,
            live_enabled: false,
            status_code: None,
            terminal_token_rejected: false,
        }
    }
}

async fn delivery_outcome(
    deps: &Deps,
    payload: &Value,
    family: &str,
    notification: &ApnsNotification,
) -> Result<DeliveryOutcome, CapabilityError> {
    let Some(policy) = payload.get("notificationPolicy") else {
        return Ok(DeliveryOutcome::skipped(
            "skipped_policy_disabled",
            "missing_notification_policy",
        ));
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
        return Ok(DeliveryOutcome::skipped(
            "skipped_policy_disabled",
            "device_push_not_opted_in",
        ));
    } else if !family_enabled {
        return Ok(DeliveryOutcome::skipped(
            "skipped_family_opt_out",
            "event_family_not_enabled_for_device",
        ));
    }
    let Some(sender) = &deps.apns_runtime.sender else {
        return Ok(DeliveryOutcome::skipped(
            "skipped_transport_disabled",
            "apns_relay_not_configured",
        ));
    };
    let apns = payload
        .get("apns")
        .ok_or_else(|| invalid("device registration is missing APNs metadata"))?;
    let token_hash = apns
        .get("tokenHash")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("device registration is missing APNs token hash"))?;
    let environment = apns
        .get("environment")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("device registration is missing APNs environment"))?;
    let bundle_id = apns
        .get("bundleId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("device registration is missing APNs bundle id"))?;
    let Some(token) = deps.apns_runtime.token_store.get(token_hash)? else {
        return Ok(DeliveryOutcome {
            state: "failed",
            reason: "private_device_token_missing".to_owned(),
            live_attempted: false,
            live_enabled: true,
            status_code: None,
            terminal_token_rejected: false,
        });
    };
    if token.environment != environment || token.bundle_id != bundle_id {
        return Ok(DeliveryOutcome {
            state: "failed",
            reason: "private_device_route_mismatch".to_owned(),
            live_attempted: false,
            live_enabled: true,
            status_code: None,
            terminal_token_rejected: false,
        });
    }
    let results = sender
        .send_to_many(
            &ApnsBatch {
                device_tokens: vec![token.token],
                environment: relay_environment(environment)?.to_owned(),
                bundle_id: bundle_id.to_owned(),
            },
            notification,
        )
        .await;
    let Some(result) = results.into_iter().next() else {
        return Ok(DeliveryOutcome {
            state: "failed",
            reason: "apns_relay_returned_no_result".to_owned(),
            live_attempted: true,
            live_enabled: true,
            status_code: None,
            terminal_token_rejected: false,
        });
    };
    let terminal_token_rejected = result.is_terminal_token_failure();
    if terminal_token_rejected {
        let _ = deps.apns_runtime.token_store.remove(token_hash)?;
    }
    Ok(DeliveryOutcome {
        state: if result.success {
            "delivered"
        } else {
            "failed"
        },
        reason: if result.success {
            "apns_accepted".to_owned()
        } else {
            result
                .reason
                .or(result.error)
                .unwrap_or_else(|| "apns_delivery_failed".to_owned())
        },
        live_attempted: true,
        live_enabled: true,
        status_code: result.status_code,
        terminal_token_rejected,
    })
}

fn relay_environment(environment: &str) -> Result<&'static str, CapabilityError> {
    match environment {
        "development" => Ok("sandbox"),
        "production" => Ok("production"),
        _ => Err(invalid(
            "device registration has unsupported APNs environment",
        )),
    }
}

fn notification_data(
    scope: &EngineResourceScope,
    notification: &EngineResource,
    version_id: &str,
) -> HashMap<String, String> {
    let mut data = HashMap::from([
        (
            "notificationResourceId".to_owned(),
            notification.resource_id.clone(),
        ),
        ("notificationVersionId".to_owned(), version_id.to_owned()),
    ]);
    match scope {
        EngineResourceScope::Session(session_id) => {
            let _ = data.insert("sessionId".to_owned(), session_id.clone());
        }
        EngineResourceScope::Workspace(workspace_id) => {
            let _ = data.insert("workspaceId".to_owned(), workspace_id.clone());
        }
        EngineResourceScope::System => {}
    }
    data
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
