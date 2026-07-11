use serde_json::{Value, json};

use crate::engine::{EngineResource, EngineResourceVersion};

use super::contract::{ACTION_SCHEMA_VERSION, POLICY_SNAPSHOT_SCHEMA_VERSION};
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
    let boundary_committed_this_invocation = !replay
        && payload
            .pointer("/result/timelineEventWritten")
            .and_then(Value::as_bool)
            == Some(true);
    json!({
        "schemaVersion": ACTION_SCHEMA_VERSION,
        "operation": operation,
        "status": resource.lifecycle,
        "idempotentReplay": replay,
        "boundaryCommittedThisInvocation": boundary_committed_this_invocation,
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

pub(super) fn policy_record_response(
    operation: &str,
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    replay: bool,
) -> Value {
    json!({
        "schemaVersion": payload["schemaVersion"],
        "operation": operation,
        "status": resource.lifecycle,
        "idempotentReplay": replay,
        "contextPolicyResourceId": resource.resource_id,
        "contextPolicyVersionId": version.version_id,
        "projection": {
            "policyRecord": policy_summary(resource, version, payload),
            "target": payload["target"],
            "policy": payload["policy"],
            "auditRefs": payload["auditRefs"],
            "proof": payload["proof"]
        }
    })
}

pub(super) fn policy_summary(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
) -> Value {
    json!({
        "resource": version_ref(resource, version, "context_policy"),
        "policyId": payload["policyId"],
        "state": payload["state"],
        "kind": payload["policy"]["kind"],
        "targetKind": payload["target"]["kind"],
        "targetRef": payload["target"]["ref"],
        "targetLabel": payload["target"]["label"],
        "futureProviderContextBinding": payload["policy"]["futureProviderContextBinding"],
        "createdAt": payload["createdAt"],
        "updatedAt": payload["updatedAt"]
    })
}

pub(super) fn policy_snapshot_response(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    payload: &Value,
    replay: bool,
) -> Value {
    json!({
        "schemaVersion": POLICY_SNAPSHOT_SCHEMA_VERSION,
        "operation": "context_policy_snapshot",
        "status": resource.lifecycle,
        "idempotentReplay": replay,
        "contextPolicySnapshotResourceId": resource.resource_id,
        "contextPolicySnapshotVersionId": version.version_id,
        "projection": {
            "policySnapshot": {
                "resource": version_ref(resource, version, "context_policy_snapshot"),
                "session": payload["session"],
                "policy": payload["policy"],
                "survivorRefs": payload["survivorRefs"],
                "exclusionRefs": payload["exclusionRefs"],
                "proof": payload["proof"]
            }
        }
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
