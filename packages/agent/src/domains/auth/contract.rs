//! Capability contracts owned by the auth domain worker.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel};

pub(crate) const STREAM_TOPICS: &[&str] = &["auth.accounts"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("auth::get", "auth", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .build()?,
        CapabilityContract::new("auth::update", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"apiKey":{"type":["string","null"]},"apiKeyLabel":{"type":"string"},"clientId":{"type":["string","null"]},"clientSecret":{"type":["string","null"]},"oauth":{"additionalProperties":true,"type":["object","null"]},"projectId":{"type":["string","null"]},"provider":{"type":"string"},"service":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("auth::clear", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"provider":{"type":"string"},"service":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("auth::oauth_begin", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"provider":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["provider"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"authUrl":{"type":"string"},"flowId":{"type":"string"}},"required":["flowId","authUrl"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("auth::oauth_complete", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"code":{"type":"string"},"flowId":{"type":"string"},"label":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["flowId","code","label"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("auth::rename_account", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"newLabel":{"type":"string"},"oldLabel":{"type":"string"},"provider":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["provider","oldLabel","newLabel"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("auth::set_active", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"credential":{"additionalProperties":true,"type":"object"},"provider":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["provider","credential"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("auth::remove_account", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"label":{"type":"string"},"provider":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["provider","label"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("auth::remove_api_key", "auth", EffectClass::IdempotentWrite, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"label":{"type":"string"},"provider":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["provider","label"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"providers":{"additionalProperties":true,"type":"object"},"services":{"additionalProperties":true,"type":"object"}},"required":["providers","services"],"type":"object"}))
            .idempotency(IdempotencyContract::system())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
