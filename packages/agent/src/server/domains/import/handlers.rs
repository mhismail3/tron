//! Operation binding for the import worker.

use super::{Deps, execute_import, list_sessions, list_sources, preview_session};
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "list_sources" => |_invocation, deps| {
            list_sources(deps).await
        },
        "list_sessions" => |invocation, deps| {
            list_sessions(&invocation.payload, deps).await
        },
        "preview_session" => |invocation, deps| {
            preview_session(&invocation.payload, deps).await
        },
        "execute" => |invocation, deps| {
            execute_import(&invocation.payload, deps).await
        },
    ];
}
