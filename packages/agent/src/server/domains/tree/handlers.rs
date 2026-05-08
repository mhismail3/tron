//! Operation binding for the tree worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get_visualization" => |invocation, deps| {
            get_visualization(&invocation.payload, deps).await
        },
        "get_branches" => |invocation, deps| {
            get_branches(&invocation.payload, deps).await
        },
        "get_subtree" => |invocation, deps| {
            get_subtree(&invocation.payload, deps).await
        },
        "get_ancestors" => |invocation, deps| {
            get_ancestors(&invocation.payload, deps).await
        },
        "compare_branches" => |invocation, _deps| {
            compare_branches(&invocation.payload).await
        },
    ];
}
