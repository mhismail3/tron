//! Operation binding for the memory worker.

use super::Deps;
use crate::server::domains::bindings::operation_bindings;
use crate::server::domains::memory::operations;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "retain" => |invocation, deps| {
            operations::retain(&invocation.payload, deps).await
        },
    ];
}
