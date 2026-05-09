//! Operation binding for the browser worker.

use super::Deps;
use crate::domains::bindings::operation_bindings;
use serde_json::json;

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
