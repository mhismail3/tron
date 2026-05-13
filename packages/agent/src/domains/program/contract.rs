//! Capability contract for the first-party JavaScript program executor.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["program.runtime"];
pub(crate) const RUN_JAVASCRIPT_FUNCTION_ID: &str = "program::run_javascript";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            RUN_JAVASCRIPT_FUNCTION_ID,
            "program",
            EffectClass::DelegatedInvocation,
            RiskLevel::High,
            Some("program.execute"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("program")
        .request_schema(run_javascript_request_schema())
        .response_schema(run_javascript_response_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "program runs only compose child capabilities; completed child invocations remain ledgered and compensation is delegated to child contracts that declare it",
        ))
        .high_risk_contract(json!({
            "programRuntime": {
                "language": "javascript",
                "runtime": "quickjs",
                "hostAccess": "tools.search/tools.inspect/tools.execute only",
                "approvalBoundary": "child approvals pause the program and cannot be self-approved",
                "limits": [
                    "timeoutMs",
                    "memoryBytes",
                    "stackBytes",
                    "maxOutputBytes",
                    "maxLogBytes",
                    "maxChildCalls",
                    "allowedContracts",
                    "allowedImplementations",
                    "riskMax"
                ]
            },
            "streamTopics": STREAM_TOPICS,
            "version": 1
        }))
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
    ])
}

fn run_javascript_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["language", "code"],
        "properties": {
            "language": {"type": "string", "enum": ["javascript"]},
            "code": {"type": "string", "maxLength": 200000, "description": "JavaScript function body. Return the program result from this body."},
            "args": {"type": "object"},
            "allowedContracts": {"type": "array", "items": {"type": "string"}, "maxItems": 256},
            "allowedImplementations": {"type": "array", "items": {"type": "string"}, "maxItems": 256},
            "timeoutMs": {"type": "integer", "minimum": 10, "maximum": 30000},
            "budget": {
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "riskMax": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
                    "memoryBytes": {"type": "integer", "minimum": 1048576, "maximum": 134217728},
                    "stackBytes": {"type": "integer", "minimum": 65536, "maximum": 8388608},
                    "maxOutputBytes": {"type": "integer", "minimum": 1024, "maximum": 1048576},
                    "maxLogBytes": {"type": "integer", "minimum": 1024, "maximum": 1048576},
                    "maxChildCalls": {"type": "integer", "minimum": 0, "maximum": 128},
                    "maxRecursionDepth": {"type": "integer", "minimum": 0, "maximum": 8}
                }
            },
            "idempotencyKey": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

fn run_javascript_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true,
        "required": ["status", "programRunId", "codeHash", "argsHash", "childInvocations", "selectedImplementations"],
        "properties": {
            "status": {"type": "string"},
            "output": {},
            "error": {"type": ["object", "null"]},
            "traceId": {"type": "string"},
            "programRunId": {"type": "string"},
            "codeHash": {"type": "string"},
            "argsHash": {"type": "string"},
            "childInvocations": {"type": "array", "items": {"type": "string"}},
            "selectedImplementations": {"type": "array", "items": {"type": "string"}},
            "approvalState": {"type": ["object", "null"]},
            "artifacts": {"type": "array"},
            "logs": {"type": "array", "items": {"type": "string"}}
        }
    })
}
