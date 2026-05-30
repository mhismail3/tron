//! Server-authored module action catalogs.
//!
//! Generated UI and control surfaces consume these action summaries as data.
//! Keeping the catalogs out of the lifecycle root prevents package mutation
//! flow from becoming the owner of presentation-specific action lists.

use super::*;

use crate::engine::primitives::action_summary::operator_action_summary;

pub(super) fn module_actions_for_trust_target(
    target_type: &str,
    target_resource_id: &str,
) -> Vec<Value> {
    let mut actions = vec![
        module_action(
            INSPECT_TRUST_FUNCTION,
            target_type,
            "targetResourceId",
            json!(target_resource_id),
            "low",
            false,
        ),
        module_action(
            SIMULATE_TRUST_CHANGE_FUNCTION,
            target_type,
            "targetResourceId",
            json!(target_resource_id),
            "low",
            false,
        ),
        module_action(
            RECORD_TRUST_REVIEW_FUNCTION,
            target_type,
            "targetResourceId",
            json!(target_resource_id),
            "medium",
            false,
        ),
    ];
    if matches!(target_type, "trust_root" | "decision") {
        actions.extend([
            module_action(
                RENEW_TRUST_ROOT_FUNCTION,
                "trust_root",
                "trustRootDecisionResourceId",
                json!(target_resource_id),
                "high",
                true,
            ),
            module_action(
                ROTATE_SIGNATURE_KEY_FUNCTION,
                "trust_root",
                "oldTrustRootDecisionResourceId",
                json!(target_resource_id),
                "high",
                true,
            ),
            module_action(
                EXPIRE_TRUST_DECISION_FUNCTION,
                "decision",
                "decisionResourceId",
                json!(target_resource_id),
                "high",
                true,
            ),
            module_action(
                ENFORCE_REVOCATION_FUNCTION,
                "decision",
                "trustDecisionResourceId",
                json!(target_resource_id),
                "high",
                true,
            ),
        ]);
    }
    actions
}

fn module_action(
    function_id: &str,
    target_type: &str,
    target_field: &str,
    target: Value,
    risk: &str,
    approval_required: bool,
) -> Value {
    operator_action_summary(
        function_id,
        target_type,
        target_field,
        target,
        risk,
        approval_required,
    )
}

pub(super) fn module_actions_for_package(package_id: Option<&str>) -> Vec<Value> {
    let target = package_id.map(package_resource_id).map(Value::String);
    vec![
        module_action(
            VERIFY_SOURCE_FUNCTION,
            "package",
            "packageResourceId",
            target.clone().unwrap_or(Value::Null),
            "medium",
            false,
        ),
        module_action(
            APPROVE_SOURCE_FUNCTION,
            "package",
            "packageResourceId",
            target.clone().unwrap_or(Value::Null),
            "high",
            true,
        ),
        module_action(
            REVOKE_SOURCE_APPROVAL_FUNCTION,
            "package",
            "decisionResourceId",
            Value::Null,
            "high",
            true,
        ),
        module_action(
            POLICY_DECIDE_FUNCTION,
            "package",
            "packageResourceId",
            target.clone().unwrap_or(Value::Null),
            "low",
            false,
        ),
        module_action(
            INSPECT_TRUST_FUNCTION,
            "package",
            "targetResourceId",
            target.clone().unwrap_or(Value::Null),
            "low",
            false,
        ),
        module_action(
            SIMULATE_TRUST_CHANGE_FUNCTION,
            "package",
            "targetResourceId",
            target.clone().unwrap_or(Value::Null),
            "low",
            false,
        ),
        module_action(
            RECORD_TRUST_REVIEW_FUNCTION,
            "package",
            "targetResourceId",
            target.clone().unwrap_or(Value::Null),
            "medium",
            false,
        ),
        module_action(
            SCHEDULE_TRUST_AUDIT_FUNCTION,
            "package",
            "selectors",
            target.clone().unwrap_or(Value::Null),
            "medium",
            false,
        ),
        module_action(
            RUN_SCHEDULED_TRUST_AUDIT_FUNCTION,
            "decision",
            "scheduleDecisionResourceId",
            Value::Null,
            "medium",
            false,
        ),
        module_action(
            ENFORCE_REVOCATION_FUNCTION,
            "decision",
            "trustDecisionResourceId",
            Value::Null,
            "high",
            true,
        ),
        module_action(
            RUN_CONFORMANCE_FUNCTION,
            "package",
            "resourceId",
            target.clone().unwrap_or(Value::Null),
            "medium",
            false,
        ),
        module_action(
            CONFIGURE_FUNCTION,
            "package",
            "packageResourceId",
            target.clone().unwrap_or(Value::Null),
            "medium",
            false,
        ),
        module_action(
            ACTIVATE_FUNCTION,
            "package",
            "packageResourceId",
            target.unwrap_or(Value::Null),
            "high",
            true,
        ),
    ]
}
