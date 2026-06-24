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
