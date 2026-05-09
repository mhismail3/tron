//! Operation binding for the message worker.

use super::{Deps, message_delete_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "delete" => |invocation, deps| {
            message_delete_value(&invocation.payload, deps).await
        },
    ];
}
