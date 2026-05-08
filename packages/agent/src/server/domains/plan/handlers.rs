//! Operation binding for the plan worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "enter" => |invocation, deps| {
            plan_set_value(Some(&invocation.payload), deps, true)
        },
        "exit" => |invocation, deps| {
            plan_set_value(Some(&invocation.payload), deps, false)
        },
        "get_state" => |invocation, deps| {
            plan_get_state_value(Some(&invocation.payload), deps)
        },
    ];
}
