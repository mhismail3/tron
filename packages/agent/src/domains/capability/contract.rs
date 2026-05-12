//! Capability contracts owned by the capability domain worker.
//!
//! This worker is the model-facing harness collapse point: providers see only
//! `search`, `inspect`, and `execute`, while actual behavior remains owned by
//! live domain/plugin workers in the engine catalog.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["capability.runtime"];

pub(crate) const SEARCH_FUNCTION_ID: &str = "capability::search";
pub(crate) const INSPECT_FUNCTION_ID: &str = "capability::inspect";
pub(crate) const EXECUTE_FUNCTION_ID: &str = "capability::execute";

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            SEARCH_FUNCTION_ID,
            "capability",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("capability.search"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("capability")
        .request_schema(search_request_schema())
        .response_schema(tool_result_schema())
        .build()?,
        CapabilityContract::new(
            INSPECT_FUNCTION_ID,
            "capability",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("capability.inspect"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("capability")
        .request_schema(inspect_request_schema())
        .response_schema(tool_result_schema())
        .build()?,
        CapabilityContract::new(
            EXECUTE_FUNCTION_ID,
            "capability",
            EffectClass::DelegatedInvocation,
            RiskLevel::Medium,
            Some("capability.execute"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("capability")
        .request_schema(execute_request_schema())
        .response_schema(tool_result_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .build()?,
    ])
}

pub(crate) fn model_metadata(function_id: &str) -> serde_json::Value {
    match function_id {
        SEARCH_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelToolName": "search",
            "toolOrder": 10,
            "toolExecutionMode": {"kind": "serialized", "group": "capability"},
            "toolSchema": {
                "name": "search",
                "description": "Search the live Tron capability catalog for contracts, implementations, workers, plugins, examples, and docs visible to this session.",
                "parameters": search_request_schema()
            }
        }),
        INSPECT_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelToolName": "inspect",
            "toolOrder": 20,
            "toolExecutionMode": {"kind": "serialized", "group": "capability"},
            "toolSchema": {
                "name": "inspect",
                "description": "Inspect one capability contract or implementation, including schemas, authority, risk, provenance, idempotency, and expected revision.",
                "parameters": inspect_request_schema()
            }
        }),
        EXECUTE_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelToolName": "execute",
            "toolOrder": 30,
            "toolExecutionMode": {"kind": "serialized", "group": "capability"},
            "toolSchema": {
                "name": "execute",
                "description": "Execute a live capability by contract, implementation, capability, or function id. Inspect first for mutating or elevated-risk work.",
                "parameters": execute_request_schema()
            }
        }),
        _ => serde_json::Value::Null,
    }
}

fn search_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "query": {"type": "string", "description": "Natural language or identifier search over live capabilities."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50},
            "cursor": {"type": "string"},
            "kind": {"type": "string", "enum": ["contract", "implementation", "plugin", "worker", "function"]},
            "contractId": {"type": "string"},
            "namespace": {"type": "string"},
            "pluginId": {"type": "string"},
            "effect": {"type": "string"},
            "riskMax": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
            "trustTierMin": {"type": "string"},
            "includeUnavailable": {"type": "boolean"},
            "scope": {"type": "string"}
        }
    })
}

fn inspect_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "capabilityId": {"type": "string"},
            "contractId": {"type": "string"},
            "implementationId": {"type": "string"},
            "functionId": {"type": "string"},
            "includeExamples": {"type": "boolean"},
            "includeDocs": {"type": "boolean"},
            "includePolicy": {"type": "boolean"}
        }
    })
}

fn execute_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["mode"],
        "additionalProperties": false,
        "properties": {
            "mode": {"type": "string", "enum": ["invoke"]},
            "capabilityId": {"type": "string"},
            "contractId": {"type": "string"},
            "implementationId": {"type": "string"},
            "functionId": {"type": "string"},
            "payload": {"type": "object"},
            "expectedRevision": {"type": "integer", "minimum": 1},
            "idempotencyKey": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

fn tool_result_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true,
        "properties": {
            "content": {},
            "details": {},
            "isError": {"type": "boolean"},
            "stopTurn": {"type": "boolean"}
        },
        "required": ["content"]
    })
}
