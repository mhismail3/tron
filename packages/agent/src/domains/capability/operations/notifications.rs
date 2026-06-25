//! Notification execute operation adapters.

use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn notification_send(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::notifications::service::send_notification_value(
        &notification_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Notification recorded.",
        "notification_send",
        details,
    ))
}

pub(super) async fn notification_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::notifications::service::list_notifications_value(
        &notification_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("notifications")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} notification(s)."),
        "notification_list",
        details,
    ))
}

pub(super) async fn notification_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::notifications::service::inspect_notification_value(
        &notification_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected notification.",
        "notification_inspect",
        details,
    ))
}

pub(super) async fn notification_mark_read(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::notifications::service::mark_notification_read_value(
        &notification_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Notification marked read.",
        "notification_mark_read",
        details,
    ))
}

pub(super) async fn notification_mark_all_read(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::notifications::service::mark_all_notifications_read_value(
        &notification_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Notifications marked read.",
        "notification_mark_all_read",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "notifications": details
        }),
    )
}
