//! Canonical operator action summaries and consequence projections.
//!
//! Control, module inspection, trust-audit status, and generated UI surfaces all
//! describe "what can be done next". This helper keeps that projection shape
//! consistent while leaving all mutations routed through the canonical target
//! capabilities.

use serde_json::{Value, json};

/// Build a bounded operator action summary for control/module projections.
pub(crate) fn operator_action_summary(
    function_id: &str,
    target_type: &str,
    target_field: &str,
    target: Value,
    risk: &str,
    approval_required: bool,
) -> Value {
    json!({
        "functionId": function_id,
        "targetType": target_type,
        "targetField": target_field,
        "target": target,
        "requiredRisk": risk,
        "approvalRequired": approval_required,
        "targetRevision": Value::Null,
        "state": "available",
        "consequence": action_consequence(function_id, risk, approval_required, Value::Null),
    })
}

/// Add consequence metadata to a stored generated-UI action.
pub(crate) fn with_stored_action_consequence(mut action: Value) -> Value {
    let target_function_id = action
        .get("targetFunctionId")
        .and_then(Value::as_str)
        .unwrap_or("unknown::unknown")
        .to_owned();
    let risk = action
        .get("requiredRisk")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned();
    let approval_required = action
        .get("approvalPolicy")
        .and_then(|policy| policy.get("required"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let target_revision = action.get("targetRevision").cloned().unwrap_or(Value::Null);
    action["consequence"] = action_consequence(
        &target_function_id,
        &risk,
        approval_required,
        target_revision,
    );
    action
}

fn action_consequence(
    target_function_id: &str,
    risk: &str,
    approval_required: bool,
    target_revision: Value,
) -> Value {
    json!({
        "kind": "canonical_capability_invocation",
        "targetFunctionId": target_function_id,
        "recommendedCanonicalAction": target_function_id,
        "targetRevision": target_revision,
        "requiredRisk": risk,
        "approvalRequired": approval_required,
        "state": "available",
        "blockedReason": Value::Null,
        "staleReason": Value::Null,
        "supportingRefs": [],
    })
}
