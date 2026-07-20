//! Private client-device resource definitions.

use serde_json::json;

use super::types::{
    DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, EngineResourceVersioningMode,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn device_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
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
        allowed_link_relations: ["rotates_from", "rotates_to", "supersedes", "derived_from"]
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
            "tokenHash": "redacted_presence_only"
        }),
        materialization_rules: json!({
            "rawApnsToken": "not_materialized_in_resource_payload",
            "privateTokenStore": "transport_only"
        }),
        required_capabilities: json!({
            "transportAuthentication": true,
            "modelVisible": false
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }]
}
