//! Operation binding for the blob worker.

use super::{Deps, blob_get_value};
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get" => |invocation, deps| {
            blob_get_value(&invocation.payload, deps).await
        },
    ];
}
