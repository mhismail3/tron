//! Operation binding for the system worker.

use super::{Deps, ping_value, system_diagnostics_value, system_info_value, system_shutdown_value};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "ping" => |invocation, _deps| {
            ping_value(Some(&invocation.payload))
        },
        "get_info" => |invocation, deps| {
            let allow_server_context = matches!(
                invocation.causal_context.actor_kind,
                crate::engine::ActorKind::Client
            );
            Ok(system_info_value(&invocation.payload, deps, allow_server_context))
        },
        "get_diagnostics" => |_invocation, deps| {
            system_diagnostics_value(deps)
        },
        "shutdown" => |_invocation, deps| {
            system_shutdown_value(deps).await
        },
    ];
}
