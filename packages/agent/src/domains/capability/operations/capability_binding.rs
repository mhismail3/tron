//! Capability binding execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn capability_binding_request_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::record_capability_binding_request_value_at(
            &binding_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Capability binding request recorded.",
        "capability_binding_request_record",
        details,
    ))
}

pub(super) async fn capability_binding_request_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::list_capability_binding_request_value(
            &binding_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    let count = details
        .get("bindingRequests")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} capability binding request(s)."),
        "capability_binding_request_list",
        details,
    ))
}

pub(super) async fn capability_binding_request_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::inspect_capability_binding_request_value(
            &binding_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(result(
        "Inspected capability binding request.",
        "capability_binding_request_inspect",
        details,
    ))
}

pub(super) async fn capability_binding_decision_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::record_capability_binding_decision_value_at(
            &binding_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Capability binding decision recorded.",
        "capability_binding_decision_record",
        details,
    ))
}

pub(super) async fn capability_binding_decision_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::list_capability_binding_decision_value(
            &binding_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    let count = details
        .get("bindingDecisions")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} capability binding decision(s)."),
        "capability_binding_decision_list",
        details,
    ))
}

pub(super) async fn capability_binding_decision_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::inspect_capability_binding_decision_value(
            &binding_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(result(
        "Inspected capability binding decision.",
        "capability_binding_decision_inspect",
        details,
    ))
}

pub(super) async fn capability_binding_policy_activate(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::activate_capability_binding_policy_value_at(
            &binding_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Capability binding policy activated.",
        "capability_binding_policy_activate",
        details,
    ))
}

pub(super) async fn capability_binding_policy_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::list_capability_binding_policy_value(
            &binding_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    let count = details
        .get("bindingPolicies")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} capability binding policy record(s)."),
        "capability_binding_policy_list",
        details,
    ))
}

pub(super) async fn capability_binding_policy_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::service::inspect_capability_binding_policy_value(
            &binding_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(result(
        "Inspected capability binding policy.",
        "capability_binding_policy_inspect",
        details,
    ))
}

pub(super) async fn capability_binding_cockpit_overview(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::service::cockpit_overview_value(
        &binding_deps,
        invocation,
    )
    .await?;
    let content = cockpit_overview_content(&details);
    let details = cockpit_overview_result_details(details);
    Ok(result(
        &content,
        "capability_binding_cockpit_overview",
        details,
    ))
}

pub(super) async fn capability_shadow_trial_request_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::shadow_trial::record_capability_shadow_trial_request_value_at(
            &binding_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(shadow_result(
        "Capability shadow trial request recorded.",
        "capability_shadow_trial_request_record",
        details,
    ))
}

pub(super) async fn capability_shadow_trial_decision_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::shadow_trial::record_capability_shadow_trial_decision_value_at(
            &binding_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(shadow_result(
        "Capability shadow trial decision recorded.",
        "capability_shadow_trial_decision_record",
        details,
    ))
}

pub(super) async fn capability_shadow_trial_run_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::shadow_trial::record_capability_shadow_trial_run_value_at(
            &binding_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(shadow_result(
        "Capability shadow trial run recorded.",
        "capability_shadow_trial_run_record",
        details,
    ))
}

pub(super) async fn capability_shadow_trial_evidence_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::capability_binding::shadow_trial::inspect_capability_shadow_trial_evidence_value(
            &binding_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(shadow_result(
        "Inspected capability shadow trial evidence.",
        "capability_shadow_trial_evidence_inspect",
        details,
    ))
}

pub(super) async fn capability_replacement_candidate_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::record_replacement_candidate_value_at(
        &binding_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(route_result(
        "Capability replacement candidate recorded.",
        "capability_replacement_candidate_record",
        details,
    ))
}

pub(super) async fn capability_replacement_candidate_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::list_replacement_candidate_value(
        &binding_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("replacementCandidates")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(route_result(
        &format!("Listed {count} capability replacement candidate(s)."),
        "capability_replacement_candidate_list",
        details,
    ))
}

pub(super) async fn capability_replacement_candidate_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::inspect_replacement_candidate_value(
        &binding_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(route_result(
        "Inspected capability replacement candidate.",
        "capability_replacement_candidate_inspect",
        details,
    ))
}

