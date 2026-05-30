//! Resource-backed notification inbox logic.
//!
//! Notification delivery/read facts are engine resources and decisions. Session
//! events remain historical invocation records and are never used as inbox
//! source truth. Inbox reconstruction uses bounded resource-capability
//! projections only; it must not grow a notification-owned side table or hidden
//! store reader.

use chrono::Utc;
use serde::Serialize;
use serde_json::{Value, json};

use crate::domains::notifications::Deps;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::server::errors::CapabilityError;

pub(crate) const NOTIFICATION_KIND: &str = "notification";
const NOTIFICATION_RESOURCE_PREFIX: &str = "notification:";
const NOTIFICATION_READ_DECISION: &str = "notification_read";
const NOTIFICATION_MARK_ALL_READ_DECISION: &str = "notification_mark_all_read";
const DELIVERY_EVIDENCE_TYPE: &str = "notification_delivery";
const NOTIFICATIONS_SYSTEM_CONTEXT_ID: &str = "notifications";
const MAX_NOTIFICATION_LIST_LIMIT: usize = 100;
const NOTIFICATION_TRUTH_SCAN_LIMIT: usize =
    crate::domains::resource_projection::MAX_RESOURCE_COLLECTION_LIMIT;

/// A single notification returned to the client inbox.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NotificationInboxEntry {
    /// Stable response id. After resource conversion this is the notification
    /// resource id, not a session event id.
    pub(crate) event_id: String,
    pub(crate) notification_resource_id: String,
    pub(crate) notification_version_id: Option<String>,
    pub(crate) session_id: String,
    pub(crate) invocation_id: Option<String>,
    pub(crate) timestamp: String,
    pub(crate) title: String,
    pub(crate) body: String,
    pub(crate) sheet_content: Option<String>,
    pub(crate) is_read: bool,
    pub(crate) read_at: Option<String>,
    pub(crate) session_title: Option<String>,
    pub(crate) is_user_session: bool,
    pub(crate) delivery_status: Option<String>,
    pub(crate) delivery_warning: Option<String>,
    pub(crate) resource_refs: Vec<Value>,
    pub(crate) decision_refs: Vec<Value>,
    pub(crate) evidence_refs: Vec<Value>,
}

/// capability response for listing notifications.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NotificationListResult {
    pub(crate) notifications: Vec<NotificationInboxEntry>,
    pub(crate) unread_count: u64,
}

/// capability response for marking a single notification as read.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MarkReadResult {
    pub(crate) success: bool,
    pub(crate) unread_count: u64,
    pub(crate) decision_refs: Vec<Value>,
}

/// capability response for marking all notifications as read.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MarkAllReadResult {
    pub(crate) marked: usize,
    pub(crate) unread_count: u64,
    pub(crate) decision_refs: Vec<Value>,
}

#[derive(Debug, Clone)]
pub(crate) struct PreparedNotification {
    pub(crate) resource_id: String,
    pub(crate) pending_payload: Value,
}

#[derive(Debug, Clone)]
pub(crate) struct DeliveryObservation {
    pub(crate) success: bool,
    pub(crate) message: Option<String>,
    pub(crate) success_count: u64,
    pub(crate) total_count: u64,
    pub(crate) warning: Option<String>,
    pub(crate) error_code: Option<String>,
}

/// Shared service for notification inbox queries and mutations.
pub(crate) struct NotificationInboxService;

impl NotificationInboxService {
    pub(crate) fn prepare(invocation: &Invocation, payload: Value) -> PreparedNotification {
        PreparedNotification {
            resource_id: notification_resource_id(invocation),
            pending_payload: payload,
        }
    }

