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
            let (key, value) = match target_type {
                "worker" => ("workerId", json!(target_id)),
                "grant" => ("grantId", json!(target_id)),
                "goal" | "resource" => ("resourceId", json!(target_id)),
                _ => ("targetId", json!(target_id)),
            };
            action["target"] = json!({
                "field": key,
                "value": value,
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
