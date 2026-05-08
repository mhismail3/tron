//! Operation binding for the logs worker.

use super::{Deps, ingest_logs_value, recent_logs_value};
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "ingest" => |invocation, deps| {
            ingest_logs_value(Some(&invocation.payload), deps).await
        },
        "recent" => |invocation, deps| {
            recent_logs_value(Some(invocation.payload.clone()), deps).await
        },
    ];
}
