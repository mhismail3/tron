//! Operation binding for the repo worker.

use super::{Deps, get_divergence, list_sessions};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list_sessions" => |invocation, deps| {
            list_sessions(&invocation.payload, deps).await
        },
        "get_divergence" => |invocation, deps| {
            get_divergence(&invocation.payload, deps).await
        },
    ];
}
