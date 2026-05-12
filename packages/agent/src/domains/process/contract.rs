//! Capability contracts owned by the process domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["process.output", "process.status"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "process::run",
            "process",
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
            Some("process.run"),
        )
        .approval_required(true)
        .request_schema(json!({
            "additionalProperties": false,
            "properties": {
                "command": {"type": "string"},
                "cwd": {"type": "string"},
                "env": {"additionalProperties": true, "type": "object"},
                "shell": {"type": "string", "enum": ["bash", "zsh", "sh"]},
                "stdin": {"type": "string"},
                "timeoutMs": {"type": "integer", "minimum": 1, "maximum": 600000},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            },
            "required": ["command"],
            "type": "object"
        }))
        .response_schema(json!({
            "additionalProperties": false,
            "properties": {
                "stdout": {"type": "string"},
                "stderr": {"type": "string"},
                "exitCode": {"type": "integer"},
                "durationMs": {"type": "integer"},
                "timedOut": {"type": "boolean"},
                "outputTruncated": {"type": "boolean"}
            },
            "required": ["stdout", "stderr", "exitCode", "durationMs", "timedOut", "outputTruncated"],
            "type": "object"
        }))
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .resource_lease(ResourceLeaseRequirement::exclusive_template(
            "process",
            "process:{sessionId}",
            600000,
        ))
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "external processes may mutate host state; command output and trace records are the audit boundary",
        ))
        .high_risk_contract(json!({
            "approvalRequiredForAgentVisibility": true,
            "resourceLock": {
                "idTemplate": "process:{sessionId}",
                "kind": "process",
                "reason": "serializes high-risk shell execution within one session",
                "required": true,
                "ttlMs": 600000
            },
            "rollbackOrCompensation": "external processes may mutate host state and require manual compensation",
            "streamTopics": STREAM_TOPICS,
            "version": 1
        }))
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
    ])
}
