//! Capability contracts owned by the notifications domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["notifications.inbox"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("notifications::send", "notifications", EffectClass::ExternalSideEffect, RiskLevel::Low, Some("notifications.write"))
            .description("Send a user-visible iOS/app notification through Tron push delivery and record it in the notification inbox.")
            .tags(vec!["notify", "notification", "push", "ios", "app", "alert", "inbox", "message user"])
            .request_schema(json!({
                "additionalProperties": false,
                "properties": {
                    "title": {"type": "string", "description": "Short notification title."},
                    "body": {"type": "string", "description": "Notification body shown to the user."},
                    "priority": {"type": "string", "enum": ["low", "normal", "high"]},
                    "badge": {"type": "integer", "minimum": 0},
                    "data": {"additionalProperties": true, "type": "object"},
                    "sheetContent": {"additionalProperties": true, "type": "object"},
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                },
                "required": ["title", "body"],
                "type": "object"
            }))
            .response_schema(json!({
                "additionalProperties": false,
                "properties": {
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                    "priority": {"type": "string"},
                    "success": {"type": "boolean"},
                    "message": {"type": ["string", "null"]},
                    "successCount": {"type": "integer"},
                    "totalCount": {"type": "integer"},
                    "warning": {"type": ["string", "null"]},
                    "sheetContent": {},
                    "data": {}
                },
                "required": ["title", "body", "priority", "success", "successCount", "totalCount"],
                "type": "object"
            }))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(
                CompensationKind::ManualOnly,
                "push delivery cannot be unsent; notification_read_state can mark the inbox entry read after delivery",
            ))
            .high_risk_contract(json!({
                "directExecutionAllowed": true,
                "directExecutionReason": "low-risk user-visible notification with caller idempotency key",
                "rollbackOrCompensation": "push delivery cannot be unsent; inbox state can be marked read",
                "streamTopics": STREAM_TOPICS,
                "version": 1
            }))
            .stream_topics(STREAM_TOPICS.to_vec())
            .examples(vec![json!({
                "mode": "invoke",
                "capabilityId": "notifications::send",
                "payload": {
                    "title": "Tron test",
                    "body": "This is a test notification from Tron.",
                    "priority": "normal"
                },
                "idempotencyKey": "test-notification-<stable-purpose>",
                "reason": "User asked for a test notification."
            })])
            .build()?,
        CapabilityContract::new("notifications::list", "notifications", EffectClass::PureRead, RiskLevel::Low, Some("notifications.read"))
            .description("List recent Tron app notifications from the engine notification inbox.")
            .tags(vec!["notification", "notify", "inbox", "unread", "push"])
            .request_schema(json!({"additionalProperties":false,"properties":{"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"notifications":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"unreadCount":{"type":"integer"}},"required":["notifications","unreadCount"],"type":"object"}))
            .build()?,
        CapabilityContract::new("notifications::mark_read", "notifications", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("notifications.write"))
            .description("Mark one notification inbox event as read.")
            .tags(vec!["notification", "inbox", "read", "badge"])
            .request_schema(json!({"additionalProperties":false,"properties":{"eventId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["eventId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("notifications::mark_all_read", "notifications", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("notifications.write"))
            .description("Mark all visible notification inbox events as read, optionally scoped to one session.")
            .tags(vec!["notification", "inbox", "read", "badge"])
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"marked":{"type":"integer"}},"required":["marked"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
