//! Operation binding for the system worker.

use super::{
    Deps, ping_value, system_check_for_updates_value, system_diagnostics_value, system_info_value,
    system_shutdown_value, system_update_status_value,
};
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
        "get_update_status" => |_invocation, deps| {
            system_update_status_value(deps).await
        },
        "check_for_updates" => |_invocation, deps| {
            system_check_for_updates_value(deps).await
        },
        "shutdown" => |_invocation, deps| {
            system_shutdown_value(deps).await
        },
    ];
}
