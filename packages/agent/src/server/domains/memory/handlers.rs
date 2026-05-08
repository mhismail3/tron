//! Operation binding for the memory worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "retain" => |invocation, deps| {
            operations::retain(&invocation.payload, deps).await
        },
    ];
}
