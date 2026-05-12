//! Operation binding for the capability worker.

use super::{Deps, execute_value, inspect_value, search_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "search" => |invocation, deps| {
            search_value(invocation, deps).await
        },
        "inspect" => |invocation, deps| {
            inspect_value(invocation, deps).await
        },
        "execute" => |invocation, deps| {
            execute_value(invocation, deps).await
        },
    ];
}
