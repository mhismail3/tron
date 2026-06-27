//! Module dependency execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn module_dependency_request_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::record_module_dependency_request_value_at(
            &module_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Module dependency request recorded.",
        "module_dependency_request_record",
        details,
    ))
}

pub(super) async fn module_dependency_request_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::list_module_dependency_request_value(
            &module_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    let count = details
        .get("dependencyRequests")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module dependency request(s)."),
        "module_dependency_request_list",
        details,
    ))
}

pub(super) async fn module_dependency_request_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::inspect_module_dependency_request_value(
            &module_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(result(
        "Inspected module dependency request.",
        "module_dependency_request_inspect",
        details,
    ))
}

pub(super) async fn module_dependency_decision_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::record_module_dependency_decision_value_at(
            &module_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Module dependency decision recorded.",
        "module_dependency_decision_record",
        details,
    ))
}

pub(super) async fn module_dependency_decision_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::list_module_dependency_decision_value(
            &module_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    let count = details
        .get("dependencyDecisions")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module dependency decision(s)."),
        "module_dependency_decision_list",
        details,
    ))
}

pub(super) async fn module_dependency_decision_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::inspect_module_dependency_decision_value(
            &module_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(result(
        "Inspected module dependency decision.",
        "module_dependency_decision_inspect",
        details,
    ))
}

pub(super) async fn module_dependency_policy_activate(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::activate_module_dependency_policy_value_at(
            &module_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Module dependency policy activated.",
        "module_dependency_policy_activate",
        details,
    ))
}

pub(super) async fn module_dependency_policy_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::list_module_dependency_policy_value(
            &module_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    let count = details
        .get("dependencyPolicies")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module dependency policy record(s)."),
        "module_dependency_policy_list",
        details,
    ))
}

pub(super) async fn module_dependency_policy_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_deps = crate::domains::module_dependencies::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_dependencies::service::inspect_module_dependency_policy_value(
            &module_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(result(
        "Inspected module dependency policy.",
        "module_dependency_policy_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "moduleDependency": details
        }),
    )
}
