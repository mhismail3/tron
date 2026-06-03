//! Operation binding for the self-extension worker.

use super::{Deps, grant_workspace_autonomy};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "grant_workspace_autonomy" => |invocation, deps| {
            grant_workspace_autonomy(invocation, deps).await
        }
    ];
}
