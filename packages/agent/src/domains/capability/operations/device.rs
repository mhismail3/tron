//! Device execute operation adapters.

use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn device_register(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let device_deps = crate::domains::device::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::device::service::register_device_value(
        &device_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Device registration recorded.",
        "device_register",
        details,
    ))
}

pub(super) async fn device_unregister(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let device_deps = crate::domains::device::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::device::service::unregister_device_value(
        &device_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Device registration unregistered.",
        "device_unregister",
        details,
    ))
}

pub(super) async fn device_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let device_deps = crate::domains::device::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::device::service::list_devices_value(
        &device_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("devices")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} device registration(s)."),
        "device_list",
        details,
    ))
}

pub(super) async fn device_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let device_deps = crate::domains::device::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::device::service::inspect_device_value(
        &device_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected device registration.",
        "device_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "device": details
        }),
    )
}
