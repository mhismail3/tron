//! Operator action catalog for the control projection.

use serde_json::{Value, json};

use crate::engine::primitives::action_summary::operator_action_summary;

pub(super) fn substrate_actions() -> Vec<Value> {
    vec![
        action_summary("ui::surface_for_target", "*", "targetId", "medium", false),
        action_summary(
            "ui::refresh_surface",
            "*",
            "surfaceResourceId",
            "medium",
            false,
        ),
        action_summary("grant::revoke", "grant", "grantId", "high", true),
        action_summary("worker::disconnect", "worker", "workerId", "high", true),
        action_summary(
            "resource::link",
            "resource",
            "sourceResourceId",
            "medium",
            false,
        ),
        action_summary(
            "artifact::promote",
            "resource",
            "resourceId",
            "medium",
            false,
        ),
        action_summary(
            "approval::resolve",
            "approval",
            "approvalId",
            "medium",
            false,
        ),
        action_summary("agent::abort", "goal", "sessionId", "high", true),
        action_summary(
            "module::inspect_package",
            "package",
            "packageId",
            "low",
            false,
        ),
        action_summary(
            "module::configure",
            "package",
            "packageResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::activate",
            "package",
            "packageResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::disable",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::upgrade",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::rollback",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::quarantine",
            "activation",
            "resourceId",
            "high",
            true,
        ),
        action_summary(
            "module::check_health",
            "activation",
            "activationResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::verify_integrity",
            "activation",
            "resourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::recover_activation",
            "activation",
            "activationResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::verify_source",
            "package",
            "packageResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::approve_source",
            "package",
            "packageResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::revoke_source_approval",
            "package",
            "decisionResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::policy_decide",
            "package",
            "packageResourceId",
            "low",
            false,
        ),
        action_summary(
            "module::run_conformance",
            "package",
            "resourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::register_source",
            "package",
            "packageResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::verify_signature",
            "package",
            "packageResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::audit_policy",
            "package",
            "packageResourceId",
            "low",
            false,
        ),
        action_summary(
            "module::record_policy_audit",
            "package",
            "packageResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::reconcile_trust",
            "package",
            "packageResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::inspect_trust",
            "package",
            "targetResourceId",
            "low",
            false,
        ),
        action_summary(
            "module::renew_trust_root",
            "decision",
            "trustRootDecisionResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::rotate_signature_key",
            "decision",
            "oldTrustRootDecisionResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::expire_trust_decision",
            "decision",
            "decisionResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::enforce_revocation",
            "decision",
            "trustDecisionResourceId",
            "high",
            true,
        ),
        action_summary(
            "module::simulate_trust_change",
            "package",
            "targetResourceId",
            "low",
            false,
        ),
        action_summary(
            "module::record_trust_review",
            "package",
            "targetResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::trust_audit_status",
            "decision",
            "scheduleDecisionResourceId",
            "low",
            false,
        ),
        action_summary(
            "module::schedule_trust_audit",
            "package",
            "selectors",
            "medium",
            false,
        ),
        action_summary(
            "module::run_scheduled_trust_audit",
            "decision",
            "scheduleDecisionResourceId",
            "medium",
            false,
        ),
        action_summary(
            "module::record_trust_audit_retention",
            "decision",
            "scheduleDecisionResourceId",
            "medium",
            false,
        ),
    ]
}

pub(super) fn actions_for_target(target_type: &str, target_id: &str) -> Vec<Value> {
    substrate_actions()
        .into_iter()
        .filter(|action| {
            action
                .get("targetType")
                .and_then(Value::as_str)
                .is_none_or(|kind| {
                    kind == "*"
                        || kind == target_type
                        || target_type == "goal" && kind == "resource"
                })
        })
        .map(|mut action| {
            let key = match target_type {
                "worker" => "workerId",
                "grant" => "grantId",
                "package" => "packageId",
                "activation" => "activationResourceId",
                "goal" | "resource" => "resourceId",
                _ => "targetId",
            };
            action["target"] = json!({
                "field": key,
                "value": target_id,
            });
            action
        })
        .collect()
}

fn action_summary(
    function_id: &str,
    target_type: &str,
    target_field: &str,
    risk: &str,
    approval_required: bool,
) -> Value {
    operator_action_summary(
        function_id,
        target_type,
        target_field,
        Value::Null,
        risk,
        approval_required,
    )
}
