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
