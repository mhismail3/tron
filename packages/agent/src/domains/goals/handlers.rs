use crate::domains::registration::bindings::operation_bindings;

use super::{Deps, service};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "create" => |invocation, deps| {
            service::goal_create_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "list" => |invocation, deps| {
            service::goal_list_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "inspect" => |invocation, deps| {
            service::goal_inspect_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "cancel" => |invocation, deps| {
            service::goal_cancel_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "question_create" => |invocation, deps| {
            service::question_create_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "question_list" => |invocation, deps| {
            service::question_list_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "question_inspect" => |invocation, deps| {
            service::question_inspect_value(&deps.engine_host, invocation, &invocation.payload).await
        },
        "question_answer" => |invocation, deps| {
            service::question_answer_value(&deps.engine_host, invocation, &invocation.payload).await
        },
    ];
}
