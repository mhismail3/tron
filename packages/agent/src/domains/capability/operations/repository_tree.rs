//! Repository tree snapshot execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn repository_tree_snapshot(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let repository_tree_deps = crate::domains::repository_tree::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::repository_tree::service::record_repository_tree_snapshot_value_at(
            &repository_tree_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Repository tree snapshot recorded.",
        "repository_tree_snapshot",
        details,
    ))
}

pub(super) async fn repository_tree_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let repository_tree_deps = crate::domains::repository_tree::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::repository_tree::service::list_repository_tree_value(
        &repository_tree_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} repository tree snapshot(s)."),
        "repository_tree_list",
        details,
    ))
}

pub(super) async fn repository_tree_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let repository_tree_deps = crate::domains::repository_tree::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::repository_tree::service::inspect_repository_tree_value(
        &repository_tree_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected repository tree snapshot.",
        "repository_tree_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "repositoryTree": details
        }),
    )
}
