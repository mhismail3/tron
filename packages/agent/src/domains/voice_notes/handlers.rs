//! Operation binding for the voice notes worker.

use super::{Deps, delete, list, save};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list" => |invocation, deps| {
            list(&invocation.payload, deps).await
        },
        "save" => |invocation, deps| {
            save(&invocation.payload, deps).await
        },
        "delete" => |invocation, deps| {
            delete(&invocation.payload, deps).await
        },
    ];
}