    pub(crate) async fn persist_delivery(
        deps: &Deps,
        parent: &Invocation,
        prepared: PreparedNotification,
        delivery: DeliveryObservation,
    ) -> Result<(Vec<Value>, Vec<Value>), CapabilityError> {
        let created = ensure_notification_resource(
            deps,
            parent,
            &prepared.resource_id,
            prepared.pending_payload.clone(),
        )
        .await?;
        let inspection = inspect_resource(deps, Some(parent), &prepared.resource_id)
            .await?
            .ok_or_else(|| CapabilityError::Internal {
                message: format!(
                    "created notification {} was not inspectable",
                    prepared.resource_id
                ),
            })?;
        let mut delivered_payload = current_payload(&inspection)?;
        delivered_payload["delivery"] = json!({
            "status": if delivery.success { "delivered" } else { "delivery_failed" },
            "success": delivery.success,
            "message": delivery.message,
            "successCount": delivery.success_count,
            "totalCount": delivery.total_count,
            "warning": delivery.warning,
            "errorCode": delivery.error_code,
            "observedAt": Utc::now().to_rfc3339(),
        });
        delivered_payload["updatedAt"] = json!(Utc::now().to_rfc3339());
        let lifecycle = if delivery.success {
            "active"
        } else {
            "delivery_failed"
        };
        let updated = invoke_resource_capability(
            deps,
            Some(parent),
            "resource::update",
            json!({
                "resourceId": prepared.resource_id,
                "expectedCurrentVersionId": inspection.pointer("/resource/currentVersionId").cloned().unwrap_or(Value::Null),
                "lifecycle": lifecycle,
                "payload": delivered_payload
            }),
            "delivery:update",
            "resource.write",
        )
        .await?;
        let evidence =
            attach_delivery_evidence(deps, parent, &prepared.resource_id, &delivery).await?;
        let mut refs = resource_refs(&created);
        refs.extend(resource_refs(&updated));
        Ok((refs, resource_refs(&evidence)))
    }

