//! Operation binding for the message worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "delete" => |invocation, deps| {
            message_delete_value(&invocation.payload, deps).await
        },
    ];
}