pub(super) async fn capability_route_binding_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::record_route_binding_value_at(
        &binding_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(route_result(
        "Capability route binding recorded.",
        "capability_route_binding_record",
        details,
    ))
}

pub(super) async fn capability_route_binding_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::list_route_binding_value(
        &binding_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("routeBindings")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(route_result(
        &format!("Listed {count} capability route binding(s)."),
        "capability_route_binding_list",
        details,
    ))
}

pub(super) async fn capability_route_binding_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::inspect_route_binding_value(
        &binding_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(route_result(
        "Inspected capability route binding.",
        "capability_route_binding_inspect",
        details,
    ))
}

pub(super) async fn capability_route_activate(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::activate_route_value_at(
        &binding_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(route_result(
        "Capability route activated.",
        "capability_route_activate",
        details,
    ))
}

pub(super) async fn capability_route_disable(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::disable_route_value_at(
        &binding_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(route_result(
        "Capability route disabled.",
        "capability_route_disable",
        details,
    ))
}

pub(super) async fn capability_route_rollback(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::rollback_route_value_at(
        &binding_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(route_result(
        "Capability route rolled back.",
        "capability_route_rollback",
        details,
    ))
}

pub(super) async fn capability_route_event_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::list_route_event_value(
        &binding_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("routeEvents")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(route_result(
        &format!("Listed {count} capability route event(s)."),
        "capability_route_event_list",
        details,
    ))
}

pub(super) async fn capability_route_event_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let binding_deps = crate::domains::capability_binding::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::capability_binding::route::inspect_route_event_value(
        &binding_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(route_result(
        "Inspected capability route event.",
        "capability_route_event_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "capabilityBinding": details
        }),
    )
}

fn route_result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "capabilityRoute": details
        }),
    )
}

fn shadow_result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "capabilityShadowTrial": details
        }),
    )
}

