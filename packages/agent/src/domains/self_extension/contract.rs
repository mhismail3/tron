//! Capability contracts owned by the self-extension domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &[];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "self_extension::grant_workspace_autonomy",
            "self_extension",
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            Some("self_extension.write"),
        )
        .visibility(VisibilityScope::System)
        .approval_required(true)
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["workspaceId", "workspacePath"],
            "properties": {
                "workspaceId": {"type": "string"},
                "workspacePath": {"type": "string"},
                "sessionId": {"type": "string"},
                "reason": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "required": [
                "status",
                "grantId",
                "grantRevision",
                "workspaceId",
                "workspacePath",
                "summary",
                "allowedWork",
                "nextActions",
                "grant"
            ],
            "properties": {
                "status": {"type": "string", "enum": ["approved"]},
                "grantId": {"type": "string"},
                "grantRevision": {"type": "integer"},
                "workspaceId": {"type": "string"},
                "workspacePath": {"type": "string"},
                "summary": {"type": "string"},
                "allowedWork": {"type": "array", "items": {"type": "string"}},
                "nextActions": {"type": "array", "items": {"type": "string"}},
                "grant": {"type": "object"}
            }
        }))
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .resource_lease(ResourceLeaseRequirement::exclusive_template(
            "workspace-autonomy",
            "workspace-autonomy:{workspaceId}",
            60000,
        ))
        .compensation(CompensationContract::new(
            CompensationKind::InverseCommandAvailable,
            "the derived workspace autonomy grant is reversible through grant::revoke and all child capability work remains ledgered under the grant",
        ))
        .high_risk_contract(json!({
            "approvalRequiredForAgentVisibility": true,
            "workspaceAutonomy": {
                "approvedByUser": true,
                "grantFunction": "grant::derive",
                "consumer": "worker::spawn",
                "scope": "workspace",
                "networkPolicy": "loopback",
                "summary": "Safe in this workspace"
            },
            "resourceLock": {
                "idTemplate": "workspace-autonomy:{workspaceId}",
                "kind": "workspace-autonomy",
                "reason": "serializes autonomy grant creation for one workspace",
                "required": true,
                "ttlMs": 60000
            },
            "rollbackOrCompensation": "grant::revoke disables the workspace autonomy grant; spawned helpers remain separately stoppable through sandbox::stop_spawned_worker",
            "streamTopics": STREAM_TOPICS,
            "version": 1
        }))
        .presentation_hints(json!({
            "displayName": "Workspace autonomy",
            "chipTitle": "Workspace autonomy",
            "summary": "Allow local capability work in this workspace",
            "generatingLabel": "Preparing workspace autonomy",
            "runningLabel": "Preparing workspace autonomy",
            "approvalLabel": "Review workspace autonomy",
            "successLabel": "Workspace autonomy enabled",
            "failureLabel": "Review needed",
            "icon": "shield.lefthalf.filled",
            "themeColor": "#48C6A8"
        }))
        .tags(vec![
            "self extension",
            "workspace autonomy",
            "local capability work",
            "create helper capability",
        ])
        .examples(vec![json!({
            "summary": "Approve local capability creation for the active workspace.",
            "payload": {
                "workspaceId": "current-workspace",
                "workspacePath": "/path/to/workspace",
                "reason": "Create and test a local helper capability."
            }
        })])
        .build()?
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_autonomy_contract_is_approval_owned_and_product_facing() {
        let specs = capabilities().expect("self-extension capabilities build");
        let grant = specs
            .iter()
            .find(|spec| spec.function_id.as_str() == "self_extension::grant_workspace_autonomy")
            .expect("workspace autonomy grant spec exists");

        assert_eq!(grant.authority_scope, Some("self_extension.write"));
        assert!(grant.approval_required);
        assert_eq!(grant.risk_level, RiskLevel::High);
        assert_eq!(grant.visibility, VisibilityScope::System);
        let idempotency = grant.idempotency.as_ref().unwrap();
        assert_eq!(idempotency.dedupe_scope, VisibilityScope::Session);
        assert_eq!(
            idempotency.ledger_kind,
            crate::engine::LedgerKind::EngineLedger
        );
        assert_eq!(
            grant
                .high_risk_contract
                .as_ref()
                .unwrap()
                .pointer("/workspaceAutonomy/grantFunction"),
            Some(&json!("grant::derive"))
        );
        assert_eq!(
            grant
                .high_risk_contract
                .as_ref()
                .unwrap()
                .pointer("/workspaceAutonomy/consumer"),
            Some(&json!("worker::spawn"))
        );
        assert_eq!(
            grant
                .presentation_hints
                .as_ref()
                .unwrap()
                .get("summary")
                .and_then(serde_json::Value::as_str),
            Some("Allow local capability work in this workspace")
        );
    }
}
