//! Prompt artifact execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn prompt_artifact_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let prompt_artifact_deps = crate::domains::prompt_artifacts::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::prompt_artifacts::service::record_prompt_artifact_value_at(
        &prompt_artifact_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Prompt artifact recorded.",
        "prompt_artifact_record",
        details,
    ))
}

pub(super) async fn prompt_artifact_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let prompt_artifact_deps = crate::domains::prompt_artifacts::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::prompt_artifacts::service::list_prompt_artifact_value(
        &prompt_artifact_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} prompt artifact(s)."),
        "prompt_artifact_list",
        details,
    ))
}

pub(super) async fn prompt_artifact_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let prompt_artifact_deps = crate::domains::prompt_artifacts::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::prompt_artifacts::service::inspect_prompt_artifact_value(
        &prompt_artifact_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected prompt artifact.",
        "prompt_artifact_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "promptArtifact": details
        }),
    )
}
