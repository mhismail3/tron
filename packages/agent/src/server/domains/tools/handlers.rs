//! Operation binding for the tool worker.

use super::operations::*;
use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "result" => |invocation, deps| {
            tool_result_value(&invocation.payload, deps).await
        },
    ];
}