    pub(crate) async fn list(
        deps: &Deps,
        limit: u64,
        session_id: Option<&str>,
    ) -> Result<NotificationListResult, CapabilityError> {
        let limit = usize::try_from(limit)
            .unwrap_or(MAX_NOTIFICATION_LIST_LIMIT)
            .clamp(1, MAX_NOTIFICATION_LIST_LIMIT);
        let decisions = read_decisions(deps).await?;
        let mut entries = Vec::new();
        for resource in notification_resources(deps).await? {
            if matches!(
                resource.get("lifecycle").and_then(Value::as_str),
                Some("discarded" | "archived")
            ) {
                continue;
            }
            let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
                continue;
            };
            let Some(inspection) = inspect_resource(deps, None, resource_id).await? else {
                continue;
            };
            let Ok(payload) = current_payload(&inspection) else {
                continue;
            };
            if let Some(requested_session) = session_id
                && payload.get("sessionId").and_then(Value::as_str) != Some(requested_session)
            {
                continue;
            }
            if let Some(entry) = entry_from_payload(&inspection, &payload, &decisions) {
                entries.push(entry);
            }
        }
        entries.sort_by(|left, right| {
            right
                .timestamp
                .cmp(&left.timestamp)
                .then_with(|| left.event_id.cmp(&right.event_id))
        });
        let unread_count = entries.iter().filter(|entry| !entry.is_read).count() as u64;
        entries.truncate(limit);
        Ok(NotificationListResult {
            notifications: entries,
            unread_count,
        })
    }

    pub(crate) async fn mark_read(
        deps: &Deps,
        parent: &Invocation,
        event_id: &str,
    ) -> Result<MarkReadResult, CapabilityError> {
        let resource_id = normalize_notification_resource_id(event_id);
        let inspection = require_notification(deps, Some(parent), &resource_id).await?;
        if let Some(existing) = existing_single_read_decision(deps, &resource_id).await? {
            let unread_count = Self::global_unread_count(deps).await?;
            return Ok(MarkReadResult {
                success: true,
                unread_count,
                decision_refs: vec![existing],
            });
        }
        let payload = current_payload(&inspection)?;
        let read_at = Utc::now().to_rfc3339();
        let decision_id = format!("decision:notification-read:{}", short_hash(&resource_id));
        let decision = invoke_resource_capability(
            deps,
            Some(parent),
            "decision::create",
            json!({
                "resourceId": decision_id,
                "scope": "system",
                "lifecycle": "final",
                "payload": {
                    "status": "final",
                    "summary": "Notification marked read",
                    "metadata": {
                        "decisionType": NOTIFICATION_READ_DECISION,
                        "notificationResourceId": resource_id,
                        "eventId": resource_id,
                        "sessionId": payload.get("sessionId").cloned().unwrap_or(Value::Null),
                        "workspaceId": payload.get("workspaceId").cloned().unwrap_or(Value::Null),
                        "readAt": read_at
                    }
                }
            }),
            "mark-read:decision",
            "resource.write",
        )
        .await?;
        link_resource(
            deps,
            parent,
            decision["resourceRefs"][0]["resourceId"]
                .as_str()
                .unwrap_or(&decision_id),
            &resource_id,
            "affects_notification",
            json!({"decisionType": NOTIFICATION_READ_DECISION}),
            "mark-read:link",
        )
        .await?;
        let unread_count = Self::global_unread_count(deps).await?;
        Ok(MarkReadResult {
            success: true,
            unread_count,
            decision_refs: resource_refs(&decision),
        })
    }

    pub(crate) async fn mark_all_read(
        deps: &Deps,
        parent: &Invocation,
        session_id: Option<&str>,
    ) -> Result<MarkAllReadResult, CapabilityError> {
        let current = Self::list(deps, MAX_NOTIFICATION_LIST_LIMIT as u64, session_id).await?;
        let unread = current
            .notifications
            .into_iter()
            .filter(|entry| !entry.is_read)
            .collect::<Vec<_>>();
        if unread.is_empty() {
            let unread_count = Self::global_unread_count(deps).await?;
            return Ok(MarkAllReadResult {
                marked: 0,
                unread_count,
                decision_refs: Vec::new(),
            });
        }
        let read_at = Utc::now().to_rfc3339();
        let affected = unread
            .iter()
            .map(|entry| entry.notification_resource_id.clone())
            .collect::<Vec<_>>();
        let scope = session_id.unwrap_or("all");
        let decision_id = format!(
            "decision:notification-mark-all-read:{}:{}",
            slug(scope),
            short_hash(parent.id.as_str())
        );
        let decision = invoke_resource_capability(
            deps,
            Some(parent),
            "decision::create",
            json!({
                "resourceId": decision_id,
                "scope": "system",
                "lifecycle": "final",
                "payload": {
                    "status": "final",
                    "summary": "Notifications marked read",
                    "metadata": {
                        "decisionType": NOTIFICATION_MARK_ALL_READ_DECISION,
                        "sessionId": session_id,
                        "affectedNotificationIds": affected.clone(),
                        "readAt": read_at
                    }
                }
            }),
            "mark-all-read:decision",
            "resource.write",
        )
        .await?;
        let decision_resource_id = decision["resourceRefs"][0]["resourceId"]
            .as_str()
            .unwrap_or(&decision_id)
            .to_owned();
        for resource_id in &affected {
            link_resource(
                deps,
                parent,
                &decision_resource_id,
                resource_id,
                "affects_notification",
                json!({"decisionType": NOTIFICATION_MARK_ALL_READ_DECISION}),
                &format!("mark-all-read:link:{resource_id}"),
            )
            .await?;
        }
        let unread_count = Self::global_unread_count(deps).await?;
        Ok(MarkAllReadResult {
            marked: affected.len(),
            unread_count,
            decision_refs: resource_refs(&decision),
        })
    }

    async fn global_unread_count(deps: &Deps) -> Result<u64, CapabilityError> {
        Ok(Self::list(deps, 1, None).await?.unread_count)
    }
}

