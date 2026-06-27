use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::domains::approval::types::ApprovalCheckRequirement;
use crate::engine::EngineResourceScope;
use crate::shared::server::errors::CapabilityError;

use super::MODULE_LIFECYCLE_STATE_KIND;
use super::records::scope_ref;
use super::validation::invalid;
use super::{Deps, MODULE_LIFECYCLE_STATE_KIND as KIND};

pub(super) async fn check_lifecycle_approval(
    deps: &Deps,
    scope: &EngineResourceScope,
    lifecycle_resource_id: &str,
    install_decision_resource_id: &str,
    action: &str,
    approval_request_resource_id: &str,
    approval_decision_resource_id: Option<&str>,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let requirement = ApprovalCheckRequirement {
        request_resource_id: approval_request_resource_id.to_owned(),
        decision_resource_id: approval_decision_resource_id.map(str::to_owned),
        action: json!({
            "kind": "module_lifecycle",
            "operation": "module_lifecycle_decision",
            "lifecycleAction": action,
            "metadataOnly": true
        }),
        scope: scope_ref(scope),
        risk_class: "medium".to_owned(),
        resource_selectors: vec![
            json!({"kind": MODULE_LIFECYCLE_STATE_KIND, "resourceId": lifecycle_resource_id}),
            json!({"kind": "module_install_decision", "resourceId": install_decision_resource_id}),
        ],
    };
    let check = crate::domains::approval::service::check_approval_at(
        &deps.engine_host,
        requirement,
        operation_at,
    )
    .await?;
    if !check.allowed {
        return Err(invalid(format!(
            "module lifecycle approval denied: {}",
            check.reason
        )));
    }
    Ok(json!({
        "allowed": check.allowed,
        "outcome": serde_json::to_value(&check.outcome).unwrap_or_else(|_| json!("malformed")),
        "reason": check.reason,
        "riskClass": "medium",
        "requestRef": {
            "kind": "approval_request",
            "resourceId": approval_request_resource_id,
            "role": "approval_request"
        },
        "decisionRef": approval_decision_resource_id.map(|id| json!({
            "kind": "approval_decision",
            "resourceId": id,
            "role": "approval_decision"
        })).unwrap_or(Value::Null),
        "approvalEvidenceOnly": true,
        "derivedAuthorityRequired": true,
        "rawAuthorityIdsStored": false,
        "resourceKind": KIND
    }))
}
