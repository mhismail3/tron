//! Operation binding for the capability worker.

use super::{
    Deps, audit_query_value, binding_list_value, binding_set_value, conformance_run_value,
    execute_value, implementation_set_state_value, inspect_value, plugin_inspect_value,
    plugin_install_value, plugin_list_value, plugin_promote_value, plugin_set_state_value,
    plugin_update_value, policy_get_value, policy_update_value, policy_validate_value,
    registry_snapshot_value, search_value, status_value,
};
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "search" => |invocation, deps| {
            search_value(invocation, deps).await
        },
        "inspect" => |invocation, deps| {
            inspect_value(invocation, deps).await
        },
        "execute" => |invocation, deps| {
            execute_value(invocation, deps).await
        },
        "status" => |invocation, deps| {
            status_value(invocation, deps).await
        },
        "registry_snapshot" => |invocation, deps| {
            registry_snapshot_value(invocation, deps).await
        },
        "audit_query" => |invocation, deps| {
            audit_query_value(invocation, deps).await
        },
        "binding_list" => |invocation, deps| {
            binding_list_value(invocation, deps).await
        },
        "binding_set" => |invocation, deps| {
            binding_set_value(invocation, deps).await
        },
        "plugin_list" => |invocation, deps| {
            plugin_list_value(invocation, deps).await
        },
        "plugin_inspect" => |invocation, deps| {
            plugin_inspect_value(invocation, deps).await
        },
        "plugin_install" => |invocation, deps| {
            plugin_install_value(invocation, deps).await
        },
        "plugin_update" => |invocation, deps| {
            plugin_update_value(invocation, deps).await
        },
        "plugin_set_state" => |invocation, deps| {
            plugin_set_state_value(invocation, deps).await
        },
        "plugin_promote" => |invocation, deps| {
            plugin_promote_value(invocation, deps).await
        },
        "conformance_run" => |invocation, deps| {
            conformance_run_value(invocation, deps).await
        },
        "implementation_set_state" => |invocation, deps| {
            implementation_set_state_value(invocation, deps).await
        },
        "policy_get" => |invocation, deps| {
            policy_get_value(invocation, deps).await
        },
        "policy_validate" => |invocation, deps| {
            policy_validate_value(invocation, deps).await
        },
        "policy_update" => |invocation, deps| {
            policy_update_value(invocation, deps).await
        },
    ];
}
