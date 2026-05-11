//! Operation binding for the agent worker.

use super::Deps;
use super::operations::*;
use crate::domains::bindings::operation_bindings;

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
        "prompt_queue_drain" => |invocation, deps| {
            prompt_queue_drain_value(Some(&invocation.payload), invocation, deps).await
        },
        "status" => |invocation, deps| {
            status_value(Some(&invocation.payload), deps).await
        },
        "abort" => |invocation, deps| {
            abort_value(Some(&invocation.payload), deps).await
        },
        "abort_tool" => |invocation, deps| {
            abort_tool_value(Some(&invocation.payload), deps).await
        },
        "queue_prompt" => |invocation, deps| {
            queue_prompt_value(Some(&invocation.payload), invocation, deps).await
        },
        "dequeue_prompt" => |invocation, deps| {
            dequeue_prompt_value(Some(&invocation.payload), invocation, deps).await
        },
        "clear_queue" => |invocation, deps| {
            clear_queue_value(Some(&invocation.payload), invocation, deps).await
        },
        "deliver_subagent_results" => |invocation, deps| {
            deliver_subagent_results_value(Some(&invocation.payload), deps).await
        },
        "submit_answers" => |invocation, deps| {
            submit_answers_value(Some(&invocation.payload), deps).await
        },
    ];
}
