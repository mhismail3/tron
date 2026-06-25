//! Media execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn media_create(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let media_deps = crate::domains::media::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::media::service::create_media_value_at(
        &media_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result("Media artifact recorded.", "media_create", details))
}

pub(super) async fn media_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let media_deps = crate::domains::media::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::media::service::list_media_value(
        &media_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("media")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} media artifact(s)."),
        "media_list",
        details,
    ))
}

pub(super) async fn media_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let media_deps = crate::domains::media::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::media::service::inspect_media_value(
        &media_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected media artifact.",
        "media_inspect",
        details,
    ))
}

pub(super) async fn media_archive(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let media_deps = crate::domains::media::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::media::service::archive_media_value_at(
        &media_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result("Archived media artifact.", "media_archive", details))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "media": details
        }),
    )
}
