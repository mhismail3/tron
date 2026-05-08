//! Operation binding for the memory worker.

use super::Deps;
use crate::server::domains::bindings::operation_bindings;
use crate::server::domains::memory::operations;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "auto_retain_fire" => |invocation, deps| {
            operations::auto_retain_fire(&invocation.payload, deps).await
        },
        "retain" => |invocation, deps| {
            operations::retain(&invocation.payload, deps).await
        },
    ];
}
