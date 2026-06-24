use serde_json::Value;

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;

use super::{Deps, service};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "search" => |invocation, deps| {
            search(invocation, deps).await
        },
        "inspect" => |invocation, deps| {
            inspect(invocation, deps).await
        },
        "conformance_report" => |invocation, deps| {
            conformance_report(invocation, deps).await
        },
    ];
}

async fn search(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    service::search_catalog_value(&deps.engine_host, invocation, &invocation.payload).await
}

async fn inspect(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    service::inspect_catalog_value(&deps.engine_host, invocation, &invocation.payload).await
}

async fn conformance_report(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    service::conformance_report_value(&deps.engine_host, invocation, &invocation.payload).await
}