fn entry_from_payload(
    inspection: &Value,
    payload: &Value,
    decisions: &[ReadDecision],
) -> Option<NotificationInboxEntry> {
    let resource_id = inspection["resource"]["resourceId"].as_str()?.to_owned();
    let title = payload.get("title")?.as_str()?.to_owned();
    let body = payload.get("body")?.as_str()?.to_owned();
    let session_id = payload
        .get("sessionId")
        .and_then(Value::as_str)
        .unwrap_or("notifications")
        .to_owned();
    let read_decision = decisions
        .iter()
        .filter(|decision| decision.affects(&resource_id))
        .max_by(|left, right| left.read_at.cmp(&right.read_at));
    let notification_version_id = inspection["resource"]["currentVersionId"]
        .as_str()
        .map(str::to_owned);
    Some(NotificationInboxEntry {
        event_id: resource_id.clone(),
        notification_resource_id: resource_id.clone(),
        notification_version_id: notification_version_id.clone(),
        session_id,
        invocation_id: payload
            .get("invocationId")
            .and_then(Value::as_str)
            .map(str::to_owned),
        timestamp: payload
            .get("createdAt")
            .and_then(Value::as_str)
            .or_else(|| payload.get("timestamp").and_then(Value::as_str))
            .unwrap_or_default()
            .to_owned(),
        title,
        body,
        sheet_content: payload
            .get("sheetContent")
            .and_then(Value::as_str)
            .map(str::to_owned),
        is_read: read_decision.is_some(),
        read_at: read_decision.map(|decision| decision.read_at.clone()),
        session_title: payload
            .get("sessionTitle")
            .and_then(Value::as_str)
            .map(str::to_owned),
        is_user_session: payload
            .get("isUserSession")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        delivery_status: payload
            .pointer("/delivery/status")
            .and_then(Value::as_str)
            .map(str::to_owned),
        delivery_warning: payload
            .pointer("/delivery/warning")
            .and_then(Value::as_str)
            .map(str::to_owned),
        resource_refs: vec![json!({
            "resourceId": resource_id,
            "versionId": notification_version_id,
            "kind": NOTIFICATION_KIND,
            "role": "notification"
        })],
        decision_refs: read_decision
            .map(|decision| decision.reference.clone())
            .into_iter()
            .collect(),
        evidence_refs: payload
            .get("evidenceRefs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
    })
}

#[derive(Debug, Clone)]
struct ReadDecision {
    reference: Value,
    decision_type: String,
    notification_resource_id: Option<String>,
    affected_notification_ids: Vec<String>,
    read_at: String,
}

impl ReadDecision {
    fn affects(&self, resource_id: &str) -> bool {
        match self.decision_type.as_str() {
            NOTIFICATION_READ_DECISION => {
                self.notification_resource_id.as_deref() == Some(resource_id)
            }
            NOTIFICATION_MARK_ALL_READ_DECISION => self
                .affected_notification_ids
                .iter()
                .any(|affected| affected == resource_id),
            _ => false,
        }
    }
}

async fn read_decisions(deps: &Deps) -> Result<Vec<ReadDecision>, CapabilityError> {
    let decisions = invoke_resource_capability(
        deps,
        None,
        "resource::list",
        json!({"kind": "decision", "limit": NOTIFICATION_TRUTH_SCAN_LIMIT}),
        "list:read-decisions",
        "resource.read",
    )
    .await?;
    let mut out = Vec::new();
    for resource in decisions["resources"]
        .as_array()
        .cloned()
        .unwrap_or_default()
    {
        if resource["lifecycle"] == "archived" {
            continue;
        }
        let Some(resource_id) = resource.get("resourceId").and_then(Value::as_str) else {
            continue;
        };
        let Some(inspection) = inspect_resource(deps, None, resource_id).await? else {
            continue;
        };
        let Ok(payload) = current_payload(&inspection) else {
            continue;
        };
        let Some(metadata) = payload.get("metadata") else {
            continue;
        };
        let Some(decision_type) = metadata.get("decisionType").and_then(Value::as_str) else {
            continue;
        };
        if !matches!(
            decision_type,
            NOTIFICATION_READ_DECISION | NOTIFICATION_MARK_ALL_READ_DECISION
        ) {
            continue;
        }
        let reference = json!({
            "resourceId": resource_id,
            "versionId": inspection["resource"]["currentVersionId"],
            "kind": "decision",
            "role": "read_state"
        });
        let linked_notification_ids = linked_notification_targets(&inspection);
        if linked_notification_ids.is_empty() {
            continue;
        }
        out.push(ReadDecision {
            reference,
            decision_type: decision_type.to_owned(),
            notification_resource_id: linked_notification_ids.first().cloned(),
            affected_notification_ids: linked_notification_ids,
            read_at: metadata
                .get("readAt")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
        });
    }
    Ok(out)
}

fn linked_notification_targets(inspection: &Value) -> Vec<String> {
    inspection
        .get("outgoingLinks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|link| link.get("relation").and_then(Value::as_str) == Some("affects_notification"))
        .filter_map(|link| {
            link.get("targetResourceId")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect()
}

async fn existing_single_read_decision(
    deps: &Deps,
    resource_id: &str,
) -> Result<Option<Value>, CapabilityError> {
    Ok(read_decisions(deps)
        .await?
        .into_iter()
        .find(|decision| {
            decision.decision_type == NOTIFICATION_READ_DECISION && decision.affects(resource_id)
        })
        .map(|decision| decision.reference))
}

async fn notification_resources(deps: &Deps) -> Result<Vec<Value>, CapabilityError> {
    let listed = invoke_resource_capability(
        deps,
        None,
        "resource::list",
        json!({"kind": NOTIFICATION_KIND, "limit": NOTIFICATION_TRUTH_SCAN_LIMIT}),
        "list:notifications",
        "resource.read",
    )
    .await?;
    Ok(listed["resources"].as_array().cloned().unwrap_or_default())
}

async fn require_notification(
    deps: &Deps,
    parent: Option<&Invocation>,
    resource_id: &str,
) -> Result<Value, CapabilityError> {
    let inspection = inspect_resource(deps, parent, resource_id)
        .await?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "NOTIFICATION_NOT_FOUND".to_owned(),
            message: format!("Notification not found: {resource_id}"),
        })?;
    if inspection["resource"]["kind"] != NOTIFICATION_KIND {
        return Err(CapabilityError::InvalidParams {
            message: format!("{resource_id} is not a notification resource"),
        });
    }
    Ok(inspection)
}

async fn ensure_notification_resource(
    deps: &Deps,
    parent: &Invocation,
    resource_id: &str,
    payload: Value,
) -> Result<Value, CapabilityError> {
    if let Some(inspection) = inspect_resource(deps, Some(parent), resource_id).await? {
        return Ok(json!({
            "resource": inspection["resource"],
            "resourceRefs": [{
                "resourceId": resource_id,
                "versionId": inspection["resource"]["currentVersionId"],
                "kind": NOTIFICATION_KIND,
                "role": "existing"
            }]
        }));
    }
    invoke_resource_capability(
        deps,
        Some(parent),
        "resource::create",
        json!({
            "kind": NOTIFICATION_KIND,
            "resourceId": resource_id,
            "scope": "system",
            "lifecycle": "pending",
            "payload": payload,
            "policy": {"retention": "notification_inbox"}
        }),
        "notification:create",
        "resource.write",
    )
    .await
}

async fn attach_delivery_evidence(
    deps: &Deps,
    parent: &Invocation,
    resource_id: &str,
    delivery: &DeliveryObservation,
) -> Result<Value, CapabilityError> {
    let evidence_id = format!(
        "evidence:notification-delivery:{}:{}",
        slug(resource_id),
        short_hash(&json!(delivery_summary(delivery)).to_string())
    );
    invoke_resource_capability(
        deps,
        Some(parent),
        "evidence::attach",
        json!({
            "resourceId": evidence_id,
            "targetResourceId": resource_id,
            "relation": "evidence_for",
            "scope": "system",
            "lifecycle": "accepted",
            "payload": {
                "summary": delivery_summary(delivery),
                "source": "notifications::send",
                "resourceRef": resource_id,
                "metadata": {
                    "evidenceType": DELIVERY_EVIDENCE_TYPE,
                    "notificationResourceId": resource_id,
                    "success": delivery.success,
                    "successCount": delivery.success_count,
                    "totalCount": delivery.total_count,
                    "warning": delivery.warning,
                    "errorCode": delivery.error_code
                }
            },
            "metadata": {"evidenceType": DELIVERY_EVIDENCE_TYPE}
        }),
        "delivery:evidence",
        "resource.write",
    )
    .await
}

fn delivery_summary(delivery: &DeliveryObservation) -> String {
    if delivery.success {
        format!(
            "Notification delivered to {}/{} targets",
            delivery.success_count, delivery.total_count
        )
    } else {
        delivery
            .warning
            .clone()
            .or_else(|| delivery.message.clone())
            .unwrap_or_else(|| "Notification delivery failed".to_owned())
    }
}

async fn inspect_resource(
    deps: &Deps,
    parent: Option<&Invocation>,
    resource_id: &str,
) -> Result<Option<Value>, CapabilityError> {
    let value = invoke_resource_capability(
        deps,
        parent,
        "resource::inspect",
        json!({"resourceId": resource_id}),
        &format!("inspect:{resource_id}"),
        "resource.read",
    )
    .await?;
    Ok(value
        .get("inspection")
        .cloned()
        .filter(|value| !value.is_null()))
}

async fn link_resource(
    deps: &Deps,
    parent: &Invocation,
    source_resource_id: &str,
    target_resource_id: &str,
    relation: &str,
    metadata: Value,
    idempotency_label: &str,
) -> Result<Value, CapabilityError> {
    invoke_resource_capability(
        deps,
        Some(parent),
        "resource::link",
        json!({
            "sourceResourceId": source_resource_id,
            "targetResourceId": target_resource_id,
            "relation": relation,
            "metadata": metadata
        }),
        idempotency_label,
        "resource.write",
    )
    .await
}

fn current_payload(inspection: &Value) -> Result<Value, CapabilityError> {
    let current = inspection
        .pointer("/resource/currentVersionId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource has no current version".to_owned(),
        })?;
    inspection
        .get("versions")
        .and_then(Value::as_array)
        .and_then(|versions| {
            versions
                .iter()
                .find(|version| version["versionId"] == current)
        })
        .and_then(|version| version.get("payload"))
        .cloned()
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource current payload is missing".to_owned(),
        })
}

