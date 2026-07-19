use crate::domains::registration::bindings::operation_bindings;
use crate::engine::EngineHostHandle;

use super::service;

operation_bindings! {
    deps = EngineHostHandle;
    hidden = [];
    bindings = [
        "search" => |invocation, engine_host| {
            service::search_catalog_value(engine_host, invocation, &invocation.payload).await
        },
        "inspect" => |invocation, engine_host| {
            service::inspect_catalog_value(engine_host, invocation, &invocation.payload).await
        },
        "conformance_report" => |invocation, engine_host| {
            service::conformance_report_value(engine_host, invocation, &invocation.payload).await
        },
    ];
}
