//! Operator action catalog for the control projection.

use serde_json::{Value, json};

use crate::engine::primitives::action_summary::operator_action_summary;

pub(super) fn substrate_actions() -> Vec<Value> {
    let no_scopes: Vec<String> = Vec::new();
    let grant_write = vec!["grant.write".to_owned()];
    let worker_write = vec!["worker.write".to_owned()];
    let agent_write = vec!["agent.write".to_owned()];
    vec![
        action_summary(
            "ui::surface_for_target",
            "*",
            "targetId",
            "medium",
            &no_scopes,
        ),
        action_summary(
            "ui::refresh_surface",
            "*",
            "surfaceResourceId",
            "medium",
            &no_scopes,
        ),
        action_summary("grant::revoke", "grant", "grantId", "high", &grant_write),
        action_summary(
            "worker::disconnect",
            "worker",
            "workerId",
            "high",
            &worker_write,
        ),
        action_summary(
            "resource::link",
            "resource",
            "sourceResourceId",
            "medium",
            &no_scopes,
        ),
        action_summary(
            "artifact::promote",
            "resource",
            "resourceId",
            "medium",
            &no_scopes,
        ),
        action_summary("agent::abort", "goal", "sessionId", "high", &agent_write),
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
    authority_scopes: &[String],
) -> Value {
    operator_action_summary(
        function_id,
        target_type,
        target_field,
        Value::Null,
        risk,
        authority_scopes,
    )
}
