//! Operation binding for the Codex App Server status worker.

use super::*;
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "status" => |_invocation, deps| {
            codex_app_status_value(deps).await
        },
    ];
}
