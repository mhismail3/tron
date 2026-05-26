//! Operation binding for the memory worker.

use super::Deps;
use crate::domains::bindings::operation_bindings;
use crate::domains::memory::operations;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "auto_retain_fire" => |invocation, deps| {
            operations::auto_retain_fire(invocation, deps).await
        },
        "retain" => |invocation, deps| {
            operations::retain(invocation, deps).await
        },
    ];
}
