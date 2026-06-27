//! Module install execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn module_install_request_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_install_deps = crate::domains::module_install::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_install::service::record_module_install_request_value_at(
        &module_install_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Module install review request recorded.",
        "module_install_request_record",
        details,
    ))
}

pub(super) async fn module_install_request_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_install_deps = crate::domains::module_install::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_install::service::list_module_install_request_value(
        &module_install_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("installRequests")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module install request(s)."),
        "module_install_request_list",
        details,
    ))
}

pub(super) async fn module_install_request_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_install_deps = crate::domains::module_install::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_install::service::inspect_module_install_request_value(
        &module_install_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected module install request.",
        "module_install_request_inspect",
        details,
    ))
}

pub(super) async fn module_install_decision_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_install_deps = crate::domains::module_install::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_install::service::record_module_install_decision_value_at(
        &module_install_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Module install decision recorded.",
        "module_install_decision_record",
        details,
    ))
}

pub(super) async fn module_install_decision_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_install_deps = crate::domains::module_install::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_install::service::list_module_install_decision_value(
        &module_install_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("installDecisions")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module install decision(s)."),
        "module_install_decision_list",
        details,
    ))
}

pub(super) async fn module_install_decision_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_install_deps = crate::domains::module_install::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_install::service::inspect_module_install_decision_value(
        &module_install_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected module install decision.",
        "module_install_decision_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "moduleInstall": details
        }),
    )
}
