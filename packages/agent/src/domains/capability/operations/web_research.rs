//! Web research execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn web_research_request_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::record_request_value_at(
        &web_research,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Web research request recorded.",
        "web_research_request_record",
        details,
    ))
}

pub(super) async fn web_research_request_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::list_request_value(
        &web_research,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("requests")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} web research request(s)."),
        "web_research_request_list",
        details,
    ))
}

pub(super) async fn web_research_request_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::inspect_request_value(
        &web_research,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected web research request.",
        "web_research_request_inspect",
        details,
    ))
}

pub(super) async fn web_research_review_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::record_review_value_at(
        &web_research,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Web research review recorded.",
        "web_research_review_record",
        details,
    ))
}

pub(super) async fn web_research_review_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::list_review_value(
        &web_research,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("reviews")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} web research review(s)."),
        "web_research_review_list",
        details,
    ))
}

pub(super) async fn web_research_review_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::inspect_review_value(
        &web_research,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected web research review.",
        "web_research_review_inspect",
        details,
    ))
}

pub(super) async fn web_research_source_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::record_source_value_at(
        &web_research,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Web research source artifact recorded.",
        "web_research_source_record",
        details,
    ))
}

pub(super) async fn web_research_source_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::list_source_value(
        &web_research,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("sources")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} web research source artifact(s)."),
        "web_research_source_list",
        details,
    ))
}

pub(super) async fn web_research_source_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_research = crate::domains::web_research::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::web_research::service::inspect_source_value(
        &web_research,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected web research source artifact.",
        "web_research_source_inspect",
        details,
    ))
}

fn result(summary: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        summary.to_owned(),
        json!({
            "primitiveOperation": operation,
            "details": details
        }),
    )
}
