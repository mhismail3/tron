//! Operation binding for the browser worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get_status" => |_invocation, _deps| {
            Ok(json!({
                "running": false,
                "streaming": false,
            }))
        },
    ];
}
