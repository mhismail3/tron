use serde_json::{Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

use super::contract::ACTION_SCHEMA_VERSION;
use super::records::version_ref;

pub(super) fn snapshot_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "snapshot": {
            "resource": version_ref(resource, version, "snapshot"),
            "session": payload["session"],
            "composition": payload["composition"],
            "memory": payload["memory"],
            "proof": payload["proof"]
        }
    })
}

pub(super) fn action_response(
    operation: &str,
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    replay: bool,
) -> Value {
    json!({
        "schemaVersion": ACTION_SCHEMA_VERSION,
        "operation": operation,
        "status": resource.lifecycle,
        "idempotentReplay": replay,
        "contextControlActionResourceId": resource.resource_id,
        "contextControlActionVersionId": version.version_id,
        "projection": action_projection(resource, version, payload)
    })
}

pub(super) fn action_projection(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "action": action_summary(resource, version, payload),
        "preflight": payload["preflight"],
        "result": payload["result"],
        "auditRefs": payload["auditRefs"],
        "proof": payload["proof"]
    })
}

pub(super) fn action_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "resource": version_ref(resource, version, "context_control_action"),
        "actionId": payload["actionId"],
        "state": payload["state"],
        "kind": payload["action"]["kind"],
        "reason": payload["action"]["reason"],
        "actorKind": payload["action"]["actorKind"],
        "createdAt": payload["createdAt"],
        "updatedAt": payload["updatedAt"],
        "resultStatus": payload["result"]["status"]
    })
}

pub(super) fn event_ref(event_id: &str, sequence: i64, event_type: &str) -> Value {
    json!({
        "kind": "session_event",
        "eventId": event_id,
        "sequence": sequence,
        "eventType": event_type
    })
}

pub(super) fn safe_compaction_summary(
    session_id: &str,
    message_count: u64,
    estimated_tokens: u64,
) -> String {
    format!(
        "Earlier provider context for session {session_id} was compacted by Context Control. \
         It contained {message_count} reconstructed messages and about {estimated_tokens} \
         estimated tokens. Raw prior turns remain inspectable through durable session history, \
         traces, and resource refs, but are intentionally excluded from future provider context."
    )
}

pub(super) fn safe_compacted_token_estimate(message_count: u64) -> u64 {
    120_u64.saturating_add(message_count.min(100).saturating_mul(2))
}
