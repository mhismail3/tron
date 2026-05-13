//! Operation bindings for the program executor worker.

use super::{Deps, run_javascript_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "run_javascript" => |invocation, deps| {
            run_javascript_value(invocation, deps).await
        },
    ];
}
