//! Notification execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn notification_send(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
        apns_runtime: deps.apns_runtime.clone(),
    };
    let details = crate::domains::notifications::service::send_notification_value_at(
        &notification_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    let content = notification_send_content(&details);
    Ok(result(&content, "notification_send", details))
}

pub(super) async fn notification_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
        apns_runtime: deps.apns_runtime.clone(),
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
        apns_runtime: deps.apns_runtime.clone(),
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
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
        apns_runtime: deps.apns_runtime.clone(),
    };
    let details = crate::domains::notifications::service::mark_notification_read_value_at(
        &notification_deps,
        invocation,
        &invocation.payload,
        operation_at,
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
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let notification_deps = crate::domains::notifications::Deps {
        engine_host: deps.engine_host.clone(),
        apns_runtime: deps.apns_runtime.clone(),
    };
    let details = crate::domains::notifications::service::mark_all_notifications_read_value_at(
        &notification_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Notifications marked read.",
        "notification_mark_all_read",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    let status = details
        .pointer("/delivery/status")
        .or_else(|| details.get("status"))
        .and_then(Value::as_str)
        .unwrap_or("ok");
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": status,
            "notifications": details
        }),
    )
}

fn notification_send_content(details: &Value) -> String {
    let status = details
        .pointer("/delivery/status")
        .and_then(Value::as_str)
        .unwrap_or("inbox_only");
    let delivered = details
        .pointer("/delivery/deliveredCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let not_delivered = details
        .pointer("/delivery/failedCount")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .saturating_add(
            details
                .pointer("/delivery/skippedCount")
                .and_then(Value::as_u64)
                .unwrap_or(0),
        );
    match status {
        "apns_accepted" => {
            format!("Notification recorded; APNs accepted push for {delivered} device(s).")
        }
        "partial" => format!(
            "Notification recorded; APNs accepted push for {delivered} device(s), while {not_delivered} delivery attempt(s) did not succeed. Inspect notifications.delivery.records before retrying."
        ),
        "failed" => format!(
            "Notification recorded, but push delivery failed for {not_delivered} device(s). Inspect notifications.delivery.records before retrying."
        ),
        "skipped" => "Notification recorded, but push was not attempted. Inspect notifications.delivery.records for the policy or configuration reason.".to_owned(),
        _ => "Notification recorded in the durable inbox; push was not requested.".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::notification_send_content;

    #[test]
    fn send_content_distinguishes_apns_acceptance_from_recording() {
        assert_eq!(
            notification_send_content(&json!({
                "delivery": {"status": "apns_accepted", "deliveredCount": 1}
            })),
            "Notification recorded; APNs accepted push for 1 device(s)."
        );
        assert_eq!(
            notification_send_content(&json!({
                "delivery": {"status": "skipped", "skippedCount": 1}
            })),
            "Notification recorded, but push was not attempted. Inspect notifications.delivery.records for the policy or configuration reason."
        );
        assert_eq!(
            notification_send_content(&json!({
                "delivery": {"status": "failed", "failedCount": 1}
            })),
            "Notification recorded, but push delivery failed for 1 device(s). Inspect notifications.delivery.records before retrying."
        );
    }
}
