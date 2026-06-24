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
    ];
}
