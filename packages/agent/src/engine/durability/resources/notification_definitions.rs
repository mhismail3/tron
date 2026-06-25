//! Device and notification resource definitions.

use serde_json::json;

use super::types::{
    DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, EngineResourceVersioningMode,
    NOTIFICATION_DELIVERY_KIND, NOTIFICATION_DELIVERY_SCHEMA_ID, NOTIFICATION_KIND,
    NOTIFICATION_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn notification_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        RegisterResourceType {
            kind: DEVICE_REGISTRATION_KIND.to_owned(),
            schema_id: DEVICE_REGISTRATION_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion", "state", "deviceId", "platform", "scope",
                    "apns", "notificationPolicy", "retention", "createdAt",
                    "updatedAt", "traceRefs", "replayRefs", "authority",
                    "idempotency", "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "state": {"type": "string", "enum": ["active", "unregistered", "archived"]},
                    "deviceId": {"type": "string"},
                    "platform": {"type": "string"},
                    "label": {"type": ["string", "null"]},
                    "scope": {"type": "object"},
                    "apns": {"type": "object"},
                    "notificationPolicy": {"type": "object"},
                    "retention": {"type": "object"},
                    "createdAt": {"type": "string"},
                    "updatedAt": {"type": "string"},
                    "unregistered": {"type": ["object", "null"]},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "authority": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["active", "unregistered", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: [
                "receives_notification",
                "delivery_evidence",
                "rotates_from",
                "rotates_to",
                "supersedes",
                "derived_from",
                "evidence_for",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            default_retention: json!({
                "class": "private_device",
                "maxAgeDays": 90,
                "tokenCustody": "hash_only"
            }),
            redaction_rules: json!({
                "preview": "device_registration_redacted",
                "rawApnsToken": "never_return",
                "tokenHash": "prefix_only"
            }),
            materialization_rules: json!({
                "rawApnsToken": "not_materialized_in_resource_payload",
                "liveApnsTransport": "disabled"
            }),
            required_capabilities: json!({
                "read": ["device.read", "resource.read"],
                "write": ["device.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
        RegisterResourceType {
            kind: NOTIFICATION_KIND.to_owned(),
            schema_id: NOTIFICATION_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion", "state", "notificationId", "family",
                    "severity", "title", "body", "scope", "createdAt",
                    "updatedAt", "readState", "badge", "deliveryPolicy",
                    "retention", "refs", "traceRefs", "replayRefs",
                    "authority", "idempotency", "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "state": {"type": "string", "enum": ["unread", "read", "archived"]},
                    "notificationId": {"type": "string"},
                    "family": {"type": "string"},
                    "severity": {"type": "string"},
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                    "scope": {"type": "object"},
                    "createdAt": {"type": "string"},
                    "updatedAt": {"type": "string"},
                    "readState": {"type": "object"},
                    "badge": {"type": "object"},
                    "deliveryPolicy": {"type": "object"},
                    "retention": {"type": "object"},
                    "refs": {"type": "object"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "authority": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["unread", "read", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: [
                "delivery_evidence",
                "source_event",
                "evidence_for",
                "derived_from",
                "supersedes",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            default_retention: json!({
                "class": "user_visible_notification",
                "maxAgeDays": 90,
                "maxInboxRecords": 500
            }),
            redaction_rules: json!({
                "preview": "bounded_notification_summary",
                "deliveryTokenFields": "redacted"
            }),
            materialization_rules: json!({
                "body": "bounded_inline",
                "liveApnsTransport": "disabled"
            }),
            required_capabilities: json!({
                "read": ["notifications.read", "resource.read"],
                "write": ["notifications.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
        RegisterResourceType {
            kind: NOTIFICATION_DELIVERY_KIND.to_owned(),
            schema_id: NOTIFICATION_DELIVERY_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion", "state", "notificationResourceId",
                    "notificationVersionId", "family", "outcome", "push",
                    "badge", "createdAt", "traceRefs", "replayRefs",
                    "authority", "idempotency", "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "state": {
                        "type": "string",
                        "enum": [
                            "inbox_only", "skipped_no_device",
                            "skipped_policy_disabled", "skipped_family_opt_out",
                            "skipped_transport_disabled", "failed", "archived"
                        ]
                    },
                    "notificationResourceId": {"type": "string"},
                    "notificationVersionId": {"type": "string"},
                    "deviceRegistrationResourceId": {"type": ["string", "null"]},
                    "family": {"type": "string"},
                    "apnsEnvironment": {"type": ["string", "null"]},
                    "outcome": {"type": "object"},
                    "push": {"type": "object"},
                    "badge": {"type": "object"},
                    "createdAt": {"type": "string"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "authority": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: [
                "inbox_only",
                "skipped_no_device",
                "skipped_policy_disabled",
                "skipped_family_opt_out",
                "skipped_transport_disabled",
                "failed",
                "archived",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: ["delivery_for", "device", "evidence_for", "derived_from"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            default_retention: json!({"class": "delivery_evidence", "maxAgeDays": 90}),
            redaction_rules: json!({
                "preview": "delivery_summary",
                "rawApnsToken": "never_return",
                "tokenHash": "prefix_only"
            }),
            materialization_rules: json!({"liveApnsAttempt": "disabled", "externalNetwork": "none"}),
            required_capabilities: json!({
                "read": ["notifications.read", "resource.read"],
                "write": ["notifications.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
    ]
}
