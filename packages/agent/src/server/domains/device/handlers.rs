//! Operation binding for the device worker.

use super::{Deps, register_token, respond, unregister_token};
use crate::server::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "register" => |invocation, deps| {
            register_token(&invocation.payload, deps).await
        },
        "unregister" => |invocation, deps| {
            unregister_token(&invocation.payload, deps).await
        },
        "respond" => |invocation, deps| {
            respond(&invocation.payload, deps).await
        },
    ];
}
