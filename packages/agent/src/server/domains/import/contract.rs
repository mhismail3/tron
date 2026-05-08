//! Capability contracts owned by the import domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("import::list_sources", "import", EffectClass::PureRead, RiskLevel::Low, Some("import.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("import::list_sessions", "import", EffectClass::PureRead, RiskLevel::Low, Some("import.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"encodedDir":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["encodedDir"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("import::preview_session", "import", EffectClass::PureRead, RiskLevel::Low, Some("import.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"sessionPath":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionPath"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("import::execute", "import", EffectClass::AppendOnlyEvent, RiskLevel::High, Some("import.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"sessionPath":{"type":"string"},"tags":{"items":{"type":"string"},"type":"array"},"workingDirectory":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionPath"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"alreadyImported":{"type":"boolean"},"cost":{"type":"number"},"eventCount":{"type":"integer"},"existingSessionId":{"type":"string"},"messageCount":{"type":"integer"},"model":{"type":"string"},"sessionId":{"type":"string"},"turnCount":{"type":"integer"},"warnings":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"workingDirectory":{"type":"string"}},"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("import", "import:{sessionPath}", 300000))
            .compensation(CompensationContract::new(CompensationKind::EventSourced, "import is append-only and duplicate sources return alreadyImported; full rollback is deferred"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"import:{canonicalSessionPath}","kind":"import","reason":"serializes session import for one source transcript path","required":true,"ttlMs":300000},"rollbackOrCompensation":"import is append-only and duplicate sources return alreadyImported; full rollback is deferred","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?
    ])
}