fn cockpit_overview_content(details: &Value) -> String {
    let total = details
        .pointer("/summary/totalOperations")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let returned = details
        .pointer("/summary/returnedOperations")
        .and_then(Value::as_u64)
        .unwrap_or(total);
    let target_operation = details
        .pointer("/operationList/targetOperation")
        .and_then(Value::as_str);
    if let Some(target_operation) = target_operation {
        let operation = details.pointer("/operations/0");
        let shadow_runs = operation
            .and_then(|operation| operation.pointer("/shadowTrial/runs"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let evidence_refs = operation
            .and_then(|operation| operation.pointer("/shadowTrial/evidenceRefs"))
            .and_then(Value::as_array)
            .map_or(0, Vec::len);
        let active_routes = operation
            .and_then(|operation| operation.pointer("/route/activeRoutes"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let candidates = operation
            .and_then(|operation| operation.pointer("/route/candidates"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let bindings = operation
            .and_then(|operation| operation.pointer("/route/bindings"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let route_events = operation
            .and_then(|operation| operation.pointer("/route/routeEvents"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let next_steps = operation
            .and_then(|operation| operation.pointer("/agentPath/completion/governedNextSteps"))
            .and_then(Value::as_array)
            .map(|steps| governed_next_step_operations_text(steps))
            .unwrap_or_else(|| "No governed next-step operations are available.".to_owned());
        let evidence_counts = format!(
            "shadowEvidenceRefs={evidence_refs}; shadowRuns={shadow_runs}; replacementCandidates={candidates}; routeBindings={bindings}; activeRoutes={active_routes}; routeEvents={route_events}"
        );
        if evidence_refs > 0 {
            return format!(
                "Targeted cockpit for {target_operation}: currentScopeEvidence: {evidence_counts}. Final answer fields: stop-after-targeted-cockpit=false; inspect returned evidence refs only; capabilityRequestedMutation=false; engineAuditPersistence=true. Exact governed next-step operations: {next_steps}"
            );
        }
        return format!(
            "Targeted cockpit for {target_operation}: currentScopeEvidence: {evidence_counts}. Final answer fields: stop-after-targeted-cockpit=true; report no current-scope evidence; capabilityRequestedMutation=false; engineAuditPersistence=true. Exact governed next-step operations: {next_steps} Do not inspect evidence schemas without an exact evidence resource id, and do not invoke the target adapter unless the task requires its effect."
        );
    }
    if returned < total {
        return format!("Capability cockpit overview returned {returned} of {total} operation(s).");
    }
    format!("Capability cockpit overview returned {total} operation(s).")
}

fn governed_next_step_operations_text(steps: &[Value]) -> String {
    let operations = steps
        .iter()
        .filter_map(|step| step.get("operation").and_then(Value::as_str))
        .collect::<Vec<_>>();
    if operations.is_empty() {
        "No governed next-step operations are available.".to_owned()
    } else {
        operations.join(" -> ")
    }
}

fn cockpit_overview_result_details(details: Value) -> Value {
    if details
        .pointer("/operationList/targetOperation")
        .and_then(Value::as_str)
        .is_none()
    {
        return details;
    }
    let operation = details
        .pointer("/operations/0")
        .cloned()
        .unwrap_or(Value::Null);
    json!({
        "schemaVersion": details.get("schemaVersion").cloned().unwrap_or(Value::Null),
        "operation": details.get("operation").cloned().unwrap_or(Value::String("capability_binding_cockpit_overview".to_owned())),
        "summary": {
            "totalOperations": details.pointer("/summary/totalOperations").cloned().unwrap_or(Value::Null),
            "returnedOperations": details.pointer("/summary/returnedOperations").cloned().unwrap_or(Value::Null),
            "title": details.pointer("/summary/title").cloned().unwrap_or(Value::Null),
            "detail": details.pointer("/summary/detail").cloned().unwrap_or(Value::Null),
            "shadowRequests": details.pointer("/summary/shadowRequests").cloned().unwrap_or(Value::Null),
            "shadowRuns": details.pointer("/summary/shadowRuns").cloned().unwrap_or(Value::Null),
            "routeCandidates": details.pointer("/summary/routeCandidates").cloned().unwrap_or(Value::Null),
            "activeRoutes": details.pointer("/summary/activeRoutes").cloned().unwrap_or(Value::Null),
            "routeEvents": details.pointer("/summary/routeEvents").cloned().unwrap_or(Value::Null),
            "failedClosedRoutes": details.pointer("/summary/failedClosedRoutes").cloned().unwrap_or(Value::Null),
            "routeRollbacks": details.pointer("/summary/routeRollbacks").cloned().unwrap_or(Value::Null),
            "rollbackAvailable": details.pointer("/summary/rollbackAvailable").cloned().unwrap_or(Value::Null),
        },
        "operationList": details.get("operationList").cloned().unwrap_or(Value::Null),
        "resourceScan": details.get("resourceScan").cloned().unwrap_or(Value::Null),
        "operations": [operation.clone()],
        "target": {
            "name": operation.get("name").cloned().unwrap_or(Value::Null),
            "family": operation.get("family").cloned().unwrap_or(Value::Null),
            "familyLabel": operation.get("familyLabel").cloned().unwrap_or(Value::Null),
            "capabilityPool": operation.get("capabilityPool").cloned().unwrap_or(Value::Null),
            "agentUsage": operation.get("agentUsage").cloned().unwrap_or(Value::Null),
            "owner": operation.get("owner").cloned().unwrap_or(Value::Null),
            "status": operation.get("status").cloned().unwrap_or(Value::Null),
            "replacement": operation.get("replacement").cloned().unwrap_or(Value::Null),
            "readiness": operation.get("readiness").cloned().unwrap_or(Value::Null),
            "binding": operation.get("binding").cloned().unwrap_or(Value::Null),
            "shadowTrial": operation.get("shadowTrial").cloned().unwrap_or(Value::Null),
            "route": operation.get("route").cloned().unwrap_or(Value::Null),
            "rollback": operation.get("rollback").cloned().unwrap_or(Value::Null),
            "agentPath": operation.get("agentPath").cloned().unwrap_or(Value::Null),
        },
        "scope": details.get("scope").cloned().unwrap_or(Value::Null),
        "projection": details.get("projection").cloned().unwrap_or(Value::Null),
    })
}

#[cfg(test)]
mod tests {
    use super::{cockpit_overview_content, cockpit_overview_result_details};
    use serde_json::json;

    #[test]
    fn cockpit_overview_content_names_targeted_operation() {
        let details = json!({
            "summary": {
                "totalOperations": 190,
                "returnedOperations": 1
            },
            "operationList": {
                "filterApplied": true,
                "targetOperation": "git_status"
            },
            "operations": [{
                "shadowTrial": {
                    "runs": 0,
                    "evidenceRefs": []
                },
                "route": {
                    "candidates": 0,
                    "bindings": 0,
                    "activeRoutes": 0,
                    "routeEvents": 0
                },
                "agentPath": {
                    "completion": {
                        "governedNextSteps": [
                            {"operation": "capability_replacement_candidate_record"},
                            {"operation": "capability_shadow_trial_request_record"},
                            {"operation": "capability_shadow_trial_decision_record"},
                            {"operation": "capability_shadow_trial_run_record"},
                            {"operation": "capability_shadow_trial_evidence_inspect"},
                            {"operation": "capability_binding_request_record"},
                            {"operation": "capability_binding_decision_record"},
                            {"operation": "capability_binding_policy_activate"},
                            {"operation": "capability_route_binding_record"},
                            {"operation": "capability_route_activate"},
                            {"operation": "capability_route_event_list"}
                        ]
                    }
                }
            }]
        });

        assert_eq!(
            cockpit_overview_content(&details),
            "Targeted cockpit for git_status: currentScopeEvidence: shadowEvidenceRefs=0; shadowRuns=0; replacementCandidates=0; routeBindings=0; activeRoutes=0; routeEvents=0. Final answer fields: stop-after-targeted-cockpit=true; report no current-scope evidence; capabilityRequestedMutation=false; engineAuditPersistence=true. Exact governed next-step operations: capability_replacement_candidate_record -> capability_shadow_trial_request_record -> capability_shadow_trial_decision_record -> capability_shadow_trial_run_record -> capability_shadow_trial_evidence_inspect -> capability_binding_request_record -> capability_binding_decision_record -> capability_binding_policy_activate -> capability_route_binding_record -> capability_route_activate -> capability_route_event_list Do not inspect evidence schemas without an exact evidence resource id, and do not invoke the target adapter unless the task requires its effect."
        );
    }

    #[test]
    fn cockpit_overview_content_reports_truncated_operation_count() {
        let details = json!({
            "summary": {
                "totalOperations": 190,
                "returnedOperations": 25
            },
            "operationList": {
                "filterApplied": false
            }
        });

        assert_eq!(
            cockpit_overview_content(&details),
            "Capability cockpit overview returned 25 of 190 operation(s)."
        );
    }

    #[test]
    fn cockpit_overview_result_details_compacts_targeted_projection() {
        let details = json!({
            "schemaVersion": "tron.capability_binding.cockpit_visibility.v1",
            "operation": "capability_binding_cockpit_overview",
            "summary": {
                "totalOperations": 190,
                "returnedOperations": 1,
                "shadowRuns": 0,
                "routeCandidates": 0,
                "activeRoutes": 0
            },
            "operationList": {
                "targetOperation": "git_status",
                "filterApplied": true
            },
            "resourceScan": {
                "complete": true
            },
            "families": [{"family": "core"}],
            "routeStories": [{"operation": "git_status"}],
            "operations": [{
                "name": "git_status",
                "family": "git",
                "familyLabel": "Source control",
                "capabilityPool": {"audience": "session_work"},
                "agentUsage": {"effect": {"mode": "read_only"}},
                "owner": {"label": "Git"},
                "status": {"label": "Built-in"},
                "replacement": {"canReplace": true},
                "readiness": {"state": "idle"},
                "binding": {"requested": 0},
                "shadowTrial": {
                    "runs": 0,
                    "evidenceInspectReady": false,
                    "evidenceRefs": []
                },
                "route": {"activeRoutes": 0},
                "rollback": {"available": false},
                "agentPath": {"purpose": "Agent-native path"}
            }],
            "scope": {"exactScopeRequired": true},
            "projection": {"boundedItems": true}
        });

        let compact = cockpit_overview_result_details(details);

        assert!(compact.get("families").is_none());
        assert!(compact.get("routeStories").is_none());
        assert_eq!(
            compact["operations"].as_array().expect("operations").len(),
            1
        );
        assert_eq!(compact["operations"][0]["name"], "git_status");
        assert_eq!(compact["target"]["name"], "git_status");
        assert_eq!(
            compact["target"]["shadowTrial"]["evidenceInspectReady"],
            false
        );
        assert_eq!(
            compact["target"]["agentPath"]["purpose"],
            "Agent-native path"
        );
        assert_eq!(compact["operationList"]["targetOperation"], "git_status");
    }
}
