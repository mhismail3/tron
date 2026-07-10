//! Capability contracts owned by the session domain worker.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

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
            .request_schema(json!({"additionalProperties":false,"properties":{"cursor":{"type":"string"},"includeArchived":{"type":"boolean"},"limit":{"maximum":200,"minimum":1,"type":"integer"},"offset":{"minimum":0,"type":"integer"},"sessionId":{"type":"string"},"workingDirectory":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({
                "additionalProperties": false,
                "properties": {
                    "sessions": {"type": "array", "items": {"type": "object"}},
                    "hasMore": {"type": "boolean"},
                    "nextCursor": {"type": ["string", "null"]},
                    "snapshotAsOf": {"type": "string"},
                    "snapshotCanReconcile": {"type": "boolean"}
                },
                "required": ["sessions", "hasMore", "nextCursor", "snapshotAsOf", "snapshotCanReconcile"],
                "type": "object"
            }))
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
    fn session_list_response_contract_requires_complete_pagination_state() {
        let list = capabilities()
            .expect("session contracts")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "session::list")
            .expect("session::list contract");
        let schema = list
            .response_schema
            .as_ref()
            .expect("session::list response schema");

        let missing = crate::engine::kernel::schema::validate_payload(
            &list.function_id,
            "response",
            schema,
            &json!({}),
        )
        .expect_err("empty list response must fail the wire contract");
        assert!(missing.to_string().contains("$.sessions"));

        crate::engine::kernel::schema::validate_payload(
            &list.function_id,
            "response",
            schema,
            &json!({
                "sessions": [],
                "hasMore": false,
                "nextCursor": null,
                "snapshotAsOf": "2026-07-09T12:00:00.000000001Z",
                "snapshotCanReconcile": true
            }),
        )
        .expect("complete pagination response must pass the wire contract");
    }
}
