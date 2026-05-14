//! Capability contracts owned by the job domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["jobs.status"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("job::background", "job", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("job.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId","sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"backgrounded":{"type":"boolean"},"jobId":{"type":"string"}},"required":["jobId","backgrounded"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("job::cancel", "job", EffectClass::IdempotentWrite, RiskLevel::High, Some("job.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId","sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"cancelled":{"type":"boolean"},"jobId":{"type":"string"}},"required":["jobId","cancelled"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("job::list", "job", EffectClass::PureRead, RiskLevel::Low, Some("job.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"jobs":{"type":"array"}},"required":["jobs"],"type":"object"}))
            .lifecycle(json!({"kind": "immediate"}))
            .tags(vec!["jobs", "list jobs", "background processes", "subagents"])
            .build()?,
        CapabilityContract::new("job::wait", "job", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("job.write"))
            .description("Wait for one or more background process or subagent jobs to complete and return partial results on timeout.")
            .request_schema(json!({"additionalProperties":false,"properties":{"jobIds":{"items":{"type":"string"},"type":"array"},"mode":{"type":"string","enum":["all","any"]},"sessionId":{"type":"string"},"timeoutMs":{"type":"integer","minimum":1,"maximum":3600000},"workspaceId":{"type":"string"}},"required":["sessionId","jobIds"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "waiting is read-like over an existing async run; completed children remain ledgered"))
            .lifecycle(json!({"kind": "async_run", "stopsTurn": false, "statusContractId": "job::list", "cancelContractId": "job::cancel", "streamTopics": STREAM_TOPICS}))
            .presentation_hints(json!({"icon": "clock", "chipTitle": "Wait", "summaryFields": ["jobIds", "mode", "timeoutMs"]}))
            .tags(vec!["wait", "job wait", "background job", "subagent wait", "process wait"])
            .examples(vec![json!({"summary": "Wait up to five minutes for a subagent job.", "payload": {"sessionId": "current-session", "jobIds": ["subagent-session-id"], "mode": "all", "timeoutMs": 300000}})])
            .build()?,
        CapabilityContract::new("job::stream_output", "job", EffectClass::PureRead, RiskLevel::Low, Some("job.read"))
            .description("Read the retained output buffer for a background process job.")
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"offset":{"type":"integer","minimum":0},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .lifecycle(json!({"kind": "stream", "streamTopics": STREAM_TOPICS}))
            .presentation_hints(json!({"icon": "terminal", "chipTitle": "Output", "summaryFields": ["jobId", "offset"]}))
            .tags(vec!["stream output", "job output", "stdout", "stderr", "logs"])
            .build()?,
        CapabilityContract::new("job::subscribe", "job", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("job.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId","sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"subscribed":{"type":"boolean"}},"required":["subscribed","jobId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("job::unsubscribe", "job", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("job.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"unsubscribed":{"type":"boolean"}},"required":["jobId","unsubscribed"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
