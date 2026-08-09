//! Function contracts owned by the model domain worker.

use serde_json::json;

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, IdempotencyContract, Result as EngineResult, RiskLevel,
};

/// Canonical function contracts exposed by this domain worker.
pub(crate) fn function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    Ok(vec![
        FunctionContract::new("model::list", "model", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"models":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["models"],"type":"object"}))
            .build()?,
        FunctionContract::new("model::switch", "model", EffectClass::ReversibleSideEffect, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"model":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","model"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"newModel":{"type":"string"},"previousModel":{"type":"string"}},"required":["previousModel","newModel"],"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("model::set_reasoning_level", "model", EffectClass::ReversibleSideEffect, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"level":{"type":"string"},"sessionId":{"type":"string"}},"required":["sessionId","level"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"changed":{"type":"boolean"},"newLevel":{"type":"string"},"previousLevel":{"type":["string","null"]}},"required":["previousLevel","newLevel","changed"],"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?
    ])
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;
    use crate::engine::DedupeScope;

    #[test]
    fn list_request_contains_only_client_owned_correlation() {
        let list = function_definitions()
            .expect("model contracts")
            .into_iter()
            .find(|definition| definition.id.as_str() == "model::list")
            .expect("model list contract");
        let properties = list.request_schema.expect("request schema")["properties"]
            .as_object()
            .expect("request properties")
            .keys()
            .cloned()
            .collect::<BTreeSet<_>>();
        assert_eq!(
            properties,
            BTreeSet::from(["sessionId".to_owned(), "workspaceId".to_owned()])
        );
    }

    #[test]
    fn reasoning_selection_is_a_closed_session_scoped_write_contract() {
        let definition = function_definitions()
            .expect("model contracts")
            .into_iter()
            .find(|definition| definition.id.as_str() == "model::set_reasoning_level")
            .expect("reasoning selection contract");
        let schema = definition
            .request_schema
            .as_ref()
            .expect("reasoning request schema");

        crate::engine::kernel::schema::validate_payload(
            &definition.id,
            "request",
            schema,
            &json!({"sessionId":"session-1","level":"high"}),
        )
        .expect("exact session reasoning selection must validate");
        assert!(
            crate::engine::kernel::schema::validate_payload(
                &definition.id,
                "request",
                schema,
                &json!({"sessionId":"session-1","level":"high","model":"gpt-5.6-sol"}),
            )
            .is_err(),
            "the server resolves the session model; clients cannot race it in this write"
        );
        assert_eq!(
            definition
                .idempotency
                .expect("reasoning write idempotency")
                .dedupe_scope,
            DedupeScope::Session
        );
    }
}
