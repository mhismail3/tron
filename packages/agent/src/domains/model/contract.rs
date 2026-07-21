//! Capability contracts owned by the model domain worker.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel};

pub(crate) const STREAM_TOPICS: &[&str] = &["model.config"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("model::list", "model", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"models":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["models"],"type":"object"}))
            .build()?,
        CapabilityContract::new("model::switch", "model", EffectClass::ReversibleSideEffect, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"model":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","model"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"newModel":{"type":"string"},"previousModel":{"type":"string"}},"required":["previousModel","newModel"],"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn list_request_contains_only_client_owned_correlation() {
        let list = capabilities()
            .expect("model contracts")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "model::list")
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
}
