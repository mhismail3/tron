//! Import preview execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn import_preview_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let import_preview_deps = crate::domains::import_preview::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::import_preview::service::record_import_preview_record_value_at(
        &import_preview_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Import preview recorded.",
        "import_preview_record",
        details,
    ))
}

pub(super) async fn import_preview_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let import_preview_deps = crate::domains::import_preview::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::import_preview::service::list_import_preview_value(
        &import_preview_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} import preview(s)."),
        "import_preview_list",
        details,
    ))
}

pub(super) async fn import_preview_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let import_preview_deps = crate::domains::import_preview::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::import_preview::service::inspect_import_preview_value(
        &import_preview_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected import preview.",
        "import_preview_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "importPreview": details
        }),
    )
}
