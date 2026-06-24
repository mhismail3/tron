//! Operation binding for the read-only git worker.

use crate::domains::registration::bindings::operation_bindings;

use super::Deps;
use super::service::{diff_value, status_value};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "status" => |invocation, _deps| {
            status_value(&invocation, &invocation.payload).await
        },
        "diff" => |invocation, _deps| {
            diff_value(&invocation, &invocation.payload).await
        },
    ];
}
