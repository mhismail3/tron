//! Operation binding for the prompt library worker.

use super::{
    Deps, prompt_history_clear_value, prompt_history_delete_value, prompt_history_list_value,
    prompt_snippet_create_value, prompt_snippet_delete_value, prompt_snippet_get_value,
    prompt_snippet_list_value, prompt_snippet_update_value,
};
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "history_list" => |invocation, deps| {
            prompt_history_list_value(Some(&invocation.payload), deps).await
        },
        "history_delete" => |invocation, deps| {
            prompt_history_delete_value(Some(&invocation.payload), deps).await
        },
        "history_clear" => |_invocation, deps| {
            prompt_history_clear_value(deps).await
        },
        "snippet_list" => |_invocation, deps| {
            prompt_snippet_list_value(deps).await
        },
        "snippet_get" => |invocation, deps| {
            prompt_snippet_get_value(Some(&invocation.payload), deps).await
        },
        "snippet_create" => |invocation, deps| {
            prompt_snippet_create_value(Some(&invocation.payload), deps).await
        },
        "snippet_update" => |invocation, deps| {
            prompt_snippet_update_value(Some(&invocation.payload), deps).await
        },
        "snippet_delete" => |invocation, deps| {
            prompt_snippet_delete_value(Some(&invocation.payload), deps).await
        },
    ];
}
