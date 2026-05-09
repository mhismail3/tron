//! Capability contracts owned by the git domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["git.operations"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("git::clone", "git", EffectClass::ExternalSideEffect, RiskLevel::High, Some("git.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"targetPath":{"type":"string"},"url":{"type":"string"},"workspaceId":{"type":"string"}},"required":["url","targetPath"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("git", "clone:{targetPath}", 1800000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "manual cleanup of the target directory is required if clone partially succeeds"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"clone:{targetPath}","kind":"git","reason":"serializes clone operations into one target path","required":true,"ttlMs":1800000},"rollbackOrCompensation":"manual cleanup of the target directory is required if clone partially succeeds","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("git::sync_main", "git", EffectClass::ExternalSideEffect, RiskLevel::High, Some("git.write"))
            .approval_required(true)
            .domain_module("worktree::git_workflow")
            .request_schema(json!({"additionalProperties":false,"properties":{"dryRun":{"type":"boolean"},"fetchTimeoutMs":{"type":"integer"},"prune":{"type":"boolean"},"remote":{"type":"string"},"sessionId":{"type":"string"},"targetBranch":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("git", "session:{sessionId}:sync-main", 900000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "sync_main uses existing stash/reset checks and must be manually inspected on failure"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"session:{sessionId}:sync-main","kind":"git","reason":"serializes main-branch synchronization for the session repository","required":true,"ttlMs":900000},"rollbackOrCompensation":"sync_main uses existing stash/reset checks and must be manually inspected on failure","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("git::push", "git", EffectClass::ExternalSideEffect, RiskLevel::Critical, Some("git.write"))
            .approval_required(true)
            .domain_module("worktree::git_workflow")
            .request_schema(json!({"additionalProperties":false,"properties":{"branch":{"type":"string"},"dryRun":{"type":"boolean"},"forceWithLease":{"type":"boolean"},"overrideProtected":{"type":"boolean"},"protectedBranches":{"items":{"type":"string"},"type":"array"},"remote":{"type":"string"},"sessionId":{"type":"string"},"setUpstream":{"type":"boolean"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("git", "session:{sessionId}:push", 900000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "remote pushes are external side effects; force/protected-branch checks limit blast radius"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"session:{sessionId}:push","kind":"git","reason":"serializes outbound pushes for a session worktree","required":true,"ttlMs":900000},"rollbackOrCompensation":"remote pushes are external side effects; force/protected-branch checks limit blast radius","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("git::list_local_branches", "git", EffectClass::PureRead, RiskLevel::Low, Some("git.read"))
            .domain_module("worktree::git_workflow")
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("git::list_remote_branches", "git", EffectClass::PureRead, RiskLevel::Low, Some("git.read"))
            .domain_module("worktree::git_workflow")
            .request_schema(json!({"additionalProperties":false,"properties":{"remote":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ])
}
