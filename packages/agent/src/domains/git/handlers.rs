use crate::domains::registration::bindings::operation_bindings;

use super::{Deps, service};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "status" => |invocation, _deps| {
            service::status_value(invocation, &invocation.payload).await
        },
        "diff" => |invocation, _deps| {
            service::diff_value(invocation, &invocation.payload).await
        },
        "stage" => |invocation, deps| {
            super::mutation::stage_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "unstage" => |invocation, deps| {
            super::mutation::unstage_value(&deps.engine_host, invocation, &invocation.payload).await
        },
    ];
}
