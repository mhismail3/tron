//! Transport-only device registration operation binding.

use chrono::Utc;

use super::{Deps, service};
use crate::domains::registration::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "register" => |invocation, deps| {
            service::register_device_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "unregister" => |invocation, deps| {
            service::unregister_device_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
    ];
}
