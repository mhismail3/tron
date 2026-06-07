//! Operation binding for the capability worker.

use super::{Deps, execute_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "execute" => |invocation, deps| {
            execute_value(invocation, deps).await
        },
    ];
}
