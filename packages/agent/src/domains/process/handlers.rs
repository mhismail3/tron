//! Operation binding for the process worker.

use super::{Deps, process_run_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "run" => |invocation, deps| {
            process_run_value(invocation, deps).await
        },
    ];
}