fn resource_refs(value: &Value) -> Vec<Value> {
    value["resourceRefs"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

async fn invoke_resource_capability(
    deps: &Deps,
    parent: Option<&Invocation>,
    function_id: &str,
    payload: Value,
    idempotency_label: &str,
    scope: &str,
) -> Result<Value, CapabilityError> {
    let mut causal = CausalContext::new(
        ActorId::new("system:notifications").map_err(engine_capability_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_capability_error)?,
        TraceId::new(
            parent
                .map(|invocation| invocation.causal_context.trace_id.as_str())
                .unwrap_or("notifications-resource"),
        )
        .map_err(engine_capability_error)?,
    )
    .with_scope(scope)
    .with_idempotency_key(format!(
        "notifications:{}:{idempotency_label}",
        parent
            .map(|invocation| invocation.id.as_str())
            .unwrap_or("read")
    ));
    if let Some(parent) = parent {
        causal.parent_invocation_id = Some(parent.id.clone());
    }
    let session_id = parent
        .and_then(|invocation| invocation.causal_context.session_id.as_deref())
        .unwrap_or(NOTIFICATIONS_SYSTEM_CONTEXT_ID);
    let workspace_id = parent
        .and_then(|invocation| invocation.causal_context.workspace_id.as_deref())
        .unwrap_or(NOTIFICATIONS_SYSTEM_CONTEXT_ID);
    causal = causal
        .with_session_id(session_id)
        .with_workspace_id(workspace_id);
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(engine_capability_error)?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_capability_error(error));
    }
    result.value.ok_or_else(|| CapabilityError::Internal {
        message: format!("{function_id} returned no value"),
    })
}

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "NOTIFICATION_RESOURCE_OPERATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn notification_resource_id(invocation: &Invocation) -> String {
    format!("{NOTIFICATION_RESOURCE_PREFIX}{}", invocation.id.as_str())
}

fn normalize_notification_resource_id(id: &str) -> String {
    if id.starts_with(NOTIFICATION_RESOURCE_PREFIX) {
        id.to_owned()
    } else {
        format!("{NOTIFICATION_RESOURCE_PREFIX}{id}")
    }
}

fn short_hash(input: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())[..16].to_owned()
}

fn slug(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(96)
        .collect()
}
