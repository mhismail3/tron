//! Operation binding for the Codex App Server status worker.

use super::{Deps, codex_app_status_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "status" => |_invocation, deps| {
            codex_app_status_value(deps).await
        },
    ];
}
