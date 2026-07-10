//! Capability contracts owned by the session domain worker.
//!
//! `session::list` has a recursively closed response shape. Pagination and
//! snapshot proof fields are required so clients cannot infer terminal state
//! from an absent or malformed value.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

fn session_list_response_schema() -> serde_json::Value {
    let activity_line = json!({
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string"},
            "text": {"type": "string"},
            "modelPrimitiveName": {"type": "string"},
            "operationName": {"type": "string"},
            "traceId": {"type": "string"},
            "rootInvocationId": {"type": "string"},
            "themeColor": {"type": "string"},
            "presentationHints": {"additionalProperties": true, "type": "object"},
            "summary": {"type": "string"},
            "capabilityArgs": {"additionalProperties": true, "type": "object"},
            "durationMs": {"type": "integer"},
            "isError": {"type": "boolean"},
            "turns": {"type": "integer"}
        },
        "required": ["kind"],
        "type": "object"
    });
    let session = json!({
        "additionalProperties": false,
        "properties": {
            "sessionId": {"type": "string"},
            "model": {"type": "string"},
            "title": {"type": ["string", "null"]},
            "workingDirectory": {"type": "string"},
            "createdAt": {"type": "string"},
            "lastActivity": {"type": "string"},
            "endedAt": {"type": ["string", "null"]},
            "isActive": {"type": "boolean"},
            "isRunning": {"type": "boolean"},
            "isArchived": {"type": "boolean"},
            "eventCount": {"type": "integer"},
            "turnCount": {"type": "integer"},
            "messageCount": {"type": "integer"},
            "inputTokens": {"type": "integer"},
            "outputTokens": {"type": "integer"},
            "lastTurnInputTokens": {"type": "integer"},
            "cacheReadTokens": {"type": "integer"},
            "cacheCreationTokens": {"type": "integer"},
            "cost": {"type": "number"},
            "parentSessionId": {"type": ["string", "null"]},
            "lastUserPrompt": {"type": ["string", "null"]},
            "lastAssistantResponse": {"type": ["string", "null"]},
            "activityLines": {"items": activity_line, "maxItems": 5, "type": "array"}
        },
        "required": [
            "sessionId", "model", "title", "workingDirectory", "createdAt",
            "lastActivity", "endedAt", "isActive", "isRunning", "isArchived",
            "eventCount", "turnCount", "messageCount", "inputTokens", "outputTokens",
            "lastTurnInputTokens", "cacheReadTokens", "cacheCreationTokens", "cost",
            "parentSessionId", "lastUserPrompt", "lastAssistantResponse", "activityLines"
        ],
        "type": "object"
    });

    json!({
        "additionalProperties": false,
        "properties": {
            "sessions": {"items": session, "maxItems": 200, "type": "array"},
            "hasMore": {"type": "boolean"},
            "nextCursor": {"type": ["string", "null"]},
            "snapshotAsOf": {"type": "string"},
            "snapshotCanReconcile": {"type": "boolean"}
        },
        "required": [
            "sessions", "hasMore", "nextCursor", "snapshotAsOf", "snapshotCanReconcile"
        ],
        "type": "object"
    })
}

pub(crate) const STREAM_TOPICS: &[&str] = &["session.events", "session.lifecycle"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("session::create", "session", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("session.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"__capabilityContext":{"additionalProperties":false,"properties":{"transportId":{"type":"string"}},"type":"object"},"model":{"type":"string"},"sessionId":{"type":"string"},"title":{"type":"string"},"workingDirectory":{"type":"string"},"workspaceId":{"type":"string"}},"required":["workingDirectory"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("session::resume", "session", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("session.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("session::list", "session", EffectClass::PureRead, RiskLevel::Low, Some("session.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"cursor":{"type":"string"},"includeArchived":{"type":"boolean"},"limit":{"maximum":200,"minimum":1,"type":"integer"},"sessionId":{"type":"string"},"workingDirectory":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(session_list_response_schema())
            .build()?,
        CapabilityContract::new("session::delete", "session", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("session.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("session::fork", "session", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("session.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"fromEventId":{"type":"string"},"sessionId":{"type":"string"},"title":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("session::get_head", "session", EffectClass::PureRead, RiskLevel::Low, Some("session.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("session::get_state", "session", EffectClass::PureRead, RiskLevel::Low, Some("session.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("session::get_history", "session", EffectClass::PureRead, RiskLevel::Low, Some("session.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"beforeId":{"type":"string"},"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("session::reconstruct", "session", EffectClass::PureRead, RiskLevel::Low, Some("session.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"beforeEventId":{"type":"string"},"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("session::archive", "session", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("session.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("session::unarchive", "session", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("session.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("session::archive_older_than", "session", EffectClass::IdempotentWrite, RiskLevel::High, Some("session.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"days":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["days"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("session::export", "session", EffectClass::PureRead, RiskLevel::Low, Some("session.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("session::replay_manifest", "session", EffectClass::PureRead, RiskLevel::Low, Some("session.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_list_contract_accepts_a_server_issued_page_two_cursor() {
        let list = capabilities()
            .expect("session contracts")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "session::list")
            .expect("session::list contract");
        let schema = list
            .request_schema
            .as_ref()
            .expect("session::list request schema");

        crate::engine::kernel::schema::validate_payload(
            &list.function_id,
            "request",
            schema,
            &json!({
                "cursor": "opaque-server-cursor",
                "includeArchived": true,
                "limit": 200
            }),
        )
        .expect("page-two payload must pass the actual closed engine contract");
    }

    #[test]
    fn session_list_contract_rejects_missing_terminal_proof_and_unknown_fields() {
        let list = capabilities()
            .expect("session contracts")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "session::list")
            .expect("session::list contract");
        let schema = list.response_schema.as_ref().expect("response schema");

        for invalid in [
            json!({
                "sessions": [],
                "nextCursor": null,
                "snapshotAsOf": "2026-07-01T12:00:00.000000000Z",
                "snapshotCanReconcile": true
            }),
            json!({
                "sessions": [],
                "hasMore": false,
                "nextCursor": null,
                "snapshotAsOf": "2026-07-01T12:00:00.000000000Z",
                "snapshotCanReconcile": true,
                "unexpected": true
            }),
        ] {
            assert!(
                crate::engine::kernel::schema::validate_payload(
                    &list.function_id,
                    "response",
                    schema,
                    &invalid,
                )
                .is_err(),
                "closed response accepted {invalid}"
            );
        }
    }
}
