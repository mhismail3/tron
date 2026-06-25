//! Import-history execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn import_history_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let import_history_deps = crate::domains::import_history::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::import_history::service::record_import_history_value_at(
        &import_history_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Import/session graph lineage recorded.",
        "import_history_record",
        details,
    ))
}

pub(super) async fn import_history_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let import_history_deps = crate::domains::import_history::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::import_history::service::list_import_history_value(
        &import_history_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} import/session graph record(s)."),
        "import_history_list",
        details,
    ))
}

pub(super) async fn import_history_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let import_history_deps = crate::domains::import_history::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::import_history::service::inspect_import_history_value(
        &import_history_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected import/session graph lineage record.",
        "import_history_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "importHistory": details
        }),
    )
}
