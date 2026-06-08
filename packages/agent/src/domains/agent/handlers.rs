//! Operation binding for the agent worker.

use super::Deps;
use super::prompt::*;
use crate::domains::registration::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "prompt" => |invocation, deps| {
            prompt_value(invocation, deps).await
        },
        "prompt_apply" => |invocation, deps| {
            prompt_apply_value(Some(&invocation.payload), invocation, deps).await
        },
        "run_turn" => |invocation, deps| {
            run_turn_value(Some(&invocation.payload), invocation, deps).await
        },
        "status" => |invocation, deps| {
            status_value(Some(&invocation.payload), deps).await
        },
        "abort" => |invocation, deps| {
            abort_value(Some(&invocation.payload), deps).await
        },
        "abort_invocation" => |invocation, deps| {
            abort_invocation_value(Some(&invocation.payload), deps).await
        },
    ];
}
