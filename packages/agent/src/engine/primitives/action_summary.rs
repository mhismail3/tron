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
        "label": action_label(function_id),
        "targetType": target_type,
        "targetField": target_field,
        "target": target,
        "requiredRisk": risk,
        "approvalRequired": approval_required,
        "targetRevision": Value::Null,
        "state": "available",
        "consequence": action_consequence(function_id, risk, approval_required, Value::Null),
        "presentation": action_presentation(function_id, None, risk, approval_required),
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
    let action_id = action
        .get("actionId")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    action["consequence"] = action_consequence(
        &target_function_id,
        &risk,
        approval_required,
        target_revision,
    );
    action["presentation"] = action_presentation(
        &target_function_id,
        action_id.as_deref(),
        &risk,
        approval_required,
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

fn action_presentation(
    target_function_id: &str,
    action_id: Option<&str>,
    risk: &str,
    approval_required: bool,
) -> Value {
    let key = format!("{target_function_id} {}", action_id.unwrap_or_default()).to_lowercase();
    let (tone, button_role, icon) = if contains_any(
        &key,
        &[
            "delete",
            "clear",
            "discard",
            "expire",
            "quarantine",
            "remove",
            "revoke",
            "cancel",
        ],
    ) {
        ("destructive", "destructive", "trash")
    } else if contains_any(&key, &["refresh", "reload"]) {
        ("neutral", "neutral", "arrow.clockwise")
    } else if contains_any(
        &key,
        &[
            "create",
            "register",
            "add",
            "schedule",
            "surface_for_target",
        ],
    ) {
        ("primary", "primary", "plus")
    } else if contains_any(&key, &["verify", "approve", "recover", "reconcile"]) {
        ("primary", "primary", "shield.checkered")
    } else if contains_any(&key, &["update", "save", "record", "submit", "mark_read"]) {
        ("primary", "primary", "checkmark")
    } else if contains_any(&key, &["inspect", "audit", "status", "snapshot", "health"]) {
        ("neutral", "neutral", "magnifyingglass")
    } else if approval_required || matches!(risk, "high" | "critical") {
        ("neutral", "neutral", "exclamationmark.triangle")
    } else {
        ("neutral", "neutral", "arrow.right")
    };

    json!({
        "tone": tone,
        "buttonRole": button_role,
        "icon": icon,
    })
}

fn contains_any(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| text.contains(needle))
}

fn action_label(function_id: &str) -> String {
    match function_id {
        "module::register_package" => "Register pack",
        "module::inspect_package" => "Inspect pack",
        "module::configure" => "Configure pack",
        "module::activate" => "Activate pack",
        "module::disable" => "Disable pack",
        "module::upgrade" => "Upgrade pack",
        "module::rollback" => "Roll back",
        "module::quarantine" => "Quarantine",
        "module::remove_package" => "Remove pack",
        "module::check_health" => "Check health",
        "module::verify_integrity" => "Verify integrity",
        "module::recover_activation" => "Recover activation",
        "module::verify_source" => "Verify source",
        "module::approve_source" => "Approve source",
        "module::revoke_source_approval" => "Revoke source approval",
        "module::policy_decide" => "Check policy",
        "module::run_conformance" => "Run conformance",
        "module::register_source" => "Register source",
        "module::verify_signature" => "Verify signature",
        "module::audit_policy" => "Audit policy",
        "module::record_policy_audit" => "Record audit",
        "module::reconcile_trust" => "Reconcile trust",
        "module::inspect_trust" => "Inspect trust",
        "module::renew_trust_root" => "Renew trust root",
        "module::rotate_signature_key" => "Rotate signature key",
        "module::expire_trust_decision" => "Expire trust decision",
        "module::enforce_revocation" => "Enforce revocation",
        "module::simulate_trust_change" => "Simulate trust",
        "module::record_trust_review" => "Record review",
        "module::trust_audit_status" => "Audit status",
        "module::schedule_trust_audit" => "Schedule audit",
        "module::run_scheduled_trust_audit" => "Run audit",
        "module::record_trust_audit_retention" => "Review retention",
        _ => function_id,
    }
    .to_owned()
}
