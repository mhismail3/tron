//! Operation binding for the web worker.

use super::{Deps, web_fetch_value, web_search_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "fetch" => |invocation, deps| {
            web_fetch_value(Some(&invocation.payload), deps).await
        },
        "search" => |invocation, deps| {
            web_search_value(Some(&invocation.payload), deps).await
        },
    ];
}
