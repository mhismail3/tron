//! Operation binding for the display worker.

use super::{Deps, stop_stream};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "stop_stream" => |invocation, deps| {
            stop_stream(&invocation.payload, deps).await
        },
    ];
}
