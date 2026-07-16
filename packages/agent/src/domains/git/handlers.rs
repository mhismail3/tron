use crate::domains::registration::bindings::operation_bindings;

use super::service;

operation_bindings! {
    deps = crate::engine::EngineHostHandle;
    hidden = [];
    bindings = [
        "status" => |invocation, _engine_host| {
            service::status_value(invocation, &invocation.payload).await
        },
        "diff" => |invocation, _engine_host| {
            service::diff_value(invocation, &invocation.payload).await
        },
        "stage" => |invocation, engine_host| {
            super::mutation::stage_value(engine_host, invocation, &invocation.payload).await
        },
        "unstage" => |invocation, engine_host| {
            super::mutation::unstage_value(engine_host, invocation, &invocation.payload).await
        },
    ];
}
