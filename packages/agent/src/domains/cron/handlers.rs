//! Operation binding for the cron worker.

use super::Deps;
use super::operations::*;
use crate::domains::bindings::operation_bindings;

operation_bindings! {
    deps = Deps;
    hidden = ["scheduled_fire"];
    bindings = [
        "list" => |invocation, deps| {
            cron_list_value(&invocation.payload, deps).await
        },
        "get" => |invocation, deps| {
            cron_get_value(&invocation.payload, deps).await
        },
        "create" => |invocation, deps| {
            cron_create_value(&invocation.payload, invocation, deps).await
        },
        "update" => |invocation, deps| {
            cron_update_value(&invocation.payload, invocation, deps).await
        },
        "delete" => |invocation, deps| {
            cron_delete_value(&invocation.payload, invocation, deps).await
        },
        "run" => |invocation, deps| {
            cron_run_value(&invocation.payload, invocation, deps).await
        },
        "status" => |_invocation, deps| {
            cron_status_value(deps).await
        },
        "get_runs" => |invocation, deps| {
            cron_get_runs_value(&invocation.payload, deps).await
        },
        "scheduled_fire" => |invocation, deps| {
            cron_scheduled_fire_value(&invocation.payload, invocation, deps).await
        },
    ];
}
