use crate::domains::registration::bindings::operation_bindings;
use crate::engine::EngineHostHandle;

use super::service;

operation_bindings! {
    deps = EngineHostHandle;
    hidden = [];
    bindings = [
        "request" => |invocation, engine_host| {
            service::request_approval_value(engine_host, invocation, &invocation.payload).await
        },
        "decide" => |invocation, engine_host| {
            service::decide_approval_value(engine_host, invocation, &invocation.payload).await
        },
        "check" => |invocation, engine_host| {
            service::check_approval_value(engine_host, &invocation.payload).await
        },
    ];
}
