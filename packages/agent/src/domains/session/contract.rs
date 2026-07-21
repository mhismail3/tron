//! Function contracts owned by the session domain worker.

use serde_json::json;

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, IdempotencyContract, Result as EngineResult, RiskLevel,
};

/// Canonical function contracts exposed by this domain worker.
pub(crate) fn function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    Ok(vec![
        FunctionContract::new("session::create", "session", EffectClass::IdempotentWrite, RiskLevel::Medium)
            .request_schema(json!({"additionalProperties":false,"properties":{"model":{"type":"string"},"title":{"type":"string"},"workingDirectory":{"type":"string"}},"required":["workingDirectory"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::profile())
            .build()?,
        FunctionContract::new("session::resume", "session", EffectClass::IdempotentWrite, RiskLevel::Medium)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("session::list", "session", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"cursor":{"type":"string"},"includeArchived":{"type":"boolean"},"limit":{"maximum":200,"minimum":1,"type":"integer"},"offset":{"minimum":0,"type":"integer"},"workingDirectory":{"type":"string"}},"type":"object"}))
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
        FunctionContract::new("session::delete", "session", EffectClass::IrreversibleSideEffect, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("session::fork", "session", EffectClass::IdempotentWrite, RiskLevel::Medium)
            .request_schema(json!({"additionalProperties":false,"properties":{"fromEventId":{"type":"string"},"sessionId":{"type":"string"},"title":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("session::get_head", "session", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        FunctionContract::new("session::get_state", "session", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        FunctionContract::new("session::get_history", "session", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"beforeId":{"type":"string"},"limit":{"type":"integer"},"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        FunctionContract::new("session::reconstruct", "session", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"beforeEventId":{"type":"string"},"limit":{"type":"integer"},"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        FunctionContract::new("session::archive", "session", EffectClass::IdempotentWrite, RiskLevel::Medium)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("session::unarchive", "session", EffectClass::IdempotentWrite, RiskLevel::Medium)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("session::archive_older_than", "session", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"days":{"type":"integer"}},"required":["days"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::profile())
            .build()?,
        FunctionContract::new("session::export", "session", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        FunctionContract::new("session::replay_manifest", "session", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ])
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};

    use super::*;

    #[test]
    fn session_contracts_contain_only_behavioral_inputs() {
        let expected = BTreeMap::from([
            (
                "session::create",
                &["model", "title", "workingDirectory"][..],
            ),
            ("session::resume", &["sessionId"][..]),
            (
                "session::list",
                &[
                    "cursor",
                    "includeArchived",
                    "limit",
                    "offset",
                    "workingDirectory",
                ][..],
            ),
            ("session::delete", &["sessionId"][..]),
            ("session::fork", &["fromEventId", "sessionId", "title"][..]),
            ("session::get_head", &["sessionId"][..]),
            ("session::get_state", &["sessionId"][..]),
            (
                "session::get_history",
                &["beforeId", "limit", "sessionId"][..],
            ),
            (
                "session::reconstruct",
                &["beforeEventId", "limit", "sessionId"][..],
            ),
            ("session::archive", &["sessionId"][..]),
            ("session::unarchive", &["sessionId"][..]),
            ("session::archive_older_than", &["days"][..]),
            ("session::export", &["sessionId"][..]),
            ("session::replay_manifest", &["sessionId"][..]),
        ]);
        let definitions = function_definitions().expect("session contracts");
        assert_eq!(definitions.len(), expected.len());
        for definition in definitions {
            let expected = expected
                .get(definition.id.as_str())
                .unwrap_or_else(|| panic!("unexpected session function {}", definition.id));
            let properties = definition.request_schema.expect("request schema")["properties"]
                .as_object()
                .expect("request properties")
                .keys()
                .cloned()
                .collect::<BTreeSet<_>>();
            assert_eq!(
                properties,
                expected.iter().map(|key| (*key).to_owned()).collect(),
                "{} advertises an input its production operation does not consume",
                definition.id
            );
        }
    }

    #[test]
    fn session_list_contract_accepts_a_server_issued_page_two_cursor() {
        let list = function_definitions()
            .expect("session contracts")
            .into_iter()
            .find(|definition| definition.id.as_str() == "session::list")
            .expect("session::list contract");
        let schema = list
            .request_schema
            .as_ref()
            .expect("session::list request schema");

        crate::engine::kernel::schema::validate_payload(
            &list.id,
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
        let list = function_definitions()
            .expect("session contracts")
            .into_iter()
            .find(|definition| definition.id.as_str() == "session::list")
            .expect("session::list contract");
        let schema = list
            .response_schema
            .as_ref()
            .expect("session::list response schema");

        let missing = crate::engine::kernel::schema::validate_payload(
            &list.id,
            "response",
            schema,
            &json!({}),
        )
        .expect_err("empty list response must fail the wire contract");
        assert!(missing.to_string().contains("$.sessions"));

        crate::engine::kernel::schema::validate_payload(
            &list.id,
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
