//! Context-control execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn context_control_snapshot(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::snapshot_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context snapshot recorded.",
        "context_control_snapshot",
        details,
    ))
}

pub(super) async fn context_control_compact(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::compact_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context compaction action recorded.",
        "context_control_compact",
        details,
    ))
}

pub(super) async fn context_control_clear(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::clear_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context clear action recorded.",
        "context_control_clear",
        details,
    ))
}

pub(super) async fn context_control_action_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::action_list_value(
        &context_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .pointer("/projection/actions")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} context-control action(s)."),
        "context_control_action_list",
        details,
    ))
}

pub(super) async fn context_control_action_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::action_inspect_value(
        &context_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected context-control action.",
        "context_control_action_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "contextControl": details
        }),
    )
}
