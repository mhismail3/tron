//! Web execute operation adapter.

use serde_json::json;

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn web_fetch(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_deps = crate::domains::web::Deps {
        engine_host: deps.engine_host.clone(),
        #[cfg(test)]
        dns_overrides: None,
    };
    let value =
        crate::domains::web::fetch::web_fetch_value(&web_deps, invocation, &invocation.payload)
            .await?;
    Ok(ok_result(
        format!(
            "Fetched source {}",
            value["webSourceResourceId"]
                .as_str()
                .unwrap_or("web_source")
        ),
        json!({
            "primitiveOperation": "web_fetch",
            "status": "ok",
            "web": value
        }),
    ))
}

pub(super) async fn web_robots_check(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_deps = crate::domains::web::Deps {
        engine_host: deps.engine_host.clone(),
        #[cfg(test)]
        dns_overrides: None,
    };
    let value = crate::domains::web::robots::web_robots_check_value(
        &web_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Checked robots policy {}",
            value["webRobotsPolicyResourceId"]
                .as_str()
                .unwrap_or("web_robots_policy")
        ),
        json!({
            "primitiveOperation": "web_robots_check",
            "status": "ok",
            "web": value
        }),
    ))
}

pub(super) async fn web_source_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_deps = crate::domains::web::Deps {
        engine_host: deps.engine_host.clone(),
        #[cfg(test)]
        dns_overrides: None,
    };
    let value = crate::domains::web::source::web_source_list_value(
        &web_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = value["sources"].as_array().map_or(0, Vec::len);
    Ok(ok_result(
        format!("Listed {count} web source(s)"),
        json!({
            "primitiveOperation": "web_source_list",
            "status": "ok",
            "web": value
        }),
    ))
}

pub(super) async fn web_source_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_deps = crate::domains::web::Deps {
        engine_host: deps.engine_host.clone(),
        #[cfg(test)]
        dns_overrides: None,
    };
    let value = crate::domains::web::source::web_source_inspect_value(
        &web_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Inspected source {}",
            value["source"]["resourceRefs"][0]["resourceId"]
                .as_str()
                .unwrap_or("web_source")
        ),
        json!({
            "primitiveOperation": "web_source_inspect",
            "status": "ok",
            "web": value
        }),
    ))
}

pub(super) async fn web_source_archive(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let web_deps = crate::domains::web::Deps {
        engine_host: deps.engine_host.clone(),
        #[cfg(test)]
        dns_overrides: None,
    };
    let value = crate::domains::web::archive::web_source_archive_value(
        &web_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Archived source {}",
            value["webSourceResourceId"]
                .as_str()
                .unwrap_or("web_source")
        ),
        json!({
            "primitiveOperation": "web_source_archive",
            "status": "ok",
            "web": value
        }),
    ))
}
